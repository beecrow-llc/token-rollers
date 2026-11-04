import CoreGraphics
import Testing

@testable import Stercorarius

@Suite struct PassPlannerTests {
    private let sprite = CGSize(width: 200, height: 100)
    // A 1000×800 display right of the main one, with a 30 pt menu bar and a 70 pt Dock.
    private let screen = CGRect(x: 1440, y: 0, width: 1000, height: 800)
    private let visible = CGRect(x: 1440, y: 70, width: 1000, height: 700)

    private func plan(
        leftward: Bool, height: CGFloat, progress: CGFloat = 0, sprite: CGSize? = nil
    ) -> Pass {
        PassPlanner.plan(
            sprite: sprite ?? self.sprite, screenFrame: screen, visibleFrame: visible,
            leftward: leftward, heightFraction: height, progress: progress)
    }

    @Test func rightwardPassCrossesFromOffLeftToOffRight() {
        let pass = plan(leftward: false, height: 0)
        #expect(pass.start == CGPoint(x: -100, y: 120))
        #expect(pass.end == CGPoint(x: 1100, y: 120))
        #expect(pass.duration == 12)
        #expect(!pass.isLeftward)
    }

    @Test func leftwardPassRunsBackAtTheTopOfTheVisibleBand() {
        let pass = plan(leftward: true, height: 1)
        #expect(pass.start == CGPoint(x: 1100, y: 720))
        #expect(pass.end == CGPoint(x: -100, y: 720))
        #expect(pass.isLeftward)
    }

    @Test func heightFractionIsClampedToTheVisibleBand() {
        #expect(plan(leftward: false, height: -0.5).start.y == 120)
        #expect(plan(leftward: false, height: 7).start.y == 720)
        #expect(plan(leftward: false, height: 0.5).start.y == 420)
    }

    @Test func progressStartsPartWayAlongAShorterPass() {
        let pass = plan(leftward: false, height: 0, progress: 0.25)
        #expect(pass.start == CGPoint(x: 200, y: 120))
        #expect(pass.end == CGPoint(x: 1100, y: 120))
        #expect(pass.duration == 9)
    }

    @Test func leftwardProgressCountsFromTheRightEdge() {
        let pass = plan(leftward: true, height: 0, progress: 0.5)
        #expect(pass.start == CGPoint(x: 500, y: 120))
        #expect(pass.end == CGPoint(x: -100, y: 120))
        #expect(pass.duration == 6)
    }

    @Test func progressIsClampedToThePass() {
        #expect(plan(leftward: false, height: 0, progress: -1).start.x == -100)
        let finished = plan(leftward: false, height: 0, progress: 2)
        #expect(finished.start == finished.end)
        #expect(finished.duration == 0)
    }

    @Test func spriteTallerThanTheVisibleBandSitsAtItsBottom() {
        let tall = CGSize(width: 200, height: 900)
        #expect(plan(leftward: false, height: 0.5, sprite: tall).start.y == 520)
    }
}
