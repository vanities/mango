import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds real zip bytes in memory so `ZipReader` can be tested against something it didn't
/// also produce — stored and deflated entries, ordered however the test wants.
enum ZipTestBuilder {
    struct Input {
        var name: String
        var data: Data
        var deflate: Bool
    }

    static func make(_ inputs: [Input]) -> Data {
        var output = Data()
        var central = Data()
        var count = 0

        for input in inputs {
            let nameBytes = Array(input.name.utf8)
            let payload = input.deflate ? deflate(input.data) : input.data
            let method: UInt16 = input.deflate ? 8 : 0
            let crc = crc32(input.data)
            let localOffset = UInt32(output.count)

            // Local file header.
            output.append(le32(0x0403_4B50))
            output.append(le16(20))                       // version needed
            output.append(le16(0x0800))                   // UTF-8 names
            output.append(le16(method))
            output.append(le16(0))                        // mod time
            output.append(le16(0))                        // mod date
            output.append(le32(crc))
            output.append(le32(UInt32(payload.count)))
            output.append(le32(UInt32(input.data.count)))
            output.append(le16(UInt16(nameBytes.count)))
            output.append(le16(0))                        // extra length
            output.append(contentsOf: nameBytes)
            output.append(payload)

            // Central directory header.
            central.append(le32(0x0201_4B50))
            central.append(le16(20))                      // version made by
            central.append(le16(20))                      // version needed
            central.append(le16(0x0800))
            central.append(le16(method))
            central.append(le16(0))
            central.append(le16(0))
            central.append(le32(crc))
            central.append(le32(UInt32(payload.count)))
            central.append(le32(UInt32(input.data.count)))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0))                       // extra
            central.append(le16(0))                       // comment
            central.append(le16(0))                       // disk start
            central.append(le16(0))                       // internal attrs
            central.append(le32(0))                       // external attrs
            central.append(le32(localOffset))
            central.append(contentsOf: nameBytes)
            count += 1
        }

        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(le32(0x0605_4B50))
        output.append(le16(0))
        output.append(le16(0))
        output.append(le16(UInt16(count)))
        output.append(le16(UInt16(count)))
        output.append(le32(UInt32(central.count)))
        output.append(le32(centralOffset))
        output.append(le16(0))                            // comment length
        return output
    }

    /// A tiny valid PNG, so a page is something ImageIO can actually decode.
    static func pngPixel(width: Int = 8, height: Int = 8, gray: UInt8 = 128) -> Data {
        var pixels = [UInt8](repeating: gray, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: Bytes

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }

    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    private static func deflate(_ input: Data) -> Data {
        guard !input.isEmpty else { return Data() }
        let capacity = max(64, input.count + input.count / 2 + 64)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return out.prefix(written)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
