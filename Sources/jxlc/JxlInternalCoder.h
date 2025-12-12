//
//  JxlInternalCoder.h
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

#ifndef JXLCoder_h
#define JXLCoder_h

#import <Foundation/Foundation.h>
#import "JXLSystemImage.hpp"
#import "CJpegXLAnimatedEncoder.h"
#import "CJpegXLAnimatedDecoder.h"

@interface JxlInternalCoder: NSObject
- (nullable JXLSystemImage *)decode:(nonnull NSInputStream *)inputStream
                             rescale:(CGSize)rescale
                             pixelFormat:(JXLPreferredPixelFormat)preferredPixelFormat
                             scale:(int)scale
                             error:(NSError *_Nullable * _Nullable)error;
- (CGSize)getSize:(nonnull NSInputStream *)inputStream error:(NSError *_Nullable * _Nullable)error;
- (nullable NSData *)encode:(nonnull JXLSystemImage *)platformImage
                     colorSpace:(JXLColorSpace)colorSpace
                     compressionOption:(JXLCompressionOption)compressionOption
                     effort:(int)effort
                     quality:(int)quality
                     decodingSpeed:(JXLEncoderDecodingSpeed)decodingSpeed
                     error:(NSError * _Nullable *_Nullable)error;

/// HDR-aware encoder that preserves bit depth and ICC color profile.
/// Ideal for archiving RAW, HEIC HDR, and other high-fidelity sources.
- (nullable NSData *)encodeHDR:(nonnull JXLSystemImage *)platformImage
             compressionOption:(JXLCompressionOption)compressionOption
                        effort:(int)effort
                      distance:(float)distance
                 decodingSpeed:(JXLEncoderDecodingSpeed)decodingSpeed
                         error:(NSError * _Nullable *_Nullable)error;

/// HDR-aware encoder with metadata support.
/// Preserves bit depth, ICC color profile, and EXIF/XMP metadata.
/// @param platformImage Source image
/// @param exifData Raw EXIF data in TIFF format (can be nil)
/// @param xmpData Raw XMP data as UTF-8 XML (can be nil)
/// @param compressionOption Lossless or lossy compression
/// @param effort Compression effort 1-9
/// @param distance Lossy distance 0.0-15.0 (0=lossless, 1=visually lossless, 15=max lossy)
/// @param decodingSpeed Decode speed vs size tradeoff
/// @param error Error output
- (nullable NSData *)encodeHDR:(nonnull JXLSystemImage *)platformImage
                      exifData:(nullable NSData *)exifData
                       xmpData:(nullable NSData *)xmpData
             compressionOption:(JXLCompressionOption)compressionOption
                        effort:(int)effort
                      distance:(float)distance
                 decodingSpeed:(JXLEncoderDecodingSpeed)decodingSpeed
                         error:(NSError * _Nullable *_Nullable)error;
@end

#endif /* JXLCoder_h */
