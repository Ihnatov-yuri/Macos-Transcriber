// Transcriberr Microphone: a Core Audio HAL plug-in (AudioServerPlugIn)
// with two devices that share one ring buffer.
//
//   "Transcriberr Microphone"  input only, what a call app (Teams, Meet,
//                              Zoom) picks as its mic.
//   "Transcriberr Mic Feed"    output only and hidden. Transcriberr opens it
//                              by UID and plays its echo-cancelled mic into
//                              it; nothing else should ever see it.
//
// Why: Apple's voice processing (VPIO) on the built-in mic breaks the
// per-app Voice Isolation chain macOS builds for Teams (coreaudiod reopens
// the mic as the raw array and fails to rebuild Teams' DSP; Teams' mic
// drops to room noise). With this device only Transcriberr opens the real
// mic, and the call gets the same cleaned signal the recording does.
//
// When Transcriberr is not feeding, the microphone device does not exist:
// it is published only while the feed device's IO runs (plus a short grace
// so a restart of Transcriberr's feed does not flap it). A call app that
// had it selected sees the device go away, as with an unplugged USB mic,
// and falls back to another microphone instead of sending silence. If the
// feed falls behind for a moment the mic reads silence, never stale audio.
//
// Both devices run on one timeline (a shared zero time stamp anchored when
// the first of them starts IO), so the feed's output for sample time t is
// written before t and the microphone reads t after it: a round trip of
// about two IO buffers.
//
// Based on the structure of Apple's NullAudio sample; one fixed format
// (48 kHz, mono, Float32), no controls.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

// MARK: - Objects and constants

enum {
    kObjectID_PlugIn     = kAudioObjectPlugInObject,
    kObjectID_Mic        = 2,
    kObjectID_MicStream  = 3,
    kObjectID_Feed       = 4,
    kObjectID_FeedStream = 5,
};

#define kPlugInBundleID   "nl.ihnatov.Transcriberr.MicDriver"
#define kManufacturer     "Transcriberr"
#define kMicName          "Transcriberr Microphone"
#define kMicUID           "nl.ihnatov.Transcriberr.Microphone"
#define kFeedName         "Transcriberr Mic Feed"
#define kFeedUID          "nl.ihnatov.Transcriberr.MicFeed"
#define kModelUID         "nl.ihnatov.Transcriberr.MicModel"

static const Float64 kSampleRate       = 48000.0;
static const UInt32  kChannels         = 1;
static const UInt32  kRingFrames       = 16384;   // also the zero time stamp period
static const UInt32  kClockDomain      = 0x54724D63; // 'TrMc', shared by both devices
static const UInt32  kSafetyOffset     = 0;
static const UInt32  kLatency          = 0;
/// How long the microphone stays published after the feed stops.
static const int64_t kUnpublishGraceNs = 3 * NSEC_PER_SEC;

static os_log_t gLog;

// MARK: - State

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;

/// Clients doing IO, per device (under gStateMutex).
static UInt32 gMicIOCount = 0;
static UInt32 gFeedIOCount = 0;
/// The microphone device exists for clients (under gStateMutex).
static bool gMicPublished = false;
/// Bumped on every feed start/stop so a pending unpublish knows it is stale.
static UInt64 gFeedGeneration = 0;

/// Shared timeline (under gStateMutex; read on the IO threads, which only
/// run while it is set).
static UInt64 gAnchorHostTime = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gTimestampCount = 0;

/// The ring, indexed by sample time modulo kRingFrames. `gWrittenEnd` is
/// one past the newest sample time the feed wrote; the microphone reads
/// silence for anything at or beyond it, or older than a ring behind it.
static Float32 gRing[16384];
static _Atomic Float64 gWrittenEnd = 0;
static _Atomic bool gFeedLive = false;

// MARK: - Helpers

static Float64 HostTicksPerFrame(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1.0e9 * (Float64)tb.denom / (Float64)tb.numer;
    return ticksPerSecond / kSampleRate;
}

static void Notify(AudioObjectID object, AudioObjectPropertySelector selector) {
    if (gHost == NULL) return;
    AudioObjectPropertyAddress a = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    gHost->PropertiesChanged(gHost, object, 1, &a);
}

static void NotifyDeviceList(void) {
    if (gHost == NULL) return;
    AudioObjectPropertyAddress a[2] = {
        { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    gHost->PropertiesChanged(gHost, kObjectID_PlugIn, 2, a);
}

static bool IsDevice(AudioObjectID id) { return id == kObjectID_Mic || id == kObjectID_Feed; }
static bool IsStream(AudioObjectID id) { return id == kObjectID_MicStream || id == kObjectID_FeedStream; }

/// Objects a client may address: the microphone and its stream only while
/// published.
static bool IsKnown(AudioObjectID id) {
    if (id == kObjectID_PlugIn || id == kObjectID_Feed || id == kObjectID_FeedStream) return true;
    if (id == kObjectID_Mic || id == kObjectID_MicStream) {
        pthread_mutex_lock(&gStateMutex);
        bool p = gMicPublished;
        pthread_mutex_unlock(&gStateMutex);
        return p;
    }
    return false;
}

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4 * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static OSStatus WriteCFString(const char* s, UInt32 inSize, UInt32* outSize, void* outData) {
    if (inSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
    *(CFStringRef*)outData = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    *outSize = sizeof(CFStringRef);
    return noErr;
}

#define WRITE_SCALAR(type, value) \
    do { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
         *(type*)outData = (value); *outDataSize = sizeof(type); return noErr; } while (0)

// MARK: - Publishing the microphone

static void PublishMic(bool publish) {
    pthread_mutex_lock(&gStateMutex);
    bool changed = gMicPublished != publish;
    gMicPublished = publish;
    pthread_mutex_unlock(&gStateMutex);
    if (changed) {
        os_log(gLog, "microphone %{public}s", publish ? "published" : "withdrawn (feed stopped)");
        NotifyDeviceList();
    }
}

/// Called with gStateMutex held when the feed's last client stops.
static void ScheduleUnpublishLocked(void) {
    UInt64 generation = gFeedGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kUnpublishGraceNs),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        pthread_mutex_lock(&gStateMutex);
        bool stale = generation != gFeedGeneration || gFeedIOCount > 0;
        pthread_mutex_unlock(&gStateMutex);
        if (!stale) PublishMic(false);
    });
}

// MARK: - IUnknown

static HRESULT QueryInterface(void*, REFIID, LPVOID*);
static ULONG AddRef(void*);
static ULONG Release(void*);
static OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release,
    Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformDeviceConfigurationChange, AbortDeviceConfigurationChange,
    HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
    StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

/// The factory named in Info.plist.
void* TranscriberrMicFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID);
void* TranscriberrMicFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    (void)allocator;
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    if (gLog == NULL) gLog = os_log_create(kPlugInBundleID, "driver");
    return gDriverRef;
}

static HRESULT QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG r = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

// MARK: - Basic operations

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    gHostTicksPerFrame = HostTicksPerFrame();
    os_log(gLog, "loaded; microphone hidden until Transcriberr feeds it");
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return IsDevice(id) ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return IsDevice(id) ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)a; (void)i;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return IsDevice(id) ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)a; (void)i;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return IsDevice(id) ? noErr : kAudioHardwareBadObjectError;
}

// MARK: - Properties

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)pid;
    if (d != gDriverRef || a == NULL || !IsKnown(id)) return false;
    switch (id) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObjectID_Mic: case kObjectID_Feed:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
        case kAudioObjectPropertyControlList: case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo: case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        }
        return false;
    case kObjectID_MicStream: case kObjectID_FeedStream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out) {
    if (d != gDriverRef || a == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    // The rate and the formats can be "set" to the one value they have.
    *out = (a->mSelector == kAudioDevicePropertyNominalSampleRate
            || a->mSelector == kAudioStreamPropertyVirtualFormat
            || a->mSelector == kAudioStreamPropertyPhysicalFormat);
    return noErr;
}

/// Whether the device has a stream in the requested scope.
static bool DeviceHasScope(AudioObjectID dev, AudioObjectPropertyScope scope) {
    if (scope == kAudioObjectPropertyScopeGlobal) return true;
    if (dev == kObjectID_Mic) return scope == kAudioObjectPropertyScopeInput;
    return scope == kAudioObjectPropertyScopeOutput;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                    UInt32 qs, const void* q, UInt32* outSize) {
    (void)qs; (void)q;
    if (d != gDriverRef || a == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *outSize = sizeof(AudioClassID); return noErr;
    case kAudioObjectPropertyOwner: *outSize = sizeof(AudioObjectID); return noErr;
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID: *outSize = sizeof(CFStringRef); return noErr;
    case kAudioPlugInPropertyResourceBundle: *outSize = sizeof(CFStringRef); return noErr;
    case kAudioPlugInPropertyTranslateUIDToDevice: *outSize = sizeof(AudioObjectID); return noErr;
    case kAudioPlugInPropertyDeviceList: *outSize = (IsKnown(kObjectID_Mic) ? 2 : 1) * sizeof(AudioObjectID); return noErr;
    case kAudioObjectPropertyOwnedObjects:
        if (id == kObjectID_PlugIn) *outSize = (IsKnown(kObjectID_Mic) ? 2 : 1) * sizeof(AudioObjectID);
        else if (IsDevice(id)) *outSize = DeviceHasScope(id, a->mScope) ? sizeof(AudioObjectID) : 0;
        else *outSize = 0;
        return noErr;
    case kAudioDevicePropertyStreams: *outSize = DeviceHasScope(id, a->mScope) ? sizeof(AudioObjectID) : 0; return noErr;
    case kAudioObjectPropertyControlList: *outSize = 0; return noErr;
    case kAudioDevicePropertyRelatedDevices: *outSize = sizeof(AudioObjectID); return noErr;
    case kAudioDevicePropertyNominalSampleRate: *outSize = sizeof(Float64); return noErr;
    case kAudioDevicePropertyAvailableNominalSampleRates: *outSize = sizeof(AudioValueRange); return noErr;
    case kAudioDevicePropertyPreferredChannelsForStereo: *outSize = 2 * sizeof(UInt32); return noErr;
    case kAudioDevicePropertyPreferredChannelLayout: *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription); return noErr;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: *outSize = sizeof(AudioStreamBasicDescription); return noErr;
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: *outSize = sizeof(AudioStreamRangedDescription); return noErr;
    default: *outSize = sizeof(UInt32); return noErr;
    }
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qs, const void* q, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (d != gDriverRef || a == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    const bool isMic = id == kObjectID_Mic || id == kObjectID_MicStream;

    if (id == kObjectID_PlugIn) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE_SCALAR(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: WRITE_SCALAR(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: return WriteCFString(kManufacturer, inDataSize, outDataSize, outData);
        case kAudioPlugInPropertyResourceBundle: return WriteCFString("", inDataSize, outDataSize, outData);
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: {
            AudioObjectID list[2] = { kObjectID_Feed, kObjectID_Mic };
            UInt32 n = IsKnown(kObjectID_Mic) ? 2 : 1;
            UInt32 fit = inDataSize / sizeof(AudioObjectID);
            if (fit < n) n = fit;
            memcpy(outData, list, n * sizeof(AudioObjectID));
            *outDataSize = n * sizeof(AudioObjectID);
            return noErr;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qs < sizeof(CFStringRef) || q == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef*)q;
            AudioObjectID found = kAudioObjectUnknown;
            CFStringRef feed = CFSTR(kFeedUID), mic = CFSTR(kMicUID);
            if (uid != NULL && CFStringCompare(uid, feed, 0) == kCFCompareEqualTo) found = kObjectID_Feed;
            else if (uid != NULL && CFStringCompare(uid, mic, 0) == kCFCompareEqualTo && IsKnown(kObjectID_Mic)) found = kObjectID_Mic;
            WRITE_SCALAR(AudioObjectID, found);
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (IsDevice(id)) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE_SCALAR(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: WRITE_SCALAR(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName: return WriteCFString(isMic ? kMicName : kFeedName, inDataSize, outDataSize, outData);
        case kAudioObjectPropertyManufacturer: return WriteCFString(kManufacturer, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyDeviceUID: return WriteCFString(isMic ? kMicUID : kFeedUID, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyModelUID: return WriteCFString(kModelUID, inDataSize, outDataSize, outData);
        case kAudioDevicePropertyTransportType: WRITE_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: WRITE_SCALAR(AudioObjectID, id);
        case kAudioDevicePropertyClockDomain: WRITE_SCALAR(UInt32, kClockDomain);
        case kAudioDevicePropertyDeviceIsAlive: WRITE_SCALAR(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = (isMic ? gMicIOCount : gFeedIOCount) > 0;
            pthread_mutex_unlock(&gStateMutex);
            WRITE_SCALAR(UInt32, running);
        }
        // The microphone can be the system's default input (so apps set to
        // "default" can use it), never the alert/system sound device. The
        // feed is never a default anything.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: WRITE_SCALAR(UInt32, isMic ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: WRITE_SCALAR(UInt32, 0);
        case kAudioDevicePropertyLatency: WRITE_SCALAR(UInt32, kLatency);
        case kAudioDevicePropertySafetyOffset: WRITE_SCALAR(UInt32, kSafetyOffset);
        case kAudioDevicePropertyIsHidden: WRITE_SCALAR(UInt32, isMic ? 0 : 1);
        case kAudioDevicePropertyZeroTimeStampPeriod: WRITE_SCALAR(UInt32, kRingFrames);
        case kAudioDevicePropertyNominalSampleRate: WRITE_SCALAR(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            WRITE_SCALAR(AudioValueRange, r);
        }
        case kAudioObjectPropertyControlList: *outDataSize = 0; return noErr;
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams:
            if (!DeviceHasScope(id, a->mScope)) { *outDataSize = 0; return noErr; }
            WRITE_SCALAR(AudioObjectID, isMic ? kObjectID_MicStream : kObjectID_FeedStream);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 1;
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription);
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* l = (AudioChannelLayout*)outData;
            memset(l, 0, size);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = kChannels;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            *outDataSize = size;
            return noErr;
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (IsStream(id)) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: WRITE_SCALAR(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: WRITE_SCALAR(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: WRITE_SCALAR(AudioObjectID, isMic ? kObjectID_Mic : kObjectID_Feed);
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return noErr;
        case kAudioObjectPropertyName: return WriteCFString(isMic ? "Transcriberr Microphone" : "Transcriberr Mic Feed", inDataSize, outDataSize, outData);
        case kAudioStreamPropertyIsActive: WRITE_SCALAR(UInt32, 1);
        case kAudioStreamPropertyDirection: WRITE_SCALAR(UInt32, isMic ? 1 : 0);
        case kAudioStreamPropertyTerminalType: WRITE_SCALAR(UInt32, isMic ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: WRITE_SCALAR(UInt32, 1);
        case kAudioStreamPropertyLatency: WRITE_SCALAR(UInt32, kLatency);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            WRITE_SCALAR(AudioStreamBasicDescription, Format());
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r;
            r.mFormat = Format();
            r.mSampleRateRange.mMinimum = kSampleRate;
            r.mSampleRateRange.mMaximum = kSampleRate;
            WRITE_SCALAR(AudioStreamRangedDescription, r);
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    (void)q;
    return kAudioHardwareBadObjectError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qs, const void* q, UInt32 inDataSize, const void* inData) {
    (void)qs; (void)q;
    if (d != gDriverRef || a == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
        if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64*)inData == kSampleRate ? noErr : kAudioHardwareIllegalOperationError;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
        if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = inData;
        bool same = f->mSampleRate == kSampleRate && f->mFormatID == kAudioFormatLinearPCM
            && f->mChannelsPerFrame == kChannels && f->mBitsPerChannel == 32
            && (f->mFormatFlags & kAudioFormatFlagIsFloat);
        return same ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || !IsKnown(id) || !IsDevice(id)) return kAudioHardwareBadObjectError;
    bool feedStarted = false;
    pthread_mutex_lock(&gStateMutex);
    if (gMicIOCount == 0 && gFeedIOCount == 0) {
        gAnchorHostTime = mach_absolute_time();
        gTimestampCount = 0;
        atomic_store(&gWrittenEnd, 0);
    }
    if (id == kObjectID_Mic) {
        gMicIOCount++;
    } else {
        gFeedGeneration++;
        if (gFeedIOCount++ == 0) feedStarted = true;
        atomic_store(&gFeedLive, true);
    }
    bool micRunningChanged = id == kObjectID_Mic && gMicIOCount == 1;
    pthread_mutex_unlock(&gStateMutex);
    if (feedStarted) { os_log(gLog, "feed started"); PublishMic(true); }
    Notify(id, kAudioDevicePropertyDeviceIsRunning);
    if (micRunningChanged) os_log(gLog, "microphone in use");
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || !IsDevice(id)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (id == kObjectID_Mic) {
        if (gMicIOCount > 0) gMicIOCount--;
    } else if (gFeedIOCount > 0) {
        gFeedGeneration++;
        if (--gFeedIOCount == 0) {
            atomic_store(&gFeedLive, false);
            os_log(gLog, "feed stopped");
            ScheduleUnpublishLocked();
        }
    }
    pthread_mutex_unlock(&gStateMutex);
    Notify(id, kAudioDevicePropertyDeviceIsRunning);
    return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client,
                                 Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)client;
    if (d != gDriverRef || !IsDevice(id)) return kAudioHardwareBadObjectError;
    // One timeline for both devices; whichever asks first advances it.
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * kRingFrames;
    UInt64 nextPeriodHost = gAnchorHostTime + (UInt64)((gTimestampCount + 1) * ticksPerPeriod);
    if (nextPeriodHost <= now) gTimestampCount++;
    *outSampleTime = (Float64)(gTimestampCount * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)(gTimestampCount * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op,
                                  Boolean* outWill, Boolean* outInPlace) {
    (void)client;
    if (d != gDriverRef || !IsDevice(id)) return kAudioHardwareBadObjectError;
    bool will = (id == kObjectID_Mic && op == kAudioServerPlugInIOOperationReadInput)
             || (id == kObjectID_Feed && op == kAudioServerPlugInIOOperationWriteMix);
    if (outWill) *outWill = will;
    if (outInPlace) *outInPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n,
                                 const AudioServerPlugInIOCycleInfo* info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && IsDevice(id)) ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n,
                               const AudioServerPlugInIOCycleInfo* info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && IsDevice(id)) ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client,
                              UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* info, void* main, void* secondary) {
    (void)stream; (void)client; (void)secondary;
    if (d != gDriverRef || !IsDevice(id) || main == NULL || info == NULL) return kAudioHardwareBadObjectError;
    Float32* buf = (Float32*)main;

    if (id == kObjectID_Feed && op == kAudioServerPlugInIOOperationWriteMix) {
        Float64 start = info->mOutputTime.mSampleTime;
        UInt64 t0 = (UInt64)start;
        for (UInt32 i = 0; i < frames; i++) gRing[(t0 + i) % kRingFrames] = buf[i];
        Float64 end = start + frames;
        if (end > atomic_load(&gWrittenEnd)) atomic_store(&gWrittenEnd, end);
        return noErr;
    }

    if (id == kObjectID_Mic && op == kAudioServerPlugInIOOperationReadInput) {
        Float64 start = info->mInputTime.mSampleTime;
        Float64 written = atomic_load(&gWrittenEnd);
        bool live = atomic_load(&gFeedLive);
        UInt64 t0 = (UInt64)(start < 0 ? 0 : start);
        for (UInt32 i = 0; i < frames; i++) {
            Float64 t = start + i;
            // Silence for what the feed has not written yet, and for what it
            // wrote more than a ring ago (it would have been overwritten).
            bool valid = live && t >= 0 && t < written && t >= written - kRingFrames;
            buf[i] = valid ? gRing[(t0 + i) % kRingFrames] : 0.0f;
        }
        return noErr;
    }
    return noErr;
}
