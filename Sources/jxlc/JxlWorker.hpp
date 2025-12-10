//
//  JxlWorker.hpp
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

#ifndef jxl_worker_hpp
#define jxl_worker_hpp

#include <stdio.h>
#ifdef __cplusplus
#include <vector>
#endif
#ifdef __cplusplus

#include "JxlDefinitions.h"

bool DecodeJpegXlOneShot(const uint8_t *jxl, size_t size,
                         std::vector<uint8_t> *pixels, size_t *xsize,
                         size_t *ysize,
                         std::vector<uint8_t> *icc_profile,
                         int* depth,
                         int* components,
                         bool* useFloats,
                         JxlExposedOrientation* exposedOrientation,
                         JxlDecodingPixelFormat pixelFormat);
bool DecodeBasicInfo(const uint8_t *jxl, size_t size, size_t *xsize, size_t *ysize);
bool EncodeJxlOneshot(const std::vector<uint8_t> &pixels, const uint32_t xsize,
                      const uint32_t ysize, std::vector<uint8_t> *compressed,
                      JxlPixelType colorspace,
                      JxlCompressionOption compressionOption,
                      float compressionDistance,
                      int effort,
                      int decodingSpeed);

// Transfer function enum (must match JXLTransferFunction in JXLSystemImage.hpp)
enum JxlTransferFunctionType {
    TransferSRGB = 0,
    TransferLinear = 1,
    TransferPQ = 2,      // HDR10 Perceptual Quantizer
    TransferHLG = 3      // Hybrid Log-Gamma
};

// Color primaries enum (must match JXLColorPrimaries in JXLSystemImage.hpp)
enum JxlColorPrimariesType {
    PrimariesSRGB = 0,      // sRGB/Rec.709
    PrimariesDisplayP3 = 1,
    PrimariesBT2020 = 2     // Rec.2020 wide gamut
};

// HDR-aware encoder that preserves bit depth and color profile
bool EncodeJxlHDR(
    const std::vector<uint8_t>& pixels,
    uint32_t xsize, uint32_t ysize,
    std::vector<uint8_t>* compressed,
    int numChannels,                         // 3 or 4
    int containerBitsPerSample,              // Container size: 8, 16, 32
    int originalBitsPerSample,               // Original precision: 8, 10, 12, 16 (for better compression)
    bool isFloat,                            // true for float16/float32
    const std::vector<uint8_t>* iccProfile,  // can be nullptr
    JxlTransferFunctionType transferFunction, // Transfer function when no ICC profile
    JxlColorPrimariesType colorPrimaries,     // Color primaries when no ICC profile
    JxlCompressionOption compressionOption,
    float compressionDistance,
    int effort,
    int decodingSpeed,
    const std::vector<uint8_t>* exifData = nullptr,  // Optional EXIF data (TIFF format)
    const std::vector<uint8_t>* xmpData = nullptr    // Optional XMP data (UTF-8 XML)
);

bool isJXL(std::vector<uint8_t>& src);

template <typename DataType>
class JXLDataWrapper {
public:
    JXLDataWrapper() {}
    std::vector<DataType> data;
};
#endif

#endif /* jxl_worker_hpp */
