# Transcriberr release notes
#
# Shown in Transcriberr → About for the running version, and printed by
# scripts/release-notes.sh for the "What changed" part of the GitHub release.
# Every release adds its section at the top before it ships; the test suite
# fails when MARKETING_VERSION has no entry here. One user-facing line per
# change. The how and the learning belong in the GitHub release.

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
