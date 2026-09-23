# How Super works

Super runs two speech engines over every chunk of audio, merges their readings word by word, and asks Gemma to rule only on the chunks where the two engines disagree. Everything runs on the Mac.

![Super: audio in, pass 1 (two engines and a word vote), pass 2 (Gemma reads, then rules), finalize](img/super.svg)

## 01 · Audio in

A meeting recording has two tracks. The **mic track** is you, so anything on it is labelled "ME" without guessing. It first goes through an NLMS echo canceller that subtracts the far side's voice leaking from your speakers. The **system track** is everyone else, captured by the audio tap. Only the system track goes to the diarizer, which works out who among the others is speaking.

The chunker cuts each track into chunks of at most 28 s, cutting in silence where it can. Each chunk after the first repeats the last second of the one before it (the "recap"), so a word spoken across a cut is never lost. The mic and system chunks share one timeline.

The **engine pair** comes from Detail → RUN → MERGE A / MERGE B. The default is Parakeet v3 with Parakeet v2. Parakeet v2 only knows English, so in a non-English run it is replaced by Whisper large-v3, which then leads the pair. The referee is the local text engine, Gemma 4 on LiteRT, used in text mode only (its audio mode is not trusted).

Code: `TranscriptionRunner.run`, `AudioDecoder.chunk`, `EnsembleBackend.resolvePair`.

## 02 · Pass 1: every chunk, three in flight

Three chunks are in progress at any time. For each chunk:

1. **Silent?** If the loudest 200 ms of the chunk is below 0.005 RMS, neither engine runs and the chunk is empty. In a split-track meeting each track is silent while the other side talks, and Whisper used to spend about 2.3 s per silent chunk writing a phantom "you".
2. **Both engines, in parallel.** Each returns its text plus a confidence for every word. Whisper already drops subtitle sign-offs, and the stock lines it writes over the zero padding it adds to reach 30 s.
3. **Phantom check.** If one engine heard only a stock line ("Thank you", "Дякую") and the other heard silence, the line is dropped.
4. **Agreement.** A Dice score over the two word lists (1.0 means the same words).
5. **Word vote (ROVER).** The two word sequences are aligned, and every place they differ is decided by the rules in the diagram. The same word takes the trusted engine's spelling and punctuation. A word from your vocabulary wins. A Latin-script word from the trusted engine beats a native-script guess from the weak one. Otherwise the choice goes by confidence times a per-language prior (0.5 for an engine that is weak in this language). Stray extra words from the weak engine are dropped unless there are three or more in a row. The vote is pure CPU and takes milliseconds.

The runner then trims the recap repeat at the seam, drops a line that echoes the previous one, shows the voted text live, and stores the raw text from each engine plus the agreement score for pass 2.

**The inference gate.** LiteRT's Metal path hangs if another engine runs inference at the same moment. `InferenceGate` is a readers-writer lock: Whisper and Parakeet share it, so all six engine calls (three chunks, two engines) can overlap, while Gemma takes it exclusively and runs alone. A Gemma call that is waiting blocks new shared calls, so it can't be starved. Before v3.8.0 the gate was held whenever LiteRT was merely loaded, which made the whole first pass run one call at a time while Gemma sat idle.

Code: `EnsembleBackend.transcribeChunkRich`, `EnsembleBackend.roverMerge`, `WhisperBackend.transcribeDetailed`, `InferenceGate`.

## 03 · Pass 2: Gemma reads first, then rules

This pass runs only when **Max quality** is on (Settings). It exists because most chunks agree and never need context. Running pass 1 flat out and spending the slow judgment afterwards, where the engines actually fought, is faster and better informed than asking Gemma chunk by chunk.

1. **Read the whole thing.** Gemma reads the voted transcript in sections of about 3,000 tokens and writes a brief: topic, people, and names as spelled in this recording. It may also propose spelling fixes, which are kept only if they pass the guards in `MeetingBrief.swift` (the replacement already appears in the transcript, the two words sound alike, and so on). Larger reads were measured to hang LiteRT.
2. **Pick disputes.** Chunks with agreement below 0.8, the worst 10 at most.
3. **Gemma rules.** For each disputed chunk it sees both raw readings, the transcript before and after the chunk, your vocabulary, and the brief. It is told to choose between the readings and never to invent.
4. **Splice.** The ruling replaces the chunk's text. If a ruling takes more than 120 s, the chunk keeps its word vote.

With **Max quality off** there is no pass 2. A chunk with agreement below 0.5 goes to Gemma during pass 1, with only the text before it as context.

Code: `TranscriptionRunner.run` (max-quality second pass), `MeetingBriefBuilder`, `EnsembleBackend.arbitrate`.

## 04 · Finalize

The brief's guarded spelling fixes are applied. The echo scrub then finds lines from the system track that were heard again on your mic and keeps one copy. Speakers are assigned: mic lines are you, the diarizer's regions label the others, and names are picked up from the conversation. The result is saved as a new version of the transcript.

Code: `TranscriptionRunner.finalizeSegments`.

## If an engine hangs

Every chunk has a 120 s limit. After a timeout the engine is rebuilt and the chunk is retried. If it hangs again, the healthy engine transcribes the chunk alone. After two hangs in one run, Gemma is benched and the rest of the run uses a single engine, so the run still finishes.

## Where the time goes

On a 42-minute split-track meeting (v3.7.0), pass 1 took about 96% of the run and pass 2 about a minute. In v3.8.0 the engines overlap, silent chunks are skipped, and the low-confidence refine pass no longer runs for Super (its re-runs never changed the text). On a 6-minute slice this cut the run from 241 s to 183 s with the same words. Three Whisper large-v3 calls at once give about 1.5×, not 3×, because they compete for the same Neural Engine and GPU.

To measure a change on a real recording, see [Real-world regression check](../README.md#real-world-regression-check).
