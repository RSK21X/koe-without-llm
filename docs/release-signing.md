# Release signing and notarization

Tagged releases (`v*`) are signed with a Developer ID Application certificate,
notarized with Apple, and attached to a GitHub Release. Pull request and `main`
branch builds fall back to ad-hoc signing and skip notarization, so no signing
secrets are required for regular CI.

The signing and notarization logic lives in
`.github/scripts/package-app.sh`, which is invoked by
`.github/workflows/release.yml`.

## Required repository secrets

| Secret | Description |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64-encoded **Developer ID Application** certificate + private key (`.p12`) |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting the `.p12` file |
| `APPLE_ID` | Apple ID email of the developer account used for notarization |
| `APPLE_APP_PASSWORD` | [App-specific password](https://support.apple.com/102654) for that Apple ID |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |

## Preparing the certificate secret

Export the “Developer ID Application: …” certificate, including its private
key, from Keychain Access as a `.p12`, then encode it:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste the result into the `MACOS_CERTIFICATE_P12` secret.

## What the release pipeline does

For the Apple Silicon Koe build it:

1. Imports the certificate into a temporary keychain, which is deleted after the job.
2. Embeds the `koe-cli` binary into `Koe.app/Contents/MacOS/`.
3. Signs nested frameworks and binaries, then the app bundle with the Developer ID identity and hardened runtime.
4. Submits the app to Apple’s notary service.
5. Staples and verifies the notarization ticket.
6. Creates a zip and uploads it to the GitHub Release.

This fork has no in-app updater and does not publish update feeds. Users install
new versions manually from GitHub Releases.
