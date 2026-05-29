# Release Packaging

Use the existing signed-notarized DMG flow; do not invent a parallel release process.

## Local release script

`scripts/package-dmg.sh` archives the app, exports a Developer ID-signed `.app`, builds the branded DMG, notarizes it, staples it, and verifies it.

Required environment variables:

- `DEVELOPER_ID_APPLICATION`
- `NOTARY_PROFILE`

Prerequisites:

- `create-dmg` installed via Homebrew
- `scripts/dmg/background.png` present

Example:

```bash
DEVELOPER_ID_APPLICATION='Developer ID Application: ...' \
NOTARY_PROFILE='your-notary-profile' \
bash scripts/package-dmg.sh
```

## GitHub release workflow

`.github/workflows/release.yml` is the canonical CI release flow.

- Runs on tag pushes matching `v*.*.*` or manual dispatch.
- Requires signing, notarization, and Sparkle secrets from GitHub Actions.
- Updates `docs/appcast.xml` after publishing the DMG.

If release behavior changes, update both the script and the workflow.