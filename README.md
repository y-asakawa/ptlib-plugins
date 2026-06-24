# External PTLib Plugins

External PTLib plugins maintained in this repository.

## Plugins

| Directory | Plugin | Platform | Purpose |
| --- | --- | --- | --- |
| `vidinput_macos/` | `vidinput_macos` | macOS | AVFoundation video input |
| `sound_portaudio/` | `PortAudio` | macOS/Linux | PortAudio sound channel |

## Requirements

- PTLib development headers and libraries
- C++17 compiler
- macOS and Xcode Command Line Tools for `vidinput_macos`
- PortAudio development package for `sound_portaudio`

## Build: macOS Video Input

```sh
cd vidinput_macos
make PTLIB_DIR=/path/to/ptlib
make install PTLIB_DIR=/path/to/ptlib PTLIB_PLUGIN_DIR=/path/to/ptlib/lib_Darwin_aarch64
```

If PTLib headers and libraries are not under the same prefix, override them directly:

```sh
make PTLIB_INC="-I/path/to/ptlib/include" PTLIB_LIB="-L/path/to/ptlib/lib_Darwin_aarch64"
```

## Build: PortAudio Sound

The PortAudio plugin Makefile uses PTLib's `plugins.mak`.

```sh
cd sound_portaudio
make PTLIB_MAKE_DIR=/path/to/ptlib/make
```

PortAudio flags are detected with `pkg-config` when available. On Homebrew-based macOS environments, the Makefile falls back to `/opt/homebrew/include` and `/opt/homebrew/lib`.

## Repository Policy

The repository tracks source code, Makefiles, and project documentation only. Local editor files, `.DS_Store`, and generated plugin binaries such as `*_pwplugin.dylib` are intentionally ignored.

## License

The plugin source maintained in this repository is distributed under the
Mozilla Public License 1.0, except where an individual source file states
otherwise.

PortAudio is an external build and runtime dependency and remains under its
own license. See [LICENSE](LICENSE),
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md),
[LICENSES/PortAudio-license.txt](LICENSES/PortAudio-license.txt), and the
source-file headers.

Local modifications and source-origin notes are recorded in
[CHANGES.md](CHANGES.md).

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting guidance.
