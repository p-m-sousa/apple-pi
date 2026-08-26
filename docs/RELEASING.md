# Releasing ApplePi outside the Mac App Store

ApplePi's release pipeline produces an Apple-silicon DMG and ZIP, signs the app
with a **Developer ID Application** certificate, enables the hardened runtime,
submits the app and disk image to Apple's notary service, staples the tickets,
checks Gatekeeper, and writes `SHA256SUMS`. It does not use App Store review,
App Store provisioning, or a Mac App Distribution certificate.

The GitHub workflow deliberately creates a **draft** release for a pushed
version tag. Publishing remains a manual final decision after installation and
smoke testing.

## 1. Apple prerequisites

You need:

- an active Apple Developer Program membership;
- Account Holder access to create a Developer ID certificate, or access to an
  existing team certificate and private key;
- Account Holder or Admin access in App Store Connect to create a Team API key
  usable by `notarytool`;
- an Apple-silicon Mac running macOS 26+ with Xcode 26+; and
- a GitHub repository with Actions enabled.

Apple's documentation distinguishes **Developer ID Application**, which signs
apps distributed outside the Mac App Store, from **Mac App Distribution**,
which is for the store. A DMG/ZIP release does not need a Developer ID Installer
certificate because no signed `.pkg` installer is produced.

References:

- [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Signing Mac software with Developer ID](https://developer.apple.com/developer-id/)
- [Prepare software for notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Create App Store Connect API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api)

## 2. Create and install the Developer ID certificate

The simplest native workflow is Xcode:

1. Open **Xcode → Settings → Accounts** and select the Apple Developer team.
2. Open **Manage Certificates**, click **+**, and choose **Developer ID
   Application**.
3. Confirm that the certificate and its private key appear together in
   **Keychain Access → My Certificates**.
4. Verify the identity in Terminal:

   ```sh
   security find-identity -v -p codesigning
   ```

The output must contain a valid identity beginning with `Developer ID
Application:`. Keep the exact displayed identity for
`APPLE_PI_SIGNING_IDENTITY`.

For GitHub Actions, export the certificate and private key from Keychain Access
as a password-protected `.p12`. Store the file and its password securely; never
commit either one.

## 3. Create notarization credentials

In **App Store Connect → Users and Access → Integrations → Team Keys**, create a
Team API key and download its `AuthKey_<KEY_ID>.p8` private key. Apple permits
the private key to be downloaded only once. Record the Key ID and Issuer ID and
store the `.p8` outside the repository.

Validate and save the key in the local Keychain:

```sh
xcrun notarytool store-credentials applepi-notary \
  --key /secure/path/AuthKey_KEYID.p8 \
  --key-id KEYID \
  --issuer ISSUER-UUID
```

`notarytool` validates the credentials before saving them by default.

## 4. Configure the GitHub release environment

Create a GitHub Actions environment named `release`. Adding a required reviewer
is recommended so a tag cannot use signing credentials without an explicit
approval.

Add these six environment secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Base64 contents of the exported `.p12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `DEVELOPER_ID_APPLICATION_IDENTITY` | Exact `Developer ID Application: …` identity |
| `APPLE_API_PRIVATE_KEY_BASE64` | Base64 contents of `AuthKey_<KEY_ID>.p8` |
| `APPLE_API_KEY_ID` | App Store Connect Team API Key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect Issuer ID |

On macOS, copy the base64 values without creating an unencrypted intermediate
file:

```sh
base64 -i /secure/path/ApplePi-Developer-ID.p12 | pbcopy
base64 -i /secure/path/AuthKey_KEYID.p8 | pbcopy
```

GitHub documents environment secrets under **Settings → Environments →
release**. Do not put signing material in the repository, workflow YAML, release
notes, issues, or logs.

## 5. Run a local signed package rehearsal

First run the complete secret-free quality gate:

```sh
./script/xcodegen.sh generate
APPLE_PI_TEST_DERIVED_DATA_PATH=.build/ReleaseRehearsalTests \
  ./script/test_release_suite.sh
```

Then build, sign, notarize, staple, and validate version 0.1.0:

```sh
APPLE_PI_VERSION=0.1.0 \
APPLE_PI_BUILD_NUMBER=1 \
APPLE_PI_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
APPLE_PI_NOTARY_PROFILE=applepi-notary \
./script/package_release.sh
```

Use `--skip-notarization` only for diagnosis. Its output is not suitable for a
public release because it has no notarization ticket and skips Gatekeeper's
notarized-distribution checks.

The successful script writes:

```text
dist/ApplePi-0.1.0.dmg
dist/ApplePi-0.1.0.zip
dist/SHA256SUMS
```

The script fails if the app exceeds its size budget, contains a bundled
`PiRuntime`, has an invalid signature, is rejected by notarization, fails
stapling or Gatekeeper, or produces an invalid artifact. A notarization failure
also saves Apple's submission log under `dist/`.

## 6. Install and smoke-test the release candidate

Test the exact DMG that will be uploaded, preferably in a clean macOS user
account:

1. Verify the checksum against `SHA256SUMS`.
2. Open the DMG and drag ApplePi to Applications.
3. Launch it from Finder without bypassing Gatekeeper.
4. Confirm first-run setup with Pi absent: installation help appears, provider
   configuration is disabled, and the rest of the app remains browsable.
5. Install Pi 0.84.2, retry detection, and confirm native task creation,
   streaming, tool output, stop/restart, and session persistence.
6. Configure a provider through Pi's terminal UI without exposing credentials
   to ApplePi.
7. Add a Git repository, create an isolated worktree task, and verify that the
   source checkout remains intact.
8. Install or load a trusted test extension, reload it, then remove it.
9. Export one session as HTML and raw JSONL.
10. Quit and relaunch ApplePi; confirm projects and session presentation state
    are restored.

Optional command-line verification:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/ApplePi.app
spctl --assess --type execute --verbose=2 /Applications/ApplePi.app
xcrun stapler validate /Applications/ApplePi.app
```

## 7. Stage the GitHub release

Before the first release, authenticate GitHub CLI and create or connect the
repository:

```sh
gh auth login
git remote add origin git@github.com:OWNER/REPOSITORY.git
git push -u origin main
```

Run **Release** manually with version `0.1.0` once to prove that preflight,
signing, notarization, and artifact upload work. A manual run uploads workflow
artifacts only; it does not create a GitHub Release.

When the rehearsal succeeds and `main` is at the intended release commit:

```sh
git status --short
git tag -a v0.1.0 -m 'ApplePi 0.1.0'
git push origin v0.1.0
```

The tag-triggered workflow reruns every quality gate, builds fresh signed and
notarized artifacts, and creates or updates a **draft** GitHub Release. It will
refuse to overwrite an already-published release.

## 8. Publish manually

Open the draft release on GitHub and verify:

- the tag and target commit are correct;
- release notes are accurate and contain no private data;
- the DMG, ZIP, and `SHA256SUMS` are attached;
- local checksums match the attached checksum file;
- the downloaded DMG installs and launches successfully; and
- signature, stapling, and Gatekeeper checks pass on the downloaded copy.

Only then click **Publish release**. Keep the immutable tag and uploaded
artifacts aligned; do not move a published version tag to another commit.

## 9. Recovery and key hygiene

- A failed workflow does not publish anything. Fix the cause and rerun it.
- A draft release may be updated by another successful run for the same tag.
- The workflow refuses to replace assets on a published release. Publish a new
  patch version instead.
- Revoke an App Store Connect key immediately if its `.p8` is exposed.
- Revoke and replace a Developer ID certificate if its private key or `.p12`
  is exposed.
- Keep an encrypted backup of the certificate private key. A downloaded `.cer`
  alone cannot sign updates.
