import Foundation

// Test runner entry point.
//
// Compiled together with the production sources (everything except
// `Sources/PhotoCleaner/main.swift`, which owns the application's top-level code)
// into a single executable. SwiftPM does not work on this machine, so this is the
// whole test infrastructure.

// Line-buffer stdout so a hanging case is identifiable from the last line printed.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
var only: String?
var strict = false
var listOnly = false

var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--only":
        index += 1
        guard index < arguments.count else {
            FileHandle.standardError.write(Data("run-tests: --only needs a value\n".utf8))
            exit(2)
        }
        only = arguments[index]
    case "--strict":
        strict = true
    case "--list":
        listOnly = true
    case "-h", "--help":
        print("""
        usage: run-tests.sh [--only SUITE] [--strict] [--list]

          --only SUITE   run only cases whose suite name contains SUITE
          --strict       also exit non-zero when a known-bug case still fails
          --list         print the registered cases and exit
        """)
        exit(0)
    default:
        print("run-tests: unknown argument \(argument)")
        exit(2)
    }
    index += 1
}

registerSelectionTests()
registerFavouriteProtectionTests()
registerPaginationTests()
registerTimelineTests()
registerStateMachineTests()
registerConfirmTokenTests()
registerRecordTests()
registerEventBusTests()
registerSettingsTests()
registerThumbnailTests()
registerSimilarGroupTests()
registerHTTPServerTests()
registerVideoRouteTests()
registerPresentationTests()
registerSchemaTests()
registerAuthorizationTests()
registerUpdateTests()
registerIconTests()
registerVideoTests()

if listOnly {
    print("\(Registry.shared.count) cases registered")
    exit(0)
}

print("PhotoCleaner regression suite — \(Registry.shared.count) cases")
print("temporary SQLite databases only; no Photos library, no network, no root")

let started = Date()
let results = await Registry.shared.run(only: only, strict: strict)
let elapsed = Date().timeIntervalSince(started)

let passed = results.filter { $0.outcome == .passed }
let failed = results.filter { $0.outcome == .failed }
let knownBugs = results.filter { $0.outcome == .knownBug }
let fixedBugs = results.filter { $0.outcome == .knownBugFixed }
let skipped = results.filter { $0.outcome == .skipped }

func summary() {
    var line = "\(passed.count) passed"
    line += ", \(failed.count) failed"
    line += ", \(knownBugs.count) known bug\(knownBugs.count == 1 ? "" : "s")"
    if !fixedBugs.isEmpty { line += ", \(fixedBugs.count) known bug(s) now fixed" }
    if !skipped.isEmpty { line += ", \(skipped.count) skipped" }
    print("\n\(line)  in \(String(format: "%.2f", elapsed))s")
}

if !failed.isEmpty {
    print("\nREGRESSIONS — production code does not do what these cases require:")
    for result in failed {
        print("\n  \(result.suite) / \(result.name)")
        for message in result.messages { print("      \(message)") }
    }
}

if !knownBugs.isEmpty {
    print("\nKNOWN BUGS — these cases assert the behaviour production code *should* have")
    print("and currently fails. Each one is annotated with the defect it documents.")
    for result in knownBugs {
        print("\n  \(result.suite) / \(result.name)")
        for message in result.messages { print("      \(message)") }
    }
}

if !fixedBugs.isEmpty {
    print("\nKNOWN BUGS NOW FIXED — delete the knownBug marker from:")
    for result in fixedBugs { print("      \(result.suite) / \(result.name)") }
}

summary()

// Every fixture directory is a throwaway SQLite database; remove them all.
Fixture.removeAll()

if !failed.isEmpty || (strict && !knownBugs.isEmpty) {
    exit(1)
}
exit(0)