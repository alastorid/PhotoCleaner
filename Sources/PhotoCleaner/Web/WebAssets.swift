import Foundation

/// Access to the UI assets compiled into the executable.
///
/// Nothing is read from the filesystem at runtime: `GeneratedWebAssets.swift`
/// is produced by `tools/embed-web.swift` from the `web/` directory at build
/// time, so the binary is self-contained and there is no path that could be
/// traversed or used to serve arbitrary files.
enum WebAssets {
    static func bytes(named name: String) -> Data? {
        EmbeddedWebAssets.bytes(named: name)
    }
}
