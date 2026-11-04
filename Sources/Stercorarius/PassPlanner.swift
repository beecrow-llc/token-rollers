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

    /// Plans a walk from fully past one edge of the display to fully past the other, at a height
    /// inside `visibleFrame` chosen by `heightFraction` (0 lowest, 1 highest). `progress` (0...1)
    /// skips that share of the walk, so a new beetle can start anywhere along it.
    /// `screenFrame` and `visibleFrame` are global (`NSScreen.frame`, `NSScreen.visibleFrame`);
    /// the result is relative to `screenFrame`'s origin.
    static func plan(
        sprite: CGSize, screenFrame: CGRect, visibleFrame: CGRect, leftward: Bool,
        heightFraction: CGFloat, progress: CGFloat = 0
    ) -> Pass {
        let lowest = visibleFrame.minY - screenFrame.minY + sprite.height / 2
        let highest = max(lowest, visibleFrame.maxY - screenFrame.minY - sprite.height / 2)
        let y = lowest + (highest - lowest) * unit(heightFraction)
        let left = CGPoint(x: -sprite.width / 2, y: y)
        let right = CGPoint(x: screenFrame.width + sprite.width / 2, y: y)
        let (origin, destination) = leftward ? (right, left) : (left, right)
        let skipped = unit(progress)
        return Pass(
            start: CGPoint(x: origin.x + (destination.x - origin.x) * skipped, y: y),
            end: destination,
            duration: (screenFrame.width + sprite.width) * (1 - skipped) / speed,
            isLeftward: leftward)
    }

    private static func unit(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
}
