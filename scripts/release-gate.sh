#!/bin/zsh
# Release gate: everything that must be true before `git tag vX.Y.Z`.
# Run it on main with the version-bump commit made and pushed (no tag yet).
# It replaces a manual test round, so it has no skip switches.
#
#   scripts/release-gate.sh              # check; exit 1 when anything FAILs
#   scripts/release-gate.sh --build      # build and sign the Release app and CLI first
#   scripts/release-gate.sh --wait       # wait for this commit's CI and E2E runs to finish
#   scripts/release-gate.sh --reviewed   # record that the changes since the last tag were
#                                        # code-reviewed and the findings fixed, then exit
#
# Checks, cheapest first:
#   tree      on main, nothing uncommitted, not behind origin, tag not taken
#   notes     ReleaseNotes.md has a section for MARKETING_VERSION
#   tests     app or CLI code changed since the last tag => a test changed too
#             (NO_TEST_REASON="why" lets a release through and prints the reason)
#   review    `--reviewed` was recorded for exactly these changes
#   ci        the CI and E2E workflows are green on this commit
#   build     `--build` built the Release app AND the CLI from exactly this commit,
#             both carry this version, and the app's signature verifies
#   replay    scripts/replay-check.sh: real meetings, WER against the baseline
#             (with Super when ASR/ or Audio/ changed)
#   field     scripts/field-report.sh: what the installed build logged in real
#             use; printed for reading, never fails the gate
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
BUILD=0; WAIT=0; MARK=0
for a in "$@"; do
  case "$a" in
    --build) BUILD=1 ;; --wait) WAIT=1 ;; --reviewed) MARK=1 ;;
    *) echo "unknown option: $a" >&2; exit 64 ;;
  esac
done

V="$(grep -m1 'MARKETING_VERSION:' project.yml | grep -oE '[0-9]+(\.[0-9]+)+')"
SHA="$(git rev-parse HEAD)"
LAST="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
RANGE="${LAST:+$LAST..}HEAD"
STATE="$ROOT/.build/gate"; mkdir -p "$STATE"
# The reviewed changes: everything since the last tag except the files a
# release edits after review (version number, user-facing notes).
CHANGES_ID="$(git diff "$RANGE" -- . ':!project.yml' ':!Transcriberr/Resources/ReleaseNotes.md' | shasum | cut -c1-16)"

if [ "$MARK" = 1 ]; then
  git diff --quiet HEAD || { echo "commit the review fixes first: the record is for committed changes"; exit 1; }
  date -u +%FT%TZ > "$STATE/reviewed-$CHANGES_ID"
  echo "recorded: changes $RANGE ($CHANGES_ID) reviewed"; exit 0
fi

FAILS=0; typeset -a SUMMARY
ok()   { SUMMARY+=("PASS  $1  $2"); echo "PASS  $1  $2"; }
bad()  { SUMMARY+=("FAIL  $1  $2"); echo "FAIL  $1  $2"; FAILS=$((FAILS + 1)); }
echo "== release gate: v$V at ${SHA[1,7]} (changes since ${LAST:-the first commit})"

# --- tree
T=""
[ "$(git branch --show-current)" = main ] || T+="not on main; "
git diff --quiet HEAD || T+="uncommitted changes; "
[ -z "$(git ls-files --others --exclude-standard)" ] || T+="untracked files; "
git fetch -q origin main 2>/dev/null || T+="could not fetch origin; "
[ "$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)" = 0 ] || T+="behind origin/main; "
git rev-parse -q --verify "refs/tags/v$V" >/dev/null && T+="tag v$V already exists (bump MARKETING_VERSION); "
[ -z "$(git ls-remote --tags origin "v$V" 2>/dev/null)" ] || T+="tag v$V exists on origin; "
if [ -z "$T" ]; then ok tree "main, clean, v$V is free"; else bad tree "$T"; fi

# --- notes
if scripts/release-notes.sh "$V" >/dev/null 2>&1; then ok notes "section $V present"; else bad notes "no '## $V' section in ReleaseNotes.md"; fi

# --- tests
CODE="$(git diff --name-only "$RANGE" -- Transcriberr TranscriberrCLI MicDriver UzuRuntime | grep -E '\.(swift|c|cpp|m|mm|h)$' | wc -l | tr -d ' ')"
# Added or modified only: deleting a test is not "a test changed too".
TESTS="$(git diff --name-only --diff-filter=AM "$RANGE" -- TranscriberrTests scripts/ci-e2e.sh | wc -l | tr -d ' ')"
if [ "$CODE" = 0 ]; then ok tests "no code changed"
elif [ "$TESTS" != 0 ]; then ok tests "$CODE code files, $TESTS test files changed"
elif [ -n "${NO_TEST_REASON:-}" ]; then ok tests "$CODE code files, no test: $NO_TEST_REASON"
else bad tests "$CODE code files changed and no test did: add the test that would have caught it"
fi

# --- review
if [ "$CODE" = 0 ]; then ok review "no code changed"
elif [ -f "$STATE/reviewed-$CHANGES_ID" ]; then ok review "recorded $(cat "$STATE/reviewed-$CHANGES_ID")"
else bad review "review 'git diff $RANGE', fix the findings, then: scripts/release-gate.sh --reviewed"
fi

# --- ci
if ! git merge-base --is-ancestor "$SHA" origin/main 2>/dev/null; then
  bad ci "commit not pushed: git push origin main (no tag), then rerun with --wait"
else
  runs() { gh run list --commit "$SHA" --json name,status,conclusion,databaseId 2>/dev/null; }
  if [ "$WAIT" = 1 ]; then
    for id in $(runs | python3 -c 'import json,sys; [print(r["databaseId"]) for r in json.load(sys.stdin) if r["status"]!="completed"]'); do
      gh run watch "$id" --interval 30 >/dev/null 2>&1 || true
    done
  fi
  C="$(runs | python3 -c '
import json,sys
r={}
for x in json.load(sys.stdin):  # newest first: the latest run of each workflow decides
    r.setdefault(x["name"], x["conclusion"] or x["status"])
print(" ".join(n + "=" + r.get(n, "missing") for n in ("CI", "E2E")))' 2>/dev/null)"
  if [ "$C" = "CI=success E2E=success" ]; then ok ci "$C"; else bad ci "${C:-gh could not list runs} (rerun with --wait while they are in progress)"; fi
fi

# --- build
REL="$ROOT/.build/xcode/Build/Products/Release"
# A stamp, not file times, says which commit the binaries were built from:
# package.sh re-signs in place, which makes an old binary look new.
STAMP="$STATE/built"
B=""
if [ "$BUILD" = 1 ]; then
  rm -f "$STAMP"
  if ! git diff --quiet HEAD; then
    B+="not built: uncommitted changes would go into the binary; "
  else
    BUILT=1
    # The Xcode project is generated: without this a bumped MARKETING_VERSION
    # in project.yml never reaches the binaries.
    xcodegen generate > "$STATE/xcodegen.log" 2>&1 || { BUILT=0; B+="xcodegen failed (see $STATE/xcodegen.log); "; }
    for scheme in Transcriberr TranscriberrCLI; do
      echo "building $scheme (Release)…"
      xcodebuild build -project Transcriberr.xcodeproj -scheme "$scheme" -configuration Release \
        -destination "platform=macOS" -derivedDataPath .build/xcode \
        -skipPackagePluginValidation -skipMacroValidation > "$STATE/build-$scheme.log" 2>&1 \
        && grep -q "BUILD SUCCEEDED" "$STATE/build-$scheme.log" \
        || { BUILT=0; B+="$scheme build failed (see $STATE/build-$scheme.log); "; }
    done
    if [ "$BUILT" = 1 ]; then
      if scripts/package.sh > "$STATE/package.log" 2>&1; then echo "$SHA" > "$STAMP"
      else B+="package.sh failed (see $STATE/package.log); "; fi
    fi
  fi
fi
[ "$(cat "$STAMP" 2>/dev/null)" = "$SHA" ] || B+="no gate build of this commit; "
APPV="$(defaults read "$REL/Transcriberr.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo none)"
CLIV="$(otool -s __TEXT __info_plist -V "$REL/transcriberrcli" 2>/dev/null | grep -A1 CFBundleShortVersionString | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
[ "$APPV" = "$V" ] || B+="app is $APPV; "
[ "${CLIV:-none}" = "$V" ] || B+="CLI is ${CLIV:-none} (the Transcriberr scheme does not build it); "
codesign --verify --deep "$REL/Transcriberr.app" 2>/dev/null || B+="app signature does not verify (scripts/package.sh); "
if [ -z "$B" ]; then ok build "app and CLI are $V, built from ${SHA[1,7]}, signed"; BUILD_OK=1; else bad build "$B(rerun with --build)"; BUILD_OK=0; fi

# --- replay
if [ "$BUILD_OK" = 1 ]; then
  SUPER=""
  [ -n "$(git diff --name-only "$RANGE" -- Transcriberr/ASR Transcriberr/Audio)" ] && SUPER="--super"
  echo "replaying the reference set ${SUPER:+with Super }…"
  if REQUIRE_BASELINE=1 scripts/replay-check.sh $SUPER > "$STATE/replay.log" 2>&1; then ok replay "$(grep -c . "$STATE/replay.log") lines, no regression ${SUPER}"
  else bad replay "see below"; fi
  grep -vE '^(==|replay:)' "$STATE/replay.log" | sed 's/^/      /'
else
  bad replay "not run: there is no current build to replay"
fi

# --- field
echo; scripts/field-report.sh 7 | sed 's/^/   /'

echo; echo "== summary"
print -l -- "${SUMMARY[@]}"
if [ "$FAILS" = 0 ]; then
  echo "$SHA" > "$STATE/passed-v$V"
  echo "GATE PASSED: v$V may be tagged at ${SHA[1,7]}"
else
  echo "GATE FAILED: $FAILS check(s). Do not tag."; exit 1
fi
