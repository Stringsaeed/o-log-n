import Foundation
import UniformTypeIdentifiers

public enum Router {
    public static func kind(of url: URL) throws -> FileKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw JobError.unreadable("missing file")
        }
        if isDirectory.boolValue { return .folder }

        let header = try readPrefix(url, count: 64)
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if header.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if header.starts(with: Array("%PDF-".utf8)) { return .pdf }
        if let brand = isoBrand(header) {
            if heicBrands.contains(brand) { return .heic }
            if brand == "M4A " { return .audio }
            if extensionConforms(url, to: .audio) { return .audio }
            return .video
        }
        if isRIFFWave(header) || isAIFF(header) || header.starts(with: Array("caff".utf8))
            || header.starts(with: Array("fLaC".utf8))
        {
            return .audio
        }
        if extensionConforms(url, to: .movie) { return .video }
        if extensionConforms(url, to: .audio) { return .audio }
        return .generic
    }

    static func lane(for kind: FileKind) -> Lane {
        switch kind {
        case .png, .jpeg, .heic, .pdf, .audio: .cpu
        case .generic, .folder: .wide
        case .video: .media
        }
    }

    private static let heicBrands: Set<String> = ["heic", "heix", "hevc", "mif1", "msf1"]

    private static func readPrefix(_ url: URL, count: Int) throws -> [UInt8] {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: count) ?? Data()
            return [UInt8](data)
        } catch let error as JobError {
            throw error
        } catch {
            throw JobError.unreadable(error.localizedDescription)
        }
    }

    private static func isoBrand(_ header: [UInt8]) -> String? {
        guard header.count >= 12 else { return nil }
        let box = String(bytes: header[4..<8], encoding: .ascii)
        guard box == "ftyp" else { return nil }
        return String(bytes: header[8..<12], encoding: .ascii)
    }

    private static func isRIFFWave(_ header: [UInt8]) -> Bool {
        guard header.count >= 12 else { return false }
        return header.starts(with: Array("RIFF".utf8))
            && Array(header[8..<12]) == Array("WAVE".utf8)
    }

    private static func isAIFF(_ header: [UInt8]) -> Bool {
        guard header.count >= 12 else { return false }
        guard header.starts(with: Array("FORM".utf8)) else { return false }
        let kind = Array(header[8..<12])
        return kind == Array("AIFF".utf8) || kind == Array("AIFC".utf8)
    }

    private static func extensionConforms(_ url: URL, to parent: UTType) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: parent)
    }
}
