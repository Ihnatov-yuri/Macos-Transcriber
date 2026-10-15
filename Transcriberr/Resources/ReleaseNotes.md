# Transcriberr release notes
#
# Shown in Transcriberr → About for the running version, and printed by
# scripts/release-notes.sh for the "What changed" part of the GitHub release.
# Every release adds its section at the top before it ships; the test suite
# fails when MARKETING_VERSION has no entry here. One user-facing line per
# change. The how and the learning belong in the GitHub release.

## 4.3.0
- Your corrections become a benchmark. Every line you fix is kept as a checked reference: its audio (all tracks of a meeting), the text you approved and what the engine first wrote. More ⋯ → Mark transcript as checked adds a whole transcript. It lives in Documents → Transcriberr Backups → benchmark, next to your transcript backups.
- Settings → Style & vocabulary → Your benchmark shows how much checked speech you have per language and how far the engine's text was from yours.

## 4.2.0
- Meetings start with what your calendar knows. Before a recording is transcribed, the invite it was made in (its title, the people invited and the names in its notes) becomes vocabulary for that run, together with the names that keep coming up in your earlier meetings with the same people. The recording's header shows which invite was used.
- Transcriberr asks for Calendar access when you start your first meeting recording. Only recordings made in the app use it (not imported, merged or split files). Turn it off in Settings → Engines → Use the meeting's calendar invite. Nothing leaves this Mac.

## 4.1.0
- Super shows where its two engines disagreed. Words they heard differently have a dotted underline; hover to see the other reading, click to use it instead, click again to switch back.
- Your choice teaches the app: when the engines split the same way again, Super picks what you picked. Names and terms you choose ("Kaiko", "KimKim") also join your vocabulary. Settings → Style & vocabulary → Your word choices lists every choice, and one click takes a wrong one back.

## 4.0.0
- Your voice print. Read a short passage aloud once (Settings → Audio input → Your voice) and meetings find you on the microphone by your voice instead of by how loud the mic is.
- On calls with headphones, nothing you said is removed for being quieter than the other person.
- On calls without headphones, the other person's voice leaking into your microphone is no longer written under your name, however clearly the mic heard it, and what you say while talking over someone stays.
- When the call sends your own voice back, those lines are recognised as yours: a repeat of what your mic already has is removed, anything else moves to your name.
- Recordings with one track (a recording made in the room, an imported file) name you too: the speaker who sounds like you gets your name instead of a number. When nobody clearly does, the speakers keep their numbers.
- Without a voice print, meetings work as before.
- More Whisper models: large-v3 turbo, compressed large-v3 and turbo, distil-large-v3 (English), medium and small. Pick one in Settings → Engines; download or delete them in Settings → Models. large-v3 stays the default.

## 3.17.4
- On calls with headphones, Super no longer deletes what you said. 3.17.1's filter for invented text could remove a quarter of your own words when the other person was louder than you; it now applies only when your microphone mostly picked up the speakers, and never to words the microphone heard clearly.

## 3.17.3
- While Super runs on a call without headphones, the live transcript no longer shows your side full of repeated words ("So. So. So.", "I'm going." over and over) and the other person's echo. It gets the same cleanup the finished transcript gets.

## 3.17.2
- Your answer no longer prints before the question it answers when Whisper adds a few words the other engine did not hear.
- Single echoed words of the other person ("architecture") no longer appear as lines of their own under your name, while a word you repeat after them stays.
- On calls without headphones, short garbled lines of echo under your name are removed.

## 3.17.1
- On calls without headphones, your side of the transcript keeps only what you actually said. Whisper no longer fills the quiet stretches of your microphone with invented sentences ("Hello, I'm Joe", "Welcome to the music hall") or repeated words ("Silence. Silence.").
- Short echoes of the other person ("We are", "have 17") no longer appear under your name and no longer stretch your line across their answer.
- Your own first words stay when the other person happens to say the same word at the same moment.

## 3.17.0
- Meeting transcripts read in the order things were said. Your replies sit after the question they answer, and the other side's sentences are no longer cut in half by your lines. Before, both sides came in 26-second blocks that overlapped.
- Several people on the other side of a call get separate turns. Before, everyone who spoke within the same 26 seconds was given one name.
- On calls without headphones, fewer of the other side's words show up under your name, and runs like "So. So. So." or "Silence. Silence." are removed from your side.
- Older meetings keep their transcript until you run Super on them again.

## 3.16.1
- Switching Live off and on again during a recording works: captions carry on below the earlier text. Before, they stopped for the rest of the recording.
- Live captions no longer stay empty when one reading of the audio gets stuck: a reading that takes longer than 10 seconds is dropped and the audio is read again.
- The live panel says "waiting for audio" until the first sound arrives, and live reconnects to the recording by itself if nothing arrives within 5 seconds.

## 3.16.0
- Live captions show the whole conversation while you record, not just the last few words. Text appears as it is spoken, in a lighter shade until the sentence is finished, and the panel keeps the newest line in view.
- Live captions work in meetings again, and switching Live on during a recording starts it straight away. Before, the switch only took effect from the next recording.
- Captions follow pauses in speech instead of cutting every five seconds, so words are no longer split in half.
- Super waits while you record. When meetings follow each other, the previous meeting's Super run no longer keeps three to four processor cores busy during the next call; it carries on as soon as you press Stop.
- The record screen uses less processor time while recording: the level meter no longer redraws the whole screen 30 times a second.

## 3.15.10
- Meeting playback no longer plays the other person twice when you use speakers instead of headphones. When the echo is too unsteady to cancel (a Bluetooth speaker, for example), your microphone is now muted while only the other side talks and opens again as soon as you speak. On two real calls the echo dropped from 8-10 dB to 20-24 dB below their voice.
- The old fallback let the full echo through whenever the speaker was loud.

## 3.15.9
- Super no longer freezes the Mac on long meetings. Whisper goes back to the Neural Engine, as before 3.13.0 (the GPU setting made two long runs freeze the screen).
- A chunk that Whisper keeps failing is given up after 100 seconds and Parakeet's reading is used, instead of the engine being rebuilt over and over and the chunk being lost. Whisper also retries a doubtful chunk twice instead of five times.
- A slow Whisper chunk is logged with how long it took and how many retries it needed.

## 3.15.8
- Closing the lid during a recording pauses it, and opening the lid carries on in the same recording. The record screen then says "Paused while your Mac slept" with the times.
- After a Super run, a short message on the recording says when Whisper first heard a different language than the one it transcribed in, for example "Whisper first heard Norwegian Nynorsk in 4 parts, and transcribed them as English."

## 3.15.7
- With two or more languages selected (for example English and Arabic), Super no longer reads English speech as Arabic. When Whisper's first guess was a language you had not selected, the choice between yours was effectively alphabetical. It now uses Whisper's real confidence for each of your languages.
- Arabic on Auto is now rescued from Whisper's Maltese and Persian guesses as 3.15.1 intended. The rescue never fired before.
- A cancelled transcription is now recorded in the log.

## 3.15.6
- Under-the-hood stability work: code that could be reached from two threads at once is now locked or kept on the main thread. The project builds with no compiler warnings, the first step towards Swift 6's data-race checking.

## 3.15.5
- Dictation held for another app expires after ten minutes, so old text no longer appears in a chat or document you have since moved on to. It is never pasted into a password field, and "scratch that" can take it back.
- Running the test suite next to the app no longer starts a second dictation hotkey, touches your library or writes into your log.

## 3.15.4
- Dictation you speak while you are in another app is no longer lost. Passages recognized while another app is in front wait for the app you started in and paste, in order, when you switch back to it.

## 3.15.3
- An idle Transcriberr no longer uses 15-30% of a CPU core: the pulsing dots on the Record, Dictate and Run transcription buttons stopped animating while nothing is running.

## 3.15.2
- Long recordings in a chosen pair of languages are again read window by window, so a recording that switches language keeps both.

## 3.15.1
- Arabic is no longer lost when the language is on Auto: Whisper's habit of calling it Maltese and spelling it in Latin letters is corrected, and Parakeet's Latin guesses no longer outvote a real Arabic reading. With two or more languages selected, Whisper now chooses only among those, never another language.

## 3.15.0
- A recording cut short by a crash is repaired on the next launch and comes back in the library as "Recovered recording" or "Recovered meeting".
- Unplugging the mic during a meeting now stops the meeting and saves everything recorded so far, instead of showing RECORDING over a dead device.
- The first words of a meeting are no longer muted by echo cancellation.
- When speaker detection fails, a transcript keeps its chunks instead of collapsing into one block.
- Password-field dictation types exactly what you said, with no added space or capital, and never lands in the Dictate pad or stays on the clipboard.
- OpenAI dictation works in German, French, Spanish, Italian, Portuguese and Polish.
- Update now waits if you start recording while it downloads, and a double click no longer starts two installs.
- Audio stops when you close or delete the recording that is playing.
- Merging a just-stopped recording waits for its compression, so the merge never reads a file being deleted.
- A merge lands in the folder of the recording you started it from.
- Cancel is honoured at once during Super arbitration, model downloads and transcription waits.
- Subtitle (SRT) times are rounded to the millisecond, and empty cues are left out.
- Downloaded models are left out of Time Machine backups; they download again on demand.
- API keys pasted with a trailing newline or space now work.
- The CLI: `kb help` works without a database, `kb search` takes several words, `--since` accepts a plain date, and the MCP server follows JSON-RPC more strictly.

## 3.14.3
- The same app as 3.14.2 under a new number, and the first release that installs itself: 3.14.2 updates to it with one button.

## 3.14.2
- Update installs a new version with one button, in the sidebar, in Settings, Updates, and in Check for Updates.
- The download is checked against a signature made with the author's own key before anything is installed, then the app reopens as the new version. Library, settings and permissions stay as they are.
- Update waits while you record or dictate. A running transcription starts again after the update.

## 3.14.1
- The same app as 3.14.0 under a new number, published so that 3.14.0 has a newer release to find and the update notice can be seen working.

## 3.14.0
- Transcriberr can tell you when a new version is out. It asks once, on first launch, and does nothing until you say yes.
- The check asks GitHub for the newest version number once a day and compares it on this Mac. The request is the same from every Mac and carries nothing about you.
- A notice in the sidebar links to the release page. Check for Updates in the app menu and Settings, Updates check by hand.
- About now shows what changed in this version, with links to the story of how the app was built and to ihnatov.nl.

## 3.13.1
- A stuck Whisper, Parakeet or Gemma engine now recovers on its own, without reloading the others.
- Transcript text appears in order while the first pass is still running, and chunks finished before a failure are kept.
- Background Super refinement carries on after the app restarts.
- Dictation into a password field is pasted and nothing else: no history, backups, preview or HUD text.
- The sidebar and the MCP server report the real app version.
- Smaller fixes to the meeting mix, mic downmix, waveform loading, Super text and folder splits.
