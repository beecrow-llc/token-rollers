import Foundation
import Testing

@testable import Stercorarius

/// Serialized because the tests share one defaults suite; a fixed name keeps them from leaving a
/// new plist in ~/Library/Preferences on every run.
@Suite(.serialized) final class BeetleSizeTests {
    private static let suiteName = "com.jamg.Stercorarius.tests"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    deinit { defaults.removePersistentDomain(forName: Self.suiteName) }

    @Test func defaultsToHalfSize() {
        #expect(BeetleSize.saved(in: defaults) == .half)
    }

    @Test func remembersTheChosenSize() {
        BeetleSize.full.save(in: defaults)
        #expect(BeetleSize.saved(in: defaults) == .full)
    }

    @Test func unknownSavedValueFallsBackToHalfSize() {
        defaults.set(0.3, forKey: "beetleScale")
        #expect(BeetleSize.saved(in: defaults) == .half)
    }

    @Test func titlesArePercentages() {
        #expect(BeetleSize.allCases.map(\.title) == ["50%", "75%", "100%"])
    }
}
