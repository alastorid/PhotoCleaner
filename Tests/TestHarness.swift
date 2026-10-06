import Foundation

// A hand-rolled assertion harness.
//
// SwiftPM does not work on this machine (`swift package dump-package` cannot link
// `libPackageDescription`), so there is no XCTest target. Everything here is
// deliberately small: a case registry, a failure sink, and enough assertions to
// write regression tests against production code that is compiled *into this same
// binary* — the tests call the real functions, they never re-implement them.
//
// Two consequences are worth stating out loud, because they decide how a failing
// test should be read:
//
//   * A test compiles the production sources (everything except `main.swift`)
//     together with `Tests/`. So a failure means the real code misbehaved; it
//     cannot be a mismatch against a mock.
//   * A case marked `knownBug:` asserts the behaviour production code *should*
//     have. It is expected to fail. It is reported separately from real
//     regressions so a newly broken invariant is never lost in the noise of an
//     already-known defect, and `./run-tests.sh --strict` makes known bugs fail
//     the run too.

struct TestCase {
    let name: String
    /// Non-nil when this case encodes a *known* defect in production code.
    let knownBug: String?
    let body: @Sendable () async throws -> Void
}

/// Thrown by a case body that cannot run in this environment. Reported, not failed.
struct SkipTest: Error {
    let reason: String
}

struct CaseResult {
    enum Outcome {
        case passed
        case failed
        case skipped
        /// A known-bug case that still fails, as expected.
        case knownBug
        /// A known-bug case that now passes: the defect has been fixed and the
        /// `knownBug:` marker should be deleted.
        case knownBugFixed
    }

    let suite: String
    let name: String
    let outcome: Outcome
    let messages: [String]
    let seconds: Double
}

// MARK: - Failure sink

/// Collects assertion failures for the case currently running. Cases run one at a
/// time, so a single buffered sink is enough and keeps the assertions free of
/// `throws` plumbing.
enum Harness {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failures: [String] = []

    /// stdout is block-buffered when it is a pipe, which makes a hanging case
    /// impossible to locate. Line-buffer it so the last printed line is the case
    /// that hung.
    static func flush() {
        fflush(stdout)
    }

    static func record(_ message: String) {
        lock.withLock { failures.append(message) }
    }

    static func reset() {
        lock.withLock { failures = [] }
    }

    static func drain() -> [String] {
        lock.withLock {
            let drained = failures
            failures = []
            return drained
        }
    }
}

// MARK: - Registry

final class Registry: @unchecked Sendable {
    static let shared = Registry()

    private let lock = NSLock()
    private var registered: [(suite: String, test: TestCase)] = []

    func add(suite: String, _ test: TestCase) {
        lock.withLock { registered.append((suite, test)) }
    }

    var count: Int { lock.withLock { registered.count } }

    func run(only suiteFilter: String?, strict: Bool) async -> [CaseResult] {
        let pending = lock.withLock { registered }
        var results: [CaseResult] = []
        var lastSuite = ""
        for entry in pending {
            if let suiteFilter, !entry.suite.localizedCaseInsensitiveContains(suiteFilter) { continue }
            if entry.suite != lastSuite {
                lastSuite = entry.suite
                print("\n\(entry.suite)")
            }
            results.append(await execute(entry.suite, entry.test))
            Harness.flush()
        }
        return results
    }

    private func execute(_ suite: String, _ test: TestCase) async -> CaseResult {
        Harness.reset()
        let started = Date()
        var thrown: Error?
        do {
            try await test.body()
        } catch let skip as SkipTest {
            print("  SKIP  \(test.name) — \(skip.reason)")
            return CaseResult(suite: suite, name: test.name, outcome: .skipped,
                              messages: [], seconds: Date().timeIntervalSince(started))
        } catch {
            thrown = error
        }
        var messages = Harness.drain()
        let seconds = Date().timeIntervalSince(started)

        if let thrown {
            messages.append("unexpected error: \(thrown)")
        }

        let failed = !messages.isEmpty
        switch (failed, test.knownBug) {
        case (false, nil):
            print("  PASS  \(test.name)  (\(Self.format(seconds)))")
            return CaseResult(suite: suite, name: test.name, outcome: .passed,
                              messages: messages, seconds: seconds)
        case (true, nil):
            print("  FAIL  \(test.name)  (\(Self.format(seconds)))")
            return CaseResult(suite: suite, name: test.name, outcome: .failed,
                              messages: messages, seconds: seconds)
        case (true, let bug?):
            print("  KNOWN BUG  \(test.name)  (\(Self.format(seconds)))")
            return CaseResult(suite: suite, name: test.name, outcome: .knownBug,
                              messages: messages + ["known bug: \(bug)"], seconds: seconds)
        case (false, let bug?):
            print("  KNOWN BUG NOW FIXED  \(test.name) — delete the knownBug marker: \(bug)")
            return CaseResult(suite: suite, name: test.name, outcome: .knownBugFixed,
                              messages: ["known bug appears fixed: \(bug)"], seconds: seconds)
        }
    }

    private static func format(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0fms", seconds * 1000) : String(format: "%.2fs", seconds)
    }
}

// MARK: - Assertions

func check(_ condition: Bool, _ what: @autoclosure () -> String,
           file: StaticString = #fileID, line: UInt = #line) {
    if !condition { Harness.record("\(what())  (\(file):\(line))") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: @autoclosure () -> String,
                              file: StaticString = #fileID, line: UInt = #line) {
    if actual != expected {
        Harness.record("\(what()): expected \(expected), got \(actual)  (\(file):\(line))")
    }
}

func checkNil(_ value: Any?, _ what: @autoclosure () -> String,
              file: StaticString = #fileID, line: UInt = #line) {
    if value != nil { Harness.record("\(what()): expected nil, got \(value!)  (\(file):\(line))") }
}

@discardableResult
func checkNotNil<T>(_ value: T?, _ what: @autoclosure () -> String,
                    file: StaticString = #fileID, line: UInt = #line) -> T? {
    if value == nil { Harness.record("\(what()): unexpectedly nil  (\(file):\(line))") }
    return value
}

func checkSetEqual<T: Hashable>(_ actual: [T], _ expected: Set<T>, _ what: @autoclosure () -> String,
                                file: StaticString = #fileID, line: UInt = #line) {
    let actualSet = Set(actual)
    if actualSet != expected {
        Harness.record("\(what()): missing \(expected.subtracting(actualSet).sorted { "\($0)" < "\($1)" }.prefix(5)), "
                       + "unexpected \(actualSet.subtracting(expected).sorted { "\($0)" < "\($1)" }.prefix(5))  "
                       + "(\(file):\(line))")
    }
}

func checkNoDuplicates<T: Hashable>(_ items: [T], _ what: @autoclosure () -> String,
                                    file: StaticString = #fileID, line: UInt = #line) {
    var seen = Set<T>()
    var repeated = Set<T>()
    for item in items where !seen.insert(item).inserted { repeated.insert(item) }
    check(repeated.isEmpty, "\(what()): \(repeated.count) duplicate(s), e.g. \(Array(repeated.prefix(5)))",
          file: file, line: line)
}

/// Fails unless `body` throws.
func checkThrows<T>(_ what: @autoclosure () -> String, _ body: () throws -> T,
                   file: StaticString = #fileID, line: UInt = #line) -> Error? {
    do {
        _ = try body()
        Harness.record("\(what()): expected an error, none thrown  (\(file):\(line))")
        return nil
    } catch {
        return error
    }
}

// MARK: - Environment gates

/// True when the slow timeout cases are enabled. Off by default so the suite
/// finishes in a couple of seconds; the cases it gates wait on real production
/// timers (a 20 s idle deadline, a 120 s request deadline).
let slowTestsEnabled = ProcessInfo.processInfo.environment["PHOTOCLEANER_SLOW_TESTS"] == "1"

/// Skips unless Photos is readable, without ever prompting: `authorizationStatus`
/// never shows UI. Several routes refuse outright when access is not granted, so
/// those cases cannot run at all without access — they say so instead of
/// pretending to pass.
func requirePhotosAccess(_ what: String) throws {
    let status = PhotoLibrary.currentAuthorization()
    guard PhotoLibrary.hasReadAccess(status) else {
        throw SkipTest(reason: "Photos access is \(PhotoLibrary.authorizationDescription(status)); \(what)")
    }
}