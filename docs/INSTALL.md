# Installing VibeView

Requires macOS 14 or later.

## From a DMG

1. Download `VibeView-<version>.dmg` from the GitHub Releases page.
2. Open it and drag VibeView onto the Applications shortcut.
3. Eject the disk image.

### First launch (Gatekeeper)

The app is ad-hoc signed and not notarized, so macOS blocks the first launch. Use one of:

- Right-click (or Control-click) VibeView in Applications, choose Open, then click Open.
- Try to open it once, then go to System Settings ▸ Privacy & Security and click Open Anyway.
- Remove the quarantine attribute: `xattr -dr com.apple.quarantine /Applications/VibeView.app`

## Quick Look extension

VibeView ships a Quick Look preview extension for structure files. If previews do not appear:

1. Open System Settings ▸ General ▸ Login Items & Extensions ▸ Quick Look and make sure VibeView Preview is enabled.
2. Run `qlmanage -r` to reset the Quick Look server (and `qlmanage -r cache`).

## Uninstall

Drag `/Applications/VibeView.app` to the Trash. Optionally remove preferences with
`defaults delete io.github.clevinliju.VibeView`.

## Build from source

Requires Xcode or the Command Line Tools with Swift 6.

```sh
swift build
swift run VibeView
swift run molscope-check
scripts/make-app.sh      # dist/VibeView.app (version from VERSION)
scripts/make-dmg.sh      # dist/VibeView-<version>.dmg; add --no-build to reuse dist/VibeView.app
```

## Releasing

1. Bump the number in `VERSION`.
2. Commit, then tag: `git tag vX.Y.Z && git push --tags`.
3. The GitHub Actions workflow (`.github/workflows/build.yml`) builds, runs the self-checks, builds the DMG and attaches it to a new GitHub Release.
