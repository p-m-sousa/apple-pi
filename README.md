# ApplePi — unofficial

ApplePi is a lightweight, native macOS interface for [Pi](https://pi.dev), the
agentic coding harness. It presents Pi sessions in a focused three-column
workspace—projects and tasks, a native transcript and composer, and a Pi-only
inspector—while Pi remains responsible for agents, models, tools, credentials,
trust, sessions, and packages.

> ApplePi is an independent, unofficial project. It is not affiliated with or
> endorsed by Apple, OpenAI, or the Pi developers. Apple, OpenAI, Codex, and Pi
> may be trademarks of their respective owners.

## Highlights

- Native SwiftUI application for Apple-silicon Macs running macOS 26 or later.
- Codex-style Projects and Tasks navigation: saved folders contain their own
  task history, while standalone tasks remain separate and first-class.
- Pi JSONL RPC for efficient native conversations and an embedded SwiftTerm
  window for login, configuration, and terminal-only extension interfaces.
- Light, dark, and system appearances using an original ApplePi identity and
  the palette published in Pi's [press kit](https://pi.dev/press-kit).
- Pi-compatible extensions, skills, prompts, themes, and package management;
  there is intentionally no Apple-Pi-specific plugin API.
- Lazy session indexing and transcript rendering, bounded output buffers,
  process concurrency limits, and idle runtime eviction.
- No ApplePi telemetry, updater, background helper, or menu-bar process.

The protocol and compatibility behavior follow Pi's public documentation for
[RPC](https://pi.dev/docs/latest/rpc),
[extensions](https://pi.dev/docs/latest/extensions),
[packages](https://pi.dev/docs/latest/packages), and
[session files](https://pi.dev/docs/latest/session-format).

## Requirements

- Apple-silicon Mac
- macOS 26.0 or later
- [Pi](https://pi.dev) 0.84.2 or later in the 0.84.x series
- Xcode 26.0 or later (Xcode 27 is also supported locally)

The build scripts download the official XcodeGen 2.45.4 release into
`.build/tools`, verify its archive and executable SHA-256 values, and use that
exact version for local and CI project generation. A system-wide XcodeGen
installation is not required.

Xcode 27 may install its Metal compiler on demand. If SwiftTerm's shader build
reports that the Metal toolchain is missing, install the official component once:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Swift Package Manager resolves exact SwiftTerm 1.20.0 sources from
`project.yml` and the committed `Package.resolved` file.

## Build and run

```sh
./script/bootstrap.sh
./script/build_and_run.sh
```

`ApplePi.xcodeproj` is generated and committed for convenience;
`project.yml` remains its source of truth.

The build script stops an existing ApplePi process, builds the Debug app into
project-local DerivedData, and opens the fresh app bundle. Diagnostic modes are:

```sh
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --verify
```

ApplePi discovers a compatible Pi executable selected in Settings, available
through the login-shell `PATH`, or installed in a common location. Pi is a
separate prerequisite and is not bundled into ApplePi release artifacts.

## Extensions and security

Pi extensions and packages execute with the same filesystem and network
authority as Pi itself. ApplePi deliberately does not add a sandbox or a
permission facade, and it uses Pi's own project-trust decisions. Review package
sources before installation; see Pi's [security model](https://pi.dev/docs/latest/security).

The host app has no App Sandbox entitlement because it must launch Pi for
user-selected projects. The native ApplePi host receives no elevated
code-signing entitlement.

ApplePi records no analytics. Provider traffic, optional Pi telemetry, and
extension network behavior belong to Pi and installed extensions, not ApplePi.
The package catalog opens `pi.dev/packages` in a nonpersistent WebKit data store.

## Performance verification

Normal CI and the secret-free release preflight regenerate the project, run the
unit and UI suites, analyze first-party code, build the size-optimized Release
app, and enforce its 15 MiB host budget. Packaging separately enforces the 20 MiB
ZIP budget.

The weekly/manual `Resource benchmark` workflow records clean-build and test
resource usage plus lossless indexing and transcript timings for 1, 10, and
100 MiB JSONL fixtures. It uploads measurements for trend comparison without
using shared-runner wall-clock timings as brittle pass/fail gates. Local Release
profiles expose `ProcessLaunch`, `ProcessLifetime`, `SessionIndexScan`,
`TranscriptLoad`, and `MarkdownRender` intervals through Instruments' Points of
Interest; no profiling data is sent or persisted by the app.

## Release engineering

`script/package_release.sh` creates a size-optimized arm64 archive, signs nested
Mach-O files inside-out, signs the app with Developer ID, notarizes, staples,
validates Gatekeeper, and produces DMG, ZIP, and `SHA256SUMS` artifacts in
`dist/`. The packager fails if a `PiRuntime` resource is present.

Required release environment:

- `APPLE_PI_SIGNING_IDENTITY`
- either `APPLE_PI_NOTARY_PROFILE`, or
  `APPLE_PI_NOTARY_KEY`, `APPLE_PI_NOTARY_KEY_ID`, and
  `APPLE_PI_NOTARY_ISSUER_ID`
- optional `APPLE_PI_VERSION` (defaults to `0.1.0`)
- optional `APPLE_PI_BUILD_NUMBER` (positive integer; GitHub uses the workflow run number)
- optional host-app and ZIP byte budgets; defaults are 15 MiB and 20 MiB

Use `--skip-notarization` only to inspect a locally signed package. GitHub's
release workflow expects Developer ID and App Store Connect key material in
repository secrets, runs on the arm64 `macos-26` image with Xcode 26.6, and
publishes notarized DMG and ZIP artifacts for tags beginning with `v`.

Configure these GitHub Actions secrets before publishing:

- `DEVELOPER_ID_CERTIFICATE_P12_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `DEVELOPER_ID_APPLICATION_IDENTITY`
- `APPLE_API_PRIVATE_KEY_BASE64`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`

## License

ApplePi is available under the [MIT License](LICENSE). Distributed dependencies
retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
