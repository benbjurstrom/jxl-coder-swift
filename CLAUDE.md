# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

JxlCoder is a Swift library providing JPEG XL (JXL) image encoding and decoding support for iOS 14+ and macOS 11+. It wraps the native `libjxl` library (currently v0.10.1) and provides Swift APIs for single images and animations.

This is a fork of [awxkee/jxl-coder-swift](https://github.com/awxkee/jxl-coder-swift) with enhanced HDR encoding support for archival use cases.

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
   - `JXLSystemImage.mm` - Pixel extraction and format conversion
   - `RgbaScaler.mm` - Image scaling using Accelerate framework

3. **Precompiled Libraries** (`Sources/Frameworks/`)
   - XCFrameworks for libjxl, brotli, highway (SIMD), jpegli, skcms (color management)
   - Supports iOS arm64, iOS Simulator (arm64/x86_64), macOS (arm64/x86_64)
   - No build scripts in repo; maintainer compiles externally and commits binaries

### Key Types

- `JXLColorSpace`: `.rgb`, `.rgba`
- `JXLCompressionOption`: `.lossy`, `.lossless`
- `JXLPreferredPixelFormat`: `.optimal`, `.r8`, `.r16`
- `JXLEncoderDecodingSpeed`: Controls decode speed vs size tradeoff
- `JXLImageInfo`: Struct carrying image metadata (width, height, bitsPerComponent, isFloat, transferFunction, colorPrimaries, etc.)
- `JXLTransferFunction`: `.srgb`, `.linear`, `.pq`, `.hlg`
- `JXLColorPrimaries`: `.srgb`, `.displayP3`, `.bt2020`

### Plugin Integrations

- `JxlNukePlugin/` - Nuke image loading integration
- `JxlSDWebImageCoder/` - SDWebImage integration (single + animated)

## C++ Configuration

The project uses C++20 (`cxxLanguageStandard: .cxx20`). The highway SIMD library is configured with `HWY_COMPILE_ONLY_STATIC=1`.

## HDR Encoding

The `JXLCoder.encodeHDR()` method preserves HDR images including 8-bit standard, 10-bit HEIC HDR, and 12-14 bit RAW files.

### Key Files

- `Sources/jxlc/JXLSystemImage.mm` - `jxlExtractPixels` and `jxlGetImageInfo` methods
- `Sources/jxlc/JxlWorker.cpp` - `EncodeJxlHDR` function
- `Sources/jxlc/JxlInternalCoder.mm` - `encodeHDR:` Objective-C method
- `Sources/JxlCoder/JXLCoder.swift` - `encodeHDR` Swift API

### Pixel Extraction Pipeline

The pixel extraction uses `CGDataProviderCopyData` to read raw pixels directly without redrawing, which preserves HDR values. The pipeline handles:

1. **Format detection** - Analyzes `CGBitmapInfo` to determine pixel layout
2. **Channel order normalization** - Converts BGRA/ARGB to RGBA
3. **Alpha handling** - Unpremultiplies if needed, strips dummy alpha channels
4. **Bit depth handling** - Supports 8-bit, 16-bit integer, float16, and float32

### CGImage Format Notes

**16-bit formats**: `kCGBitmapByteOrder16Little` affects component endianness only, NOT channel order. On little-endian systems, 16Little is native and requires no byte swapping. Channel order is determined solely by `alphaFirst` (premultipliedFirst/First vs premultipliedLast/Last).

**Packed 10-bit formats**: Formats like ARGB2101010 or RGBX1010102 pack 3×10-bit RGB + 2-bit padding into 32 bits. These are detected when `bitsPerComponent == 10 && bitsPerPixel == 32` and unpacked to 16-bit containers.

**Float16**: Uses `0x3C00` for 1.0f (opaque alpha). vImage doesn't have native half-float unpremultiply, so manual float16↔float32 conversion is used.

### Color Space Handling

HDR color spaces require special handling because `CGColorSpaceCopyICCData()` returns NULL for built-in HDR color spaces like `kCGColorSpaceITUR_2100_PQ`.

**Detection hierarchy:**
1. Try named color space detection (parse `CGColorSpaceCopyName()` for PQ, HLG, Linear, P3, 2020, etc.)
2. For "unnamed" color spaces, use CGColorSpace API functions:
   - `CGColorSpaceUsesITUR_2100TF()` (macOS 11+) → BT.2100 (PQ or HLG)
   - `CGColorSpaceIsHDR()` (macOS 10.15+) → Extended range HDR
   - `CGColorSpaceIsWideGamutRGB()` (macOS 10.12+) → Wide gamut (P3/BT.2020)
3. Fall back to sRGB only when nothing else matches

**Encoder color handling:**
- For lossless with valid ICC profile: `uses_original_profile = TRUE`, embed ICC
- For lossy or when ICC fails: Use `JxlColorEncoding` with detected transfer function and primaries
- The `uses_original_profile` flag is only set TRUE after confirming ICC profile acceptance

### Bit Depth Optimization

For sources like 10-bit HEIC stored in 16-bit containers:
- `containerBitsPerSample` (16) - actual memory layout for pixel format
- `originalBitsPerSample` (10) - significant precision for `bits_per_sample`

This tells libjxl only 10 bits are significant, improving lossless compression.

For 16-bit integer data, `detectActualBitDepth16()` samples pixel values to detect if data is actually 8, 10, 12, or 14 bits stored in a 16-bit container.

### Supported Source Formats

| Source Type | Bits | Container | Transfer | Primaries |
|-------------|------|-----------|----------|-----------|
| Standard JPEG/PNG | 8 | 8-bit | sRGB | sRGB |
| iPhone HEIC | 8/10 | 16-bit | sRGB/PQ | P3/BT.2020 |
| iPhone ProRAW | 12-14 | 16-bit | PQ/HLG | BT.2020 |
| Canon HIF/RAW | 10-14 | Packed/16-bit | PQ | BT.2020 |

## Common Issues

### Washed-out colors (ungraded log appearance)
Usually caused by transfer function mismatch. Verify the color space is being detected correctly - check if `CGColorSpaceUsesITUR_2100TF()` returns true for HDR content with "unnamed" color space.

### Film negative / inverted colors on 16-bit
For 16-bit formats, the byte order flag affects component endianness, NOT channel order. Don't swap BGR↔RGB based on `byteOrderLittle` for 16-bit data.

### Encoding failure for packed 10-bit
Packed 10-bit formats (32bpp with 10bpc) need special unpacking via `unpackPacked10BitToRGB16()`.

### Large lossless file sizes
Check if `originalBitsPerComponent` is being set correctly. 10-bit sources stored in 16-bit containers should have `originalBitsPerSample = 10` to avoid encoding 6 bits of padding.
