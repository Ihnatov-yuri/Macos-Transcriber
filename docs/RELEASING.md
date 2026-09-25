# Releasing Transcriberr

Every build that leaves this Mac, to /Applications or to GitHub, gets its own
version number and tag. Installed copies from 3.14.2 on update themselves from
the GitHub release, so a release is also a delivery to every user who presses
Update. The steps below are the whole route.

## Once per release Mac

The update-signing key lives in the login Keychain as
`nl.ihnatov.Transcriberr.update-signing` (account `release`). It was created on
2026-09-25 by `scripts/update-keygen.sh`, and its public half is compiled into
`Transcriberr/App/UpdateInstaller.swift` (`UpdateSignature.publicKey`).

Never generate a new key: every installed copy trusts only the key it shipped
with, and a release signed with any other key can only be installed by hand.
Keep a copy of the private key in the password manager:

```bash
security find-generic-password -s nl.ihnatov.Transcriberr.update-signing -a release -w
```

To release from another Mac, add the same key to its Keychain:

```bash
security add-generic-password -s nl.ihnatov.Transcriberr.update-signing -a release \
    -l "Transcriberr update signing key" -w "<private key>"
```

## Steps

1. **Start from an up-to-date main.**
   ```bash
   git fetch origin && git rev-list --left-right --count main...origin/main   # expect 0 0
   ```

2. **Bump the version** in `project.yml` (`MARKETING_VERSION`), patch or minor as
   appropriate.

3. **Write the release notes** at the top of `Transcriberr/Resources/ReleaseNotes.md`:
   a `## X.Y.Z` heading and one short, user-facing line per change. They appear in
   Transcriberr → About for that version. The test suite fails when the current
   version has no section.

4. **Regenerate, patch, test.** The suite must be green before anything ships.
   ```bash
   xcodegen generate && ./scripts/patch-artifacts.sh
   xcodebuild test -project Transcriberr.xcodeproj -scheme Transcriberr -destination "platform=macOS" \
       -derivedDataPath ~/Library/Caches/transcriberr-test-dd -clonedSourcePackagesDirPath .build/xcode/SourcePackages
   ```

5. **Build and package.** `package.sh` re-signs the embedded dylibs and applies the
   identifier-based signing requirement that keeps permission grants across updates.
   ```bash
   xcodebuild -scheme Transcriberr -derivedDataPath .build/xcode -configuration Release build
   ./scripts/package.sh
   defaults read "$PWD/.build/xcode/Build/Products/Release/Transcriberr.app/Contents/Info.plist" CFBundleShortVersionString
   ```
   The last line must print the new version before anything is zipped.

6. **Zip and sign.** The zip name is fixed; the app builds the download address
   from it.
   ```bash
   V=X.Y.Z
   ditto -c -k --sequesterRsrc --keepParent .build/xcode/Build/Products/Release/Transcriberr.app \
       Transcriberr-v$V-macOS-arm64.zip
   ./scripts/sign-update.sh Transcriberr-v$V-macOS-arm64.zip
   ```
   `sign-update.sh` writes `Transcriberr-v$V-macOS-arm64.zip.sig` and verifies it
   against the public key in the source. It stops if they don't match.

7. **Commit, tag, push.**
   ```bash
   git commit -am "vX.Y.Z: <what changed>"
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

8. **Publish the GitHub release with both files.** Without the `.sig`, installed
   copies show only "What's new…" and people have to update by hand.
   ```bash
   gh release create vX.Y.Z Transcriberr-v$V-macOS-arm64.zip Transcriberr-v$V-macOS-arm64.zip.sig \
       --title "vX.Y.Z: <headline>" --notes-file notes.md --latest
   ```
   `notes.md` has four parts. **What changed** comes from
   `scripts/release-notes.sh` (the same lines as About). **How** describes the
   mechanism, **Learning** what the release taught, and **Verified** the test count
   and checks.

9. **Check what the app will see.**
   ```bash
   curl -s -H "User-Agent: Transcriberr" \
       https://api.github.com/repos/Ihnatov-yuri/Macos-Transcriber/releases/latest \
       | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['tag_name'],[a['name'] for a in d['assets']])"
   ```
   Expect the new tag, the zip and the `.sig`.

10. **Install on this Mac** with Update in the running app, or by copying the
    packaged app into /Applications while Transcriberr is closed.

## How installed copies update

- **Check.** With the user's consent, asked once on first launch, the app fetches
  `api.github.com/repos/Ihnatov-yuri/Macos-Transcriber/releases/latest` once a
  day. The request is identical from every Mac, and the version is compared
  locally. A release counts as installable when its assets include both
  `Transcriberr-vX.Y.Z-macOS-arm64.zip` and the matching `.sig`.
- **Update.** The app downloads both files and checks the Ed25519 signature over
  the version and the zip's SHA-256. It unpacks the zip and requires one
  `Transcriberr.app` with the same bundle identifier, the promised version and a
  strictly valid code signature. Then it quits, and a small helper swaps the
  bundle and reopens the app.
- **Blocked.** Recording, meeting capture and dictation block the update. A
  running transcription asks first.
- **Draft and pre-release** GitHub releases are never offered.

## Releases for testing only

When a build is only for this Mac, tag it but don't publish a GitHub release; the
update check only sees published releases. 3.14.0 and 3.14.2 were released this
way.
