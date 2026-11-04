import Foundation

/// Beetle sizes offered in the menu, as a share of the sprite's native size (221 pt).
enum BeetleSize: Double, CaseIterable, Sendable {
    case half = 0.5
    case threeQuarters = 0.75
    case full = 1

    /// The size used until the user picks another.
    static let standard = BeetleSize.half

    private static let defaultsKey = "beetleScale"

    /// Menu title, such as "50%".
    var title: String { "\(Int(rawValue * 100))%" }

    /// The size saved in `defaults`, or `standard` when none (or an unknown one) is saved.
    static func saved(in defaults: UserDefaults) -> BeetleSize {
        BeetleSize(rawValue: defaults.double(forKey: defaultsKey)) ?? standard
    }

    /// Remembers this size in `defaults`.
    func save(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
