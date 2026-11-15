#!/bin/zsh
# Interface strings: extract every key from a Debug build and rebuild
# Transcriberr/Resources/Localizable.xcstrings, keeping the translations it
# has. Prints the keys that still need Ukrainian or Dutch; translate them into
# a JSON file as docs/localization.md describes and pass it as an argument.
#
#   scripts/l10n/strings.sh                 # report what is untranslated
#   scripts/l10n/strings.sh new.json ...    # add translations
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
xcodebuild -project Transcriberr.xcodeproj -scheme Transcriberr -configuration Debug \
    -destination "platform=macOS" -derivedDataPath .build/xcode build -quiet
KEYS="$(mktemp -t transcriberr-keys)"
python3 -I scripts/l10n/collect.py .build/xcode/Build/Intermediates.noindex/Transcriberr.build/Debug/Transcriberr.build "$KEYS"
python3 -I scripts/l10n/build_catalog.py "$KEYS" Transcriberr/Resources/Localizable.xcstrings "$@"
python3 -I - <<'PY'
import json, re
c = json.load(open("Transcriberr/Resources/Localizable.xcstrings"))["strings"]
todo = [k for k, v in c.items()
        if re.search(r"[A-Za-z]", re.sub(r"%(\d+\$)?(lld|ld|d|@|\.?\d*f)", "", k))
        and not {"uk", "nl"} <= set(v.get("localizations", {}))]
print(f"{len(todo)} keys need a translation")
for k in todo: print("  " + json.dumps(k, ensure_ascii=False))
PY
