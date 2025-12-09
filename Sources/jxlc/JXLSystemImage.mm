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

// Convert any 4-channel 16-bit format to RGBA order
static void convertToRGBA16(uint16_t* data, size_t pixelCount, bool alphaFirst, bool littleEndian, bool hasAlpha) {
    for (size_t i = 0; i < pixelCount; i++) {
        uint16_t* p = data + i * 4;
        uint16_t r, g, b, a;

        if (alphaFirst && littleEndian) {
            // Memory: B,G,R,A
            b = p[0]; g = p[1]; r = p[2]; a = p[3];
        } else if (alphaFirst && !littleEndian) {
            // Memory: A,R,G,B
            a = p[0]; r = p[1]; g = p[2]; b = p[3];
        } else if (!alphaFirst && littleEndian) {
            // Memory: A,B,G,R
            a = p[0]; b = p[1]; g = p[2]; r = p[3];
        } else {
            // Memory: R,G,B,A
            r = p[0]; g = p[1]; b = p[2]; a = p[3];
        }

        p[0] = r; p[1] = g; p[2] = b;
        p[3] = hasAlpha ? a : 65535;
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

// Unpremultiply 16-bit RGBA (after conversion to RGBA order)
static void unpremultiplyRGBA16(uint16_t* data, size_t pixelCount) {
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

static void grayscaleToRGB16(const uint16_t* src, uint16_t* dst, size_t pixelCount, int srcChannels, bool hasAlpha) {
    for (size_t i = 0; i < pixelCount; i++) {
        uint16_t gray = src[i * srcChannels];
        uint16_t alpha = (srcChannels == 2) ? src[i * srcChannels + 1] : 65535;
        dst[i * 4 + 0] = gray;
        dst[i * 4 + 1] = gray;
        dst[i * 4 + 2] = gray;
        dst[i * 4 + 3] = hasAlpha ? alpha : 65535;
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
            grayscaleToRGB16((uint16_t*)srcBuffer.data(), rgbaBuffer.data(), pixelCount, srcChannels, info->hasAlpha);
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
            convertToRGBA16((uint16_t*)srcBuffer.data(), pixelCount, info->alphaFirst, info->byteOrderLittle, info->hasAlpha);

            if (info->alphaPremultiplied && info->hasAlpha) {
                unpremultiplyRGBA16((uint16_t*)srcBuffer.data(), pixelCount);
            }

            if (info->hasAlpha) {
                buffer = std::move(srcBuffer);
            } else {
                stripAlpha16((uint16_t*)srcBuffer.data(), (uint16_t*)buffer.data(), pixelCount);
            }
        }
    }

    // Update info to reflect output format
    info->bitsPerPixel = outChannels * info->bitsPerComponent;

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
