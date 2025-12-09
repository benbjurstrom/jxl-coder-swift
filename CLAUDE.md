# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

JxlCoder is a Swift library providing JPEG XL (JXL) image encoding and decoding support for iOS 13+ and macOS 12+. It wraps the native `libjxl` library and provides Swift APIs for single images and animations.

## Build Commands

**Swift Package Manager:**
```bash
swift build
```

**Xcode:**
Open `Jxl Coder.xcodeproj` or use the workspace `Jxl Coder.xcworkspace`

**CocoaPods:**
```bash
pod install
```

## Architecture

### Layer Structure

1. **Swift API Layer** (`Sources/JxlCoder/`)
   - `JXLCoder.swift` - Main static API for encoding/decoding single images and JPEG transcoding
   - `JXLAnimatedDecoder.swift` - Animated JXL decoding (frame-by-frame access)
   - `JXLAnimatedEncoder.swift` - Animated JXL encoding (add frames with durations)
   - `JpegLiEncoder.swift` - Jpegli encoder wrapper
   - `JXLSupport.swift` - Platform image typealias (`JXLPlatformImage` = UIImage/NSImage)

2. **C++/Objective-C++ Bridge** (`Sources/jxlc/`)
   - Objective-C++ wrappers that bridge Swift to C++ implementation
   - `JxlInternalCoder.mm` - Core encoding/decoding implementation
   - `CJpegXLAnimatedDecoder.mm` / `CJpegXLAnimatedEncoder.mm` - Animation handling
   - `JxlWorker.cpp` - Low-level JXL processing using libjxl APIs
   - `RgbaScaler.mm` - Image scaling using Accelerate framework

3. **Precompiled Libraries** (`Sources/Frameworks/`)
   - XCFrameworks for libjxl, brotli, highway (SIMD), jpegli, skcms (color management)
   - Supports iOS arm64, iOS Simulator (arm64/x86_64), macOS (arm64/x86_64)

### Key Types

- `JXLColorSpace`: `.rgb`, `.rgba`
- `JXLCompressionOption`: `.lossy`, `.loseless` (note: typo in original, kept for compatibility)
- `JXLPreferredPixelFormat`: `.optimal`, `.r8`, `.r16`
- `JXLEncoderDecodingSpeed`: Controls decode speed vs size tradeoff
- `JXLImageInfo`: Struct carrying image metadata (width, height, bitsPerComponent, isFloat, etc.)

### Plugin Integrations

- `JxlNukePlugin/` - Nuke image loading integration
- `JxlSDWebImageCoder/` - SDWebImage integration (single + animated)

## C++ Configuration

The project uses C++20 (`cxxLanguageStandard: .cxx20`). The highway SIMD library is configured with `HWY_COMPILE_ONLY_STATIC=1`.

## HDR Encoding

This fork adds HDR encoding support via `JXLCoder.encodeHDR()`. The implementation:

1. **Pixel extraction** (`JXLSystemImage.mm:jxlExtractPixels`) - Uses `CGDataProviderCopyData` to read raw pixels without redrawing, preserving HDR values
2. **ICC profile extraction** - Captures color profile via `CGColorSpaceCopyICCData`
3. **HDR encoder** (`JxlWorker.cpp:EncodeJxlHDR`) - Sets ICC profile via `JxlEncoderSetICCProfile` and configures appropriate bit depth

Key files for HDR support:
- `Sources/jxlc/JXLSystemImage.mm` - `jxlExtractPixels` and `jxlGetImageInfo` methods
- `Sources/jxlc/JxlWorker.cpp` - `EncodeJxlHDR` function
- `Sources/jxlc/JxlInternalCoder.mm` - `encodeHDR:` Objective-C method
- `Sources/JxlCoder/JXLCoder.swift` - `encodeHDR` Swift API
