import Foundation
import Testing

@testable import Stercorarius

@Suite final class BeetleSizeTests {
    private let suiteName = "stercorarius-tests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit { defaults.removePersistentDomain(forName: suiteName) }

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
