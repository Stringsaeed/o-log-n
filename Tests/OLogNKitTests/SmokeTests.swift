import Testing
@testable import OLogNKit

@Test func versionIsSet() {
    #expect(!OLogNKit.version.isEmpty)
}
