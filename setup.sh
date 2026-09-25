#!/usr/bin/env bash
set -euo pipefail

# One-shot setup for Transcriberr.
# - installs XcodeGen if missing
# - generates Transcriberr.xcodeproj from project.yml
# - opens the project in Xcode

# Every path below is relative to the repo; run from anywhere.
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found. Install from https://brew.sh first, or install xcodegen manually." >&2
    exit 1
  fi
  echo "Installing xcodegen via Homebrew..."
  brew install xcodegen
fi

xcodegen generate

# Resolve packages, then nest the NemoTextProcessing headers so the FluidAudio
# and LiteRT-LM xcframeworks stop colliding on include/module.modulemap
# (see scripts/patch-artifacts.sh for the why).
# Two package checkouts need it: .build/xcode, which the README's
# command-line builds and scripts use, and the DerivedData folder Xcode itself
# builds from on ⌘R. Patching only the first left ⌘R failing on
# "Multiple commands produce .../include/module.modulemap".
xcodebuild -resolvePackageDependencies -scheme Transcriberr -derivedDataPath .build/xcode >/dev/null
scripts/patch-artifacts.sh .build/xcode/SourcePackages
xcodebuild -resolvePackageDependencies -scheme Transcriberr >/dev/null
xcode_build_dir=$(xcodebuild -showBuildSettings -scheme Transcriberr 2>/dev/null \
  | awk -F ' = ' '/^ *BUILD_DIR = / { print $2; exit }' || true)
if [[ -n "$xcode_build_dir" ]]; then
  scripts/patch-artifacts.sh "${xcode_build_dir%/Build/Products}/SourcePackages"
else
  echo "setup: couldn't locate Xcode's DerivedData — if ⌘R fails on module.modulemap, run" >&2
  echo "  scripts/patch-artifacts.sh <DerivedData>/Transcriberr-*/SourcePackages" >&2
fi

if [[ "${1-}" != "--no-open" ]]; then
  open Transcriberr.xcodeproj
fi

echo
echo "Done. In Xcode:"
echo "  1. Select the Transcriberr target → Signing & Capabilities"
echo "  2. Choose your Team (or leave 'None' for local builds)"
echo "  3. ⌘R to run"
echo
echo "If Xcode re-resolves packages (File → Packages → Reset/Update), run"
echo "./setup.sh --no-open again: the resolve undoes the header patch."
