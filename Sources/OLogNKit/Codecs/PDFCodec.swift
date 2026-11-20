import Foundation
import PDFKit
import Quartz

private final class PDFBox: @unchecked Sendable {
    let document: PDFDocument
    init(_ document: PDFDocument) { self.document = document }
}

struct PDFCodec: Codec {
    let kind: FileKind = .pdf
    let lane: Lane = .cpu

    func compress(_ ctx: CodecContext) async throws -> CodecOutcome {
        if ctx.mode == .lossless { return .skipped("PDF lossless is already optimal") }
        let opened = try await Offload.run { token -> PDFBox? in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            guard let document = PDFDocument(url: ctx.input) else { return nil }
            return PDFBox(document)
        }
        guard let box = opened else { return .skipped("unreadable PDF") }
        if box.document.isEncrypted || box.document.isLocked { return .skipped("encrypted PDF") }
        let preset = QualityScale.pdf(ctx.settings.quality)
        let temp = TempFile.make(in: ctx.scratch, ext: "pdf")
        let wrote = try await Offload.run { token -> Bool in
            if token.isCancelled || ctx.isCancelled() { throw CancellationError() }
            if let filter = PDFFilters.make(dpi: preset.dpi, quality: preset.quality),
               PDFFilters.write(box.document, to: temp, filter: filter),
               PDFFilters.matches(ctx.input, temp) {
                return true
            }
            try? FileManager.default.removeItem(at: temp)
            let system = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
            if let filter = QuartzFilter(url: system),
               PDFFilters.write(box.document, to: temp, filter: filter),
               PDFFilters.matches(ctx.input, temp) {
                return true
            }
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        guard wrote else { return .skipped("PDF filter did not preserve the document") }
        let outputBytes = try Files.size(temp)
        guard Gain.accepts(input: ctx.inputBytes, output: outputBytes) else {
            try? FileManager.default.removeItem(at: temp)
            return .skipped("below minimum gain")
        }
        let q = Int((preset.quality * 100).rounded())
        return .produced(
            temp: temp, ext: "pdf", method: "PDF · images \(preset.dpi) dpi q\(q)",
            lossless: false, note: nil)
    }
}

enum PDFFilters {
    static func make(dpi: Int, quality: Double) -> QuartzFilter? {
        let properties: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "Logn",
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "ImageCompression": "ImageJPEGCompress",
                        "Compression Quality": quality,
                        "ImageScaleSettings": [
                            "ImageResolution": dpi,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": 3200,
                            "ImageSizeMin": 0,
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        return QuartzFilter(properties: properties)
    }

    static func write(_ document: PDFDocument, to url: URL, filter: QuartzFilter) -> Bool {
        let key = PDFDocumentWriteOption(rawValue: "QuartzFilter")
        return document.write(to: url, withOptions: [key: filter])
    }

    static func matches(_ original: URL, _ output: URL) -> Bool {
        guard let left = PDFDocument(url: original), let right = PDFDocument(url: output) else { return false }
        if left.pageCount != right.pageCount { return false }
        if (left.string?.count ?? 0) != (right.string?.count ?? 0) { return false }
        if annotationCount(left) != annotationCount(right) { return false }
        if outlineCount(left.outlineRoot) != outlineCount(right.outlineRoot) { return false }
        let leftTitle = left.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let rightTitle = right.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return leftTitle == rightTitle
    }

    private static func annotationCount(_ document: PDFDocument) -> Int {
        var total = 0
        for index in 0..<document.pageCount {
            total += document.page(at: index)?.annotations.count ?? 0
        }
        return total
    }

    private static func outlineCount(_ outline: PDFOutline?) -> Int {
        guard let outline else { return 0 }
        var total = 0
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            total += 1 + outlineCount(child)
        }
        return total
    }
}
