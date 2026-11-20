import Foundation
import Testing
@testable import OLogNKit

@Test func routerClassifiesMagicBeforeExtension() async throws {
    let bundle = try await Fixtures.make()
    defer { try? FileManager.default.removeItem(at: bundle.directory) }
    #expect(try Router.kind(of: bundle.png) == .png)
    #expect(try Router.kind(of: bundle.jpeg) == .jpeg)
    #expect(try Router.kind(of: bundle.jpegNamedPNG) == .jpeg)
    #expect(try Router.kind(of: bundle.wav) == .audio)
    #expect(try Router.kind(of: bundle.pdf) == .pdf)
    #expect(try Router.kind(of: bundle.video) == .video)
    #expect(try Router.kind(of: bundle.folder) == .folder)
    #expect(try Router.kind(of: bundle.text) == .generic)
    #expect(try Router.kind(of: bundle.random) == .generic)
}
