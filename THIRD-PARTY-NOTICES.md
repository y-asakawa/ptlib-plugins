# Third-Party Notices

This repository contains PTLib plugin source code and uses third-party
libraries and platform frameworks.

The license notice in each source file is authoritative.

## PTLib

The plugins are designed for use with PTLib and may contain code derived from
PTLib plugin examples or interfaces.

PTLib is distributed under the Mozilla Public License Version 1.0, subject to
the notices in its individual source files.

Project: <https://github.com/willamowius/ptlib>

## PortAudio

The `sound_portaudio` plugin uses PortAudio as an external build and runtime
dependency. PortAudio source code and headers are not bundled in this
repository.

PortAudio remains under its own permissive license and is not relicensed under
the license of this repository. See
[LICENSES/PortAudio-license.txt](LICENSES/PortAudio-license.txt).

Project: <https://www.portaudio.com/>

The exact PortAudio version used for a binary build should be recorded for each
release.

## Apple Frameworks

The `vidinput_macos` plugin uses Apple system frameworks, including:

- AVFoundation
- AppKit
- CoreFoundation
- CoreGraphics
- CoreMedia
- CoreVideo
- Foundation

These frameworks are supplied by macOS and are not redistributed as
third-party project files by this repository.

## Binary Distribution

Before distributing compiled plugin binaries, record the exact PTLib and
PortAudio versions used and inspect the completed binaries for non-system
dependencies.

On macOS, use:

```sh
otool -L vidinput_macos/vidinput_macos_pwplugin.dylib
otool -L sound_portaudio/portaudio_pwplugin.dylib
```

Include all applicable license texts and notices with the binary release.

No endorsement by PTLib, PortAudio, Apple, or their contributors is implied.
