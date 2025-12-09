//
//  JxlWorker.cpp
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

#include "JxlWorker.hpp"
#include <jxl/decode.h>
#include <jxl/decode_cxx.h>
#include <jxl/resizable_parallel_runner.h>
#include <jxl/resizable_parallel_runner_cxx.h>
#include <jxl/encode.h>
#include <jxl/encode_cxx.h>
#include <jxl/thread_parallel_runner_cxx.h>
#include <vector>

bool DecodeJpegXlOneShot(const uint8_t *jxl, size_t size,
                         std::vector<uint8_t> *pixels, size_t *xsize,
                         size_t *ysize,
                         std::vector<uint8_t> *iccProfile,
                         int* depth,
                         int* components,
                         bool* useFloats,
                         JxlExposedOrientation* exposedOrientation,
                         JxlDecodingPixelFormat pixelFormat) {
    // Multi-threaded parallel runner.
    auto runner = JxlResizableParallelRunnerMake(nullptr);

    auto dec = JxlDecoderMake(nullptr);
    if (JXL_DEC_SUCCESS !=
        JxlDecoderSubscribeEvents(dec.get(), JXL_DEC_BASIC_INFO |
                                  JXL_DEC_COLOR_ENCODING |
                                  JXL_DEC_FULL_IMAGE)) {
        return false;
    }

    if (JXL_DEC_SUCCESS != JxlDecoderSetParallelRunner(dec.get(),
                                                       JxlResizableParallelRunner,
                                                       runner.get())) {
        return false;
    }
    
    if (JXL_DEC_SUCCESS != JxlDecoderSetUnpremultiplyAlpha(dec.get(), JXL_TRUE)) {
        return false;
    }

    JxlBasicInfo info;
    JxlPixelFormat format;
    if (pixelFormat == optimal) {
        format = {4, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
    } else {
        if (pixelFormat == r16) {
            format = {4, JXL_TYPE_UINT16, JXL_NATIVE_ENDIAN, 0};
        } else if (pixelFormat == r8) {
            format = {4, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
        }
    }

    JxlDecoderSetInput(dec.get(), jxl, size);
    JxlDecoderCloseInput(dec.get());
    int bitDepth = 8;
    *useFloats = false;
    bool hdrImage = false;

    for (;;) {
        JxlDecoderStatus status = JxlDecoderProcessInput(dec.get());

        if (status == JXL_DEC_ERROR) {
            return false;
        } else if (status == JXL_DEC_NEED_MORE_INPUT) {
            return false;
        } else if (status == JXL_DEC_BASIC_INFO) {
            if (JXL_DEC_SUCCESS != JxlDecoderGetBasicInfo(dec.get(), &info)) {
                return false;
            }
            *xsize = info.xsize;
            *ysize = info.ysize;
            bitDepth = info.bits_per_sample;
            *depth = info.bits_per_sample;
            int baseComponents = info.num_color_channels;
            if (info.num_extra_channels > 0) {
                baseComponents = 4;
            }
            *components = baseComponents;
            *exposedOrientation = static_cast<JxlExposedOrientation>(info.orientation);
            if (bitDepth > 8 && pixelFormat == optimal) {
                *useFloats = true;
                hdrImage = true;
                format = { static_cast<uint32_t>(baseComponents), JXL_TYPE_UINT16, JXL_NATIVE_ENDIAN, 0 };
            } else if (pixelFormat == r16) {
                *useFloats = true;
                hdrImage = true;
                format = { static_cast<uint32_t>(baseComponents), JXL_TYPE_UINT16, JXL_NATIVE_ENDIAN, 0 };
            } else {
                if (pixelFormat == r8) {
                    *depth = 8;
                }
                format.num_channels = baseComponents;
                *useFloats = false;
            }
            JxlResizableParallelRunnerSetThreads(
                                                 runner.get(),
                                                 JxlResizableParallelRunnerSuggestThreads(info.xsize, info.ysize));
        } else if (status == JXL_DEC_COLOR_ENCODING) {
            // Get the ICC color profile of the pixel data

            //            JxlColorEncoding colorEncoding;
            //            if (JXL_DEC_SUCCESS != JxlDecoderGetColorAsEncodedProfile(dec.get(), JXL_COLOR_PROFILE_TARGET_DATA, &colorEncoding)) {
            //                return false;
            //            }
            
            size_t iccSize;
            if (JXL_DEC_SUCCESS ==
                JxlDecoderGetICCProfileSize(dec.get(), JXL_COLOR_PROFILE_TARGET_DATA, &iccSize)) {
                iccProfile->resize(iccSize);
                if (JXL_DEC_SUCCESS != JxlDecoderGetColorAsICCProfile(dec.get(), JXL_COLOR_PROFILE_TARGET_DATA,
                                                                      iccProfile->data(), iccProfile->size())) {
                                                                          return false;
                                                                      }
            } else {
                iccProfile->resize(0);
            }
        } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            size_t buffer_size;
            if (JXL_DEC_SUCCESS !=
                JxlDecoderImageOutBufferSize(dec.get(), &format, &buffer_size)) {
                return false;
            }
            if (buffer_size != *xsize * *ysize * (*components) * (hdrImage ? sizeof(uint16_t) : sizeof(uint8_t))) {
                return false;
            }
            pixels->resize(*xsize * *ysize * (*components) * (hdrImage ? sizeof(uint16_t) : sizeof(uint8_t)));
            void *pixelsBuffer = (void *) pixels->data();

            if (JXL_DEC_SUCCESS != JxlDecoderSetImageOutBuffer(dec.get(),
                                                               &format,
                                                               pixelsBuffer,
                                                               pixels->size())) {
                return false;
            }
        } else if (status == JXL_DEC_FULL_IMAGE) {
            // Nothing to do. Do not yet return. If the image is an animation, more
            // full frames may be decoded. This example only keeps the last one.
        } else if (status == JXL_DEC_SUCCESS) {
            // All decoding successfully finished.
            // It's not required to call JxlDecoderReleaseInput(dec.get()) here since
            // the decoder will be destroyed.
            return true;
        } else {
            return false;
        }
    }
}

bool DecodeBasicInfo(const uint8_t *jxl, size_t size, size_t *xsize, size_t *ysize) {
    auto runner = JxlResizableParallelRunnerMake(nullptr);

    auto dec = JxlDecoderMake(nullptr);
    if (JXL_DEC_SUCCESS !=
        JxlDecoderSubscribeEvents(dec.get(), JXL_DEC_BASIC_INFO |
                                  JXL_DEC_COLOR_ENCODING |
                                  JXL_DEC_FULL_IMAGE)) {
        return false;
    }

    if (JXL_DEC_SUCCESS != JxlDecoderSetParallelRunner(dec.get(),
                                                       JxlResizableParallelRunner,
                                                       runner.get())) {
        return false;
    }

    JxlBasicInfo info;

    JxlDecoderSetInput(dec.get(), jxl, size);
    JxlDecoderCloseInput(dec.get());

    for (;;) {
        JxlDecoderStatus status = JxlDecoderProcessInput(dec.get());

        if (status == JXL_DEC_ERROR) {
            return false;
        } else if (status == JXL_DEC_NEED_MORE_INPUT) {
            return false;
        } else if (status == JXL_DEC_BASIC_INFO) {
            if (JXL_DEC_SUCCESS != JxlDecoderGetBasicInfo(dec.get(), &info)) {
                return false;
            }
            *xsize = info.xsize;
            *ysize = info.ysize;
            return true;
        } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            return false;
        } else if (status == JXL_DEC_FULL_IMAGE) {
            return false;
        } else if (status == JXL_DEC_SUCCESS) {
            return false;
        } else {
            return false;
        }
    }
}

/**
 * Compresses the provided pixels.
 *
 * @param pixels input pixels
 * @param xsize width of the input image
 * @param ysize height of the input image
 * @param compressed will be populated with the compressed bytes
 */
bool EncodeJxlOneshot(const std::vector<uint8_t> &pixels, const uint32_t xsize,
                      const uint32_t ysize, std::vector<uint8_t> *compressed,
                      JxlPixelType colorspace, 
                      JxlCompressionOption compressionOption,
                      float compressionDistance,
                      int effort,
                      int decodingSpeed) {
    auto enc = JxlEncoderMake(nullptr);
    auto runner = JxlThreadParallelRunnerMake(nullptr,
                                              JxlThreadParallelRunnerDefaultNumWorkerThreads());
    if (JXL_ENC_SUCCESS != JxlEncoderSetParallelRunner(enc.get(),
                                                       JxlThreadParallelRunner,
                                                       runner.get())) {
        return false;
    }

    JxlPixelFormat pixel_format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
    switch (colorspace) {
        case rgb:
            pixel_format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
            break;
        case rgba:
            pixel_format = {4, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
            break;
    }

    JxlBasicInfo basicInfo;
    JxlEncoderInitBasicInfo(&basicInfo);
    basicInfo.xsize = xsize;
    basicInfo.ysize = ysize;
    basicInfo.bits_per_sample = 8;
    basicInfo.uses_original_profile = compressionOption == lossy ? JXL_FALSE : JXL_TRUE;
    basicInfo.num_color_channels = 3;

    if (colorspace == rgba) {
        basicInfo.num_extra_channels = 1;
        basicInfo.alpha_bits = 8;
    }

    if (JXL_ENC_SUCCESS != JxlEncoderSetBasicInfo(enc.get(), &basicInfo)) {
        return false;
    }

    switch (colorspace) {
        case rgb:
            basicInfo.num_color_channels = 3;
            break;
        case rgba:
            basicInfo.num_color_channels = 4;
            JxlExtraChannelInfo channelInfo;
            JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_ALPHA, &channelInfo);
            channelInfo.bits_per_sample = 8;
            channelInfo.alpha_premultiplied = false;
            if (JXL_ENC_SUCCESS != JxlEncoderSetExtraChannelInfo(enc.get(), 0, &channelInfo)) {
                return false;
            }
            break;
    }

    JxlColorEncoding color_encoding = {};
    JxlColorEncodingSetToSRGB(&color_encoding, pixel_format.num_channels < 3);
    if (JXL_ENC_SUCCESS !=
        JxlEncoderSetColorEncoding(enc.get(), &color_encoding)) {
        return false;
    }

    JxlEncoderFrameSettings *frameSettings =
    JxlEncoderFrameSettingsCreate(enc.get(), nullptr);

    JxlBitDepth depth;
    depth.bits_per_sample = 8;
    depth.exponent_bits_per_sample = 0;
    depth.type = JXL_BIT_DEPTH_FROM_PIXEL_FORMAT;
    if (JXL_ENC_SUCCESS != JxlEncoderSetFrameBitDepth(frameSettings, &depth)) {
        return false;
    }

    if (JXL_ENC_SUCCESS != JxlEncoderSetFrameLossless(frameSettings, compressionOption == lossless)) {
        return false;
    }

    if (JXL_ENC_SUCCESS != JxlEncoderFrameSettingsSetOption(frameSettings,
                                                            JXL_ENC_FRAME_SETTING_DECODING_SPEED, decodingSpeed)) {
        return false;
    }

    if (JXL_ENC_SUCCESS !=
        JxlEncoderSetFrameDistance(frameSettings, compressionDistance)) {
        return false;
    }

    if (colorspace == rgba) {
        if (JXL_ENC_SUCCESS !=
            JxlEncoderSetExtraChannelDistance(frameSettings, 0, compressionDistance)) {
            return false;
        }
    }


    if (JxlEncoderFrameSettingsSetOption(frameSettings,
                                         JXL_ENC_FRAME_SETTING_EFFORT, effort) != JXL_ENC_SUCCESS) {
        return false;
    }

    if (JXL_ENC_SUCCESS !=
        JxlEncoderAddImageFrame(frameSettings, &pixel_format,
                                (void *) pixels.data(),
                                sizeof(uint8_t) * pixels.size())) {
        return false;
    }

    JxlEncoderCloseInput(enc.get());

    compressed->resize(64);
    uint8_t *next_out = compressed->data();
    size_t avail_out = compressed->size() - (next_out - compressed->data());
    JxlEncoderStatus process_result = JXL_ENC_NEED_MORE_OUTPUT;
    while (process_result == JXL_ENC_NEED_MORE_OUTPUT) {
        process_result = JxlEncoderProcessOutput(enc.get(), &next_out, &avail_out);
        if (process_result == JXL_ENC_NEED_MORE_OUTPUT) {
            size_t offset = next_out - compressed->data();
            compressed->resize(compressed->size() * 2);
            next_out = compressed->data() + offset;
            avail_out = compressed->size() - offset;
        }
    }
    compressed->resize(next_out - compressed->data());
    if (JXL_ENC_SUCCESS != process_result) {
        return false;
    }

    return true;
}

bool isJXL(std::vector<uint8_t>& src) {
    if (JXL_SIG_INVALID == JxlSignatureCheck(src.data(), src.size())) {
        return false;
    }
    return true;
}

// HDR-aware encoder that preserves bit depth and color profile
bool EncodeJxlHDR(
    const std::vector<uint8_t>& pixels,
    uint32_t xsize, uint32_t ysize,
    std::vector<uint8_t>* compressed,
    int numChannels,
    int containerBitsPerSample,    // Container size: 8, 16, 32
    int originalBitsPerSample,     // Original precision for better compression
    bool isFloat,
    const std::vector<uint8_t>* iccProfile,
    JxlTransferFunctionType transferFunction,
    JxlColorPrimariesType colorPrimaries,
    JxlCompressionOption compressionOption,
    float compressionDistance,
    int effort,
    int decodingSpeed
) {
    auto enc = JxlEncoderMake(nullptr);
    auto runner = JxlThreadParallelRunnerMake(
        nullptr, JxlThreadParallelRunnerDefaultNumWorkerThreads());

    if (JXL_ENC_SUCCESS != JxlEncoderSetParallelRunner(
            enc.get(), JxlThreadParallelRunner, runner.get())) {
        return false;
    }

    // Basic info - use original bit depth for better compression
    // e.g., 10-bit data in 16-bit container: tell encoder only 10 bits are significant
    JxlBasicInfo basicInfo;
    JxlEncoderInitBasicInfo(&basicInfo);
    basicInfo.xsize = xsize;
    basicInfo.ysize = ysize;
    basicInfo.num_color_channels = 3;
    basicInfo.bits_per_sample = originalBitsPerSample;  // Use original precision

    // For float formats, set exponent bits (float16 = 5, float32 = 8)
    if (isFloat) {
        basicInfo.exponent_bits_per_sample = (containerBitsPerSample == 16) ? 5 : 8;
    } else {
        basicInfo.exponent_bits_per_sample = 0;
    }

    // For lossless with ICC profile, must use original profile
    basicInfo.uses_original_profile = (compressionOption == lossless) ? JXL_TRUE : JXL_FALSE;

    if (numChannels == 4) {
        basicInfo.num_extra_channels = 1;
        basicInfo.alpha_bits = originalBitsPerSample;
        basicInfo.alpha_exponent_bits = isFloat ? basicInfo.exponent_bits_per_sample : 0;
    }

    if (JXL_ENC_SUCCESS != JxlEncoderSetBasicInfo(enc.get(), &basicInfo)) {
        return false;
    }

    // Alpha channel info
    if (numChannels == 4) {
        JxlExtraChannelInfo channelInfo;
        JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_ALPHA, &channelInfo);
        channelInfo.bits_per_sample = originalBitsPerSample;
        channelInfo.exponent_bits_per_sample = isFloat ? basicInfo.exponent_bits_per_sample : 0;
        channelInfo.alpha_premultiplied = JXL_FALSE;
        if (JXL_ENC_SUCCESS != JxlEncoderSetExtraChannelInfo(enc.get(), 0, &channelInfo)) {
            return false;
        }
    }

    // COLOR ENCODING - critical for HDR preservation
    bool colorEncodingSet = false;

    if (iccProfile && !iccProfile->empty()) {
        // Try to use ICC profile - preserves HDR color space (BT.2020, Display P3, etc.)
        if (JXL_ENC_SUCCESS == JxlEncoderSetICCProfile(
                enc.get(), iccProfile->data(), iccProfile->size())) {
            colorEncodingSet = true;
        }
        // If ICC profile fails, fall through to use detected color encoding
    }

    if (!colorEncodingSet) {
        // No ICC profile or ICC profile rejected - use detected transfer function and primaries
        JxlColorEncoding color_encoding = {};

        // For sRGB with sRGB primaries, use the helper function for reliability
        if (transferFunction == TransferSRGB && colorPrimaries == PrimariesSRGB) {
            JxlColorEncodingSetToSRGB(&color_encoding, numChannels < 3);
        } else {
            // HDR or wide gamut - set up manually
            color_encoding.color_space = JXL_COLOR_SPACE_RGB;
            color_encoding.white_point = JXL_WHITE_POINT_D65;
            color_encoding.rendering_intent = JXL_RENDERING_INTENT_PERCEPTUAL;

            // Set color primaries
            switch (colorPrimaries) {
                case PrimariesBT2020:
                    color_encoding.primaries = JXL_PRIMARIES_2100;  // BT.2020/2100
                    break;
                case PrimariesDisplayP3:
                    color_encoding.primaries = JXL_PRIMARIES_P3;
                    break;
                case PrimariesSRGB:
                default:
                    color_encoding.primaries = JXL_PRIMARIES_SRGB;
                    break;
            }

            // Set transfer function
            switch (transferFunction) {
                case TransferPQ:
                    color_encoding.transfer_function = JXL_TRANSFER_FUNCTION_PQ;
                    break;
                case TransferHLG:
                    color_encoding.transfer_function = JXL_TRANSFER_FUNCTION_HLG;
                    break;
                case TransferLinear:
                    color_encoding.transfer_function = JXL_TRANSFER_FUNCTION_LINEAR;
                    break;
                case TransferSRGB:
                default:
                    color_encoding.transfer_function = JXL_TRANSFER_FUNCTION_SRGB;
                    break;
            }
        }

        if (JXL_ENC_SUCCESS != JxlEncoderSetColorEncoding(enc.get(), &color_encoding)) {
            return false;
        }
    }

    // Frame settings
    JxlEncoderFrameSettings* frameSettings =
        JxlEncoderFrameSettingsCreate(enc.get(), nullptr);

    // Bit depth setting - use original precision for compression efficiency
    // This tells the encoder that e.g. 10-bit data is stored in 16-bit container
    JxlBitDepth depth;
    depth.bits_per_sample = originalBitsPerSample;
    depth.exponent_bits_per_sample = isFloat ? basicInfo.exponent_bits_per_sample : 0;
    depth.type = JXL_BIT_DEPTH_FROM_PIXEL_FORMAT;
    if (JXL_ENC_SUCCESS != JxlEncoderSetFrameBitDepth(frameSettings, &depth)) {
        return false;
    }

    // Lossless mode
    if (JXL_ENC_SUCCESS != JxlEncoderSetFrameLossless(
            frameSettings, compressionOption == lossless)) {
        return false;
    }

    // Effort setting
    if (JXL_ENC_SUCCESS != JxlEncoderFrameSettingsSetOption(
            frameSettings, JXL_ENC_FRAME_SETTING_EFFORT, effort)) {
        return false;
    }

    // Decoding speed setting
    if (JXL_ENC_SUCCESS != JxlEncoderFrameSettingsSetOption(
            frameSettings, JXL_ENC_FRAME_SETTING_DECODING_SPEED, decodingSpeed)) {
        return false;
    }

    // Distance (quality) - only applies to lossy
    if (compressionOption != lossless) {
        if (JXL_ENC_SUCCESS != JxlEncoderSetFrameDistance(frameSettings, compressionDistance)) {
            return false;
        }
        if (numChannels == 4) {
            if (JXL_ENC_SUCCESS != JxlEncoderSetExtraChannelDistance(
                    frameSettings, 0, compressionDistance)) {
                return false;
            }
        }
    }

    // Pixel format - use container size (actual data layout in memory)
    JxlDataType dataType;
    if (isFloat) {
        dataType = (containerBitsPerSample == 16) ? JXL_TYPE_FLOAT16 : JXL_TYPE_FLOAT;
    } else {
        dataType = (containerBitsPerSample <= 8) ? JXL_TYPE_UINT8 : JXL_TYPE_UINT16;
    }

    JxlPixelFormat pixel_format = {
        static_cast<uint32_t>(numChannels),
        dataType,
        JXL_NATIVE_ENDIAN,
        0
    };

    // Validate pixel buffer size matches expected
    size_t bytesPerSample = (containerBitsPerSample <= 8) ? 1 :
                            (containerBitsPerSample <= 16) ? 2 : 4;
    size_t expectedSize = static_cast<size_t>(xsize) * ysize * numChannels * bytesPerSample;
    if (pixels.size() != expectedSize) {
        // Buffer size mismatch - this would cause encoding to fail
        return false;
    }

    // Add image frame
    if (JXL_ENC_SUCCESS != JxlEncoderAddImageFrame(
            frameSettings, &pixel_format,
            pixels.data(), pixels.size())) {
        return false;
    }

    JxlEncoderCloseInput(enc.get());

    // Process output with dynamic buffer growth
    compressed->resize(64);
    uint8_t* next_out = compressed->data();
    size_t avail_out = compressed->size();
    JxlEncoderStatus status = JXL_ENC_NEED_MORE_OUTPUT;

    while (status == JXL_ENC_NEED_MORE_OUTPUT) {
        status = JxlEncoderProcessOutput(enc.get(), &next_out, &avail_out);
        if (status == JXL_ENC_NEED_MORE_OUTPUT) {
            size_t offset = next_out - compressed->data();
            compressed->resize(compressed->size() * 2);
            next_out = compressed->data() + offset;
            avail_out = compressed->size() - offset;
        }
    }

    compressed->resize(next_out - compressed->data());
    return status == JXL_ENC_SUCCESS;
}
