import Foundation
import zlib

/// `.tgs` files are gzip-compressed Lottie JSON.
enum Gzip {
    static func isCompressed(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Inflates a gzip stream, refusing to produce more than `limit` bytes
    /// so a tiny file can not expand into gigabytes.
    static func decompress(_ data: Data, limit: Int) throws -> Data {
        guard data.count <= Int(UInt32.max) else {
            throw TLottieError.invalidArgument
        }

        var stream = z_stream()
        // 16 + MAX_WBITS tells zlib to expect a gzip header instead of a zlib one.
        let initStatus = inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw TLottieError.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var output = Data()

        return try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)

            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if output.count + produced > limit {
                    throw TLottieError.decompressedSizeLimitExceeded(limit: limit)
                }
                output.append(contentsOf: chunk[0 ..< produced])

                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK:
                    continue
                default:
                    // Z_BUF_ERROR here means the input ended before the stream did.
                    throw TLottieError.decompressionFailed
                }
            }
        }
    }
}
