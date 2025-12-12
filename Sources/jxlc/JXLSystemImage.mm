//
//  JXLSystemImage.mm
//  JxclCoder [https://github.com/awxkee/jxl-coder-swift]
//
//  Created by Radzivon Bartoshyk on 27/08/2023.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import <Foundation/Foundation.h>
#import "JXLSystemImage.hpp"
#import <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>

@implementation JXLSystemImage (JXLColorData)

-(bool)unpremultiply:(nonnull unsigned char*)data width:(NSInteger)width height:(NSInteger)height {
    vImage_Buffer src = {
        .data = (void*)data,
        .width = static_cast<vImagePixelCount>(width),
        .height = static_cast<vImagePixelCount>(height),
        .rowBytes = static_cast<vImagePixelCount>(width * 4)
    };

    vImage_Buffer dest = {
        .data = data,
        .width = static_cast<vImagePixelCount>(width),
        .height = static_cast<vImagePixelCount>(height),
        .rowBytes = static_cast<vImagePixelCount>(width * 4)
    };
    vImage_Error vEerror = vImageUnpremultiplyData_RGBA8888(&src, &dest, kvImageNoFlags);
    if (vEerror != kvImageNoError) {
        return false;
    }
    return true;
}

- (bool)jxlGetImageInfo:(nonnull JXLImageInfo*)info {
    CGImageRef imageRef;
#if TARGET_OS_OSX
    imageRef = [self CGImageForProposedRect:nil context:nil hints:nil];
#else
    imageRef = [self CGImage];
#endif
    if (!imageRef) return false;

    info->width = (int)CGImageGetWidth(imageRef);
    info->height = (int)CGImageGetHeight(imageRef);
    info->bitsPerComponent = (int)CGImageGetBitsPerComponent(imageRef);
    info->bitsPerPixel = (int)CGImageGetBitsPerPixel(imageRef);
    info->originalBitsPerComponent = info->bitsPerComponent;  // Will be updated if unpacking occurs

    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
    info->isFloat = (bitmapInfo & kCGBitmapFloatComponents) != 0;

    CGImageAlphaInfo alphaInfo = (CGImageAlphaInfo)(bitmapInfo & kCGBitmapAlphaInfoMask);
    info->hasAlpha = (alphaInfo != kCGImageAlphaNone &&
                      alphaInfo != kCGImageAlphaNoneSkipLast &&
                      alphaInfo != kCGImageAlphaNoneSkipFirst);
    info->alphaPremultiplied = (alphaInfo == kCGImageAlphaPremultipliedLast ||
                                 alphaInfo == kCGImageAlphaPremultipliedFirst);
    info->alphaFirst = (alphaInfo == kCGImageAlphaPremultipliedFirst ||
                        alphaInfo == kCGImageAlphaFirst ||
                        alphaInfo == kCGImageAlphaNoneSkipFirst);

    CGBitmapInfo byteOrder = bitmapInfo & kCGBitmapByteOrderMask;
    info->byteOrderLittle = (byteOrder == kCGBitmapByteOrder16Little ||
                             byteOrder == kCGBitmapByteOrder32Little);

    // Detect packed 10-bit format: 10 bits per component, 32 bits per pixel = 3 components packed
    // Common formats: ARGB2101010 (2-bit alpha + 3x10-bit RGB) or RGBX1010102
    info->isPacked10Bit = (info->bitsPerComponent == 10 && info->bitsPerPixel == 32);

    // Detect HDR color space from CGColorSpace
    // Default to sRGB
    info->transferFunction = kTransferSRGB;
    info->colorPrimaries = kPrimariesSRGB;

    CGColorSpaceRef colorSpace = CGImageGetColorSpace(imageRef);
    if (colorSpace) {
        bool detectedFromName = false;
        CFStringRef name = CGColorSpaceCopyName(colorSpace);

        if (name) {
            // Check if it's a known named color space (not "unnamed")
            bool isUnnamed = (CFStringCompare(name, CFSTR("unnamed"), 0) == kCFCompareEqualTo);

            if (!isUnnamed) {
                // Check for PQ (Perceptual Quantizer) transfer function - HDR10, Dolby Vision
                if (CFStringFind(name, CFSTR("PQ"), 0).location != kCFNotFound ||
                    CFStringFind(name, CFSTR("2100_PQ"), 0).location != kCFNotFound) {
                    info->transferFunction = kTransferPQ;
                    detectedFromName = true;
                }
                // Check for HLG (Hybrid Log-Gamma) - BBC/NHK HDR
                else if (CFStringFind(name, CFSTR("HLG"), 0).location != kCFNotFound ||
                         CFStringFind(name, CFSTR("2100_HLG"), 0).location != kCFNotFound) {
                    info->transferFunction = kTransferHLG;
                    detectedFromName = true;
                }
                // Check for linear transfer
                else if (CFStringFind(name, CFSTR("Linear"), 0).location != kCFNotFound) {
                    info->transferFunction = kTransferLinear;
                    detectedFromName = true;
                }

                // Check for color primaries from name
                // Note: ITUR_2100 refers to the transfer function spec, not primaries.
                // The actual primaries could be BT.2020, P3, or even sRGB with PQ/HLG transfer.
                // We DON'T assume primaries from "2100" - need ICC profile or API detection.
                if (CFStringFind(name, CFSTR("P3"), 0).location != kCFNotFound ||
                    CFStringFind(name, CFSTR("DisplayP3"), 0).location != kCFNotFound) {
                    info->colorPrimaries = kPrimariesDisplayP3;
                    detectedFromName = true;
                }
                else if (CFStringFind(name, CFSTR("2020"), 0).location != kCFNotFound) {
                    // Only BT.2020 explicitly mentioned - NOT 2100 which is just transfer function
                    info->colorPrimaries = kPrimariesBT2020;
                    detectedFromName = true;
                }
            }

            CFRelease(name);
        }

        // Use CGColorSpace API functions for additional detection
        // These provide accurate info even when name-based detection is incomplete

        // If transfer function not yet detected, check for BT.2100 TF
        if (info->transferFunction == kTransferSRGB) {
            if (@available(macOS 11.0, iOS 14.0, *)) {
                if (CGColorSpaceUsesITUR_2100TF(colorSpace)) {
                    // BT.2100 uses either PQ or HLG - default to PQ
                    info->transferFunction = kTransferPQ;
                }
            }
        }

        // Detect primaries using API if not yet determined or still at default
        // This is critical because ITUR_2100_PQ can have P3 OR BT.2020 primaries
        if (info->colorPrimaries == kPrimariesSRGB) {
            if (@available(macOS 10.12, iOS 10.0, *)) {
                if (CGColorSpaceIsWideGamutRGB(colorSpace)) {
                    // Wide gamut - but is it P3 or BT.2020?
                    // Try to compare against known color spaces
                    CGColorSpaceRef displayP3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
                    CGColorSpaceRef p3Linear = CGColorSpaceCreateWithName(kCGColorSpaceLinearDisplayP3);
                    CGColorSpaceRef bt2020Linear = NULL;
                    CGColorSpaceRef bt2020PQ = NULL;

                    if (@available(macOS 11.0, iOS 14.0, *)) {
                        bt2020Linear = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
                        bt2020PQ = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
                    }

                    // Check if it matches BT.2020 explicitly
                    bool isBT2020 = false;
                    if (bt2020Linear && CFEqual(colorSpace, bt2020Linear)) isBT2020 = true;
                    // Note: Can't compare against bt2020PQ since that's what we might have

                    if (isBT2020) {
                        info->colorPrimaries = kPrimariesBT2020;
                    } else {
                        // Wide gamut but not BT.2020 - assume Display P3
                        // This is the most common case for iPhone HDR photos
                        info->colorPrimaries = kPrimariesDisplayP3;
                    }

                    if (displayP3) CGColorSpaceRelease(displayP3);
                    if (p3Linear) CGColorSpaceRelease(p3Linear);
                    if (bt2020Linear) CGColorSpaceRelease(bt2020Linear);
                    if (bt2020PQ) CGColorSpaceRelease(bt2020PQ);
                }
            }
        }

        // Final fallback for HDR content
        if (@available(macOS 10.15, iOS 13.0, *)) {
            if (CGColorSpaceIsHDR(colorSpace) && info->colorPrimaries == kPrimariesSRGB) {
                // HDR content with sRGB primaries detected - check wide gamut
                if (@available(macOS 10.12, iOS 10.0, *)) {
                    if (CGColorSpaceIsWideGamutRGB(colorSpace)) {
                        info->colorPrimaries = kPrimariesDisplayP3;
                    }
                }
            }
        }
    }

    return true;
}

// Pixel layout in memory based on CGBitmapInfo
// For 8-bit, 4-channel images:
//   alphaFirst + bigEndian:    A,R,G,B in memory
//   alphaFirst + littleEndian: B,G,R,A in memory (most common on iOS/macOS)
//   alphaLast + bigEndian:     R,G,B,A in memory
//   alphaLast + littleEndian:  A,B,G,R in memory

// Convert any 4-channel 8-bit format to RGBA order
static void convertToRGBA8(uint8_t* data, size_t pixelCount, bool alphaFirst, bool littleEndian, bool hasAlpha) {
    for (size_t i = 0; i < pixelCount; i++) {
        uint8_t* p = data + i * 4;
        uint8_t r, g, b, a;

        if (alphaFirst && littleEndian) {
            // Memory: B,G,R,A -> extract as BGRA
            b = p[0]; g = p[1]; r = p[2]; a = p[3];
        } else if (alphaFirst && !littleEndian) {
            // Memory: A,R,G,B -> extract as ARGB
            a = p[0]; r = p[1]; g = p[2]; b = p[3];
        } else if (!alphaFirst && littleEndian) {
            // Memory: A,B,G,R -> extract as ABGR
            a = p[0]; b = p[1]; g = p[2]; r = p[3];
        } else {
            // Memory: R,G,B,A -> already RGBA
            r = p[0]; g = p[1]; b = p[2]; a = p[3];
        }

        // Write as RGBA
        p[0] = r; p[1] = g; p[2] = b;
        p[3] = hasAlpha ? a : 255;  // Set opaque if no real alpha
    }
}

// Float16 1.0 representation (IEEE 754 half-precision)
static const uint16_t FLOAT16_ONE = 0x3C00;

// Convert any 4-channel 16-bit integer format to RGBA order
// NOTE: For 16-bit formats, byteOrder16Little affects component endianness, NOT channel order.
// On little-endian systems (all modern Macs), 16Little is native - no byte swapping needed.
// Channel order is determined solely by alphaFirst (premultipliedFirst/First vs premultipliedLast/Last).
static void convertToRGBA16_int(uint16_t* data, size_t pixelCount, bool alphaFirst, bool hasAlpha) {
    // If alpha is last (premultipliedLast, last, noneSkipLast), format is already RGBA - only fix alpha if needed
    if (!alphaFirst) {
        if (!hasAlpha) {
            // Just set alpha to opaque (integer max)
            for (size_t i = 0; i < pixelCount; i++) {
                data[i * 4 + 3] = 65535;
            }
        }
        // Otherwise data is already RGBA with valid alpha
        return;
    }

    // Alpha is first (premultipliedFirst, first, noneSkipFirst) - need to rotate ARGB -> RGBA
    for (size_t i = 0; i < pixelCount; i++) {
        uint16_t* p = data + i * 4;
        uint16_t a = p[0];
        uint16_t r = p[1];
        uint16_t g = p[2];
        uint16_t b = p[3];

        p[0] = r;
        p[1] = g;
        p[2] = b;
        p[3] = hasAlpha ? a : 65535;
    }
}

// Convert any 4-channel float16 format to RGBA order
static void convertToRGBA16_float(uint16_t* data, size_t pixelCount, bool alphaFirst, bool hasAlpha) {
    // If alpha is last, format is already RGBA - only fix alpha if needed
    if (!alphaFirst) {
        if (!hasAlpha) {
            // Set alpha to opaque (float16 1.0)
            for (size_t i = 0; i < pixelCount; i++) {
                data[i * 4 + 3] = FLOAT16_ONE;
            }
        }
        return;
    }

    // Alpha is first - need to rotate ARGB -> RGBA
    for (size_t i = 0; i < pixelCount; i++) {
        uint16_t* p = data + i * 4;
        uint16_t a = p[0];
        uint16_t r = p[1];
        uint16_t g = p[2];
        uint16_t b = p[3];

        p[0] = r;
        p[1] = g;
        p[2] = b;
        p[3] = hasAlpha ? a : FLOAT16_ONE;
    }
}

// Unpremultiply 8-bit RGBA (after conversion to RGBA order)
static void unpremultiplyRGBA8(uint8_t* data, size_t pixelCount) {
    for (size_t i = 0; i < pixelCount; i++) {
        uint8_t* p = data + i * 4;
        uint8_t a = p[3];
        if (a > 0 && a < 255) {
            float scale = 255.0f / (float)a;
            p[0] = std::min(255, (int)(p[0] * scale));
            p[1] = std::min(255, (int)(p[1] * scale));
            p[2] = std::min(255, (int)(p[2] * scale));
        }
    }
}

// Unpremultiply 16-bit integer RGBA (after conversion to RGBA order)
static void unpremultiplyRGBA16_int(uint16_t* data, size_t pixelCount) {
    for (size_t i = 0; i < pixelCount; i++) {
        uint16_t* p = data + i * 4;
        uint16_t a = p[3];
        if (a > 0 && a < 65535) {
            float scale = 65535.0f / (float)a;
            p[0] = std::min(65535, (int)(p[0] * scale));
            p[1] = std::min(65535, (int)(p[1] * scale));
            p[2] = std::min(65535, (int)(p[2] * scale));
        }
    }
}

// Helper to convert float16 to float32
static inline float float16ToFloat32(uint16_t h) {
    uint32_t sign = (h & 0x8000) << 16;
    uint32_t exponent = (h >> 10) & 0x1F;
    uint32_t mantissa = h & 0x3FF;

    if (exponent == 0) {
        if (mantissa == 0) {
            // Zero
            uint32_t result = sign;
            return *reinterpret_cast<float*>(&result);
        } else {
            // Subnormal - normalize
            while ((mantissa & 0x400) == 0) {
                mantissa <<= 1;
                exponent--;
            }
            exponent++;
            mantissa &= ~0x400;
        }
    } else if (exponent == 31) {
        // Inf or NaN
        uint32_t result = sign | 0x7F800000 | (mantissa << 13);
        return *reinterpret_cast<float*>(&result);
    }

    exponent = exponent + (127 - 15);
    uint32_t result = sign | (exponent << 23) | (mantissa << 13);
    return *reinterpret_cast<float*>(&result);
}

// Helper to convert float32 to float16
static inline uint16_t float32ToFloat16(float f) {
    uint32_t bits = *reinterpret_cast<uint32_t*>(&f);
    uint32_t sign = (bits >> 16) & 0x8000;
    int32_t exponent = ((bits >> 23) & 0xFF) - 127 + 15;
    uint32_t mantissa = bits & 0x7FFFFF;

    if (exponent <= 0) {
        if (exponent < -10) {
            return sign; // Zero
        }
        mantissa = (mantissa | 0x800000) >> (1 - exponent);
        return sign | (mantissa >> 13);
    } else if (exponent >= 31) {
        return sign | 0x7C00; // Inf
    }

    return sign | (exponent << 10) | (mantissa >> 13);
}

// Unpremultiply float16 RGBA manually (no vImage function for half-float)
static void unpremultiplyRGBA_float16(uint16_t* data, int width, int height) {
    size_t pixelCount = (size_t)width * height;
    for (size_t i = 0; i < pixelCount; i++) {
        uint16_t* p = data + i * 4;
        float a = float16ToFloat32(p[3]);

        if (a > 0.0f && a < 1.0f) {
            float r = float16ToFloat32(p[0]);
            float g = float16ToFloat32(p[1]);
            float b = float16ToFloat32(p[2]);

            p[0] = float32ToFloat16(r / a);
            p[1] = float32ToFloat16(g / a);
            p[2] = float32ToFloat16(b / a);
        }
    }
}

// Convert grayscale to RGB by replicating the value
static void grayscaleToRGB8(const uint8_t* src, uint8_t* dst, size_t pixelCount, int srcChannels, bool hasAlpha) {
    for (size_t i = 0; i < pixelCount; i++) {
        uint8_t gray = src[i * srcChannels];
        uint8_t alpha = (srcChannels == 2) ? src[i * srcChannels + 1] : 255;
        dst[i * 4 + 0] = gray;
        dst[i * 4 + 1] = gray;
        dst[i * 4 + 2] = gray;
        dst[i * 4 + 3] = hasAlpha ? alpha : 255;
    }
}

static void grayscaleToRGB16_int(const uint16_t* src, uint16_t* dst, size_t pixelCount, int srcChannels, bool hasAlpha) {
    for (size_t i = 0; i < pixelCount; i++) {
        uint16_t gray = src[i * srcChannels];
        uint16_t alpha = (srcChannels == 2) ? src[i * srcChannels + 1] : 65535;
        dst[i * 4 + 0] = gray;
        dst[i * 4 + 1] = gray;
        dst[i * 4 + 2] = gray;
        dst[i * 4 + 3] = hasAlpha ? alpha : 65535;
    }
}

static void grayscaleToRGB16_float(const uint16_t* src, uint16_t* dst, size_t pixelCount, int srcChannels, bool hasAlpha) {
    for (size_t i = 0; i < pixelCount; i++) {
        uint16_t gray = src[i * srcChannels];
        uint16_t alpha = (srcChannels == 2) ? src[i * srcChannels + 1] : FLOAT16_ONE;
        dst[i * 4 + 0] = gray;
        dst[i * 4 + 1] = gray;
        dst[i * 4 + 2] = gray;
        dst[i * 4 + 3] = hasAlpha ? alpha : FLOAT16_ONE;
    }
}

// Strip alpha channel: RGBA -> RGB
static void stripAlpha8(const uint8_t* src, uint8_t* dst, size_t pixelCount) {
    for (size_t i = 0; i < pixelCount; i++) {
        dst[i * 3 + 0] = src[i * 4 + 0];
        dst[i * 3 + 1] = src[i * 4 + 1];
        dst[i * 3 + 2] = src[i * 4 + 2];
    }
}

static void stripAlpha16(const uint16_t* src, uint16_t* dst, size_t pixelCount) {
    for (size_t i = 0; i < pixelCount; i++) {
        dst[i * 3 + 0] = src[i * 4 + 0];
        dst[i * 3 + 1] = src[i * 4 + 1];
        dst[i * 3 + 2] = src[i * 4 + 2];
    }
}

static void stripAlpha32(const float* src, float* dst, size_t pixelCount) {
    for (size_t i = 0; i < pixelCount; i++) {
        dst[i * 3 + 0] = src[i * 4 + 0];
        dst[i * 3 + 1] = src[i * 4 + 1];
        dst[i * 3 + 2] = src[i * 4 + 2];
    }
}

// Convert any 4-channel float32 format to RGBA order
static void convertToRGBA32_float(float* data, size_t pixelCount, bool alphaFirst, bool hasAlpha) {
    if (!alphaFirst) {
        // Already RGBA order, just fix alpha if needed
        if (!hasAlpha) {
            for (size_t i = 0; i < pixelCount; i++) {
                data[i * 4 + 3] = 1.0f;
            }
        }
        return;
    }

    // Alpha is first - rotate ARGB -> RGBA
    for (size_t i = 0; i < pixelCount; i++) {
        float* p = data + i * 4;
        float a = p[0];
        float r = p[1];
        float g = p[2];
        float b = p[3];

        p[0] = r;
        p[1] = g;
        p[2] = b;
        p[3] = hasAlpha ? a : 1.0f;
    }
}

// Unpremultiply float32 RGBA
static void unpremultiplyRGBA32_float(float* data, size_t pixelCount) {
    for (size_t i = 0; i < pixelCount; i++) {
        float* p = data + i * 4;
        float a = p[3];

        if (a > 0.0f && a < 1.0f) {
            p[0] /= a;
            p[1] /= a;
            p[2] /= a;
        }
    }
}

// Detect actual bit depth of 16-bit integer data by sampling pixels
// Returns the detected bit depth (8, 10, 12, 14, or 16)
// This helps identify 10-bit HEIC/RAW images stored in 16-bit containers
static int detectActualBitDepth16(const uint16_t* data, size_t pixelCount, int numChannels) {
    // Sample a subset of pixels for efficiency (up to 10000 samples)
    size_t sampleCount = std::min(pixelCount, (size_t)10000);
    size_t step = pixelCount / sampleCount;
    if (step < 1) step = 1;

    // Track the maximum value found
    uint16_t maxValue = 0;

    for (size_t i = 0; i < pixelCount; i += step) {
        for (int c = 0; c < numChannels; c++) {
            uint16_t val = data[i * numChannels + c];
            if (val > maxValue) {
                maxValue = val;
            }
        }
    }

    // Also check for patterns that indicate lower bit depth
    // 10-bit data scaled to 16-bit:
    //   - left-shifted: max value around 65472 (1023 << 6)
    //   - full-range scaled: max value around 65535 (round(1023 * 65535/1023))
    // 12-bit data scaled to 16-bit: max value around 65520 (4095 << 4)
    // 14-bit data scaled to 16-bit: max value around 65532 (16383 << 2)

    // Check if values only use upper bits (indicating scaled lower-precision data)
    // For genuine 10-bit data scaled to 16-bit, lower 6 bits should show a pattern
    size_t samplesChecked = 0;
    bool hasLower6Bits = false;
    bool hasLower4Bits = false;
    bool hasLower2Bits = false;

    for (size_t i = 0; i < pixelCount && samplesChecked < 1000; i += step) {
        for (int c = 0; c < numChannels; c++) {
            uint16_t val = data[i * numChannels + c];
            if (val > 0) {
                // Check if lower bits are non-zero and don't match the pattern
                // For properly scaled 10-bit: lower 6 bits = upper 6 bits of 10-bit value
                // Pattern: (val >> 4) should equal (val & 0x3F) for scaled 10-bit
                if ((val & 0x3F) != 0 && (val & 0x3F) != ((val >> 10) & 0x3F)) {
                    hasLower6Bits = true;
                }
                if ((val & 0x0F) != 0 && (val & 0x0F) != ((val >> 12) & 0x0F)) {
                    hasLower4Bits = true;
                }
                if ((val & 0x03) != 0 && (val & 0x03) != ((val >> 14) & 0x03)) {
                    hasLower2Bits = true;
                }
                samplesChecked++;
            }
        }
    }

    // Determine bit depth based on analysis (fast path for simple left-shifted sources)
    if (maxValue <= 255) {
        return 8;  // Data is actually 8-bit
    } else if (maxValue <= 1023 || (!hasLower6Bits && maxValue <= 65472)) {
        return 10; // 10-bit data (left-shifted / redundant low bits)
    } else if (maxValue <= 4095 || (!hasLower4Bits && maxValue <= 65520)) {
        return 12; // 12-bit data (left-shifted / redundant low bits)
    } else if (maxValue <= 16383 || (!hasLower2Bits && maxValue <= 65532)) {
        return 14; // 14-bit data (left-shifted / redundant low bits)
    }

    // Fallback: some decoders scale lower-precision data to full UINT16 range
    // (e.g. val16 = round(val10 * 65535/1023)), which makes low bits non-zero
    // and maxValue reach 65535. Detect by checking whether samples lie close to
    // a smaller-bit quantization grid.
    auto matchesQuantizedBitDepth = [&](int candidateBits) -> bool {
        const uint32_t maxCandidate = (1u << candidateBits) - 1u;
        const double stepSize = 65535.0 / static_cast<double>(maxCandidate);

        double totalError = 0.0;
        uint16_t maxError = 0;
        size_t totalSamples = 0;

        for (size_t i = 0; i < pixelCount; i += step) {
            for (int c = 0; c < numChannels; c++) {
                uint16_t v = data[i * numChannels + c];
                uint32_t vCandidate = static_cast<uint32_t>(
                    llround(static_cast<double>(v) * maxCandidate / 65535.0));
                uint32_t recon = static_cast<uint32_t>(
                    llround(static_cast<double>(vCandidate) * 65535.0 / maxCandidate));
                uint16_t err = (recon > v) ? (uint16_t)(recon - v) : (uint16_t)(v - recon);
                totalError += err;
                if (err > maxError) maxError = err;
                totalSamples++;
            }
        }

        if (totalSamples == 0) return false;
        const double meanError = totalError / static_cast<double>(totalSamples);

        // Require errors to be small relative to the candidate quantization step.
        return meanError <= stepSize * 0.10 && maxError <= stepSize * 0.50;
    };

    const int candidates[] = {8, 10, 12, 14};
    for (int candidateBits : candidates) {
        if (matchesQuantizedBitDepth(candidateBits)) {
            return candidateBits;
        }
    }

    return 16; // True 16-bit data (or heavily dithered/rescaled)
}

// Unpack ARGB2101010 / RGBX1010102 packed 10-bit format to 16-bit RGB
// Packed format on little-endian: 32-bit word where bits are arranged as:
//   For noneSkipFirst (XRGB): 2-bit padding, 10-bit R, 10-bit G, 10-bit B (from high to low)
//   For noneSkipLast (RGBX):  10-bit R, 10-bit G, 10-bit B, 2-bit padding
// The 10-bit values are scaled to 16-bit by shifting left by 6 (equivalent to *64 + some interpolation)
static void unpackPacked10BitToRGB16(const uint32_t* src, uint16_t* dst, size_t pixelCount,
                                      bool alphaFirst, bool littleEndian) {
    for (size_t i = 0; i < pixelCount; i++) {
        uint32_t pixel = src[i];

        // On little-endian system reading a 32Little value, the bytes are already in native order
        // For big-endian byte order, we'd need to swap
        if (!littleEndian) {
            pixel = ((pixel & 0xFF) << 24) | ((pixel & 0xFF00) << 8) |
                    ((pixel >> 8) & 0xFF00) | ((pixel >> 24) & 0xFF);
        }

        uint16_t r, g, b;

        if (alphaFirst) {
            // XRGB2101010: [XX RRRRRRRRRR GGGGGGGGGG BBBBBBBBBB] from bit 31 to bit 0
            // XX = bits 31-30 (padding/alpha)
            // R  = bits 29-20
            // G  = bits 19-10
            // B  = bits 9-0
            r = (pixel >> 20) & 0x3FF;
            g = (pixel >> 10) & 0x3FF;
            b = pixel & 0x3FF;
        } else {
            // RGBX1010102: [RRRRRRRRRR GGGGGGGGGG BBBBBBBBBB XX] from bit 31 to bit 0
            // R  = bits 31-22
            // G  = bits 21-12
            // B  = bits 11-2
            // XX = bits 1-0 (padding/alpha)
            r = (pixel >> 22) & 0x3FF;
            g = (pixel >> 12) & 0x3FF;
            b = (pixel >> 2) & 0x3FF;
        }

        // Scale 10-bit (0-1023) to 16-bit (0-65535)
        // Optimal scaling: val * 65535 / 1023 ≈ val * 64 + val / 16
        // Simpler approximation: (val << 6) | (val >> 4)
        dst[i * 3 + 0] = (r << 6) | (r >> 4);
        dst[i * 3 + 1] = (g << 6) | (g >> 4);
        dst[i * 3 + 2] = (b << 6) | (b >> 4);
    }
}

- (bool)jxlExtractPixels:(std::vector<uint8_t>&)buffer
              iccProfile:(std::vector<uint8_t>&)iccProfile
                    info:(nonnull JXLImageInfo*)info {
    CGImageRef imageRef;
#if TARGET_OS_OSX
    imageRef = [self CGImageForProposedRect:nil context:nil hints:nil];
#else
    imageRef = [self CGImage];
#endif
    if (!imageRef) return false;

    [self jxlGetImageInfo:info];

    // Extract ICC profile from source color space
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(imageRef);
    if (colorSpace) {
        CFDataRef iccData = CGColorSpaceCopyICCData(colorSpace);
        if (iccData) {
            const uint8_t* bytes = (const uint8_t*)CFDataGetBytePtr(iccData);
            size_t len = CFDataGetLength(iccData);
            iccProfile.assign(bytes, bytes + len);
            CFRelease(iccData);
        }
    }

    // Get raw pixel data directly - NO REDRAWING, preserves HDR values
    CGDataProviderRef provider = CGImageGetDataProvider(imageRef);
    if (!provider) return false;

    CFDataRef pixelData = CGDataProviderCopyData(provider);
    if (!pixelData) return false;

    const uint8_t* src = (const uint8_t*)CFDataGetBytePtr(pixelData);
    size_t srcStride = CGImageGetBytesPerRow(imageRef);
    int srcBytesPerPixel = info->bitsPerPixel / 8;
    size_t srcRowBytes = info->width * srcBytesPerPixel;

    size_t pixelCount = info->width * info->height;
    int srcChannels = info->bitsPerPixel / info->bitsPerComponent;
    int bytesPerComponent = info->bitsPerComponent / 8;

    // We always output RGBA (4 channels) or RGB (3 channels) depending on hasAlpha
    // For grayscale, we expand to RGB/RGBA
    int outChannels = info->hasAlpha ? 4 : 3;
    size_t outBytesPerPixel = outChannels * bytesPerComponent;
    buffer.resize(pixelCount * outBytesPerPixel);

    // First, copy source data handling stride
    std::vector<uint8_t> srcBuffer;
    if (srcStride == srcRowBytes) {
        srcBuffer.assign(src, src + srcRowBytes * info->height);
    } else {
        srcBuffer.resize(srcRowBytes * info->height);
        for (int y = 0; y < info->height; y++) {
            memcpy(srcBuffer.data() + y * srcRowBytes,
                   src + y * srcStride,
                   srcRowBytes);
        }
    }

    CFRelease(pixelData);

    // Handle packed 10-bit format specially
    if (info->isPacked10Bit) {
        // Packed 10-bit: 32 bits per pixel containing 3x10-bit RGB + 2-bit padding
        // Output as 16-bit RGB container, but preserve original 10-bit precision info
        info->originalBitsPerComponent = 10;  // Preserve original precision for encoder
        info->bitsPerComponent = 16;          // Container size after unpacking
        info->hasAlpha = false;               // Packed 10-bit has no real alpha
        buffer.resize(pixelCount * 3 * 2);    // 3 channels * 16-bit

        unpackPacked10BitToRGB16(
            (const uint32_t*)srcBuffer.data(),
            (uint16_t*)buffer.data(),
            pixelCount,
            info->alphaFirst,
            info->byteOrderLittle
        );

        info->bitsPerPixel = 48;  // 3 * 16
        return true;
    }

    // Process based on source channel count
    if (srcChannels == 1 || srcChannels == 2) {
        // Grayscale or Grayscale+Alpha -> expand to RGB/RGBA
        if (info->bitsPerComponent == 8) {
            // Expand to RGBA first, then strip if needed
            std::vector<uint8_t> rgbaBuffer(pixelCount * 4);
            grayscaleToRGB8(srcBuffer.data(), rgbaBuffer.data(), pixelCount, srcChannels, info->hasAlpha);
            if (info->hasAlpha) {
                buffer = std::move(rgbaBuffer);
            } else {
                stripAlpha8(rgbaBuffer.data(), buffer.data(), pixelCount);
            }
        } else if (info->bitsPerComponent == 16) {
            std::vector<uint16_t> rgbaBuffer(pixelCount * 4);
            if (info->isFloat) {
                grayscaleToRGB16_float((uint16_t*)srcBuffer.data(), rgbaBuffer.data(), pixelCount, srcChannels, info->hasAlpha);
            } else {
                grayscaleToRGB16_int((uint16_t*)srcBuffer.data(), rgbaBuffer.data(), pixelCount, srcChannels, info->hasAlpha);
            }
            if (info->hasAlpha) {
                memcpy(buffer.data(), rgbaBuffer.data(), pixelCount * 4 * 2);
            } else {
                stripAlpha16(rgbaBuffer.data(), (uint16_t*)buffer.data(), pixelCount);
            }
        }
    } else if (srcChannels == 3) {
        // RGB without alpha - copy directly
        buffer = std::move(srcBuffer);
        // Note: hasAlpha should be false here, outChannels = 3
    } else if (srcChannels == 4) {
        // RGBA, BGRA, ARGB, or ABGR -> normalize to RGBA
        if (info->bitsPerComponent == 8) {
            // Convert in place to RGBA order
            convertToRGBA8(srcBuffer.data(), pixelCount, info->alphaFirst, info->byteOrderLittle, info->hasAlpha);

            // Unpremultiply if needed (now that data is in RGBA order)
            if (info->alphaPremultiplied && info->hasAlpha) {
                unpremultiplyRGBA8(srcBuffer.data(), pixelCount);
            }

            if (info->hasAlpha) {
                buffer = std::move(srcBuffer);
            } else {
                // Strip the padding/dummy alpha channel
                stripAlpha8(srcBuffer.data(), buffer.data(), pixelCount);
            }
        } else if (info->bitsPerComponent == 16) {
            if (info->isFloat) {
                // Float16 data
                convertToRGBA16_float((uint16_t*)srcBuffer.data(), pixelCount, info->alphaFirst, info->hasAlpha);

                if (info->alphaPremultiplied && info->hasAlpha) {
                    unpremultiplyRGBA_float16((uint16_t*)srcBuffer.data(), info->width, info->height);
                }
            } else {
                // Integer 16-bit data
                convertToRGBA16_int((uint16_t*)srcBuffer.data(), pixelCount, info->alphaFirst, info->hasAlpha);

                if (info->alphaPremultiplied && info->hasAlpha) {
                    unpremultiplyRGBA16_int((uint16_t*)srcBuffer.data(), pixelCount);
                }
            }

            if (info->hasAlpha) {
                buffer = std::move(srcBuffer);
            } else {
                stripAlpha16((uint16_t*)srcBuffer.data(), (uint16_t*)buffer.data(), pixelCount);
            }
        } else if (info->bitsPerComponent == 32) {
            // Float32 data (32-bit floats are always float, not integer)
            convertToRGBA32_float((float*)srcBuffer.data(), pixelCount, info->alphaFirst, info->hasAlpha);

            if (info->alphaPremultiplied && info->hasAlpha) {
                unpremultiplyRGBA32_float((float*)srcBuffer.data(), pixelCount);
            }

            if (info->hasAlpha) {
                buffer = std::move(srcBuffer);
            } else {
                stripAlpha32((float*)srcBuffer.data(), (float*)buffer.data(), pixelCount);
            }
        }
    }

    // Update info to reflect output format
    info->bitsPerPixel = outChannels * info->bitsPerComponent;

    // For 16-bit integer data, detect actual bit depth (may be 10-bit, 12-bit, etc.)
    // This helps improve compression for HEIC/RAW images stored in 16-bit containers
    // Note: Even HDR content from cameras (iPhone HEIC, Sony ARW, Canon CR3) is 10-14 bit max.
    // True 16-bit sources are essentially non-existent in photography.
    if (info->bitsPerComponent == 16 && !info->isFloat && !info->isPacked10Bit) {
        int actualBitDepth = detectActualBitDepth16(
            (const uint16_t*)buffer.data(),
            pixelCount,
            outChannels
        );
        if (actualBitDepth < 16) {
            info->originalBitsPerComponent = actualBitDepth;
        }
    }

    return true;
}

#if TARGET_OS_OSX

-(nullable CGImageRef)makeCGImage {
    CGImageRef imageRef = [self CGImageForProposedRect:nil context:nil hints:nil];
    return imageRef;
}

- (bool)jxlRGBAPixels:(std::vector<uint8_t>&)buffer width:(nonnull int*)xSize height:(nonnull int*)ySize {
    CGImageRef imageRef = [self makeCGImage];
    NSUInteger width = CGImageGetWidth(imageRef);
    NSUInteger height = CGImageGetHeight(imageRef);
    int stride = (int)4 * (int)width * sizeof(uint8_t);
    buffer.resize(stride * height);
    *xSize = (int)width;
    *ySize = (int)height;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (int)kCGImageAlphaPremultipliedLast | (int)kCGImageByteOrderDefault;

    CGContextRef targetContext = CGBitmapContextCreate(buffer.data(), width, height, 8, stride, colorSpace, bitmapInfo);

    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext: [NSGraphicsContext graphicsContextWithCGContext:targetContext flipped:FALSE]];

    [self drawInRect: NSMakeRect(0, 0, width, height)
            fromRect: NSZeroRect
           operation: NSCompositingOperationCopy
            fraction: 1.0];

    [NSGraphicsContext restoreGraphicsState];

    CGContextRelease(targetContext);
    CGColorSpaceRelease(colorSpace);

    if (![self unpremultiply:buffer.data() width:width height:height]) {
        return false;
    }

    return true;
}
#else
- (bool)jxlRGBAPixels:(std::vector<uint8_t>&)buffer width:(nonnull int*)xSize height:(nonnull int*)ySize {
    CGImageRef imageRef = [self CGImage];
    NSUInteger width = CGImageGetWidth(imageRef);
    NSUInteger height = CGImageGetHeight(imageRef);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    buffer.resize(height * width * 4 * sizeof(uint8_t));
    *xSize = (int)width;
    *ySize = (int)height;
    NSUInteger bytesPerPixel = 4;
    NSUInteger bytesPerRow = bytesPerPixel * width;
    NSUInteger bitsPerComponent = 8;
    CGContextRef context = CGBitmapContextCreate(buffer.data(), width, height,
                                                 bitsPerComponent, bytesPerRow, colorSpace,
                                                 (int)kCGImageAlphaPremultipliedLast | (int)kCGImageByteOrderDefault);

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), imageRef);

    if (![self unpremultiply:buffer.data() width:width height:height]) {
        return false;
    }

    return true;
}
#endif
@end
