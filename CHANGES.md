# Change Log

This file records local modifications to PTLib plugin source code maintained
in this repository.

## 2026

- Prepared the repository for public source distribution.
- Removed generated binaries and local editor or operating-system files from
  version control.
- Made PTLib build and installation paths configurable.
- Added repository documentation, security guidance, and third-party notices.

## 2025

- Added and maintained a macOS AVFoundation video input plugin.
- Added support for built-in and external video capture devices on macOS.
- Added frame synchronization and buffer-management improvements.
- Added format conversion from NV12 and UYVY to YUV420P.
- Added and maintained a PortAudio-based PTLib sound plugin.
- Added macOS, Apple Silicon, Homebrew, and Linux-oriented build support.

## Source Origin

The plugin sources are derived from or designed for use with PTLib. Original
copyright and license notices in individual source files remain authoritative.

PortAudio source code and headers are not bundled in this repository. The
`sound_portaudio` plugin links to a separately installed PortAudio library.

This log does not replace source-file copyright, license, or historical change
notices.
