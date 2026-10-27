# Transcriberr Microphone (virtual mic for calls)

Status: opt-in, off by default. Decided 2026-10-27.

## The problem

Apple's voice processing (VPIO, `VoiceProcessedMic`) on the built-in mic is
the only echo canceller that works on MacBook speakers (about 44 dB of echo
removed; ours, WebRTC AEC3 and DTLN-aec stop near 13 dB, probably because
the speakers' own DSP is not in the system-tap reference). But when our VPIO
starts next to standalone Teams, coreaudiod stops the mic, reopens it as the
raw 3-channel array and fails to rebuild Teams' per-app Voice Isolation chain
('ucfg', "Invalid primary stream", "DSPProcessor destroyed"). Teams' mic
then carries room noise for the rest of the call. v5.0.7 turned the filter
off by default.

The way out is the one Krisp uses: one process owns the real mic and runs
voice processing on it, and the call app takes its mic from a virtual input
device fed by that process. Nothing else opens the built-in mic, so there is
no Voice Isolation chain left to break, and the call and the recording both
get Apple's echo cancelling.

## How the virtual device exists

Options considered:

| Option | Verdict |
|---|---|
| BlackHole | Works today for a prototype, but GPL-3: cannot ship inside the app. |
| DriverKit audio driver (AudioDriverKit) | Needs a system extension entitlement from Apple and a Developer ID; releases here are ad-hoc signed. |
| Shared memory between the app and a plug-in | The plug-in runs in coreaudiod's sandboxed driver helper ("Core Audio Driver (X.driver)"); no clean way to share memory with an app without an XPC service and entitlements. |
| **Own AudioServerPlugIn with a loopback** | Chosen. Plain C, NullAudio-style, ours to ship. |

`MicDriver/TranscriberrMic.c` is a HAL plug-in with two devices that share
one ring buffer and one timeline:

- **Transcriberr Microphone**: input only, 48 kHz mono Float32. What the
  user picks as the call's microphone.
- **Transcriberr Mic Feed**: output only and hidden (`IsHidden`), found by
  UID. Transcriberr plays the cleaned mic into it.

Both devices take their zero time stamps from one anchor, so the feed's
output for sample time t is written before t and the microphone reads t
after it: about two IO buffers of delay, no drift between the two.

Installed in `/Library/Audio/Plug-Ins/HAL/TranscriberrMic.driver` from
Settings (admin password, then coreaudiod restarts, which interrupts all
sound for a second). The app ships the bundle in `Contents/Resources`.
`scripts/build-mic-driver.sh` builds it; `scripts/package.sh` signs it with
the app's identity (ad-hoc on this Mac).

Ad-hoc signing: third-party plug-ins load in a separate "Core Audio Driver"
helper process, not in coreaudiod itself, and on macOS 27.0.1 (26A434) it
accepts the ad-hoc-signed bundle: measured 2026-10-27, coreaudiod logged
"Attempting to load: TranscriberrMic.driver", started "Core Audio Driver
(TranscriberrMic.driver)", and the plug-in's own "loaded" line followed.

## When Transcriberr is not running

Designed deliberately: **the microphone device only exists while
Transcriberr feeds it.** The plug-in publishes "Transcriberr Microphone"
when the feed device's IO starts and withdraws it 3 s after the feed stops
(the grace covers a restart of the feed). A quit, a crash or a force-quit
all stop the feed, because coreaudiod stops IO for a client that goes away.
A call app that had the device selected then sees it disappear, the same as
an unplugged USB mic, and moves to another microphone, instead of sending
silence for the rest of the call.

Alternatives rejected: passing silence (a crash would mute the call with no
sign of why); passing the raw mic from inside the plug-in (a HAL plug-in
cannot be a Core Audio client itself).

Quitting Transcriberr while a call uses the device asks first.

If the feed falls behind for a moment, the microphone reads silence for
those samples, never stale ring contents.

## Inside the app

`VirtualMicrophone` (Audio/VirtualMicrophone.swift) runs while the setting is
on and the driver is installed:

- Always: the feed device's output IO, playing silence when there is
  nothing to send. This is what keeps the microphone device published.
- When a call uses the microphone (`DeviceIsRunningSomewhere` on it) or a
  meeting records: one `VoiceProcessedMic` on the real mic. Its cleaned
  samples go from an `AVAudioSinkNode` (one IO cycle at a time, not the
  ~100 ms tap deliveries) through a small ring into the feed.
- The meeting recorder borrows that same unit for its `.mic` track instead
  of starting a second one.
- Output switches to headphones: voice processing goes off on the same
  engine (no echo to remove, and no duck on other apps), the call keeps the
  raw mic, the recorder falls back to its own raw mic and the offline echo
  canceller. Back on speakers it comes on again.
- Recording stops while the call goes on: the unit stays for the call.
  Call ends and nothing records: the unit is released (lifts the duck).
- The meeting recorder's system-audio tap excludes Transcriberr's own
  process while this is on, so the feed (our own mic) never lands in the
  `.sys` track.
- The real mic is never the Transcriberr Microphone: `AudioInputDevices`
  leaves it out, and resolves a system default pointing at it to a real mic.

## Verification (no audio through the speakers)

- `log show --predicate 'process == "coreaudiod" OR process CONTAINS "Core Audio Driver"' ` and the plug-in's own subsystem
  `nl.ihnatov.Transcriberr.MicDriver`: loaded, feed started, microphone
  published / withdrawn.
- `transcriberrcli virtualmic [s]`: feeds a known tone into the feed device
  and records the Transcriberr Microphone at the same time, compared sample
  by sample on the shared timeline; also checks the device appears and goes
  away. Nothing plays on the speakers.
- `transcriberrcli virtualmic [s] --live`: the app's own path
  (`VirtualMicrophone`, voice processing on the real mic, sink, ring, feed),
  checked by level and gaps.
- Input from a shell is silent without the microphone permission (BlackHole
  gives the same -180 dBFS). Run the CLI as its own process so macOS asks
  for it: `launchctl submit -l nl.ihnatov.vmprobe -o out.txt -- <abs path>/transcriberrcli virtualmic 3`
  (then `launchctl remove nl.ihnatov.vmprobe`), signed with the identifier
  requirement `package.sh` uses.

Results 2026-10-27 (MacBook Pro speakers, Transcriberr 5.0.7 running):
tone back bit-exact (difference -180 dBFS, no silent samples), feed to
microphone 25 ms median with a 512-frame mic buffer; microphone published
0.05-0.26 s after the feed starts and gone within 4.5 s of it stopping.
Live path: -45.4 dBFS room level, no gaps, 1 underrun (priming), nothing
dropped.

Not verified here: the route switch to headphones mid-call, and Teams itself
on the device. That is the user's live test.
