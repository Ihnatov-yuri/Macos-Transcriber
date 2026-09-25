# Transcriberr release notes
#
# Shown in Transcriberr → About for the running version, and printed by
# scripts/release-notes.sh for the "What changed" part of the GitHub release.
# Every release adds its section at the top before it ships; the test suite
# fails when MARKETING_VERSION has no entry here. One user-facing line per
# change. The how and the learning belong in the GitHub release.

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
