# Transcriberr release notes
#
# Shown in Transcriberr → About for the running version, and printed by
# scripts/release-notes.sh for the "What changed" part of the GitHub release.
# Every release adds its section at the top before it ships; the test suite
# fails when MARKETING_VERSION has no entry here. One user-facing line per
# change. The how and the learning belong in the GitHub release.

## 5.1.3
- Open a recording the Library search found and the words you searched for are marked in its transcript. It scrolls to the first match, and a bar steps through the matching lines (Previous, Next, Hide).
- You → How you speak covers all your meetings, not the latest 30, so every language you speak in two meetings or more is in the menu (Ukrainian was missing). Recordings of under 80 words, such as microphone tests, no longer count as meetings.
- Goal charts show a dot per meeting since the goal was set, filled green when that meeting met it, with the goal line labelled and the first and last dates.
- The tiles say what each number measures, and "About these numbers" explains which meetings and lines count and how the language is decided.

## 5.1.2
- "Merge with…" opens a picker instead of a menu of every title: the recordings closest in time come first, each with its date, its distance from this one and its length, and you can search. Return only merges a recording you picked.
- With the Transcriberr Microphone on, recording a meeting no longer turns on Apple's echo filter by itself; it only shares the filter a call on the Transcriberr Microphone already uses. A call app still set to your Mac's microphone keeps working.
- If a call starts using the Transcriberr Microphone while a meeting records with its own echo filter, the call gets your plain microphone until the recording ends, instead of a second filter on the same mic.
- Sound you play from Transcriberr during a call stays in the recording again when the Transcriberr Microphone is off.
- Stopping a transcription while it removes echo stops it straight away.

## 5.1.1
- When no microphone is chosen in Transcriberr, the Transcriberr Microphone now opens the system default the usual way. It used to ask for that microphone by name, which some USB microphones (a webcam's, for one) refused, and it then fell back to the default anyway.

## 5.1.0
- Echo from the MacBook speakers is handled with your voice print. After a meeting, where the voice print says it is you, your words are never muted, including the start of a sentence; where it is clearly someone else's voice coming back through the speakers, the echo stays out. On the test calls about half the echo bursts are gone and fewer of your sentence starts are cut off. The voice print has to be enrolled, and it only applies to meetings transcribed from now on.
- New, off by default: the Transcriberr Microphone for calls (Settings → Audio Input). Transcriberr runs Apple's echo filter on your microphone and gives the cleaned sound to Teams, Meet or Zoom through its own microphone device, so the call and the recording both get echo-free audio without the two apps fighting over the mic. It needs a small audio driver, installed once from Settings with your admin password, and the call app's microphone set to "Transcriberr Microphone". If Transcriberr quits, the device goes away and the call app falls back to another microphone; quitting during a call asks first.
- The Settings window opened from the menu is readable again when macOS is in dark mode.

## 5.0.7
- The echo filter in meetings is off by default. With the call on the MacBook speakers it could silence your microphone in Teams, so the other people could not hear you, and the recording lost your voice as well. It can still be turned on in Settings, which now says what it can do to the call.
- When the echo filter is on and you connect AirPods or other headphones during a meeting, it now turns off for the rest of the recording instead of starting again.
- Transcriberr now builds with Swift's complete concurrency checking and no warnings. Recording, decoding, voice matching and downloads are marked to run off the main thread, so they keep the window responsive.

## 5.0.6
- The knowledge base tools (MCP and transcriberrcli kb) now say which calendar meeting a recording was matched to: its title, start and end time, and who else was invited.
- transcriberrcli keeps its Documents folder permission across updates, so macOS asks once instead of after every new build.

## 5.0.5
- When the GPU is busy and the text engine moves to the CPU, it now uses about 9 GB instead of growing past 100 GB, which could make the whole Mac swap. A request too long for the CPU engine fails with a message and is tried on the GPU again next time.
- ⌘⌫ in a text field deletes to the start of the line again. Choosing Delete Recording… from the menu still deletes the selected recording.

## 5.0.4
- Switching the voice model back after a stopped rebuild no longer leaves people with an empty voice. They are rebuilt from their recordings.
- Your own voice only learns from readings made with the built-in voice model, and the High accuracy model works through one batch at a time.
- Add person: closing the sheet or pressing Cancel while the microphone starts now stops it, and a double click starts it once.
- Improve from my recordings keeps the samples it learned while it ran and skips recordings that were transcribed again during the run.
- Forget on a voice sample asks first. A deleted person's page falls back to the overview.
- Person pages and the overview reload only when something they show changes, and briefs no longer show the same commitment or question twice. Talk share counts everyone who spoke.
- Naming missed recordings at launch skips dictation, checks each recording again just before naming it, and tries each one only once.
- The speaker sheet no longer repeats a Sounds like row, Open their page ends a step-through, and Same person as... updates the exported transcript file.
- Merging speakers with the same name waits for a running transcription to finish.
- When the text engine runs on the CPU, a slow answer gets four minutes before it is treated as stuck, and a stuck check never loads a second copy of the model next to it.
- A Parakeet UK update that was withdrawn on Hugging Face is never installed.

## 5.0.3
- Transcriberr gives back the memory its text engine used three minutes after the last use, whatever used it: people briefs, the speech coach, presets, titles or dictation polish. Before, it stayed loaded until the next transcription, often several gigabytes for hours.
- When the GPU is busy and the text engine falls back to the CPU, it now stays on the CPU for ten minutes instead of reloading the model for every request. Reading a person's meetings while the GPU was taken could load it a dozen times and use tens of gigabytes.
- Memory the engine freed is returned to macOS straight away, and the engine is released when macOS reports that memory is running low.

## 5.0.2
- The meeting's calendar invite now helps name people. A saved person who is on the invite is recognised a little more readily than someone who is not.
- In a call with up to three other people, when voices account for everyone but one speaker and one person on the invite, that speaker gets that person's name.
- Who is this? lists the people on the invite who are not named yet, so naming a speaker is one click.
- Name them says what it does: Name all 5, one by one. It opens Who is this? for each unnamed speaker in turn.

## 5.0.1
- Naming missed recordings at launch now only touches recordings that still have the name Transcriberr gave them ("Meeting" or "Recording" and a date). In 5.0.0 it also renamed last week's recordings that already had a name, and would have done so at every launch.

## 5.0.0
- People has its own place in the sidebar. Each saved person gets a page with every recording they speak in, how long they talked, and the last thing they said there. Click a recording to open it at their first line.
- Each page shows how sure Transcriberr is of finding that person, as a percentage and Learning, Good or Strong. It explains why: how much of their speech was learned and from how many recordings, how alike the samples are, how close they sound to anyone else saved (you included), and how clearly they matched lately.
- Improve from my recordings, on the page, picks the best of the meetings the person is already named in, takes their longest clean stretches, and keeps the result only if it makes them easier to tell apart. Recording them reading is still there, under Why this percentage. A voice keeps up to 120 samples taken from every recording in proportion, so one long meeting no longer pushes out the voice heard elsewhere. Every sample of their voice is listed with where it came from, and one that has someone else in it can be forgotten without starting over. The sample that sounds least like the rest is marked.
- When a speaker sounds like someone saved but not clearly enough to name, their page asks "Was this them?". Listen, then answer Yes to name the speaker and add the voice, or No so that speaker is not asked about again.
- Find people, on the new overview, listens to every recording you already have, names the people it is sure of and asks about the rest. Run it once after updating, and after training someone.
- Renaming a person renames them in every recording too, saved versions included. Two entries for the same person can be merged into one, with their voices and history.
- What they said, on each page, covers their last meeting, the last week or the last month. It opens with what they mainly said in each meeting, then what they committed to, the questions they left open, and their latest word on each topic. Something they promised again in a later meeting shows once, from the newest. Read their meetings reads the last month and always their latest meeting; Refresh reads only what is new. Each item opens the recording where it was said, can be marked done, and the chosen period can be copied as text. It uses your text engine; with a cloud engine the page says that their lines are sent to it.
- How they speak: talk share, pace, longest turn, questions and cutting in, measured from the transcripts over their last 10 meetings, and how the words split between them, you and others in meetings you share.
- The overview shows who you met most in the last 30 days, open commitments across everyone, and the voices waiting for you to confirm.
- People you meet often, on the overview, suggests who to add: voices that come back in at least 3 of your meetings in the last 90 days that sound like no one saved, and names you typed in several recordings that have no saved voice. Listen, type who it is and Save, and they are named in every one of those recordings with their voice learned from them. Find people collects these voices as it goes.
- You, at the top of People, measures how you speak in meetings: talk share (against a fair share, so a 1:1 and a group of six count alike), pace, longest turn, cutting in, questions, fillers and hedges, per language for English and Ukrainian. Your microphone's lines count as yours whatever name they carried. Speech engines leave many fillers out, so those read low.
- Set goals picks up to two things to work on from your last ten meetings, worded by your text engine with tips from your own lines. The numbers alone decide progress: a goal is reached when met in 3 of your last 4 meetings, rethought when it has not moved in 6 meetings or 3 weeks, and replaced after two rethinks. A reached or replaced goal rests three weeks before it can come back. The page says when a goal is due for an update; the text engine only runs when you click.
- Your own voice has the same confidence score, and Add a reading adds to it instead of starting over.
- Deleting a person also deletes what was read from their meetings, including a read still running.
- A voice is only ever added to a person when it clearly sounds like them: at least 0.45 like their saved voice and 0.10 more than like anyone else saved, you included. This holds for every way of training, Merge too, and a new person from several recordings uses only the recordings that agree.
- Add person finds the person for you: type a name and Transcriberr lists the recordings they are named in, then learns from the five with the most of their speech, using their longest clean stretches.
- Voices in meetings recorded with the call on its own track are learned and matched from that track. Before, your microphone's lines overlapped almost everyone else's, so their voices often could not be learned at all.
- Two speakers of one recording with the same name are one person: hand-tagged lines and a diarized speaker called the same are joined, so a meeting no longer shows two of the same name.
- People in a meeting are a row above the transcript: each speaker's name, or "Speaker 2 · who?", a tick when their voice is saved, and how much of the meeting they talked. When some speakers have no name, a line above says so and Name them goes through them one by one, with Skip for anyone you don't know.
- Clicking a speaker opens one Who is this? sheet: listen to them, see which saved people they sound like and how much, type a name or pick a saved person, and choose whether to remember their voice. Same person as… joins two speakers that are really one, and Open their page goes to the person.
- Opening a recording from someone's page marks their lines, with Previous, Next and Show all to step through them.
- Only one line is highlighted as playing. On meetings recorded with the call on your Mac, two or three lines could light up at once.
- Deleting a recording or a saved version now asks first. Restore is off while a transcription runs, so a restore can no longer be mixed into a run.
- Fixed a crash when a person page reloaded while their voice was being learned, and made Merge and Split safe if a recording is deleted while they work.
- Clearing the Library search shows everything again at once. "Dictation" can no longer be used as a folder name, and recordings can no longer be filed into dictation history by mistake.
- Refresh all, on the overview, reads everyone's meetings from the last month one person at a time. Open commitments there now covers the last month too.
- A percentage that is high but held at a lower level now says why, for example while someone sounds close to another saved person.
- Learning the same speaker of a recording again replaces what was learned from it, so one meeting can no longer count twice towards a voice.
- Who is this? reads the speaker's own voice before naming them, warns when the name you picked is someone this speaker doesn't sound like, and moves on to the next speaker after a voice is refused instead of trying again.
- Add person starts from their recordings; recording a reading is the second choice.
- Record shows Starting… while the microphone gets ready, so a second press no longer stops the recording it just started.
- Disabled buttons look disabled.
- File > Delete Recording… (⌘⌫) deletes the recording open in Library, after the same confirmation.
- People are matched on 3 s of their speech instead of 1.5 s: the length their voices are learned from, and about twice as reliable. Every threshold was measured again on 381 clips of 23 people from real meetings.
- Fixed voice measurements that came out wrong whenever the voice model was given one or two pieces of audio instead of three: most matches had one or two such misreadings mixed in.
- People you meet often keep getting easier to find: a clear match adds that meeting to their voice, through the same sameness check. Turn it off in Settings › People with Keep learning from meetings.
- Settings › People › Voice model: High accuracy uses SimAM-ResNet100, trained on VoxBlink2, a 100 MB download. On the same clips it told people apart about twice as well. Switching rebuilds every voice from the meetings it was learned from, and switching back is instant. The model is licensed CC BY-NC-SA 4.0, for personal, non-commercial use.
- Recording titles describe what a meeting was about. They used to come from the first few lines, usually the greetings ("Happy Friday Work Updates"); now the text engine reads slices from across the whole recording and is told to name the subject. This applies to recordings transcribed from now on.
- Settings › AI assistants: switch off Let AI assistants read my library, and Claude and other assistants connected to Transcriberr see no tools and cannot read anything. One already connected is refused at its next request. The section also shows when an assistant last read the library.
- Settings sections fold away: click a section's title, and the app remembers which ones you keep open. Style & vocabulary starts folded. Learned names and your word choices are now small chips instead of one row each, with Show all for the rest.
- Buttons across the app are now real buttons to VoiceOver and other accessibility tools; before, many could be read but not pressed. Pause and Stop on the Record screen included.
- A recording whose transcription finished without getting a name, for example because the text engine could not run at that moment, is named the next time Transcriberr starts, for anything from the last week. When naming fails, the log now says why.
- Parakeet UK keeps itself up to date. Once a day, when update checks are on, Transcriberr asks Hugging Face whether a newer release of the model is out, downloads it in the background next to the one in use, checks every file against the fingerprint Hugging Face publishes for it, and switches to it the next time Transcriberr starts.
- This brings version 2 of Parakeet UK: better in meetings and in English than version 1, and it keeps English sentences inside Ukrainian speech more often.
- Super now pairs Whisper with Parakeet UK when you have not chosen its engines. Parakeet v2, the English-only model, is no longer downloaded unless you pick it.


## 4.7.0
- Ihnatov Parakeet UK is now an engine of its own, next to stock Parakeet v3. It is Parakeet v3 fine-tuned for Ukrainian, and it downloads on first use (about 630 MB) from huggingface.co/ihnatov-yuri/parakeet-tdt-0.6b-v3-uk, so a new Mac gets it like the other speech models. Every file is checked against its fingerprint before it is used.
- Pick it in Settings → Engines for transcription, live captions, dictation or as one side of Super. In Super it now counts the same as Whisper in Ukrainian; stock Parakeet v3 still counts half there.
- If Parakeet UK was copied over Parakeet v3 by hand, Transcriberr moves it into its own place, puts stock Parakeet v3 back from the saved copy, and switches every setting that used it to Parakeet UK, so your transcripts come out the same as before.

## 4.6.0
- Meetings recorded with the call on your Mac's speakers no longer play the other people back twice. Transcriberr now runs Apple's echo filter, the one calls in FaceTime and Teams use, on your microphone while a meeting records. Before, short bursts of echo got through every 15 to 20 seconds and sounded like doubled syllables.
- Your own words stay whole when you talk over someone. In the test, every word said over the call came through and none of the call's words did.
- The filter is off with headphones, where there is no echo. While it runs, other apps play about 4 dB quieter; that ends when you stop recording.
- Settings → Audio input → Echo filter in meetings turns it off. Dictation is unchanged.

## 4.5.3
- Clicking anywhere on a line of the transcript now jumps the audio to that line. Before, a click on the words themselves was taken as the start of a text selection, so only clicks beside the text worked.
- The jump lands exactly on the line and the highlight moves straight away, also while playback is paused.
- Right-click a line and choose Copy line to copy its text. The prose view is still fully selectable.

## 4.5.2
- Settings → Audio input → People has Add person. Record the person reading a short passage at your Mac, or pick them as a speaker in one of your recordings, and Transcriberr learns their voice. Recordings made after that name them on their own.
- The speakers above a transcript now say that clicking one also lets you remember their voice.
- Tag who said each line in the transcript itself. Click the name above a line (or "Who said this?" on a line without one), or right-click the line, and pick a speaker of the recording, one of your saved people, or a new name. Only that line changes, and lines you tag are never renamed by a later voice match.
- When Whisper runs out of time on a part of a recording (the Mac was busy), that part is tried once more. If it still has no text, the run says how many parts are empty instead of leaving silent gaps. In Super, Parakeet's reading of such a part stands, and Whisper is no longer asked to read it a second time.
- An audio file that cannot be decoded now says why, with the reason from each of the two decoders that tried it. A file that AVFoundation refuses to open now always gets the second decoder.

## 4.5.1
- When a fine-tuned Parakeet v3 is installed in place of the stock model, Transcriberr shows its name instead of "Parakeet v3" (for example Ihnatov Parakeet UK).

## 4.5.0
- Transcriberr can learn the people you talk to. In a recording, click a speaker's name, type who it is and press Remember this voice. Later recordings name that person on their own. Saving the same name from another recording adds it to their voice, so they are found on calls and in the room alike.
- Settings → Audio input → People lists everyone saved, to rename or delete. The voices stay on this Mac, outside Time Machine, and deleting one removes it. A recording made before someone was saved can be named with Find people next to its speakers.
- Generating a summary or any other output again no longer throws the old one away. History in the output tab lists every earlier one, with the engine and prompt that made it. Restore any of them; the one it replaces stays in the list.
- Each preset keeps its earlier prompts: the ones each run used, the ones you keep with Save version, and the state before a reset or restore. Restore any of them from History in the preset. A deleted preset you added can be brought back.
- Share → Export to a folder writes everything about a recording into one folder: the transcript, every saved version, each output with its earlier ones and their prompts, the presets' prompts, and with audio if you choose. A manifest lists every file with its checksum.
- You can add your own post-processing presets. Settings → Post-processing presets → Add preset gives a new one with its own tab in every recording, next to Summary and Minutes. Write what you want from the transcript, for example a read of how each speaker argues, and press Generate in that tab.
- Every preset can be renamed, duplicated, moved up or down (its tab moves with it) and deleted. Duplicate a built-in to start from its prompt without changing the original.
- A preset runs either as an analysis, which reads the transcript once and writes about it, or as a rewrite, which gives back the whole transcript changed, as Clean does.
- A prompt without {transcript_with_speakers} still gets the transcript, added at the end, instead of running on nothing.
- Deleting a preset keeps the outputs it made; their tab stays in the recording. Restore built-in presets brings back the shipped ones and no longer deletes the presets you added.
- Restoring an older version in Versions now keeps the transcript you are leaving as a version of its own ("Before restore"). Corrections you typed since the last run were lost before.
- A correction that cannot be saved now says so and leaves your text in the editor. Before, the editor closed as if it had saved.
- Gemini and OpenAI answers that stop early, cut off at their length limit or by a filter, now show as a failure you can retry, and the previous output stays. Before, half a summary could be saved as the whole one.

## 4.4.1
- Short replies from the other side of a call ("Yes", "Добре", "Yeah") are kept again. Since 4.3.3 a reply of one or two words between two stretches of you talking was taken for noise and deleted. Now only words read into silence, or a quick "uh-huh" misheard as a number like "100%", are left out.
- In a recording made on one track, with your voice print set up, you are found even when you said only a few seconds, such as one question in a long talk. Since 4.3.3 those few seconds could be given to someone else, and another person's few words could be given to you.
- Detail → Versions names the Whisper model a run used again ("Whisper large-v3 turbo compressed"), not just "Whisper".

## 4.4.0
- Whisper now has two models: one for recordings in English and one for every other language. English uses large-v3 turbo compressed by default, which makes Super about four times faster in English (under a minute for five minutes of meeting) with the same accuracy. Other languages keep large-v3, the only model that stays accurate in Ukrainian.
- If you had picked a smaller Whisper model, it now serves English and other languages go back to large-v3. Both choices are in Settings → Engines.
- The engine menus list Whisper once; the model follows the recording's language.

## 4.3.4
- The Transcriberr connection for AI assistants (MCP) keeps working after an update: it notices the new version and restarts itself, instead of failing with "Could not open the database" until it was reconnected by hand.

## 4.3.3
- Meetings no longer list extra speakers who said three words. The speaker detection splits off a few seconds of someone's voice in most meetings; those scraps now go back to the person they belong to. A two-person call shows two people again.
- "GUEST" is gone from meetings with several people: a line the speaker detection did not place gets the voice nearest to it, and one-word noise in silence ("100%", "0%") is removed.

## 4.3.2
- If your voice print does not match the microphone of a meeting (enrolled on the laptop, the meeting on AirPods, or a cold), the meeting no longer loses your words: it falls back to how meetings worked before the voice print. A reading that sounded mixed is no longer saved as your print.
- Short answers ("yes, Tuesday works") are no longer dropped from your side of a meeting transcribed without word timings.
- Picking a Whisper model while a transcription runs no longer switches models halfway through it. An English-only Whisper model is not used for other languages, the model a run is using cannot be deleted, and without internet a missing model is replaced by one on this Mac.
- Calendar invites from colleagues' shared calendars, subscribed calendars and meetings you declined are no longer used.
- Deleting or switching off the benchmark stops the clips still being written. Clicking the second underlined copy of a word changes that copy.

## 4.3.1
- Names from a calendar invite no longer make ordinary words win Super's vote: an attendee called "Kees van der Berg" or "Will Smith" used to tip every "van" or "will" the engines disagreed on.
- Clicking a disputed word back now always leaves no rule behind, and takes back only the vocabulary entry the first click added.
- Settings → Your benchmark has an off switch and a Delete button, and says plainly that a corrected line keeps a copy of its audio.
- Two quick edits of the same line no longer record your first edit as the engine's text.

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
