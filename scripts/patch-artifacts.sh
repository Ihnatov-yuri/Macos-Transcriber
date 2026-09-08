#!/usr/bin/env bash
set -euo pipefail

# Post-resolve fix for the FluidAudio 0.15.5+ / LiteRT-LM header collision.
#
# Both packages ship a library xcframework whose Headers/ folder has a
# top-level module.modulemap. Xcode's ProcessXCFramework copies every
# xcframework's Headers/ into the shared $BUILT_PRODUCTS_DIR/include, so the
# two module maps claim the same output path and the build fails with
#   error: Multiple commands produce '.../Build/Products/Debug/include/module.modulemap'
#
# Upstream fixed the NemoTextProcessing artifact by nesting its headers in a
# directory named after the Clang module (text-processing-rs PR #87, merged
# 2026-08-27) but has not released it, and FluidAudio 0.15.6 still pins the
# flat v0.3.0 zip. This script applies the same restructuring to the extracted
# artifact. Clang resolves `import CNemoTextProcessing` because it also looks
# for a module map in a subdirectory named after the module, so the FluidAudio
# sources compile unchanged.
#
# Run after every package resolve (setup.sh does; so should you after
# `xcodebuild -resolvePackageDependencies` or a clean of SourcePackages):
#   scripts/patch-artifacts.sh [SourcePackages dir]   (default .build/xcode/SourcePackages)
# Delete this script once FluidAudio ships a NemoTextProcessing artifact with
# nested headers — the patch is a no-op when the layout is already nested.

PKG_DIR="${1:-.build/xcode/SourcePackages}"
XCF="$PKG_DIR/artifacts/fluidaudio/NemoTextProcessing/NemoTextProcessing.xcframework"
MODULE="CNemoTextProcessing"

if [[ ! -d "$XCF" ]]; then
  echo "patch-artifacts: no NemoTextProcessing artifact under $PKG_DIR (resolve packages first?)" >&2
  exit 0
fi

patched=0
for headers in "$XCF"/*/Headers; do
  [[ -d "$headers" ]] || continue
  if [[ -f "$headers/module.modulemap" ]]; then
    mkdir -p "$headers/$MODULE"
    mv "$headers/module.modulemap" "$headers"/*.h "$headers/$MODULE/"
    patched=$((patched + 1))
  fi
done

if (( patched > 0 )); then
  echo "patch-artifacts: nested headers under Headers/$MODULE in $patched slice(s) of $(basename "$XCF")"
else
  echo "patch-artifacts: $(basename "$XCF") already nested — nothing to do"
fi
