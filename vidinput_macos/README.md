# PTLib vidinput_macos Plugin

macOS AVFoundation video capture plugin for PTLib.

## Overview

This plugin provides native macOS camera support for PTLib-based applications using AVFoundation framework.

## Features

- Native AVFoundation video capture
- Support for FaceTime HD Camera and external USB cameras
- Frame rate control (up to 30fps)
- Multiple resolution support (CIF, QCIF, 4CIF, etc.)
- Automatic format conversion (NV12/UYVY → YUV420P)

## Files

- `vidinput_macos.h` - Header file with class definitions
- `vidinput_macos.mm` - Objective-C++ implementation
- `Makefile` - Build configuration

## Building

```bash
make
```

## Dependencies

- macOS 10.13+
- Xcode Command Line Tools
- PTLib library
- AVFoundation.framework
- CoreMedia.framework
- CoreVideo.framework

## Modifications

This version includes:
- Enhanced frame grabbing with proper synchronization
- Buffer management optimizations
- Compatibility fixes for modern macOS versions

## License

MPL 1.0 (same as PTLib)
