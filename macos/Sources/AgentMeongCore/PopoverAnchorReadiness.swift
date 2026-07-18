import CoreGraphics
import Foundation

public enum PopoverAnchorReadiness {
    public static func isReady(
        anchorFrame: CGRect,
        screenFrame: CGRect,
        tolerance: CGFloat = 2,
        menuBarDepth: CGFloat = 80
    ) -> Bool {
        let values = [
            anchorFrame.origin.x,
            anchorFrame.origin.y,
            anchorFrame.size.width,
            anchorFrame.size.height,
            screenFrame.origin.x,
            screenFrame.origin.y,
            screenFrame.size.width,
            screenFrame.size.height,
            tolerance,
            menuBarDepth,
        ]
        guard
            values.allSatisfy({ $0.isFinite }),
            anchorFrame.size.width > 0,
            anchorFrame.size.height > 0,
            screenFrame.size.width > 0,
            screenFrame.size.height > 0
        else { return false }

        let allowedScreenFrame = screenFrame.standardized.insetBy(
            dx: -max(0, tolerance),
            dy: -max(0, tolerance)
        )
        let settledAnchorFrame = anchorFrame.standardized
        let topBandMinimumY = screenFrame.standardized.maxY
            - max(0, menuBarDepth)
            - max(0, tolerance)
        return allowedScreenFrame.contains(settledAnchorFrame)
            && settledAnchorFrame.midY >= topBandMinimumY
    }
}
