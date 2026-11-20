import CoreGraphics

public enum PanelGeometry {
    public static func trayFrame(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let height = roundPoints(min(max(screenFrame.height * 0.255, 248), 360))
        let width = min(visibleFrame.width - 24, 1360)
        let x = roundPoints(visibleFrame.midX - width / 2)
        let y = screenFrame.minY + 12
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public static func dropzoneFrame(screenFrame: CGRect, visibleFrame: CGRect, anchor: DropzoneAnchor) -> CGRect {
        let width: CGFloat = 304
        let height: CGFloat = 96
        switch anchor {
        case .topCenter:
            return CGRect(
                x: roundPoints(screenFrame.midX - 152),
                y: visibleFrame.maxY - 4 - height,
                width: width,
                height: height)
        case .rightCenter:
            return CGRect(
                x: visibleFrame.maxX - 4 - width,
                y: roundPoints(visibleFrame.midY - 48),
                width: width,
                height: height)
        case .leftCenter:
            return CGRect(
                x: visibleFrame.minX + 4,
                y: roundPoints(visibleFrame.midY - 48),
                width: width,
                height: height)
        }
    }

    private static func roundPoints(_ value: CGFloat) -> CGFloat {
        value.rounded(.toNearestOrAwayFromZero)
    }
}
