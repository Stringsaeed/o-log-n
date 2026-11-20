import Compression
import Foundation

/// Generic-only skip gate. Magic/extension first, then three entropy+LZ4 windows. Target < 2 ms.
enum SkipGate {
    private static let compressedExtensions: Set<String> = [
        "zip", "gz", "tgz", "xz", "txz", "zst", "br", "7z", "aar", "rar", "bz2", "dmg", "pkg", "xip",
    ]

    static func shouldSkip(_ url: URL) -> Bool {
        if compressedExtension(url) { return true }
        guard let header = try? prefix(url, count: 16), magic(header) else {
            return entropySkip(url)
        }
        return true
    }

    static func reason(for url: URL) -> String {
        if compressedExtension(url) || ((try? prefix(url, count: 16)).map(magic) ?? false) {
            return "already compressed"
        }
        return "high-entropy data"
    }

    private static func compressedExtension(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if compressedExtensions.contains(ext) { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.xz") || name.hasSuffix(".tar.zst")
    }

    private static func magic(_ header: [UInt8]) -> Bool {
        if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return true }
        if header.starts(with: [0x1F, 0x8B]) { return true }
        if header.starts(with: [0xFD, 0x37, 0x7A, 0x58]) { return true }
        if header.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return true }
        if header.starts(with: [0x37, 0x7A, 0xBC, 0xAF]) { return true }
        if header.starts(with: Array("BZh".utf8)) { return true }
        if header.starts(with: Array("Rar!".utf8)) { return true }
        return false
    }

    private static func entropySkip(_ url: URL) -> Bool {
        let size: Int
        do { size = Int(try Files.size(url)) } catch { return false }
        let window = 64 * 1024
        guard size >= 256 * 1024, size >= window else { return false }
        let middle = (size - window) / 2
        let offsets = [4096, middle, size - window]
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        for offset in offsets {
            do {
                try handle.seek(toOffset: UInt64(offset))
                guard let data = try handle.read(upToCount: window), data.count == window else { return false }
                if shannon(data) <= 7.92 { return false }
                if lz4Ratio(data) <= 0.98 { return false }
            } catch {
                return false
            }
        }
        return true
    }

    private static func shannon(_ data: Data) -> Double {
        var counts = [Int](repeating: 0, count: 256)
        for byte in data { counts[Int(byte)] += 1 }
        let total = Double(data.count)
        var entropy = 0.0
        for count in counts where count > 0 {
            let p = Double(count) / total
            entropy -= p * log2(p)
        }
        return entropy
    }

    /// Compressed size / raw size. A failed encode does not skip.
    private static func lz4Ratio(_ data: Data) -> Double {
        let bound = data.count + 1024
        var output = Data(count: bound)
        let written: Int = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(dstBase, dst.count, srcBase, src.count, nil, COMPRESSION_LZ4)
            }
        }
        guard written > 0 else { return 0 }
        return Double(written) / Double(data.count)
    }

    private static func prefix(_ url: URL, count: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return [UInt8](try handle.read(upToCount: count) ?? Data())
    }
}
