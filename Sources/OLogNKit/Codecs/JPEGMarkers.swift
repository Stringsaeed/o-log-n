import Foundation

/// Smart-mode metadata policy for the progressive JPEG fallback (D18).
/// Lossless coefficient passes and the lossy quality search do not use this.
enum JPEGMarkers {
    /// Drops COM, non-ICC APP2, APP1, and other APPn. Keeps a thumbnail-free JFIF APP0, ICC APP2,
    /// and APP14. Inserts a one-tag EXIF APP1 when the source orientation is not 1.
    static func applyingSmartPolicy(_ jpeg: Data) -> Data {
        guard jpeg.count >= 2, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return jpeg }
        let angle = orientation(of: jpeg)
        var output = Data()
        output.reserveCapacity(jpeg.count)
        output.append(contentsOf: [0xFF, 0xD8])
        var index = 2
        var exifDone = angle == 1
        var pastSOS = false

        func emitExif() {
            guard !exifDone else { return }
            output.append(minimalOrientationExif(angle))
            exifDone = true
        }

        while index < jpeg.count {
            guard jpeg[index] == 0xFF else {
                output.append(jpeg.subdata(in: index..<jpeg.count))
                return output
            }
            var markerAt = index
            while markerAt < jpeg.count, jpeg[markerAt] == 0xFF { markerAt += 1 }
            guard markerAt < jpeg.count else { break }
            let marker = jpeg[markerAt]
            if marker == 0x00 {
                output.append(jpeg.subdata(in: index..<(markerAt + 1)))
                index = markerAt + 1
                continue
            }
            if marker == 0xD9 {
                emitExif()
                output.append(contentsOf: [0xFF, 0xD9])
                break
            }
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                output.append(contentsOf: [0xFF, marker])
                index = markerAt + 1
                continue
            }
            let lengthAt = markerAt + 1
            guard lengthAt + 1 < jpeg.count else { break }
            let length = (Int(jpeg[lengthAt]) << 8) | Int(jpeg[lengthAt + 1])
            guard length >= 2, lengthAt + length <= jpeg.count else { break }
            let payload = jpeg.subdata(in: (lengthAt + 2)..<(lengthAt + length))
            if marker == 0xDA {
                if !pastSOS { emitExif() }
                pastSOS = true
                output.append(0xFF)
                output.append(marker)
                output.append(jpeg.subdata(in: lengthAt..<(lengthAt + length)))
                index = lengthAt + length
                var cursor = index
                while cursor < jpeg.count {
                    guard jpeg[cursor] == 0xFF else { cursor += 1; continue }
                    var look = cursor + 1
                    while look < jpeg.count, jpeg[look] == 0xFF { look += 1 }
                    guard look < jpeg.count else { cursor = jpeg.count; break }
                    let next = jpeg[look]
                    if next == 0x00 || (next >= 0xD0 && next <= 0xD7) {
                        cursor = look + 1
                        continue
                    }
                    break
                }
                if cursor > index { output.append(jpeg.subdata(in: index..<cursor)) }
                index = cursor
                continue
            }
            index = lengthAt + length
            if pastSOS {
                if marker == 0xFE || (marker >= 0xE0 && marker <= 0xEF) { continue }
                appendSegment(&output, marker: marker, payload: payload)
                continue
            }
            switch marker {
            case 0xE0:
                if let stripped = jfifWithoutThumbnail(payload) {
                    appendSegment(&output, marker: marker, payload: stripped)
                    emitExif()
                }
            case 0xE1:
                break
            case 0xE2:
                if isICC(payload) { appendSegment(&output, marker: marker, payload: payload) }
            case 0xEE:
                appendSegment(&output, marker: marker, payload: payload)
            case 0xFE:
                break
            default:
                if marker >= 0xE0 && marker <= 0xEF { break }
                if isFrame(marker) { emitExif() }
                appendSegment(&output, marker: marker, payload: payload)
            }
        }
        return output
    }

    /// Orientation tag 0x0112 from the first Exif APP1, or 1 when the tag is absent.
    static func orientation(of jpeg: Data) -> Int {
        for payload in payloads(jpeg, marker: 0xE1) {
            guard payload.count >= 6, payload.prefix(6).elementsEqual([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) else { continue }
            let tiff = payload.subdata(in: 6..<payload.count)
            guard tiff.count >= 8 else { continue }
            let be = tiff[0] == 0x4D && tiff[1] == 0x4D
            guard read16(tiff, 2, bigEndian: be) == 0x002A else { continue }
            let ifd = read32(tiff, 4, bigEndian: be)
            guard ifd >= 0, ifd + 2 <= tiff.count else { continue }
            let count = read16(tiff, ifd, bigEndian: be)
            for entry in 0..<count {
                let at = ifd + 2 + entry * 12
                guard at + 12 <= tiff.count else { break }
                guard read16(tiff, at, bigEndian: be) == 0x0112 else { continue }
                let type = read16(tiff, at + 2, bigEndian: be)
                if type == 3 { return read16(tiff, at + 8, bigEndian: be) }
                if type == 4 { return read32(tiff, at + 8, bigEndian: be) }
            }
            return 1
        }
        return 1
    }

    static func containsCOM(_ jpeg: Data) -> Bool {
        payloads(jpeg, marker: 0xFE).isEmpty == false
    }

    static func containsICC(_ jpeg: Data) -> Bool {
        payloads(jpeg, marker: 0xE2).contains { isICC($0) }
    }

    /// X and Y thumbnail from the first JFIF APP0, or nil when there is no JFIF marker.
    static func jfifThumbnailSize(_ jpeg: Data) -> (Int, Int)? {
        for payload in payloads(jpeg, marker: 0xE0) {
            guard payload.count >= 14, isJFIF(payload) else { continue }
            return (Int(payload[12]), Int(payload[13]))
        }
        return nil
    }

    static func containsApplication(_ jpeg: Data, marker: UInt8, prefix: [UInt8]) -> Bool {
        payloads(jpeg, marker: marker).contains { payload in
            payload.count >= prefix.count && payload.prefix(prefix.count).elementsEqual(prefix)
        }
    }

    private static func isFrame(_ marker: UInt8) -> Bool {
        (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC)
    }

    private static func isJFIF(_ payload: Data) -> Bool {
        payload.count >= 5 && payload.prefix(5).elementsEqual([0x4A, 0x46, 0x49, 0x46, 0x00])
    }

    private static func isICC(_ payload: Data) -> Bool {
        let prefix: [UInt8] = [0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00]
        return payload.count >= prefix.count && payload.prefix(prefix.count).elementsEqual(prefix)
    }

    private static func jfifWithoutThumbnail(_ payload: Data) -> Data? {
        guard payload.count >= 14, isJFIF(payload) else { return nil }
        var header = Data(payload.prefix(14))
        header[12] = 0
        header[13] = 0
        return header
    }

    /// Big-endian Exif with a single IFD0 SHORT orientation tag.
    private static func minimalOrientationExif(_ orientation: Int) -> Data {
        let value = UInt16(max(0, min(orientation, 65535)))
        let payload = Data([
            0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
            0x4D, 0x4D, 0x00, 0x2A,
            0x00, 0x00, 0x00, 0x08,
            0x00, 0x01,
            0x01, 0x12,
            0x00, 0x03,
            0x00, 0x00, 0x00, 0x01,
            UInt8(value >> 8), UInt8(value & 0xFF), 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
        var segment = Data([0xFF, 0xE1])
        let length = UInt16(payload.count + 2)
        segment.append(UInt8(length >> 8))
        segment.append(UInt8(length & 0xFF))
        segment.append(payload)
        return segment
    }

    private static func appendSegment(_ output: inout Data, marker: UInt8, payload: Data) {
        output.append(0xFF)
        output.append(marker)
        let length = UInt16(payload.count + 2)
        output.append(UInt8(length >> 8))
        output.append(UInt8(length & 0xFF))
        output.append(payload)
    }

    private static func payloads(_ jpeg: Data, marker wanted: UInt8) -> [Data] {
        guard jpeg.count >= 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return [] }
        var found: [Data] = []
        var index = 2
        while index < jpeg.count {
            guard jpeg[index] == 0xFF else { break }
            var markerAt = index
            while markerAt < jpeg.count, jpeg[markerAt] == 0xFF { markerAt += 1 }
            guard markerAt < jpeg.count else { break }
            let marker = jpeg[markerAt]
            if marker == 0xD9 || marker == 0xDA { break }
            if marker == 0x01 || marker == 0x00 || (marker >= 0xD0 && marker <= 0xD7) {
                index = markerAt + 1
                continue
            }
            let lengthAt = markerAt + 1
            guard lengthAt + 1 < jpeg.count else { break }
            let length = (Int(jpeg[lengthAt]) << 8) | Int(jpeg[lengthAt + 1])
            guard length >= 2, lengthAt + length <= jpeg.count else { break }
            if marker == wanted {
                found.append(jpeg.subdata(in: (lengthAt + 2)..<(lengthAt + length)))
            }
            index = lengthAt + length
        }
        return found
    }

    private static func read16(_ data: Data, _ offset: Int, bigEndian: Bool) -> Int {
        guard offset + 1 < data.count else { return 0 }
        let hi = Int(data[offset])
        let lo = Int(data[offset + 1])
        return bigEndian ? (hi << 8) | lo : (lo << 8) | hi
    }

    private static func read32(_ data: Data, _ offset: Int, bigEndian: Bool) -> Int {
        guard offset + 3 < data.count else { return 0 }
        let bytes = (0..<4).map { Int(data[offset + $0]) }
        if bigEndian {
            return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
        }
        return (bytes[3] << 24) | (bytes[2] << 16) | (bytes[1] << 8) | bytes[0]
    }
}
