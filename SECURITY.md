# Security policy

## Supported versions

Security fixes are provided for the latest published ApplePi release. Users
should update to the newest release before reporting an issue that may already
have been fixed.

## Reporting a vulnerability

Please use **Report a vulnerability** on this repository's GitHub Security tab
so the report remains private. Include:

- the affected ApplePi and macOS versions;
- the Pi version and installation method;
- clear reproduction steps and expected versus actual behavior;
- the security impact and any suggested mitigation; and
- logs or proof-of-concept material with credentials, tokens, personal paths,
  and private source code removed.

Do not open a public issue for an unpatched vulnerability. If private
vulnerability reporting is not available, contact the repository owner through
their GitHub profile and request a private reporting channel without including
exploit details in the first message.

You should receive an acknowledgement within seven days. Please allow time for
validation, a fix, release preparation, and coordinated disclosure.

## Security boundaries

ApplePi is a native interface to a separately installed Pi runtime. It is not a
sandbox for Pi, model-provider traffic, tools, or packages.

- ApplePi is not App Sandbox-enabled because it launches Pi and works with
  user-selected repositories and Pi session files.
- Pi and Pi packages execute with the current user's filesystem and network
  permissions. Install extensions and packages only from sources you trust.
- Provider credentials and authentication are owned by Pi. ApplePi does not
  store or validate those credentials.
- The package Discover view is limited to `pi.dev` and uses a nonpersistent
  WebKit data store.
- Official ApplePi releases should be downloaded from this repository's GitHub
  Releases page and verified by Developer ID signature, Apple notarization, and
  the published SHA-256 checksums.

Issues caused solely by an upstream Pi release, model provider, or third-party
Pi package should be reported to that project's maintainer. Reports showing
that ApplePi crosses or weakens one of the boundaries above remain in scope.
