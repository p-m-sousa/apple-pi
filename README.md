# ApplePi

ApplePi is an independent, native macOS desktop client for
[Pi](https://pi.dev), the extensible coding agent. It turns Pi sessions into a
focused project-and-task workspace with a native transcript, composer,
inspector, package manager, and terminal—while Pi remains responsible for the
agent runtime, models, tools, credentials, project trust, sessions, and
extensions.

ApplePi is not an Apple product and is not affiliated with or endorsed by
Apple or the Pi developers. Pi is installed separately and is not redistributed
inside ApplePi.

## Features

- A native SwiftUI workspace for projects, standalone tasks, archived sessions,
  pinned items, search, and task sorting.
- Efficient native conversations over Pi's JSONL RPC protocol, including
  streaming responses, tool activity, thinking output, Markdown, and pasted
  images.
- Per-task runtime management with visible queueing, concurrency controls, idle
  eviction, and isolated Git worktrees for repository tasks.
- Model and thinking-level selection, prompt queue behavior, session branching,
  rename/archive/delete actions, and HTML or raw JSONL exports.
- A Pi inspector for session branches, loaded resources, and extension health.
- Pi package discovery, installation, removal, updates, and local extension
  development with file watching and reload support.
- An embedded SwiftTerm window for Pi login, provider configuration, and
  extension interfaces that require the full terminal UI.
- System, light, and dark appearances with a compact Apple-silicon-native app
  bundle and no ApplePi updater, background helper, or menu-bar process.

## Installation

### Requirements

- An Apple-silicon Mac (`arm64`)
- macOS 26.0 or later
- Pi 0.84.2 or later in the 0.84.x series

ApplePi currently tests Pi versions `>= 0.84.2` and `< 0.85.0`. Install the
tested version with npm:

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0.84.2
pi --version
```

See Pi's [Quickstart](https://pi.dev/docs/latest/quickstart) for provider login
and alternative installation methods. ApplePi discovers Pi from an executable
chosen in Settings, your login-shell `PATH`, or common package-manager
locations.

### Install ApplePi from GitHub

1. Download `ApplePi-<version>.dmg` and `SHA256SUMS` from the
   [latest GitHub release](../../releases/latest).
2. Optionally run `shasum -a 256 ApplePi-<version>.dmg` in Terminal and compare
   the result with the matching line in `SHA256SUMS`.
3. Open the DMG and drag ApplePi into the Applications folder.
4. Launch ApplePi from Applications. Official release artifacts are signed with
   Developer ID and notarized by Apple for Gatekeeper.
5. Complete first-run setup. If Pi is not detected, install it or choose its
   executable under **ApplePi → Settings → Pi Runtime**, then retry detection.

To update ApplePi, quit it and replace the existing app in Applications with
the newer release. ApplePi does not currently update itself.

### Build and run from source

Building from source requires Xcode 26 or later. The bootstrap script downloads
the pinned XcodeGen 2.45.4 binary, verifies its SHA-256 checksum, regenerates the
Xcode project, and resolves the exact Swift package versions.

```sh
./script/bootstrap.sh
./script/build_and_run.sh
```

`project.yml` is the source of truth for the committed `ApplePi.xcodeproj`.
Useful local diagnostic modes are `--debug`, `--logs`, `--telemetry`, and
`--verify` on `script/build_and_run.sh`.

## Trust, privacy, and security

- ApplePi itself records no telemetry or analytics. It has no analytics SDK and
  does not send ApplePi usage data to a service.
- Pi owns model-provider traffic, provider login, credential storage, its own
  optional telemetry setting, tools, and project-trust decisions. ApplePi does
  not copy or store provider credentials and does not override `PI_TELEMETRY`.
- ApplePi reads Pi session files and selected project folders so it can display
  conversations and let Pi work in those projects. The app is therefore not App
  Sandbox-enabled.
- Pi tools, extensions, skills, prompts, themes, and packages execute with your
  user account's filesystem and network authority. Review package source before
  installing it; ApplePi does not add a separate permissions or sandbox layer.
- The package Discover view connects to `https://pi.dev/packages`, rejects
  navigation outside `pi.dev`, and uses a nonpersistent WebKit data store.
- ApplePi has no bundled Pi executable. This keeps the runtime independently
  installable and updatable and avoids redistributing Pi's transitive runtime
  dependencies.
- Official GitHub artifacts are expected to pass Developer ID signature,
  notarization-ticket, checksum, and Gatekeeper validation before a draft
  release is published.

For Pi's boundary and trust model, read the
[Pi security documentation](https://pi.dev/docs/latest/security). To report a
possible ApplePi vulnerability, follow [SECURITY.md](SECURITY.md).

## Technical details

- **Platform:** macOS 26+, Apple silicon only
- **UI:** Swift 6, SwiftUI, and narrow AppKit/WebKit integrations
- **Terminal:** [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm)
- **Pi integration:** a bundled TypeScript bridge executed by the separately
  installed Pi runtime over nonce-correlated, size-bounded JSONL RPC
- **Runtime compatibility:** Pi `>= 0.84.2` and `< 0.85.0`; an advanced override
  is accepted only after the native bridge capability probe succeeds
- **Runtime discovery:** saved executable, login-shell `PATH`, then common
  locations; there is no bundled fallback
- **Bundle ID:** `com.paulsousa.ApplePi`
- **Local ApplePi data:** `~/Library/Application Support/Apple Pi`
- **Rebuildable caches:** `~/Library/Caches/Apple Pi`
- **Pi sessions:** Pi's configured session directory, normally
  `~/.pi/agent/sessions`
- **Distribution:** size-optimized arm64 DMG and ZIP, Developer ID signing,
  hardened runtime, Apple notarization and stapling, Gatekeeper checks, and
  SHA-256 checksums

The protocol-facing behavior follows Pi's public documentation for
[RPC](https://pi.dev/docs/latest/rpc),
[extensions](https://pi.dev/docs/latest/extensions),
[packages](https://pi.dev/docs/latest/packages), and
[session files](https://pi.dev/docs/latest/session-format). Maintainer release
setup and the exact signing pipeline are documented in
[docs/RELEASING.md](docs/RELEASING.md).

## License

ApplePi is released under the [MIT License](LICENSE), Copyright © 2026 Paul
Sousa.

The distributed SwiftTerm dependency remains under its own MIT license and is
reproduced in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Pi is a separate
prerequisite, is not incorporated into ApplePi release artifacts, and remains
under the licenses supplied by its own project and installation.
