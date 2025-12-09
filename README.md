# JxlCoder (HDR Fork)

> **This is a fork of [awxkee/jxl-coder-swift](https://github.com/awxkee/jxl-coder-swift)** with added HDR encoding support for archiving high bit-depth images.

## Warning: AI-Generated Code

This fork contains AI-generated code (Claude). While the implementation follows the libjxl API correctly, please:
- Test thoroughly with your specific image types before production use
- Verify encoded files can be decoded correctly
- Check that color profiles are preserved as expected

## What's Different in This Fork

The original library only supported 8-bit sRGB encoding, losing HDR data during the encode process. This fork adds:

- **HDR encoding via `encodeHDR()`** - preserves original bit depth (8/10/12/14/16-bit)
- **ICC profile passthrough** - maintains color space (BT.2020, Display P3, camera profiles)
- **Direct pixel extraction** - no redrawing, no precision loss
- **Lossless mode default** - ideal for archival

| Source Type | Original Library | This Fork |
|-------------|------------------|-----------|
| 8-bit JPEG/PNG | 8-bit sRGB | 8-bit + ICC |
| 10-bit HEIC HDR | 8-bit sRGB (HDR lost) | 16-bit + BT.2020 ICC |
| 12-14 bit RAW | 8-bit sRGB (data lost) | 16-bit + camera ICC |

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/anthropics/jxl-coder-swift.git", branch: "main")
]
```

## Usage

### HDR Encoding (New)

```swift
import JxlCoder

// Load any image - 8-bit, 10-bit HEIC, or RAW
let image = UIImage(contentsOfFile: "/path/to/image.heic")!

// Encode preserving full fidelity (lossless, max effort)
let jxlData = try JXLCoder.encodeHDR(
    image: image,
    compressionOption: .loseless,  // Use .lossy for smaller files
    effort: 9                       // 1-9, higher = smaller but slower
)

// Save to file
try jxlData.write(to: URL(fileURLWithPath: "/path/to/output.jxl"))
```

### Lossy HDR Encoding

```swift
// For smaller files with minimal quality loss
let jxlData = try JXLCoder.encodeHDR(
    image: image,
    compressionOption: .lossy,
    effort: 7,
    quality: 90  // 0-100, higher = better quality
)
```

### Decoding (Unchanged)

```swift
// Decode JXL back to UIImage/NSImage
let decoded = try JXLCoder.decode(data: jxlData)

// Check if decoded image is HDR
if decoded.isHighDynamicRange {
    print("HDR preserved!")
}
```

### Standard Encoding (Original API)

The original encoding API is still available for backwards compatibility:

```swift
let data = try JXLCoder.encode(image: image)  // 8-bit sRGB only
```

## API Reference

### `JXLCoder.encodeHDR`

```swift
public static func encodeHDR(
    image: JXLPlatformImage,
    compressionOption: JXLCompressionOption = .lossless,
    effort: Int = 7,
    quality: Int = 0,
    decodingSpeed: JXLEncoderDecodingSpeed = .slowest
) throws -> Data
```

**Parameters:**
- `image`: Source UIImage/NSImage (any bit depth)
- `compressionOption`: `.loseless` (default, best for archival) or `.lossy`
- `effort`: 1-9, compression effort (default 7). Higher = smaller file, slower encode
- `quality`: 0-100, only for lossy mode. 0 = best quality (distance ~1.0)
- `decodingSpeed`: Trade-off between decode speed and file size

**Returns:** JXL encoded Data

## Platform Support

- iOS 13.0+
- macOS 12.0+

## How It Works

The HDR encoding pipeline:

1. **Direct pixel access** - Uses `CGDataProviderCopyData` instead of redrawing, preserving original values
2. **ICC extraction** - Captures the source color profile via `CGColorSpaceCopyICCData`
3. **Bit depth detection** - Reads `CGImageGetBitsPerComponent` to determine 8/16-bit
4. **Format normalization** - Handles BGRA/ARGB/premultiplied alpha variations
5. **libjxl encoding** - Uses `JxlEncoderSetICCProfile` and appropriate bit depth settings

## License

Same as original: See [LICENSE](LICENSE) file.

## Original Library

For the original library without HDR encoding, see [awxkee/jxl-coder-swift](https://github.com/awxkee/jxl-coder-swift).

The original library provides:
- JXL decoding with HDR support
- 8-bit sRGB encoding
- Animation support
- JPEG lossless transcoding
- Jpegli encoding
- Nuke and SDWebImage plugins
