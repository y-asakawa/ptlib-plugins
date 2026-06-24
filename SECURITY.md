# Security Policy

## Supported Versions

Only the current `master` branch is maintained for security fixes.

## Reporting a Vulnerability

Please report suspected security vulnerabilities privately by opening a GitHub security advisory for this repository.

Do not publish exploit details in a public issue before maintainers have had a chance to investigate.

When reporting, include:

- Affected plugin and commit hash
- Operating system and PTLib version
- Steps to reproduce
- Impact and any known workaround

## Scope

Security reports should focus on vulnerabilities in this repository's plugin code and build files. Issues in PTLib, PortAudio, macOS frameworks, or other upstream dependencies should also be reported to the relevant upstream project.

Video frames, audio samples, device metadata, and device-change notifications must be treated as untrusted input.
