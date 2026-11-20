import CoreGraphics
import Testing
@testable import OLogNKit

@Test func trayFrameMatchesTheReferenceDisplay() {
    let frame = PanelGeometry.trayFrame(
        screenFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 65, width: 1800, height: 1065))
    #expect(frame == CGRect(x: 220, y: 12, width: 1360, height: 298))
}
