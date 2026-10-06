import AppKit
import Foundation

// PhotoCleaner entry point.
//
// Kept deliberately thin: everything lives in `PhotoCleanerApp` so the launch
// sequence is testable and readable in one place.

let options = LaunchOptions.parse(CommandLine.arguments)
if options.showHelp {
    print(LaunchOptions.help)
    exit(0)
}
if options.showVersion {
    print("PhotoCleaner \(AppPaths.version)")
    exit(0)
}

Log.start()
Log.info("PhotoCleaner \(AppPaths.version) starting (pid \(getpid()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)), presenting as \(options.presentation.rawValue)")

// The aesthetics request requires macOS 15 or later. Fail loudly rather than
// silently substituting a different model.
if #unavailable(macOS 15.0) {
    let message = "PhotoCleaner requires macOS 15 or later: CalculateImageAestheticsScoresRequest is not available on this system.\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}

// Two launch paths, and the only difference between them is who owns the process.
//
// The windowed path hands the process to AppKit: `NSApplication.run()` blocks
// until the app quits, so the server is started from
// `applicationDidFinishLaunching` and the shutdown runs as a reply to a terminate
// request rather than as a return.
//
// The other two paths keep the original top-level-await shape, which means they
// never touch AppKit and therefore still start with no window server — the
// property that makes `--no-browser` usable from `launchd` and over SSH.
if Presentation.needsAppKit(options.presentation) {
    WindowedApp.run(options: options)
} else {
    await PhotoCleanerApp(options: options, hooks: .serverOnly).run()
}
