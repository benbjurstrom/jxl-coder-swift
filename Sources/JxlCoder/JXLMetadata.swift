//
//  JXLMetadata.swift
//  Jxl Coder [https://github.com/awxkee/jxl-coder-swift]
//
//  Created for CullShot HDR archival support
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

import Foundation
import ImageIO
import CoreGraphics
#if canImport(jxlc)
import jxlc
#endif

/// Metadata container for EXIF and XMP data to embed in JXL files.
///
/// JXL supports embedding EXIF and XMP metadata via its box-based container format.
/// This struct provides multiple ways to create metadata:
/// - From raw EXIF/XMP byte data (for advanced use)
/// - From ImageIO properties dictionary (for integration with CGImageSource)
/// - From a file URL or Data (convenience extraction)
///
/// Common preserved tags include: date/time, GPS location, camera/lens info,
/// exposure settings. Exotic or proprietary tags may be lost during re-serialization
/// from ImageIO properties.
public struct JXLMetadata {
    /// Raw EXIF data in TIFF format.
    /// Note: The 4-byte TIFF header offset required by JXL is added internally during encoding.
    public let exifData: Data?

    /// Raw XMP data as UTF-8 XML.
    public let xmpData: Data?

    /// Initialize with raw byte data.
    ///
    /// - Parameters:
    ///   - exifData: Raw EXIF data in TIFF format (without JXL's 4-byte offset prefix)
    ///   - xmpData: Raw XMP data as UTF-8 XML
    public init(exifData: Data? = nil, xmpData: Data? = nil) {
        self.exifData = exifData
        self.xmpData = xmpData
    }

    /// Initialize from an ImageIO properties dictionary.
    ///
    /// This converts the parsed dictionary from `CGImageSourceCopyPropertiesAtIndex`
    /// back into raw EXIF bytes by writing a temporary TIFF via `CGImageDestination`.
    ///
    /// Preserves common tags: DateTimeOriginal, GPS, Make, Model, LensModel,
    /// FNumber, ExposureTime, ISO, FocalLength, etc.
    /// Exotic or proprietary tags may not survive re-serialization.
    ///
    /// - Parameter properties: Properties dictionary from CGImageSourceCopyPropertiesAtIndex
    /// - Throws: If serialization fails
    public init(properties: [String: Any]) throws {
        // Extract XMP if present
        if let xmpString = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any],
           let xmpPacket = xmpString["XMLPacket"] as? String,
           let data = xmpPacket.data(using: .utf8) {
            self.xmpData = data
        } else {
            self.xmpData = nil
        }

        // Serialize properties to EXIF via CGImageDestination
        self.exifData = try JXLMetadata.serializePropertiesToExif(properties)
    }

    /// Extract metadata from an image file URL.
    ///
    /// - Parameter url: URL to an image file (JPEG, HEIC, PNG, DNG, etc.)
    /// - Returns: Extracted metadata
    /// - Throws: If the file cannot be read or contains no metadata
    public static func extract(from url: URL) throws -> JXLMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw JXLMetadataError.cannotOpenSource
        }
        return try extract(from: source)
    }

    /// Extract metadata from image data.
    ///
    /// - Parameter data: Image data (JPEG, HEIC, PNG, etc.)
    /// - Returns: Extracted metadata
    /// - Throws: If the data cannot be read or contains no metadata
    public static func extract(from data: Data) throws -> JXLMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw JXLMetadataError.cannotOpenSource
        }
        return try extract(from: source)
    }

    /// Extract metadata from a CGImageSource.
    ///
    /// - Parameter source: An open CGImageSource
    /// - Returns: Extracted metadata
    /// - Throws: If extraction fails
    public static func extract(from source: CGImageSource) throws -> JXLMetadata {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw JXLMetadataError.noMetadataFound
        }
        return try JXLMetadata(properties: properties)
    }

    // MARK: - Private

    /// Serialize ImageIO properties dictionary to raw EXIF bytes.
    ///
    /// Creates a minimal 1x1 TIFF in memory with the metadata attached,
    /// then extracts the raw bytes.
    ///
    /// IMPORTANT: RAW files (DNG, ARW, CR3, HIF) often contain huge embedded JPEG previews
    /// (20-30MB) in MakerNote, CIFF, DNG, or other dictionaries. We only preserve the
    /// essential metadata fields to avoid bloating the JXL file.
    private static func serializePropertiesToExif(_ properties: [String: Any]) throws -> Data? {
        // Build a clean properties dictionary with only essential metadata
        var cleanProperties: [String: Any] = [:]

        // === EXIF Dictionary - filter aggressively ===
        if let exifDict = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            var cleanExif: [String: Any] = [:]

            // Only keep specific, small EXIF fields
            let exifKeysToKeep: [CFString] = [
                kCGImagePropertyExifDateTimeOriginal,
                kCGImagePropertyExifDateTimeDigitized,
                kCGImagePropertyExifExposureTime,
                kCGImagePropertyExifFNumber,
                kCGImagePropertyExifISOSpeedRatings,
                kCGImagePropertyExifFocalLength,
                kCGImagePropertyExifFocalLenIn35mmFilm,
                kCGImagePropertyExifLensMake,
                kCGImagePropertyExifLensModel,
                kCGImagePropertyExifLensSpecification,
                kCGImagePropertyExifExposureProgram,
                kCGImagePropertyExifExposureMode,
                kCGImagePropertyExifMeteringMode,
                kCGImagePropertyExifFlash,
                kCGImagePropertyExifWhiteBalance,
                kCGImagePropertyExifExposureBiasValue,
                kCGImagePropertyExifApertureValue,
                kCGImagePropertyExifShutterSpeedValue,
                kCGImagePropertyExifBrightnessValue,
                kCGImagePropertyExifColorSpace,
                kCGImagePropertyExifPixelXDimension,
                kCGImagePropertyExifPixelYDimension,
                kCGImagePropertyExifSubsecTimeOriginal,
                kCGImagePropertyExifBodySerialNumber,
                kCGImagePropertyExifLensSerialNumber,
            ]

            for key in exifKeysToKeep {
                if let value = exifDict[key as String] {
                    cleanExif[key as String] = value
                }
            }

            if !cleanExif.isEmpty {
                cleanProperties[kCGImagePropertyExifDictionary as String] = cleanExif
            }
        }

        // === TIFF Dictionary - filter aggressively ===
        if let tiffDict = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            var cleanTiff: [String: Any] = [:]

            let tiffKeysToKeep: [CFString] = [
                kCGImagePropertyTIFFMake,
                kCGImagePropertyTIFFModel,
                kCGImagePropertyTIFFSoftware,
                kCGImagePropertyTIFFDateTime,
                kCGImagePropertyTIFFArtist,
                kCGImagePropertyTIFFCopyright,
                kCGImagePropertyTIFFOrientation,
                kCGImagePropertyTIFFXResolution,
                kCGImagePropertyTIFFYResolution,
                kCGImagePropertyTIFFResolutionUnit,
            ]

            for key in tiffKeysToKeep {
                if let value = tiffDict[key as String] {
                    cleanTiff[key as String] = value
                }
            }

            if !cleanTiff.isEmpty {
                cleanProperties[kCGImagePropertyTIFFDictionary as String] = cleanTiff
            }
        }

        // === GPS Dictionary - keep entirely (it's always small) ===
        if let gpsDict = properties[kCGImagePropertyGPSDictionary as String] {
            cleanProperties[kCGImagePropertyGPSDictionary as String] = gpsDict
        }

        // === IPTC Dictionary - filter to essential fields ===
        if let iptcDict = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            var cleanIptc: [String: Any] = [:]

            let iptcKeysToKeep: [CFString] = [
                kCGImagePropertyIPTCCaptionAbstract,
                kCGImagePropertyIPTCKeywords,
                kCGImagePropertyIPTCCopyrightNotice,
                kCGImagePropertyIPTCCreatorContactInfo,
                kCGImagePropertyIPTCDateCreated,
                kCGImagePropertyIPTCTimeCreated,
            ]

            for key in iptcKeysToKeep {
                if let value = iptcDict[key as String] {
                    cleanIptc[key as String] = value
                }
            }

            if !cleanIptc.isEmpty {
                cleanProperties[kCGImagePropertyIPTCDictionary as String] = cleanIptc
            }
        }

        // === Top-level properties ===
        if let orientation = properties[kCGImagePropertyOrientation as String] {
            cleanProperties[kCGImagePropertyOrientation as String] = orientation
        }

        // DO NOT include: CIFF, DNG, ExifAux, MakerNote, Raw dictionaries
        // These often contain huge embedded previews or proprietary data

        guard !cleanProperties.isEmpty else {
            return nil
        }

        // Debug: log what we're including
        print("[JXLMetadata] Building EXIF from filtered properties:")
        for (key, value) in cleanProperties {
            if let dict = value as? [String: Any] {
                print("[JXLMetadata]   \(key): \(dict.count) fields")
                // Check for any suspiciously large values
                for (subkey, subvalue) in dict {
                    if let data = subvalue as? Data, data.count > 1000 {
                        print("[JXLMetadata]     WARNING: \(subkey) contains \(data.count) bytes of data!")
                    } else if let arr = subvalue as? [Any], arr.count > 100 {
                        print("[JXLMetadata]     WARNING: \(subkey) is array with \(arr.count) elements!")
                    }
                }
            } else {
                print("[JXLMetadata]   \(key): \(type(of: value))")
            }
        }

        // Create a 1x1 dummy image
        guard let dummyImage = createDummyImage() else {
            throw JXLMetadataError.serializationFailed
        }

        // Write to TIFF format with metadata
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            "public.tiff" as CFString,
            1,
            nil
        ) else {
            throw JXLMetadataError.serializationFailed
        }

        // Add the image with clean metadata properties
        CGImageDestinationAddImage(destination, dummyImage, cleanProperties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw JXLMetadataError.serializationFailed
        }

        print("[JXLMetadata] Serialized TIFF/EXIF size: \(mutableData.length) bytes")

        // Sanity check: EXIF metadata should never be more than ~100KB
        // If it's larger, something went wrong - return nil to skip metadata
        if mutableData.length > 100_000 {
            print("[JXLMetadata] ERROR: Serialized EXIF is \(mutableData.length) bytes - way too large! Skipping metadata.")
            return nil
        }

        // The TIFF data now contains EXIF in its IFD structure
        // For JXL, we can pass the entire TIFF - libjxl expects TIFF/EXIF format
        return mutableData as Data
    }

    /// Create a minimal 1x1 RGB image for metadata serialization.
    private static func createDummyImage() -> CGImage? {
        let width = 1
        let height = 1
        let bitsPerComponent = 8
        let bytesPerRow = 4

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        var pixelData: [UInt8] = [0, 0, 0, 255] // RGBA black pixel

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        return context.makeImage()
    }
}

/// Errors that can occur during metadata operations.
public enum JXLMetadataError: Error, LocalizedError {
    case cannotOpenSource
    case noMetadataFound
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .cannotOpenSource:
            return "Cannot open image source for metadata extraction"
        case .noMetadataFound:
            return "No metadata found in image"
        case .serializationFailed:
            return "Failed to serialize metadata to EXIF format"
        }
    }
}
