import Foundation

/// A PhotoCleaner release version: the `vN.N.N` tag that publishes one, or the
/// `N.N.N` that tag stamps into `CFBundleShortVersionString`.
///
/// Both sides are parsed through this one type, and that is the point. The
/// comparison that decides whether a running app replaces itself is made between
/// the version this process was stamped with and the version a release was tagged
/// with — two different strings from two different places — so the single place
/// they become something orderable is here.
///
/// The three-component ceiling is not arbitrary: it is exactly what `build.sh`
/// accepts (`^[0-9]+(\.[0-9]+){0,2}$`) and what `CFBundleShortVersionString`
/// allows. A four-component tag would fail the build that publishes it, so
/// refusing to read one here means a malformed tag is caught by the release
/// workflow rather than surfacing as an updater willing to install a version it
/// could not have compared.
struct UpdateVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Canonical components: always exactly three, most significant first.
    ///
    /// Stored zero-padded rather than as parsed, and that is load-bearing rather
    /// than tidiness. `Comparable` is derived from `<`, but `==` and `hash` would
    /// otherwise be synthesized from the raw array, leaving `1.2` and `1.2.0`
    /// unordered by `<` yet *unequal* — a type where `a < b` and `b < a` are both
    /// false but `a != b` is true, which breaks every `Set`, every `==` in a
    /// dictionary and the `UpdateTarget` equality a plan is compared by.
    ///
    /// Padding at construction makes all four operations agree by construction.
    /// It also makes `description` canonical, which is what
    /// `AvailableUpdate.assetName` and the "up to date" tooltip want: the
    /// three-component form, which is the only form `release.yml` ever tags.
    let components: [Int]

    init(components: [Int]) {
        precondition(!components.isEmpty && components.count <= 3,
                     "UpdateVersion takes one to three components; got \(components)")
        self.components = Array(components.prefix(3)) + Array(repeating: 0, count: 3 - min(components.count, 3))
    }

    /// Parses `"1.2.3"` and `"v1.2.3"`.
    ///
    /// Nil for everything else, including the empty string and `"dev"` — which is
    /// what `AppPaths.version` reports for a build with no `Info.plist` to ask, so
    /// a developer build is refused here rather than compared as version zero.
    ///
    /// Non-ASCII digits are rejected rather than folded into `Int`: `Character`
    /// reports `"٣"` as a number, and an Arabic-Indic digit string must not parse
    /// as a release the updater would then install.
    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 1, trimmed.first == "v" || trimmed.first == "V" {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            parsed.append(value)
        }
        self.init(components: parsed)
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// Zero padding already happened in `init`, so this is a plain component
    /// comparison: 1.10.0 is after 1.9.0, where a string comparison would put it
    /// before and the updater would stop offering updates the day a minor version
    /// took a second digit.
    static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
