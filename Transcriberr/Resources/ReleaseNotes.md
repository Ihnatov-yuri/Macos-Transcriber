# Transcriberr release notes
#
# Shown in Transcriberr → About for the running version, and printed by
# scripts/release-notes.sh for the "What changed" part of the GitHub release.
# Every release adds its section at the top before it ships; the test suite
# fails when MARKETING_VERSION has no entry here. One user-facing line per
# change. The how and the learning belong in the GitHub release.

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
