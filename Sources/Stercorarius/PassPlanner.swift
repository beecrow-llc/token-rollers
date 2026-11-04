import CoreGraphics

/// One walk across a display, in the coordinates of that display's overlay window.
struct Pass: Equatable {
    let start: CGPoint
    let end: CGPoint
    let duration: CFTimeInterval
    let isLeftward: Bool
}

enum PassPlanner {
    /// Walking speed in points per second.
    static let speed: CGFloat = 100

    /// Plans a walk that starts fully past one edge of the display and ends fully past the other,
    /// at a height inside `visibleFrame` chosen by `heightFraction` (0 lowest, 1 highest).
    /// `screenFrame` and `visibleFrame` are global (`NSScreen.frame`, `NSScreen.visibleFrame`);
    /// the result is relative to `screenFrame`'s origin.
    static func plan(
        sprite: CGSize, screenFrame: CGRect, visibleFrame: CGRect, leftward: Bool,
        heightFraction: CGFloat
    ) -> Pass {
        let lowest = visibleFrame.minY - screenFrame.minY + sprite.height / 2
        let highest = max(lowest, visibleFrame.maxY - screenFrame.minY - sprite.height / 2)
        let y = lowest + (highest - lowest) * min(max(heightFraction, 0), 1)
        let left = CGPoint(x: -sprite.width / 2, y: y)
        let right = CGPoint(x: screenFrame.width + sprite.width / 2, y: y)
        return Pass(
            start: leftward ? right : left,
            end: leftward ? left : right,
            duration: (screenFrame.width + sprite.width) / speed,
            isLeftward: leftward)
    }
}
