#!/usr/bin/env bash
set -euo pipefail

# One-shot setup for Transcriberr.
# - installs XcodeGen if missing
# - generates Transcriberr.xcodeproj from project.yml
# - opens the project in Xcode

if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found. Install from https://brew.sh first, or install xcodegen manually." >&2
    exit 1
  fi
  echo "Installing xcodegen via Homebrew..."
  brew install xcodegen
fi

xcodegen generate

if [[ "${1-}" != "--no-open" ]]; then
  open Transcriberr.xcodeproj
fi

echo
echo "Done. In Xcode:"
echo "  1. Select the Transcriberr target → Signing & Capabilities"
echo "  2. Choose your Team (or leave 'None' for local builds)"
echo "  3. ⌘R to run"
