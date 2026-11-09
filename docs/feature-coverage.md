# Feature coverage

Every user-visible feature of Transcriberr, where it lives in the code, and how it is verified. Three kinds of verification:

- **unit**: the logic is tested in `TranscriberrTests` (`xcodebuild test`, run by `.github/workflows/ci.yml` on every push).
- **CI-e2e**: `scripts/ci-e2e.sh` runs `transcriberrcli` on a GitHub macOS runner against speech made with `say` (`.github/workflows/e2e.yml`). Pushes run everything except Whisper and Gemma. Whisper, Super and Gemma run from *Run workflow*.
- **manual**: needs a microphone, Accessibility, Input Monitoring, screen or system-audio capture, the calendar, an admin password, a real library or a person clicking. The steps are in [the manual checklist](#manual-checklist) below.

The **Coverage** column describes the unit tests only. **UNIT** means the feature's logic has unit tests. **NONE** means it has none yet, although it could have. **NOT-AUTOMATABLE** means it cannot run on a CI runner, and the reason is given.

The e2e script prints one line per check (`PASS`, `FAIL` or `SKIP`, with a reason) and writes `results.tsv`. The workflow uploads the logs, audio and results as the `cli-e2e` artifact. Transcript checks are keyword-based: at least 60% of the content words of the sentence `say` spoke have to come back.

## Inventory

### Recording and meetings

| # | Feature | Where in code | Unit tests | Coverage | How verified |
|---|---|---|---|---|---|
| 1 | Record from the microphone, with clock and level | `Audio/WavRecorder.swift`, `UI/Record/RecordView.swift`, `UI/Record/RecordModel.swift` | none for capture | NOT-AUTOMATABLE: microphone permission | manual. CI-e2e checks that `record` exits with code 2 and a hint when the permission is missing, instead of hanging |
| 2 | Live captions while recording | `ASR/LiveTranscriber.swift` | `PipelineLogicTests.swift` (`LiveCaptionTests`): `testPauseAfterAPhraseClosesIt`, `testShortPauseKeepsThePhraseOpen`, `testUnbrokenSpeechClosesAtTheLimit`, `testRoomToneIsNotSpeech`, `testLiveFeedReachesEverySubscriber`, `testLiveFeedSurvivesAConsumerBeingCancelled` | UNIT | unit + manual (on screen) |
| 3 | Meeting mode: microphone and system audio on one clock, kept as two tracks | `Audio/MeetingRecorder.swift`, `Audio/VoiceProcessedMic.swift` | `FinalizeTests.swift`: `testTapChannelCountNeverMatchesTheMic`, `testTapBufferIndexFollowsChannelCountNotPosition`; `VoiceProcessedMicTests.swift` (all) | NOT-AUTOMATABLE: system-audio capture and microphone permissions | unit + manual. CI-e2e runs a split-track meeting (`meeting.wav` with `.mic.wav` and `.sys.wav`) through `run` |
| 4 | Echo removed after a meeting (NLMS canceller, voice-guided suppressor, rebuilt playback file) | `Audio/EchoCanceller.swift`, `Audio/EchoGate.swift`, `Audio/MeetingMixRebuilder.swift` | `CoreLogicTests.swift`: `testEchoCancellerRemovesEchoPreservesSpeech`, `testEchoCancellerSilencesEchoAndSurvivesDoubletalk`, `testEchoGateMutesEchoKeepsUser`, `testPlaybackMixGatesMicOnlyWhenEchoKept`, `testMicEchoDBSeparatesEchoDominatedMicFromTalkingUser`; `PipelineLogicTests.swift`: `testEchoCancellerHandlesLargeDelay`; `VoiceGuideTests.swift` (all) | UNIT | unit + CI-e2e (`aec`: the echo-only stretches must be ≥ 10 dB quieter and the user's speech within 6 dB; it writes `.aec.wav` and `.mix.wav`) |
| 5 | Sentence-level echo scrub (a line under your name that repeats the call) | `ASR/TranscriptHygiene.swift`, `ASR/TurnTiming.swift`, `ASR/TranscriptionRunner.swift` | `CoreLogicTests.swift`: `testEchoSentenceScrubbedFromMixedSegment`; `TranscriptHygieneTests.swift`: `testEchoRunIsDroppedFromMic`, `testEchoFilterKeepsSimultaneousShortReplies`; `TurnTimingTests.swift`: `testEchoedRunOnTheMicIsDropped`, `testUnalignedMicEchoIsDropped` | UNIT | unit + CI-e2e (split-track `run`: at most 34% of the call's words may show up under ME) |
| 6 | Apple echo filter switch (off by default, reset once in 5.1.4) | `UI/Settings/SettingsView.swift` (Audio input), `Audio/MeetingRecorder.swift` | `EchoFilterResetTests.swift` (all) | UNIT | unit + manual (effect on a real call) |
| 7 | Transcriberr Microphone virtual device for calls | `MicDriver/TranscriberrMic.c`, `Audio/VirtualMicrophone.swift`, `TranscriberrCLI/VirtualMicCommand.swift` | `VirtualMicrophoneTests.swift`: ring buffer, resampler, `testShellAndAppleScriptQuoting` | NOT-AUTOMATABLE: the driver install needs an admin password and coreaudiod | unit + manual. CI-e2e checks that `virtualmic` reports a missing driver |
| 8 | Calendar invite as meeting context (vocabulary, attendees) | `ASR/MeetingContext.swift`, `TranscriberrCLI/main.swift` `cmdContext` | `MeetingContextTests.swift` (all) | NOT-AUTOMATABLE: EventKit lookup needs calendar access | unit + CI-e2e (`context`: unreadable date returns 64, a window under 1 min returns 1, the lookup answers or is skipped) + manual |
| 9 | Background refinement with Super after a meeting's draft | `ASR/JobManager.swift`, `ASR/TranscriptionRunner.swift` | `PipelineLogicTests.swift`: `testSuperWaitsForTheRecordingToEnd`, `testNotRecordingDoesNotWait`; `RepositoryTests.swift`: `testPendingTaskKeepsBackgroundRefinementFlag`, `testRefinementSpliceIsSameTrackOnly` | UNIT | unit + manual |
| 10 | Crash recovery of recordings (WAV header repair, orphan import) | `Audio/WavRepair.swift` | `WavRepairTests.swift` (all) | UNIT | unit |
| 11 | Recordings and sidecar tracks stored as AAC | `Audio/AudioCompressor.swift` | `AudioCompressorTests.swift` (all) | UNIT | unit |
| 12 | Import audio files, several at once, or the sound of a video file as `.m4a` (Library open panel), and decode any format | `UI/Library/LibraryView.swift` (`NSOpenPanel`), `Audio/AudioDecoder.swift` | `RunGapTests.swift`: `testSixteenKilohertzMonoFlacDecodes`, `testUndecodableFileNamesBothReadersReasons` | UNIT | unit + CI-e2e (`decode` of AIFF, WAV 16k, WAV 44.1k, M4A and FLAC: the duration must match `afinfo`; a non-audio file exits 1) + manual (panel) |
| 13 | Offline noise suppression | `Audio/NoiseSuppressor.swift` | `CoreLogicTests.swift`: `testNoiseSuppressorSafeOnSilenceAndFinite` | UNIT | unit + CI-e2e (`noisesup`) |
| 14 | Microphone picker (Settings, menu bar) | `Audio/AudioInputDevices.swift`, `UI/Dictation/DictationMenu.swift` (`MicrophonePicker`) | none | NOT-AUTOMATABLE: needs real input devices | manual |

### Speech engines

| # | Feature | Where in code | Unit tests | Coverage | How verified |
|---|---|---|---|---|---|
| 15 | Parakeet v3 transcription, downloaded on first use | `ASR/Backends/ParakeetBackend.swift`, `TranscriberrCLI/main.swift` `cmdTranscribe` | `TranscriptJSONTests.swift` (word grouping) | UNIT | unit + CI-e2e (`transcribe` of WAV and M4A in English, `--language Ukrainian`, an unknown `--language` falls back to auto-detect) |
| 16 | `transcribe --json` with word timings | `ASR/TranscriptJSON.swift` | `TranscriptJSONTests.swift` (all) | UNIT | unit + CI-e2e (stdout is exactly one JSON document, keys, ordered word times inside the duration) |
| 17 | Parakeet UK engine and its daily Hugging Face update, checked against fingerprints | `ASR/ParakeetUKModel.swift`, `ASR/HFModelRelease.swift` | `ParakeetUKModelTests.swift` (all) | UNIT | unit + CI-e2e (`uk-model status`, `run … parakeet-uk Ukrainian`, which downloads and verifies the release) |
| 18 | Whisper large-v3 through WhisperKit; Whisper model per language | `ASR/Backends/WhisperBackend.swift`, `ASR/WhisperModels.swift`, `UI/Settings/WhisperModelsSection.swift` | `WhisperModelsTests.swift` (all), `WhisperGuardTests.swift` (all), `RunGapTests.swift`: `testSuperKeepsParakeetWhenWhisperRunsOutOfTimeAndAsksWhisperOnce` | UNIT | unit + CI-e2e when run from *Run workflow* (`whisper` en/uk, `whisperbench`, `whisperloop`, `run whisper-large-v3`) |
| 19 | Whisper UK for Ukrainian recordings | `ASR/WhisperUKModel.swift` | `WhisperModelsTests.swift`: `testWhisperUKOnlyServesUkrainianRuns`, `testWhisperUKReleaseNeedsEveryPartAndTheTokenizer`, `testModelFollowsTheRunsLanguage` | UNIT | unit + manual (the 1.6 GB download and a Ukrainian run) |
| 20 | Language probe on auto (five loudest windows, switches to Whisper UK) | `ASR/Backends/WhisperLanguageProbe.swift` | `WhisperModelsTests.swift`: `testOnlyAutoLanguageRunsAreProbed`, `testLanguageProbeTakesTheLoudestWindows`; `ArabicLanguageTests.swift` (all) | UNIT | unit + CI-e2e when run from *Run workflow* (`langid`: most windows must be `en` for English and `uk` for Ukrainian) |
| 21 | Super: two engines merged word by word (ROVER), Gemma as referee | `ASR/Backends/EnsembleBackend.swift`, `ASR/TranscriptHygiene.swift` | `CoreLogicTests.swift`: `testRoverPrefersHigherConfidence`, `testRoverLanguagePriorProtectsStrongEngine`, `testMergeLongerThanItsSourcesIsRejected`; `TranscriptHygieneTests.swift`: `testRover*`, `testVote*` | UNIT | unit + CI-e2e when run from *Run workflow* (`run … ensemble whisper-large-v3 parakeet-v3`, without a Gemma referee unless `gemma` is on) |
| 22 | Disputed words: see both readings, pick one, learned choices | `ASR/Disputes.swift`, `UI/Detail/DetailView.swift` (`transcriberr-dispute:` links), `UI/Settings/LearnedChoicesSection.swift` | `DisputeTests.swift` (all) | UNIT | unit + manual (clicking) |
| 23 | Local text models (Gemma 4 on MLX, Qwen3.5 on uzu): text generation, one generation at a time, idle release | `ASR/Backends/LocalTextBackend.swift`, `ASR/Backends/MLXTextBackend.swift`, `ASR/Backends/UzuTextBackend.swift` | `BackendRaceTests.swift` (`TextIdleReleaseTests`); `PipelineLogicTests.swift` (`GenerationQueueTests`); `FeatureCoverageTests.swift`: `testLocalTextIsNotASpeechEngine`, `testTextModelDefaultsFollowMemory` | UNIT | unit + CI-e2e with `gemma` on (`gentest`, `brief`) |
| 24 | Cloud engines (OpenAI, Anthropic, Gemini), off until a key is added | `ASR/Backends/OpenAIBackend.swift`, `AnthropicBackend.swift`, `GoogleGeminiBackend.swift`, `CloudRequests.swift`, `ASR/Stores/APIKeyStore.swift` | `BackendResponseTests.swift` (all), `CloudRequestTests.swift` (all: what each model is sent) | NOT-AUTOMATABLE: live calls need paid keys | unit (response parsing) + manual |
| 25 | Chunk windowing and a second pass on low-quality chunks | `ASR/TranscriptionRunner.swift`, `ASR/ChunkConfidence.swift` | `CoreLogicTests.swift`: `testWindowsRespectMaxAndSplitOversized`; `PipelineLogicTests.swift`: `testChunksNeverExceedEngineLimit`; `FeatureCoverageTests.swift`: `testChunkConfidence*` (new) | UNIT | unit |
| 26 | Hallucination guards (subtitle sign-offs, loops, script drift, seams) | `ASR/TranscriptHygiene.swift` | `TranscriptHygieneTests.swift`: `testPhantom*`, `testWhisperRejectReasons`, `testScriptDriftShare`, `testSeamTrim*`, `testSubtitleSignOffIsAlwaysRejected`; `CoreLogicTests.swift`: `testNearDuplicate*` | UNIT | unit |
| 27 | Gemma downloads in Settings › Models (progress, cancel, SHA-256 check) | `ASR/ModelDownloader.swift`, `ASR/ModelCatalog.swift`, `UI/Settings/SettingsView.swift` (`ModelsSettingsTab`) | `FeatureCoverageTests.swift`: `testModelCatalogEntriesArePinnedAndVerifiable` (new) | UNIT | unit + CI-e2e with `gemma` on (download and SHA-256 against the catalog) + manual (progress and cancel) |
| 28 | Models kept in Application Support, excluded from Time Machine | `ASR/ModelCatalog.swift` (`durableModelsDirectory`, `excludeModelsFromBackup`) | none | NONE | not verified |

### Speakers and people

| # | Feature | Where in code | Unit tests | Coverage | How verified |
|---|---|---|---|---|---|
| 29 | Speaker diarization (Nemotron, offline fallback, scraps folded) | `ASR/DiarizationRunner.swift` | `DiarizationEngineTests.swift` (all); `FinalizeTests.swift`: `testScrapClustersFoldIntoTheirNeighbours`, `testDiarFillAssignsFromRegions` | UNIT | unit + CI-e2e (`diarize`: two labels in the RTTM, and each voice's turns under one label; `superdiar`; `run` on two voices finds two speakers) |
| 30 | Speakers named from self-introductions and being addressed | `ASR/TranscriptionRunner.swift`, `ASR/DiarizationRunner.swift` | `PipelineLogicTests.swift`: `testSelfIntroductionEnglish`, `testSelfIntroductionUkrainian`, `testStoplistBlocksNonNames`, `testAddresseeRule*`; `FinalizeTests.swift`: `testFoldedClusterSelfIntroNamesTheSurvivor` | UNIT | unit |
| 31 | Turn timing and coalescing of a speaker's lines | `ASR/TurnTiming.swift` | `TurnTimingTests.swift` (all); `CoreLogicTests.swift`: `testCoalesce*` | UNIT | unit |
| 32 | Your voice print (enrollment, target-speaker timeline) | `Audio/Voiceprint.swift`, `UI/Settings/VoiceprintSection.swift`, `TranscriberrCLI/VoiceCommands.swift` | `VoiceprintTests.swift` (all), `KaldiFbankTests.swift` (all) | UNIT | unit + CI-e2e (`voice enroll`, `voice show`, `voice score`: the enrolled voice must score at least 0.10 above another voice) |
| 33 | High-accuracy voice model (SimAM ResNet100) and switching models | `Audio/VoiceModel.swift`, `UI/People/PeopleActions.swift` (`VoiceModelSwitcher`) | `KaldiFbankTests.swift`: `testEmbeddingsMatchPyTorch`; `PeopleV5Tests.swift`: `testSwitchingParksVoicesAndSwitchingBackRestoresThem`, `testSetRebuiltRefusesAnotherModelsVoice` | UNIT | unit + manual (the download) |
| 34 | People: remember a voice, name it in later recordings | `Audio/People.swift` | `PeopleTests.swift` (all), `PeopleV5Tests.swift`: `testADifferentVoiceIsNeverAddedToAPerson`, `testASampleCloserToSomeoneElseIsRefused`, `testTheUserIsNeverFiledUnderSomeoneElse` | UNIT | unit + manual |
| 35 | Person page: confidence, samples with their source, forget a sample, the odd sample marked | `Audio/PeopleConfidence.swift`, `UI/People/PersonPage.swift` | `PeopleTests.swift`: `testConfidenceGrowsWithTrainingAndWarnsOfACloseVoice`; `PeopleV5Tests.swift`: `testEachLearningIsASampleAndCanBeForgotten`, `testTheOddSampleIsTheOneUnlikeTheRest`, `testTheCapKeepsEverySampleInProportion` | UNIT | unit + manual |
| 36 | Find people, Improve from my recordings, Add person | `UI/People/PeopleActions.swift` (`LibraryPeopleScan`, `VoiceImprover`), `UI/Settings/PeopleSection.swift` | `PeopleV5Tests.swift`: `testOnlyClearMatchesFromEnoughSpeechAreLearnedFrom`, `testANewPersonNeedsRecordingsThatAgree`; `PeopleTests.swift`: `testCleanSpeech*` | NOT-AUTOMATABLE: needs a library of real recordings and the UI | unit (rules) + manual |
| 37 | "Was this them?" and "People you meet often" suggestions | `Audio/VoiceSuggestions.swift`, `UI/People/PeopleView.swift` | `VoiceSuggestionsTests.swift` (all); `PeopleV5Tests.swift`: `testAYesIsNotAskedAgain` | UNIT | unit + manual |
| 38 | Rename, merge and delete a person (rename reaches every recording and version) | `Audio/People.swift`, `Data/RecordingRepository.swift` | `PeopleV5Tests.swift`: `testRename*`, `testMergeJoinsVoicesAndHistory`, `testMergeRefusesTwoDifferentVoices`; `PeopleTests.swift`: `testRenameDeleteAndDeleteAll`, `testDeletingAPersonDeletesTheirBrief` | UNIT | unit |
| 39 | Person brief by Gemma (what they said, commitments, open questions, done marks) | `ASR/PersonBrief.swift`, `UI/People/PersonMeetings.swift` | `PersonBriefTests.swift` (all, model stubbed) | UNIT | unit + manual (real Gemma output) |
| 40 | How they speak, the You page, goals | `Data/SpeechMetrics.swift`, `Data/SpeechGoals.swift`, `UI/People/YouDashboard.swift`, `UI/People/SpeechCoachRunner.swift` | `SpeechCoachTests.swift` (all), `YouDashboardTests.swift` (all) | UNIT | unit + manual |
| 41 | Who is this? sheet, people row, Name them, Same person as… | `UI/Detail/DetailSheets.swift`, `Data/RecordingRepository.swift` | `RepositoryTests.swift`: `testSetSpeakerNamePersistsToMapAndSegments`, `testMergeSpeakers*`, `testTagLine*`; `PeopleV5Tests.swift`: `testSpeakerLabelDisplay`, `testSpeakerLabelPlaceholders`, `testSpeakersWithTheSameNameAreOnePerson` | UNIT | unit + manual |
| 42 | The invite helps name people (head start, last unnamed speaker) | `Audio/People.swift`, `ASR/MeetingContext.swift` | `PeopleV5Tests.swift` (`InviteNamesTests`): `testInviteNamesMatchSavedNames`, `testInvitedPersonGetsAHeadStart` | UNIT | unit |

### Transcripts, versions, presets and the library

| # | Feature | Where in code | Unit tests | Coverage | How verified |
|---|---|---|---|---|---|
| 43 | Transcript view: click a line to play from it, one line highlighted; playback speed (0.75× to 2×, remembered) and skip 15 s | `UI/Detail/DetailView.swift`, `UI/Detail/PlayerBar.swift`, `Audio/AudioPlayerController.swift`, `Audio/WaveformLoader.swift` | `AudioPlayerControllerTests.swift` (all, including `testRateCyclesWrapsAndPersists`) | UNIT | unit + manual |
| 44 | Clean reading text or exactly what was said | `ASR/TextDestutter.swift`, `ASR/TranscriptHygiene.swift` (`TranscriptStyle`) | `CoreLogicTests.swift`: `testStutterRunsCollapse`, `testPhraseEchoCollapses`, `testDeliberateRepeatsSurvive`; `TranscriptHygieneTests.swift`: `testCleanStyleDropsHesitationsKeepsTicWords`; `PipelineLogicTests.swift`: `testDestutter*` | UNIT | unit |
| 45 | Edit a line, mark a transcript checked, corrections kept as a benchmark | `Data/RecordingRepository.swift`, `ASR/Benchmark.swift`, `UI/Settings/BenchmarkSection.swift` | `RepositoryTests.swift`: `testCorrectSegmentSavesAndSkipsNoOps`; `BenchmarkTests.swift` (all) | UNIT | unit + CI-e2e (`bench`: an empty set, a checked line at exactly 20.0% WER, and `bench score parakeet-v3` at 40% WER or less) |
| 46 | Versions: every run kept, compare, restore | `Data/RecordingRepository.swift` (`snapshotVersion`), `UI/Detail/DetailView.swift` | `RepositoryTests.swift`: `testSnapshotDedupsAndRestores`, `testSnapshotDoesNotDedupAcrossRecordings`, `testRestoreKeepsHandEditsAsAVersion` | UNIT | unit + manual |
| 47 | Presets: edit, duplicate, reorder, add, restore built-ins | `ASR/Stores/PresetStore.swift`, `UI/Settings/SettingsView.swift` (`PresetsSettingsTab`) | `PresetStoreTests.swift` (all) | UNIT | unit |
| 48 | Output and prompt history (restore an earlier output or prompt) | `Data/RecordingRepository.swift`, `ASR/Stores/PresetStore.swift` | `OutputHistoryTests.swift`: `testGenerateKeepsEarlierOutputs`, `testRestoreSwapsBackAndAddsNoCopies`, `testPresetHistory*`, `testDeletedPresetCanBeBroughtBack` | UNIT | unit |
| 49 | Running a preset with Gemma (deterministic pre-pass, long transcripts in sections) | `ASR/PostProcessor.swift` | `MeetingBriefTests.swift`: `testSectionsSplitOnlyWhenOverBudget` | UNIT | unit + CI-e2e with `gemma` on (`gentest`) + manual |
| 50 | Snippets (`{snippet:name}`) in preset templates | `ASR/Stores/SnippetStore.swift`, `UI/Settings/SettingsView.swift` (`SnippetsSettingsTab`) | `FeatureCoverageTests.swift`: `testSnippetsAreSubstitutedAndPersisted` (new) | UNIT | unit |
| 51 | Automatic titles, and missed default titles renamed at launch | `ASR/AutoTitle.swift` | `AutoTitleTests.swift` (all, including `AutoTitleDefaultTitleTests`) | UNIT | unit |
| 52 | Recording brief: Gemma reads the whole transcript first and proposes spellings | `ASR/MeetingBrief.swift` | `MeetingBriefTests.swift` (all) | UNIT | unit + CI-e2e with `gemma` on (`brief`) |
| 53 | Vocabulary, global and per language, fed to the engines and presets | `ASR/Stores/PromptStore.swift`, `ASR/TranscriptHygiene.swift` (`applyVocabulary`) | `TranscriptHygieneTests.swift`: `testJoinsSplitTerms`, `testRespellsNearMissOfCoinedTerm`, `testLeavesWordsNamesAndInflectionsAlone`; `DictationTextTests.swift`: `testVocabulary*` | UNIT | unit + CI-e2e (`vocab`: "Web RTC" and "Kim Kim" are joined, everything else is left alone) |
| 54 | Domain vocabulary packs (Medical, IT, Construction, Legal, Finance) | `ASR/DomainVocabulary.swift`, `Resources/Vocab/vocab.json` | `FeatureCoverageTests.swift`: `testDomainVocabularyPacksLoadFromTheAppBundle` (new) | UNIT | unit |
| 55 | Names harvested from the library offered as vocabulary | `Dictation/VocabularyHarvester.swift`, `UI/Settings/LearnedTermsSection.swift` | `DictationTextTests.swift` (`VocabularyHarvesterTests`): `testHarvest*`, `testCandidatesSkipSentenceInitialsButKeepRunsAndAcronyms` | UNIT | unit |
| 56 | Library search with the matches marked in the transcript (Previous, Next, Hide) | `UI/Library/LibraryView.swift`, `UI/Detail/SearchHighlight.swift` | `SearchHighlightTests.swift` (all) | UNIT | unit + manual |
| 57 | Folders and tags (create, rename, move, filter; "Dictation" is reserved) | `Data/RecordingRepository.swift`, `UI/Library/FolderTagUI.swift` | `FolderTagTests.swift` (all) | UNIT | unit |
| 58 | Merge recordings (picker, closest in time first) | `UI/Library/MergePickerSheet.swift`, `Data/RecordingRepository.swift` | `MergePickerTests.swift` (all); `RepositoryTests.swift`: `testMerge*` | UNIT | unit |
| 59 | Split a recording at a time | `UI/Detail/DetailSheets.swift` (`SplitRecordingSheet`), `Data/RecordingRepository.swift` | `RepositoryTests.swift`: `testSplit*` | UNIT | unit |
| 60 | Delete a recording or a version, after a confirmation | `Data/RecordingRepository.swift`, `UI/Detail/DetailView.swift` | `FolderTagTests.swift`: `testDeleteRecordingLeavesSharedOrganizersIntact`; `OutputHistoryTests.swift`: `testDeletingTheRecordingDeletesItsHistory`; `RepositoryTests.swift`: `testDeletingRecordingDropsItsPendingTask` | UNIT | unit + manual (the dialog) |
| 61 | Sidecars `.txt`, `.srt`, `.json`, `.speakers.json` (Android round trip), Re-export sidecars | `ASR/TranscriptExporter.swift` | `TranscriptExporterTests.swift` (all); `FeatureCoverageTests.swift`: `testTxtAndSpeakerSidecarsNextToTheAudio` (new) | UNIT | unit |
| 62 | Share › .txt / .srt / .json / .vtt / Markdown / audio, share the transcript as text | `UI/Detail/DetailView.swift` (share menu), `ASR/TranscriptExporter.swift` (`vttText`, `markdownText`) | `TranscriptExporterTests.swift`: `testVttHasHeaderDotMillisAndVoiceSpans`, `testMarkdownListsLinesWithTimeAndSpeaker` (the documents); the share sheet itself is NOT-AUTOMATABLE | UNIT | unit + manual (share sheet) |
| 63 | Export to a folder, with or without audio, with a checksummed manifest | `Data/RecordingFolderExporter.swift` | `OutputHistoryTests.swift`: `testExportWritesEverythingWithAManifest`, `testSafeFileNames` | UNIT | unit + manual |
| 64 | Transcript backups in ~/Documents/Transcriberr Backups, `restore-backups` | `Data/BackupService.swift`, `TranscriberrCLI/BackupCommands.swift` | `RepositoryTests.swift`: `testBackupShadowsRecordingVersionAndOutput`, `testBackupSurvivesRecordingDelete`, `testLiveAppendDoesNotBackupPerChunk` | UNIT | unit + CI-e2e (`restore-backups --dry-run` with no backups) + manual (a real restore) |
| 65 | Older stores open after an update | `Data/Schema.swift` | `StoreMigrationTests.swift` (all) | UNIT | unit |
| 66 | Per-recording Run sheet (engine, languages, diarization, speakers, translation) | `Data/Schema.swift` (`run*` fields), `UI/Detail/DetailSheets.swift` | `RepositoryTests.swift`: `testSplitPreservesSegmentLanguageAndRunSettings` | UNIT | unit + CI-e2e (`run` with engine, speakers and language) + manual |
| 67 | Translate to English | `ASR/TranscriptionRunner.swift` (`translateTo`) | none | NONE: `run` has no option for it, so it is untested | manual |
| 68 | A queued transcription survives quitting | `Data/Schema.swift` (`PendingTask`) | `RepositoryTests.swift`: `testPendingTaskRoundTripAndReplace` | UNIT | unit |
| 69 | Full RUN pipeline (decode, engine, diarization, finalize, hygiene) | `ASR/TranscriptionRunner.swift`, `TranscriberrCLI/main.swift` `cmdRun`, `cmdRefinalize` | `FinalizeTests.swift` (all) | UNIT | unit + CI-e2e (`run` on two voices and on a split-track meeting, `TRANSCRIBERR_DUMP_FINALIZE` with `refinalize` replaying it, and a hand-written dump) |

### Dictation

| # | Feature | Where in code | Unit tests | Coverage | How verified |
|---|---|---|---|---|---|
| 70 | Hold Right ⌥ to dictate, or tap mode with a paragraph per pause | `Dictation/HotkeyMonitor.swift`, `Dictation/DictationController.swift` | `CoreLogicTests.swift`: `testModifierIsDownSeparatesLeftAndRightTwins` | NOT-AUTOMATABLE: Accessibility, Input Monitoring, microphone | unit + manual |
| 71 | Text pasted at the cursor, clipboard put back | `Dictation/TextInserter.swift` | none | NOT-AUTOMATABLE: Accessibility and ⌘V into another app | manual |
| 72 | Spoken commands (EN, NL, DE, UK), "scratch that", self-corrections | `Dictation/DictationText.swift` | `DictationTextTests.swift`: `testPeriodAndParagraphCommands`, `testDutchGermanUkrainianCommands`, `testScratchPhrasesInAllLanguages`, `testSelfCorrections` | UNIT | unit |
| 73 | Per-app rules (verbatim, clean, smart Gemma pass) with the rewrite guard | `Dictation/DictationSettings.swift`, `Dictation/DictationContext.swift`, `UI/Settings/DictationSettingsTab.swift` | `DictationTextTests.swift`: `testAppRuleMatching`, `testPolishGuard*`, `testSmartGuard*`; `DictationContextTests`: `testContextToneAndLanguage` | UNIT | unit + manual |
| 74 | Automatic spacing from the text around the cursor; password fields never read | `Dictation/FocusedTextContext.swift` | `DictationTextTests.swift`: `testAutoSpacingFromContext`, `testInsertionSpacing`, `testJoinSpacingRules` | NOT-AUTOMATABLE: reading the field needs Accessibility | unit (spacing) + manual |
| 75 | Dictate screen: scratch pad, permission setup, last key event | `UI/Dictation/DictationView.swift` | none | NOT-AUTOMATABLE: UI and permissions | manual |
| 76 | Menu bar item (language, microphone) and floating status strip | `UI/Dictation/DictationMenu.swift`, `Dictation/DictationHUD.swift` | none | NOT-AUTOMATABLE: UI | manual |
| 77 | Shortcuts actions (Start, Stop & Insert, Toggle, Cancel) and Siri phrases | `Dictation/DictationIntents.swift` | none | NOT-AUTOMATABLE: needs the running app and the Shortcuts app | manual |
| 78 | URL scheme `transcriberr://dictate/start`, `/stop`, `/toggle`, `/cancel`, `/pane`, with its Settings switch | `Dictation/DictationController.swift` (`handle(url:)`), `App/TranscriberrApp.swift` (`onOpenURL`) | none (`scripts/dictation-e2e.sh` checks it on a Mac) | NOT-AUTOMATABLE: needs the running app and the microphone | manual (`scripts/dictation-e2e.sh`) |
| 79 | Dictation history kept in the Library | `Dictation/DictationController.swift`, `DictationSettings.keepHistory` | `FolderTagTests.swift`: `testDictationIsNotAFolderName` | NOT-AUTOMATABLE: a dictation needs the microphone | unit (folder rule) + manual |
| 80 | Live preview while speaking | `Dictation/DictationController.swift` (`livePreview`) | none | NOT-AUTOMATABLE: microphone and UI | manual |
| 81 | Speech gate, automatic gain, Apple voice processing for dictation | `Dictation/UtteranceCapture.swift`, `Audio/VoiceProcessedMic.swift` | `DictationTextTests.swift`: `testSpeechGate`, `testAutoGainBoostsQuietOnly`; `VoiceProcessedMicTests.swift` (all) | UNIT | unit |

### Knowledge base and AI assistants

| # | Feature | Where in code | Unit tests | Coverage | How verified |
|---|---|---|---|---|---|
| 82 | `kb list/search/get/outputs/folders/tags/stats` as Markdown, JSON or text | `Data/KBService.swift`, `Data/KBModels.swift`, `TranscriberrCLI/KBCommands.swift` | `KBServiceTests.swift` (all); `FeatureCoverageTests.swift`: `testKB*` (new: renderers, pagination footer, empty states, stats) | UNIT | unit + CI-e2e (`kb help`, usage exit 64, a missing library through `TRANSCRIBERR_STORE` and `--store` gives exit 1 with the message) |
| 83 | MCP server over stdio: six tools, protocol negotiation, JSON-RPC errors | `TranscriberrCLI/MCPServer.swift` | none (the CLI sources are not in the test target) | UNIT not possible, covered end to end | CI-e2e (`initialize`, version negotiation and fallback, `serverInfo.version` = `MARKETING_VERSION`, `tools/list` with schemas, a missing library as a tool error, unknown tool -32602, unknown method -32601, parse error -32700, invalid request -32600, no reply to a notification, string ids, a last request without a newline, exit at EOF, nothing but JSON on stdout) |
| 84 | MCP server restarts itself in place when the binary is updated | `TranscriberrCLI/MCPServer.swift` (`isStale`, `reexec`) | none | NONE | not verified |
| 85 | AI assistants switch (Settings › AI assistants) and last-read time | `Data/AssistantAccess.swift`, `UI/Settings/AssistantsSettingsSection.swift` | none | UNIT not possible: it reads the app's preferences domain | CI-e2e (switched off, `kb` exits 77 and MCP lists no tools and refuses calls; the setting is put back afterwards) + manual (the switch) |
| 86 | The library opened read-only, safe while the app runs | `Data/KBService.swift` | `KBServiceTests.swift`: `testReadOnlyContainerRejectsWrites`; `StoreMigrationTests.swift`: `testReadOnlyOpenWorksOnceTheAppHasMigrated` | UNIT | unit |
| 87 | Clean or verbatim transcripts for assistants (`style`) | `Data/KBModels.swift` (`styled`), `TranscriberrCLI/MCPServer.swift` | `FeatureCoverageTests.swift`: `testKBTranscriptStyleCleanAndVerbatim` (new); `TranscriptHygieneTests.swift`: `testCleanStyleDropsHesitationsKeepsTicWords` | UNIT | unit |

### Command-line maintenance tools

| # | Feature | Where in code | Unit tests | Coverage | How verified |
|---|---|---|---|---|---|
| 88 | `migrate-audio` (WAV to AAC for older recordings) | `TranscriberrCLI/MigrateAudioCommand.swift` | `AudioCompressorTests.swift` (the transcode) | NOT-AUTOMATABLE: needs a real library | unit (transcode) + CI-e2e (no library gives exit 1) + manual |
| 89 | `migrate-echo` (redo echo cancellation for old meetings) | `TranscriberrCLI/MigrateEchoCommand.swift` | none | NOT-AUTOMATABLE: needs a real library | CI-e2e (no library gives exit 1) + manual |
| 90 | `textbench` (speed and quality of the downloaded text models) | `TranscriberrCLI/TextModelCommands.swift` | none | NOT-AUTOMATABLE: needs downloaded text models | manual |
| 91 | `help` and command dispatch | `TranscriberrCLI/main.swift` (`usage`, `main`) | none | UNIT not possible | CI-e2e (all 16 documented commands listed, unknown command exits 64, missing argument exits 64) |

### App, updates, settings

| # | Feature | Where in code | Unit tests | Coverage | How verified |
|---|---|---|---|---|---|
| 92 | Update check against GitHub (asks once, then once a day) | `App/UpdateChecker.swift`, `UI/Settings/UpdatesSettingsTab.swift` | `UpdateCheckerTests.swift`: `testVersionOrdering`, `testOffUntilAnswered`, `testRequestCarriesNothingAboutTheUser`, `testParse*` | UNIT | unit + manual |
| 93 | Installs signed updates itself | `App/UpdateInstaller.swift` | `UpdateCheckerTests.swift` (`UpdateInstallerTests`): `testScriptSignatureVerifies`, `testSignatureRejectsAnyChange`, `testInstallableNeedsZipAndSignature`, `testBundleCheck`, `testRefusesToReplaceSomethingThatIsNotAnApp` | NOT-AUTOMATABLE: replacing the app in /Applications | unit + manual |
| 94 | About and What's new with the bundled release notes | `App/ReleaseNotes.swift`, `Resources/ReleaseNotes.md` | `UpdateCheckerTests.swift` (`ReleaseNotesTests`): `testCurrentVersionHasReleaseNotes`, `testParserReadsOnlyItsOwnSection` | UNIT | unit |
| 95 | Settings sections A to K, foldable | `UI/Settings/SettingsScreen.swift`, `UI/Settings/SettingsView.swift` | none (the settings themselves are covered in their own rows) | NOT-AUTOMATABLE: UI | manual |
| 96 | Bundled typefaces (Archivo, Schibsted Grotesk) | `Utility/FontLoader.swift`, `UI/Theme/Theme.swift` | `FeatureCoverageTests.swift`: `testBundledFontsAreRegistered` (new) | UNIT | unit |
| 97 | The text engine gives its memory back after 3 minutes idle or under memory pressure | `ASR/BackendFactory.swift` (`releaseTextIfQuiet`), `ASR/Backends/LocalTextBackend.swift` | `BackendRaceTests.swift`: `testIdleReleaseWaitsForTheQueue` | UNIT | unit |
| 98 | One text generation at a time, Whisper calls admitted in order | `ASR/Backends/LocalTextBackend.swift` (`GenerationQueue`), `ASR/Backends/WhisperBackend.swift` | `PipelineLogicTests.swift` (`GenerationQueueTests`, all); `WhisperGuardTests.swift`: `testLimiterAdmitsWaitersInOrder` | UNIT | unit + CI-e2e with `gemma` on (`gentest`: three concurrent generations, none empty) |
| 99 | No sleep during a run; a sleep gap is reported | `Utility/IdleAssertion.swift`, `ASR/TranscriptionRunner.swift` | `ArabicLanguageTests.swift`: `testSleepNoticeShowsTheGap` | UNIT | unit (the notice); the power assertion is not verified |
| 100 | File › Delete Recording… (⌘⌫), and ⌘⌫ in a text field | `App/TranscriberrApp.swift` | none | NOT-AUTOMATABLE: menu and keyboard | manual |

### Counts

- Features: 100.
- Coverage UNIT: 72. 9 of them (rows 23, 25, 27, 50, 54, 61, 82, 87 and 96) get their first unit test, or a new one, in `FeatureCoverageTests.swift`.
- Covered by `scripts/ci-e2e.sh`: 32 rows. A push runs 24 of them. Rows 18, 20 and 21 (Whisper, the language probe and Super) need `whisper` from *Run workflow*, and rows 23, 27, 49, 52 and 98 need `gemma`.
- CLI-only, so no unit test is possible and CI-e2e covers them: 3 (rows 83, 85 and 91).
- Coverage NONE (automatable but not tested yet): 3 (rows 28, 67 and 84).
- NOT-AUTOMATABLE: 22. Of these, 10 rest on the manual checklist alone: rows 14, 71, 75, 76, 77, 78, 80, 90, 95 and 100. The other 12 also have unit or CI-e2e checks on the part that can run headless.

## What CI-e2e does not prove

- The `kb` and MCP queries against a real library. The runner has no `Transcriberr.store`, and only the app creates one, so the CLI is checked for its error paths and protocol behaviour. `KBServiceTests` covers the queries against a seeded store.
- How fast the models run. The runner is a VM with no guaranteed Neural Engine or GPU, so CoreML may fall back to the CPU. The step timeouts are generous and the e2e checks test correctness only.
- Recognition of real speech. Transcripts are checked on `say` voices, which are cleaner than a meeting. `scripts/realworld-test.sh` and `scripts/eval-set.sh` cover real recordings on the owner's Mac.

## Manual checklist

Do these on an Apple Silicon Mac with macOS 26, using a build that passed CI. Each item names the matching row in the inventory.

1. **Recording (1, 2).** Library › New Recording, allow the microphone, speak for 20 s and stop.
   Expected: the clock runs and the level moves, a rough caption appears while you speak, and after Stop a draft transcript of what you said appears.
2. **Meeting mode (3, 4, 5, 9).** Start a meeting recording, then play a YouTube video of two people talking through the laptop speakers while you also talk. Stop after 2 minutes.
   Expected: the recording has a mic and a system track. Your lines are under your name, the video's voices are under Speaker N, none of the video's sentences appear under your name, and the file you play back has no audible echo of the video. With background refinement on, a Super version replaces the draft and the draft stays under versions.
3. **Apple echo filter (6).** Settings › Audio input: switch the echo filter on, record a meeting and stop.
   Expected: the switch stays on after relaunching. Switch it off again.
4. **Transcriberr Microphone (7).** Settings › Audio input › install the Transcriberr Microphone (admin password), then run `transcriberrcli virtualmic` with Transcriberr quit.
   Expected: `driver installed: true` and a level and delay for the probe tone. In a Teams or Zoom test call with "Transcriberr Microphone" chosen, the other side hears you. When you quit Transcriberr during the call, it asks first.
5. **Calendar invite (8, 42).** Create a calendar event now with two invitees, record a 2-minute meeting while it runs, and allow calendar access.
   Expected: the transcript header names the meeting, the invitees' names are spelled as in the invite, and Who is this? lists the invitees who are not named yet.
6. **Import and microphone picker (12, 14).** Library › import an .m4a file. Then pick another microphone in Settings and in the menu bar.
   Expected: the file transcribes, and the next recording uses the microphone you picked.
7. **Cloud engines (24).** Settings › API keys: add an OpenAI key, pick OpenAI in a recording's Run sheet, and run it.
   Expected: a transcript comes back. A person's page says their lines would be sent to the cloud engine.
8. **Whisper UK and the language probe (19, 20).** Run a Ukrainian recording with language on auto.
   Expected: on first use Whisper UK downloads (1.6 GB, with progress), and the version label names Whisper UK.
9. **Gemma models (27).** Settings › Models: download Gemma 4 E4B, cancel it halfway, then start it again.
   Expected: the progress moves, Cancel stops it, and the restarted download completes and is marked downloaded.
10. **People (33 to 41).** Name a speaker and choose Remember their voice. Record a second meeting with the same person.
    Expected: the person is named in the second meeting on their own. Their page shows a confidence level, the samples with their source, and Forget for a sample. Find people goes through the library. Rename the person and the new name shows up in both recordings. Read their meetings writes a brief whose items open the recording at the moment the thing was said. Settings › voice model: switching to High accuracy downloads the model and rebuilds the voices.
11. **Transcript UI (22, 43, 46, 56, 60, 62, 63).** Open a Super recording and click a line, then a highlighted disputed word. Restore an older version. Search the Library for a word and open the hit. Share › .srt. Share › Export to a folder, with audio. Delete a version.
    Expected: playback starts at that line and only that line is highlighted. The other reading replaces the word. The old version becomes current and the replaced one stays in the list. The search word is marked and Next steps through the matches. The share sheet offers the .srt. The folder holds the audio, the sidecars, every version and a manifest. Delete asks for confirmation first.
12. **Translate (67).** In a Dutch recording's Run sheet, choose Translate to English and run it.
    Expected: English text.
13. **Dictation (70 to 80).** Grant Microphone, Accessibility and Input Monitoring from the Dictate screen. In TextEdit, hold Right ⌥, say "hello comma this is a test period new paragraph second line", and let go. Then type a password into a password field and dictate.
    Expected: "Hello, this is a test." and "Second line" on a new paragraph. The clipboard holds what it held before. The menu bar item shows the state and the status strip appears while you speak. Nothing is read from the password field. With Keep history on, the passage is in Library › Dictation.
14. **Shortcuts and URL scheme (77, 78).** In Shortcuts, run Transcriberr › Toggle Dictation twice with speech in between. Then run `scripts/dictation-e2e.sh` from the repo. Switch off Settings › Dictation › Allow transcriberr://dictate links and run `open transcriberr://dictate/start`.
    Expected: the text is inserted. The script prints the recognized sentence. With links switched off, nothing starts.
15. **AI assistants (85).** Settings › AI assistants: switch it off, then ask Claude (with the MCP server configured) to list recordings. Switch it on again and ask again.
    Expected: refused while off, a list when on, and Settings shows the last-read time.
16. **Maintenance commands (88, 89, 90).** On a copy of a real library (`TRANSCRIBERR_STORE=<copy>`), with the app quit, run `transcriberrcli migrate-audio --dry-run`, `transcriberrcli migrate-echo --dry-run` and `transcriberrcli thinkab /tmp/thinkab`.
    Expected: each lists what it would do. thinkab writes its comparison.
17. **Updates (93).** Install the previous release, then Check for Updates….
    Expected: the new version is shown with its notes, Update installs it, and the app relaunches as the new version with the microphone and Accessibility grants still in place.
18. **Settings and menus (95, 100).** Fold and unfold each Settings section A to K. Select a recording and press ⌘⌫. Then press ⌘⌫ in a text field.
    Expected: each section folds and unfolds. ⌘⌫ on a recording asks before deleting it, and in a text field it deletes to the start of the line.
