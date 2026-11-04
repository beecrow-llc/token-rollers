import AppKit
import QuartzCore

/// One beetle: a layer that crosses random displays, alternating direction, until retired.
@MainActor
final class Walker {
    private let sprite: SpriteSheet
    private unowned let stage: Stage
    private let layer = CALayer()
    private var overlay: Overlay?
    private var leftward = Bool.random()
    private var retired = false

    init(sprite: SpriteSheet, stage: Stage) {
        self.sprite = sprite
        self.stage = stage
        layer.bounds = CGRect(origin: .zero, size: sprite.size)
        layer.contents = sprite.frames.first?.image
    }

    /// Fades in at a random point of a pass in a random direction, so beetles that start
    /// together spread out.
    func start() {
        startPass(progress: .random(in: 0..<1))
        fade(from: 0, to: 1)
    }

    /// Abandons the current pass (its display may be gone) and starts a new one.
    func restartPass() {
        layer.removeAnimation(forKey: "move")
        startPass()
    }

    /// Fades the beetle out, then removes it.
    func retire() {
        retired = true
        fade(from: layer.presentation()?.opacity ?? 1, to: 0) { self.remove() }
    }

    private func startPass(progress: CGFloat = 0) {
        guard !retired, let target = stage.randomScreen() else { return }
        let pass = PassPlanner.plan(
            sprite: sprite.size, screenFrame: target.screen.frame,
            visibleFrame: target.screen.visibleFrame, leftward: leftward,
            heightFraction: .random(in: 0...1), progress: progress)
        leftward.toggle()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let previous = overlay
        overlay = target.overlay
        target.overlay.host(layer)
        if previous !== target.overlay { previous?.hideIfEmpty() }
        layer.transform = pass.isLeftward ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        layer.position = pass.end
        CATransaction.commit()

        layer.add(walkCycle(), forKey: "frames")
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: pass.start)
        move.toValue = NSValue(point: pass.end)
        move.duration = pass.duration
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        move.delegate = AnimationEnd { self.startPass() }
        layer.add(move, forKey: "move")
    }

    /// The frame animation; re-added each pass because the layer may change windows.
    private func walkCycle() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = sprite.frames.map(\.image)
        animation.keyTimes = sprite.keyTimes
        animation.duration = sprite.cycleDuration
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        // A random phase keeps beetles that start together from stepping in unison.
        animation.timeOffset = .random(in: 0..<sprite.cycleDuration)
        return animation
    }

    /// Animates opacity from `start` to `end` over 0.3 s, then runs `completion`.
    private func fade(
        from start: Float, to end: Float, completion: (@MainActor () -> Void)? = nil
    ) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start
        fade.toValue = end
        fade.duration = 0.3
        // CAAnimation retains its delegate, which keeps this walker alive until the fade ends.
        fade.delegate = completion.map { AnimationEnd($0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = end
        CATransaction.commit()
        layer.add(fade, forKey: "fade")
    }

    private func remove() {
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
        overlay?.hideIfEmpty()
        overlay = nil
    }
}

/// Runs `action` when an animation finishes; not when it is removed early.
@MainActor
private final class AnimationEnd: NSObject, CAAnimationDelegate {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished else { return }
        MainActor.assumeIsolated { action() }
    }
}
