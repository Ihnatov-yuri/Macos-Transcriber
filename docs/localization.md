# Interface languages

Transcriberr's own screens come in English, Ukrainian and Dutch (since 5.8.0). Settings › Language picks one,
or System follows macOS; it is stored as the app's `AppleLanguages`, the key System Settings › Language &
Region › Applications writes, and applies after a restart. Transcripts, presets, prompts and the text model's
answers are not affected.

## How strings get translated

- SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`) are extracted by the compiler
  (`SWIFT_EMIT_LOC_STRINGS`). Text that lives in a `String` is wrapped in `String(localized: "…")`.
- Never localize what is stored, matched or sent to a model: default recording titles, folder names (the
  Dictation folder shows `Folder.shownName`), engine names saved with a run (`BackendFactory.Kind.storedName`),
  prompts, logs, exported files, CLI and MCP output.
- Counts are one string with an Int (`"\(n) lines"`); the catalog holds the plural forms, English included.
- `scripts/l10n/strings.sh` builds, extracts every key, rebuilds `Transcriberr/Resources/Localizable.xcstrings`
  keeping its translations, and lists what still needs Ukrainian or Dutch. Translate those into a JSON file in
  the format below and run `scripts/l10n/strings.sh that.json`. `LocalizationTests` fails on a translation
  that loses a format specifier or a plural form.
- macOS permission prompts are in `Transcriberr/Resources/InfoPlist.xcstrings`.

# Translation guide: Ukrainian (uk) and Dutch (nl)

Transcriberr is a Mac app that records meetings (the call and your microphone on separate tracks),
transcribes them on the Mac, works out who said what, learns voices, writes summaries and minutes with a
local text model, answers questions about your meetings, and lets you dictate into any app by holding a key.
Nothing leaves the Mac. Users are professionals in the Netherlands and Ukrainians; the author is Ukrainian
and lives in the Netherlands.

## Voice
Plain, calm, short. Say what happens, in everyday words. No exclamation marks, no marketing, no slang.
Ukrainian: address the user with "ви" (lower case), modern standard Ukrainian, no Russianisms and no Russian
words or references at all. Dutch: informal "je/jij" (as Apple's Dutch UI does), not "u".
Buttons and menu items follow Apple's macOS conventions in that language: uk "Скасувати", "Зберегти",
"Видалити"; nl "Annuleer", "Bewaar", "Verwijder".
Keep a trailing "…" where the source has one. Keep "·" separators, curly quotes become the language's quotes
(uk «…», nl ‘…’ or “…” as in the source).

## Never translate
Transcriberr, Parakeet, Parakeet UK, Whisper, Whisper UK, Super (the merged engine mode), Gemma, Qwen, MLX,
Neural Engine, Teams, Zoom, Google Meet, FaceTime, MCP, Shortcuts names, Raycast, Stream Deck, Hugging Face,
GitHub, OpenAI, Anthropic, Gemini, macOS, Mac, Time Machine, keyboard keys (⌘, ⌥, Right ⌥), file extensions
(.txt, .srt, .vtt, .json, .m4a), WebVTT, Markdown, URLs, "ROVER", "WER", "DER".

## Terms
| English | uk | nl |
|---|---|---|
| recording (noun) | запис | opname |
| record (verb) / Record (screen) | записувати / Запис | opnemen / Opnemen |
| meeting | зустріч | vergadering |
| meeting mode | режим зустрічі | vergadermodus |
| transcript | транскрипт | transcript |
| transcribe / transcription | розпізнати мовлення, транскрибувати / транскрибування | uitschrijven / transcriptie |
| run (a transcription run, noun) | запуск | transcriptie (a run of an engine); the Run button is "Start" |
| engine (speech engine) | рушій (мовний рушій) | engine (spraakengine) |
| text model | текстова модель | tekstmodel |
| speaker | мовець | spreker |
| voice print | відбиток голосу | stemafdruk |
| People (screen) | Люди | Personen |
| Library (screen) | Бібліотека | Bibliotheek |
| Dictate / dictation | Диктування / диктування | Dicteren / dicteren |
| Settings | Налаштування | Instellingen |
| vocabulary | словник | woordenlijst |
| preset | шаблон | sjabloon |
| summary | підсумок | samenvatting |
| minutes (of a meeting) | протокол | notulen |
| live captions | живі субтитри | live ondertiteling |
| echo filter / echo cancelling | фільтр луни / придушення луни | echofilter / echo-onderdrukking |
| microphone, mic | мікрофон | microfoon |
| system audio | системний звук | systeemgeluid |
| folder, tag | папка, тег | map, tag |
| version (of a transcript) | версія | versie |
| clean (text without fillers) | чистий текст | schone tekst |
| verbatim (exactly what was said) | дослівно | letterlijk |
| filler words | слова-паразити | stopwoorden |
| Ask (button: ask your meetings) | Запитати | Vraag |
| brief (person brief) | довідка | briefing |
| hotkey | гаряча клавіша | sneltoets |
| download / model download | завантажити | downloaden |
| cloud engine | хмарний рушій | cloudengine |
| on this Mac / on-device | на цьому Mac | op deze Mac |
| Normal / Advanced (settings level) | Основні / Розширені | Normaal / Geavanceerd |

## Format specifiers
Keys contain %@ (text), %lld (integer), %f / %.1f (decimal). Keep every specifier exactly once. When the word
order needs the arguments in a different order, use positional forms: %1$@, %2$lld (numbered in the order they
appear in the English key). Never translate or drop a specifier.

## Plurals
For a key with exactly ONE integer specifier (%lld) that counts something ("%lld lines", "%lld minutes",
"Delete all %lld checked lines…"), give plural forms instead of one string:
- en: {"one": "%lld line", "other": "%lld lines"}  (always give en forms for these keys)
- uk: {"one": "%lld рядок", "few": "%lld рядки", "many": "%lld рядків", "other": "%lld рядка"}
- nl: {"one": "%lld regel", "other": "%lld regels"}
For an integer that is not a count (a year, a percentage, a position "%lld of %lld"), give plain strings.

## Output
A JSON object: { "<English key exactly as given>": {"uk": ..., "nl": ..., "en": ...only for plural keys} }.
Copy keys byte-for-byte (including curly quotes, "…", "·", non-breaking spaces and trailing spaces).
