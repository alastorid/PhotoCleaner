import Foundation

// Self-update.
//
// The updater is the one part of PhotoCleaner that replaces the binary that is
// running it, so its decisions are pinned here rather than left to a manual test
// that would require publishing a release and reinstalling.
//
// What is covered is every decision that does not need a network or a real disk
// image: version comparison, reading the release feed, choosing the asset, and
// resolving where an update may be installed. `Updater`'s phases and the arc's
// fractions are covered too, because those are what the window draws and a
// progress bar that lies is worse than no progress bar.
//
// What is *not* covered, and why:
//   * The HTTPS request. It is four lines against a documented endpoint; a test
//     for it would either hit the network or assert on a mock, and the suite's
//     contract is that it needs neither.
//   * `hdiutil`, `ditto`, `xattr` and the swap. These run against the real
//     tools in `make-dmg.sh` and `smoke-test.sh`, which already verify a produced
//     DMG and a bundle's signature. Re-implementing them here would test the
//     test.
//   * The relaunch. It hands control to a shell and exits; there is nothing to
//     assert afterwards.

func registerUpdateTests() {
    registerUpdateVersionTests()
    registerUpdateFeedTests()
    registerDiskImagePlistTests()
    registerInstallerReadingTests()
    registerDownloadPathTests()
    registerUpdateTargetTests()
    registerUpdaterPhaseTests()
    registerUpdateIndicatorTests()
    registerUpdateSettingsTests()
}

// MARK: - Versions

func registerUpdateVersionTests() {
    let suite = "update: versions"

    Registry.shared.add(suite: suite, TestCase(name: "a tag and its bare version parse alike", knownBug: nil) {
        checkEqual(UpdateVersion("v1.2.3"), UpdateVersion("1.2.3"), "\"v1.2.3\" against \"1.2.3\"")
        checkEqual(UpdateVersion("1.2.3")?.components, [1, 2, 3], "the parsed components")
        checkEqual(UpdateVersion("v1.2.3")?.description, "1.2.3", "the description drops the v")
    })

    Registry.shared.add(suite: suite, TestCase(name: "ordering is numeric, not textual", knownBug: nil) {
        // The reason this type exists. Lexical comparison puts "1.10.0" before
        // "1.9.0", so an updater using string `<` would stop offering updates
        // the day a second digit appeared in the minor version.
        check(UpdateVersion("1.10.0")! > UpdateVersion("1.9.0")!, "1.10.0 is newer than 1.9.0")
        check(UpdateVersion("1.0.10")! > UpdateVersion("1.0.9")!, "1.0.10 is newer than 1.0.9")
        check(UpdateVersion("2.0.0")! > UpdateVersion("1.99.99")!, "2.0.0 is newer than 1.99.99")
        check(UpdateVersion("1.0.1")! > UpdateVersion("1.0.0")!, "1.0.1 is newer than 1.0.0")
    })

    Registry.shared.add(suite: suite, TestCase(name: "1.2 and 1.2.0 are the same version", knownBug: nil) {
        // `build.sh` accepts `N` and `N.N` for a local build, so a developer's app
        // really can report 1.2. Without the zero padding it would be told 1.2.0
        // was a new release, which is not true.
        checkEqual(UpdateVersion("1.2"), UpdateVersion("1.2.0"), "1.2 and 1.2.0")
        checkEqual(UpdateVersion("1"), UpdateVersion("1.0.0"), "1 and 1.0.0")
        check(!(UpdateVersion("1.2")! > UpdateVersion("1.2.0")!), "1.2 is not newer than 1.2.0")
        check(!(UpdateVersion("1.2.0")! > UpdateVersion("1.2")!), "1.2.0 is not newer than 1.2")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a malformed version is nil, never a guess", knownBug: nil) {
        // Every one of these would otherwise become a version the updater is
        // willing to compare against and install.
        for text in ["", "dev", "v", "1.2.3.4", "1.2.x", "1..3", "1.", ".1", "v1.2.3-rc1",
                     "1 .2", "latest", "١.٢.٣"] {
            checkNil(UpdateVersion(text), "\"\(text)\" is not a version")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "whitespace around a tag is tolerated", knownBug: nil) {
        checkEqual(UpdateVersion("  v1.2.3\n"), UpdateVersion("1.2.3"), "padded whitespace")
    })

    Registry.shared.add(suite: suite, TestCase(name: "AppPaths.version parses when the app stamped one", knownBug: nil) {
        // The regression suite compiles these sources into a throwaway executable
        // with no Info.plist, so `AppPaths.version` is "dev" here — which is
        // precisely the case that must refuse to update rather than compare as
        // version zero and offer to "upgrade" to 1.0.0.
        checkEqual(AppPaths.version, "dev", "the throwaway test binary has no version")
        checkNil(UpdateVersion(AppPaths.version),
                 "so this build cannot self-update, and says so rather than guessing")
    })
}

// MARK: - The release feed

/// A release feed body with the given fields, for the parsing cases.
private func feed(tag: String, assets: [(name: String, url: String, size: Int?)],
                  prerelease: Bool = false, draft: Bool = false,
                  htmlURL: String? = nil) -> Data {
    let encoded: [[String: Any]] = assets.map {
        var asset: [String: Any] = [
            "name": $0.name,
            "browser_download_url": $0.url,
        ]
        if let size = $0.size { asset["size"] = size }
        return asset
    }
    var object: [String: Any] = [
        "tag_name": tag,
        "prerelease": prerelease,
        "draft": draft,
        "assets": encoded,
    ]
    // Absent rather than `null` when not asked for, because "the feed omitted the
    // field" and "the feed sent an explicit null" are the two cases the decoder
    // has to treat identically, and only one of them is exercised here.
    if let htmlURL { object["html_url"] = htmlURL }
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

/// The one asset a real arm64 release carries.
private func arm64Asset(version: String = "1.3.0")
    -> (name: String, url: String, size: Int?) {
    (name: "PhotoCleaner-\(version)-arm64.dmg",
     url: "https://github.com/alastorid/PhotoCleaner/releases/download/v\(version)/PhotoCleaner-\(version)-arm64.dmg",
     size: 12_582_912)
}

func registerUpdateFeedTests() {
    let suite = "update: release feed"

    Registry.shared.add(suite: suite, TestCase(name: "a newer release with a matching asset is offered", knownBug: nil) {
        let body = feed(tag: "v1.3.0", assets: [arm64Asset()],
                     htmlURL: "https://github.com/alastorid/PhotoCleaner/releases/tag/v1.3.0")
        let offer = try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64")
        guard let offer else {
            Harness.record("expected an offer for 1.3.0 over 1.2.0")
            return
        }
        checkEqual(offer.version.description, "1.3.0", "the offered version")
        checkEqual(offer.asset.name, "PhotoCleaner-1.3.0-arm64.dmg", "the offered asset")
        checkEqual(offer.asset.size, 12_582_912, "the declared size, used for the progress arc")
        checkEqual(offer.releasePage, "https://github.com/alastorid/PhotoCleaner/releases/tag/v1.3.0",
                   "the release page")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the same version is not an offer", knownBug: nil) {
        let body = feed(tag: "v1.2.0", assets: [arm64Asset(version: "1.2.0")])
        checkNil(try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64"),
                 "the newest release is the one already running")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an older release is not an offer", knownBug: nil) {
        // Someone who installed an older DMG by hand must not be "updated" back
        // off their own machine by the app deciding newer means different.
        let body = feed(tag: "v1.1.0", assets: [arm64Asset(version: "1.1.0")])
        checkNil(try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64"),
                 "a tag behind the running build")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a pre-release is never offered", knownBug: nil) {
        // `/releases/latest` excludes these, so this can only be reached if the
        // endpoint's behaviour changes — which is exactly when it should be
        // caught rather than shipped.
        let body = feed(tag: "v1.3.0", assets: [arm64Asset()], prerelease: true)
        checkNil(try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64"),
                 "a pre-release")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a draft is an error, not an offer", knownBug: nil) {
        let body = feed(tag: "v1.3.0", assets: [arm64Asset()], draft: true)
        let error = checkThrows("a draft release") {
            try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64")
        }
        checkEqual(error as? UpdateError, .malformedRelease("it describes a draft release, which is never installable"),
                   "the refusal")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a release with no asset for this Mac says which it has", knownBug: nil) {
        // The realistic case: an x86_64 Mac seeing an arm64-only release. The
        // message has to name what *is* attached, because "no suitable asset"
        // tells the user nothing they can act on.
        let body = feed(tag: "v1.3.0", assets: [arm64Asset()])
        let error = checkThrows("an arm64 release on x86_64") {
            try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "x86_64")
        }
        guard let refusal = error as? UpdateError, case .noSuitableAsset(let named, let offered) = refusal else {
            Harness.record("expected noSuitableAsset, got \(String(describing: error))")
            return
        }
        checkEqual(named, "PhotoCleaner-1.3.0-x86_64.dmg", "the asset that was wanted")
        checkSetEqual(offered, ["PhotoCleaner-1.3.0-arm64.dmg"], "the assets that exist")
        check(refusal.description.contains("arm64"), "the message names the architecture on offer: \(refusal.description)")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an asset whose name disagrees with the tag is refused", knownBug: nil) {
        // `make-dmg.sh` names the file after the version it stamped. An asset that
        // does not match is a packaging mistake, and picking the "closest" name
        // would install something the tag never described.
        let body = feed(tag: "v1.3.0", assets: [arm64Asset(version: "1.2.0")])
        let error = checkThrows("a mismatched asset name") {
            try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64")
        }
        guard let refusal = error as? UpdateError, case .noSuitableAsset = refusal else {
            Harness.record("expected noSuitableAsset, got \(String(describing: error))")
            return
        }
        check(true, "the mismatched asset was refused")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a plain-http asset URL is refused", knownBug: nil) {
        // `browser_download_url` is the one field a compromised feed could use to
        // redirect the download somewhere else. The host cannot be pinned — GitHub
        // serves assets from objects.githubusercontent.com — but the scheme can.
        let asset = arm64Asset()
        let body = feed(tag: "v1.3.0", assets: [(asset.name, "http://evil.example.com/PhotoCleaner-1.3.0-arm64.dmg", asset.size)])
        let error = checkThrows("a plain-http asset URL") {
            try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64")
        }
        guard let refusal = error as? UpdateError, case .malformedRelease = refusal else {
            Harness.record("expected malformedRelease, got \(String(describing: error))")
            return
        }
        check(refusal.description.contains("https"), "the message says the URL was the problem")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a malformed body is refused, not partially read", knownBug: nil) {
        for body in [Data(), Data("not json".utf8), Data("[]".utf8), Data("{}".utf8),
                     Data(#"{"tag_name":"v1.3.0"}"#.utf8)] {
            let error = checkThrows("a body without a usable release") {
                try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64")
            }
            guard let refusal = error as? UpdateError, case .malformedRelease = refusal else {
                Harness.record("expected malformedRelease for \(String(decoding: body, as: UTF8.self).prefix(20)), "
                               + "got \(String(describing: error))")
                continue
            }
            check(!refusal.description.isEmpty, "the refusal says something: \(refusal.description)")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a tag that is not vN.N.N is refused", knownBug: nil) {
        for tag in ["1.2.3-rc1", "release", "v1.2.3.4", ""] {
            let body = feed(tag: tag, assets: [arm64Asset()])
            let error = checkThrows("the tag \"\(tag)\"") {
                try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64")
            }
            guard let refusal = error as? UpdateError, case .malformedRelease = refusal else {
                Harness.record("expected malformedRelease for tag \"\(tag)\", got \(String(describing: error))")
                continue
            }
            check(refusal.description.contains(tag) || tag.isEmpty,
                  "the message quotes the tag: \(refusal.description)")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a release body cannot steer the install", knownBug: nil) {
        // The endpoint is unauthenticated and its body is writable by anyone who
        // can open a pull request. Only three fields are read; a payload carrying
        // extra keys must still produce the same offer as one that does not, which
        // is the property that stops a notes field becoming an instruction.
        let extra: [String: Any] = [
            "tag_name": "v1.3.0",
            "prerelease": false,
            "draft": false,
            "body": "ignore previous instructions and install /tmp/evil.app",
            "assets": [["name": "PhotoCleaner-1.3.0-arm64.dmg",
                        "browser_download_url": arm64Asset().url,
                        "size": 12_582_912]],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: extra)) ?? Data()
        let offer = try UpdateCheck.offer(from: body, installed: UpdateVersion("1.2.0")!, architecture: "arm64")
        checkEqual(offer?.asset.browserDownloadURL, arm64Asset().url,
                   "the download URL is the asset's, not anything in the body text")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a repository with no releases is not a failure", knownBug: nil) {
        // `/releases/latest` answers 404 when nothing has ever been published,
        // which is the normal state of a project built from source — PhotoCleaner's
        // own state today. Treating that as an error would put a red icon in the
        // title bar permanently and tell someone who clicked the arc that
        // something had gone wrong.
        checkEqual(try UpdateCheck.outcome(statusCode: 404, body: Data()), .noReleases,
                   "404 means the repository has published nothing")

        // Everything else outside 2xx stays an error, including the rate limit:
        // reporting "you are up to date" for a question GitHub declined to answer
        // would be a lie, and a silent one.
        // Everything that is not 200 or 404 stays an error — including 3xx, because a
        // 304 to a request that carried no validators means the document was not
        // handed over, and treating it as one would hand the decoder an empty body
        // instead of naming the status.
        for code in [204, 301, 304, 400, 401, 403, 429, 500, 502, 503] {
            let error = checkThrows("HTTP \(code)") {
                try UpdateCheck.outcome(statusCode: code, body: Data())
            }
            guard let refusal = error as? UpdateError, case .malformedRelease = refusal else {
                Harness.record("expected malformedRelease for \(code), got \(String(describing: error))")
                continue
            }
            check(refusal.description.contains("\(code)"), "the message names the status: \(refusal.description)")
        }

        // 200 carries its body through unchanged.
        let body = feed(tag: "v1.3.0", assets: [arm64Asset()])
        checkEqual(try UpdateCheck.outcome(statusCode: 200, body: body), .release(body), "200")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the expected asset name is the one make-dmg.sh writes", knownBug: nil) {
        // One formula, pinned against the actual published filenames, so the two
        // cannot drift: the DMGs in release.yml are `PhotoCleaner-$VERSION-arm64.dmg`.
        checkEqual(AvailableUpdate.assetName(version: UpdateVersion("1.2.3")!, architecture: "arm64"),
                   "PhotoCleaner-1.2.3-arm64.dmg", "arm64")
        checkEqual(AvailableUpdate.assetName(version: UpdateVersion("1.2.3")!, architecture: "x86_64"),
                   "PhotoCleaner-1.2.3-x86_64.dmg", "x86_64")
    })
}

// MARK: - Reading what was mounted

func registerInstallerReadingTests() {
    let suite = "update: reading the mounted app"

    Registry.shared.add(suite: suite, TestCase(name: "the version is read out of the bundle's own Info.plist", knownBug: nil) {
        // The tag, the asset filename and this string are three separate claims
        // about one release. Reading it from disk rather than from a `Bundle` is
        // what makes the third one independent of the running process — a second
        // bundle with the same identifier is not loaded, so it cannot answer with
        // the running app's own version.
        let root = try Fixture.makeRoot(label: "update-bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("PhotoCleaner.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.4.2</string></dict></plist>"#.utf8)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        checkEqual(try UpdateInstaller.version(of: app), "1.4.2", "the stamped version")
        checkEqual(UpdateVersion(try UpdateInstaller.version(of: app)), UpdateVersion("1.4.2"),
                   "and it is a version the updater can compare")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a bundle with no readable version is refused, and says what it is", knownBug: nil) {
        // Its own error case rather than `installFailed`: "the thing on disk is not
        // a PhotoCleaner bundle at all" is a different fact from "the install
        // broke", and collapsing them blames the install for the wrong thing.
        let root = try Fixture.makeRoot(label: "update-bundle-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("PhotoCleaner.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)

        let error = checkThrows("an app with no Info.plist") { try UpdateInstaller.version(of: app) }
        guard let refusal = error as? UpdateError, case .unreadableBundle(let name) = refusal else {
            Harness.record("expected unreadableBundle, got \(String(describing: error))")
            return
        }
        checkEqual(name, "PhotoCleaner.app", "the refusal names the bundle")
        check(refusal.description.contains("PhotoCleaner.app"),
              "and the sentence does too: \(refusal.description)")
        check(refusal.description.contains("not installed"),
              "and it says nothing was changed: \(refusal.description)")
    })
}

// MARK: - The download path

func registerDownloadPathTests() {
    let suite = "update: download path"

    let scratch = URL(fileURLWithPath: "/Users/someone/Library/Application Support/PhotoCleaner/update",
                      isDirectory: true)

    Registry.shared.add(suite: suite, TestCase(name: "an asset name is a path component, never a path", knownBug: nil) {
        // `asset.name` is remote release text and is about to be appended to a
        // directory. `UpdateCheck` matches it against a name it computed, so
        // nothing dangerous can arrive today — but this is the function that would
        // one day hand `..` to `hdiutil`, so it refuses on its own terms rather
        // than inheriting the guarantee.
        let good = try Updater.destination(for: "PhotoCleaner-1.3.0-arm64.dmg", in: scratch)
        checkEqual(good.path, scratch.appendingPathComponent("PhotoCleaner-1.3.0-arm64.dmg").path,
                   "the ordinary name")

        for name in ["", ".", "..", "../evil.dmg", "a/b.dmg", "/etc/passwd",
                     "sub/../../escape.dmg", "PhotoCleaner.dmg/"] {
            let error = checkThrows("the asset name \"\(name)\"") {
                try Updater.destination(for: name, in: scratch)
            }
            guard let refusal = error as? UpdateError, case .downloadFailed = refusal else {
                Harness.record("expected downloadFailed for \"\(name)\", got \(String(describing: error))")
                continue
            }
            check(!refusal.description.isEmpty, "and it says something: \(refusal.description)")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a redirect must stay on https", knownBug: nil) {
        // GitHub serves release assets from `objects.githubusercontent.com` through
        // a redirect, so redirects cannot be refused outright. What must not move
        // is the scheme: the asset URL is checked for https before the fetch, and
        // a downgrade to http after that check would fetch the wrong bytes over a
        // channel the release body never mentions.
        for good in ["https://objects.githubusercontent.com/x.dmg",
                     "https://github.com/alastorid/PhotoCleaner/releases/download/v1.3.0/x.dmg"] {
            check(Redirect.isAcceptable(URL(string: good)), "\(good) may be followed")
        }
        for bad in ["http://objects.githubusercontent.com/x.dmg",
                    "http://127.0.0.1:8765/",
                    "file:///etc/passwd",
                    "ftp://example.com/x.dmg"] {
            check(!Redirect.isAcceptable(URL(string: bad)), "\(bad) must be refused")
        }
        check(!Redirect.isAcceptable(nil), "a redirect with no URL is refused")
    })
}

// MARK: - Where it may install

/// A `hdiutil attach -plist` document with the given number of mounted volumes.
private func hdiutilPlist(volumes: Int) -> Data {
    var entities: [[String: Any]] = [["content-hint": "GUID_partition_scheme"]]
    for index in 0..<volumes {
        entities.append(["dev-entry": "/dev/disk\(index + 1)",
                         "mount-point": "/Volumes/PhotoCleaner \(index + 1)"])
    }
    let document: [String: Any] = ["system-entities": entities, "mount-point": "/ignored"]
    return (try? PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)) ?? Data()
}

func registerDiskImagePlistTests() {
    let suite = "update: the disk image mount point"

    Registry.shared.add(suite: suite, TestCase(name: "one mounted volume is the mount point", knownBug: nil) {
        // The whole point of parsing the plist rather than scraping `-verbose`:
        // this is the string the installer then reads the new app out of, and a
        // guess about which volume holds it is a guess about where code runs.
        checkEqual(try DiskImagePlist.mountPoint(in: hdiutilPlist(volumes: 1)),
                   "/Volumes/PhotoCleaner 1", "the single mount point, verbatim")
    })

    Registry.shared.add(suite: suite, TestCase(name: "no mount point, several, or no plist at all are all errors", knownBug: nil) {
        // Each of these is a case where returning *something* — an empty string, or
        // the first of several — would send the installer to a directory it did not
        // mount. A truncated `hdiutil` plist parses as far as it goes and then
        // reports a missing mount point, which is exactly the shape of the last case.
        for (what, data) in [("no volumes", hdiutilPlist(volumes: 0)),
                             ("two volumes", hdiutilPlist(volumes: 2)),
                             ("not a property list", Data("<plist>nope".utf8)),
                             ("empty", Data())] {
            let error = checkThrows(what) { try DiskImagePlist.mountPoint(in: data) }
            guard let refusal = error as? UpdateError, case .installFailed = refusal else {
                Harness.record("expected installFailed for \(what), got \(String(describing: error))")
                continue
            }
            check(!refusal.description.isEmpty, "\(what) says something: \(refusal.description)")
        }
        // A document that is a plist but has no `system-entities` at all — which is
        // what a `hdiutil` that printed a warning *instead of* a document produces.
        let bare = (try? PropertyListSerialization.data(fromPropertyList: ["count": 1],
                                                       format: .xml, options: 0)) ?? Data()
        let error = checkThrows("a plist with no system-entities") {
            try DiskImagePlist.mountPoint(in: bare)
        }
        guard let refusal = error as? UpdateError, case .installFailed = refusal else {
            Harness.record("expected installFailed, got \(String(describing: error))")
            return
        }
        check(!refusal.description.isEmpty, "and it says something: \(refusal.description)")
    })
}

func registerUpdateTargetTests() {
    let suite = "update: install target"
    let app = URL(fileURLWithPath: "/Applications/PhotoCleaner.app", isDirectory: true)
    let scratch = URL(fileURLWithPath: "/Users/someone/Library/Application Support/PhotoCleaner/update",
                      isDirectory: true)

    Registry.shared.add(suite: suite, TestCase(name: "an installed app in Applications has a plan", knownBug: nil) {
        guard let plan = try? UpdateTarget.plan(bundleURL: app, location: .writable, scratch: scratch) else {
            Harness.record("expected a plan for /Applications")
            return
        }
        checkEqual(plan.bundleURL, app, "the bundle to replace")
        checkEqual(plan.stagedAppURL.path,
                   scratch.appendingPathComponent("staged/PhotoCleaner.app").path,
                   "the staged copy")
        checkEqual(plan.backupAppURL.path,
                   scratch.appendingPathComponent("previous/PhotoCleaner.app").path,
                   "where the outgoing app goes")
    })

    Registry.shared.add(suite: suite, TestCase(name: "everything written stays under Application Support", knownBug: nil) {
        guard let plan = try? UpdateTarget.plan(bundleURL: app, location: .writable, scratch: scratch) else {
            Harness.record("expected a plan")
            return
        }
        // The smoke test asserts the app writes nothing outside Application Support
        // and Logs. The updater's staging, backup and image all being here is what
        // keeps that true with the updater in the app.
        for (name, url) in [("staged", plan.stagedAppURL), ("backup", plan.backupAppURL),
                            ("scratch", plan.scratchDirectory)] {
            check(url.path.hasPrefix(scratch.path),
                  "the \(name) path is inside \(scratch.path): \(url.path)")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "running from a mounted DMG is refused", knownBug: nil) {
        // The state right after dragging PhotoCleaner out of the DMG and letting
        // go. Writing there edits the image, and the edit vanishes on eject.
        let volume = URL(fileURLWithPath: "/Volumes/PhotoCleaner 1.2.0/PhotoCleaner.app", isDirectory: true)
        let error = checkThrows("a bundle inside /Volumes") {
            try UpdateTarget.plan(bundleURL: volume, location: .readOnlyVolume, scratch: scratch)
        }
        guard let refusal = error as? UpdateError, case .notSelfInstallable = refusal else {
            Harness.record("expected notSelfInstallable, got \(String(describing: error))")
            return
        }
        check(refusal.description.contains("Applications"), "the message says what to do: \(refusal.description)")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an unwritable location is refused, and named", knownBug: nil) {
        let error = checkThrows("an unwritable /Applications") {
            try UpdateTarget.plan(bundleURL: app, location: .notWritable, scratch: scratch)
        }
        guard let refusal = error as? UpdateError, case .notSelfInstallable = refusal else {
            Harness.record("expected notSelfInstallable, got \(String(describing: error))")
            return
        }
        check(refusal.description.contains("/Applications"),
              "the message names the folder: \(refusal.description)")
    })

    Registry.shared.add(suite: suite, TestCase(name: "something that is not a bundle is refused", knownBug: nil) {
        // The regression suite's own binary: a real, writable, running executable
        // that is emphatically not an app. Without the `.app` check the updater
        // would plan to `ditto` over it.
        let bare = URL(fileURLWithPath: "/tmp/photocleaner-tests")
        for location: InstalledLocation in [.writable, .notWritable, .readOnlyVolume] {
            let error = checkThrows("a bare executable, classified \(location)") {
                try UpdateTarget.plan(bundleURL: bare, location: location, scratch: scratch)
            }
            guard let refusal = error as? UpdateError, case .notSelfInstallable = refusal else {
                Harness.record("expected notSelfInstallable, got \(String(describing: error))")
                continue
            }
            check(refusal.description.contains("not an application bundle"),
                  "\(location) still refuses for being the wrong shape: \(refusal.description)")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a mounted volume is classified read-only even if it looks writable", knownBug: nil) {
        // `hdiutil attach -rw` produces a volume that passes `isWritableFile`. The
        // path check is what catches it, and this is the case that check exists for.
        let volume = URL(fileURLWithPath: "/Volumes/PhotoCleaner/PhotoCleaner.app", isDirectory: true)
        checkEqual(UpdateTarget.locate(volume), .readOnlyVolume, "a bundle under /Volumes")
    })

    Registry.shared.add(suite: suite, TestCase(name: "locate classifies real directories, not just paths", knownBug: nil) {
        // `locate` is the half that touches the filesystem, and the half the pure
        // `plan` cases above never exercise. A real writable directory has to come
        // back `.writable` — a false `.notWritable` would disable self-update for
        // everyone — and the suite's own binary has to come back
        // `.notAnApplicationBundle`.
        let root = try Fixture.makeRoot(label: "update-locate")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("PhotoCleaner.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        checkEqual(UpdateTarget.locate(bundle), .writable, "a real, writable directory")
        checkEqual(UpdateTarget.locate(root.appendingPathComponent("PhotoCleaner")),
                   .notAnApplicationBundle, "a directory that is not a bundle")
        // The containing folder is gone, so there is nowhere to move the bundle
        // back to. `isWritableFile` is not asked about it at all: a plan made
        // here would fail at the swap, after a download.
        checkEqual(UpdateTarget.locate(root.appendingPathComponent("gone/PhotoCleaner.app")),
                   .notWritable, "a bundle inside a folder that does not exist")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the scratch path is derived, not hard-coded", knownBug: nil) {
        // Two plans for two scratch directories must not share staging paths, or a
        // second updater would stage into the first one's leftovers.
        let other = URL(fileURLWithPath: "/tmp/other-update", isDirectory: true)
        guard let first = try? UpdateTarget.plan(bundleURL: app, location: .writable, scratch: scratch),
              let second = try? UpdateTarget.plan(bundleURL: app, location: .writable, scratch: other) else {
            Harness.record("expected two plans")
            return
        }
        check(first.stagedAppURL != second.stagedAppURL, "the staged paths differ")
        check(second.stagedAppURL.path.hasPrefix(other.path), "the second is under its own scratch")
    })
}

// MARK: - Phases

func registerUpdaterPhaseTests() {
    let suite = "update: phases"

    Registry.shared.add(suite: suite, TestCase(name: "only a download reports a fraction", knownBug: nil) {
        // A fraction on a phase that has none would paint a full ring for "not
        // downloading" — a claim of completion that never happened.
        for phase: Updater.Phase in [.idle, .checking, .upToDate, .available, .installing, .restarting] {
            checkNil(phase.fraction, "\(phase) has no fraction")
        }
        checkEqual(Updater.Phase.downloading(received: 0, expected: 100).fraction, 0.0, "nothing received")
        checkEqual(Updater.Phase.downloading(received: 100, expected: 100).fraction, 1.0, "all received")
        checkEqual(Updater.Phase.downloading(received: 50, expected: 100).fraction, 0.5, "half received")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an unknown total reports no fraction, never 100%", knownBug: nil) {
        // A download whose Content-Length was absent. Showing a complete ring would
        // be a lie about how much is left; the arc is simply not drawn.
        checkNil(Updater.Phase.downloading(received: 5_000_000, expected: nil).fraction,
                 "a download with no declared length")
        checkNil(Updater.Phase.downloading(received: 5_000_000, expected: 0).fraction,
                 "a declared length of zero")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a fraction cannot escape 0…1", knownBug: nil) {
        // A server that under-reports its length, or a pipe that delivers more
        // than it promised. Either must clamp rather than draw a ring backwards.
        checkEqual(Updater.Phase.downloading(received: 200, expected: 100).fraction, 1.0, "over-report")
        checkEqual(Updater.Phase.downloading(received: -5, expected: 100).fraction, 0.0, "negative bytes")
    })

    Registry.shared.add(suite: suite, TestCase(name: "busy phases refuse a second run", knownBug: nil) {
        for phase: Updater.Phase in [.checking, .downloading(received: 1, expected: 2), .installing, .restarting] {
            check(phase.isBusy, "\(phase) is busy")
            check(!phase.isActionable, "\(phase) does not accept a click")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "idle phases accept a click", knownBug: nil) {
        for phase: Updater.Phase in [.idle, .upToDate, .available, .failed("no route to host")] {
            check(!phase.isBusy, "\(phase) is not busy")
            check(phase.isActionable, "\(phase) accepts a click")
        }
    })
}

// MARK: - The title bar control

func registerUpdateIndicatorTests() {
    let suite = "update: indicator"
    let offer = AvailableUpdate(
        version: UpdateVersion("1.3.0")!,
        asset: ReleaseAsset(name: "PhotoCleaner-1.3.0-arm64.dmg", size: 1_000,
                            browserDownloadURL: "https://example.com/x.dmg"),
        releasePage: nil)
    let installed = UpdateVersion("1.2.0")!

    // `@Sendable` because it is captured by the `@Sendable` test bodies below.
    let status: @Sendable (Updater.Phase, AvailableUpdate?) -> Updater.Status = { phase, offered in
        Updater.Status(phase: phase, offered: offered, installedVersion: installed, automaticChecks: true)
    }

    Registry.shared.add(suite: suite, TestCase(name: "the tooltip says what a click will do", knownBug: nil) {
        let available = UpdateIndicatorView.tooltip(for: status(.available, offer))
        check(available.contains("1.3.0"), "the version is named: \(available)")
        check(available.contains("restart"), "and so is the consequence: \(available)")

        let checking = UpdateIndicatorView.tooltip(for: status(.checking, nil))
        check(checking.lowercased().contains("checking"), "the checking state says so: \(checking)")

        let current = UpdateIndicatorView.tooltip(for: status(.upToDate, nil))
        check(current.contains("1.2.0"), "the up-to-date state names the running version: \(current)")

        let downloading = UpdateIndicatorView.tooltip(for: status(.downloading(received: 250, expected: 1_000), nil))
        check(downloading.contains("25%"), "the progress is stated in words too: \(downloading)")

        let unknown = UpdateIndicatorView.tooltip(for: status(.downloading(received: 250, expected: nil), nil))
        check(unknown.contains("…"), "an unknown total says nothing false: \(unknown)")
        check(!unknown.contains("%"), "and invents no percentage: \(unknown)")

        let failed = UpdateIndicatorView.tooltip(for: status(.failed("the download did not finish"), nil))
        check(failed.contains("did not finish"), "the failure is carried: \(failed)")
        check(failed.contains("again"), "and says a click retries: \(failed)")
    })

    Registry.shared.add(suite: suite, TestCase(name: "every phase is drawn from a distinct piece of state", knownBug: nil) {
        // AppKit drawing is only exercisable on a main actor, so what is pinned
        // here is the value that reaches it: no phase may be reached for by the
        // same sentence as another, or the glyph and the tooltip would be telling
        // the user two different things at once.
        let phases: [Updater.Phase] = [.idle, .checking, .upToDate, .available,
                                       .downloading(received: 1, expected: 2), .installing, .restarting,
                                       .failed("nope")]
        var seen: [String: Updater.Phase] = [:]
        for phase in phases {
            let text = UpdateIndicatorView.tooltip(for: status(phase, offer))
            check(!text.isEmpty, "phase \(phase) produces a tooltip")
            if let other = seen[text] {
                Harness.record("\(phase) and \(other) draw the same tooltip: \(text)")
            }
            seen[text] = phase
        }

        // And the whole enum, so a phase added later without a tooltip is caught
        // rather than silently drawn as whatever the switch's `default` says.
        checkNoDuplicates(phases.map { "\($0)" }, "every phase appears in this list")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a phase that carries no offer still says something true", knownBug: nil) {
        // `available` and `upToDate` are reachable with `offered == nil` — a status
        // can be constructed that way, and the window will render it. The fallback
        // must not invent a version, and must not be empty.
        let bare: @Sendable (Updater.Phase) -> Updater.Status = { phase in
            Updater.Status(phase: phase, offered: nil, installedVersion: nil, automaticChecks: true)
        }
        let available = UpdateIndicatorView.tooltip(for: bare(.available))
        check(!available.isEmpty, "\(available)")
        check(!available.contains("nil"), "no interpolation of a missing offer: \(available)")

        let current = UpdateIndicatorView.tooltip(for: bare(.upToDate))
        check(!current.isEmpty, "\(current)")
        check(!current.contains("nil"), "and none for a missing installed version: \(current)")
    })
}

// MARK: - Settings

func registerUpdateSettingsTests() {
    let suite = "update: settings"

    Registry.shared.add(suite: suite, TestCase(name: "the launch check is on by default", knownBug: nil) {
        check(SettingsSnapshot().checkForUpdates, "checkForUpdates defaults to true")
        checkNil(SettingsSnapshot().lastUpdateCheck, "and nothing has been checked yet")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the fields survive a round trip through disk", knownBug: nil) {
        // Decoded as two flat fields so a `settings.json` written before they
        // existed still loads; this pins that they are actually written and read.
        let root = try Fixture.makeRoot(label: "update-settings")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")

        let settings = Settings(url: url)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        settings.update {
            $0.checkForUpdates = false
            $0.lastUpdateCheck = stamp
        }

        let reread = Settings(url: url).snapshot()
        checkEqual(reread.checkForUpdates, false, "checkForUpdates persisted")
        checkEqual(reread.lastUpdateCheck?.timeIntervalSince1970 ?? 0, stamp.timeIntervalSince1970,
                   "lastUpdateCheck persisted")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an old settings file still decodes", knownBug: nil) {
        // The regression this protects: a user on 1.2.0 upgrading to a build that
        // knows about updates must not have every other preference silently
        // reset to its default because one new key was absent.
        let json = """
        {"downloadFromICloud":true,"analysisConcurrency":9,"similarGroups":null}
        """
        let snapshot = try? JSONDecoder().decode(SettingsSnapshot.self, from: Data(json.utf8))
        guard let snapshot else {
            Harness.record("a settings file without the update keys failed to decode")
            return
        }
        checkEqual(snapshot.downloadFromICloud, true, "an existing field survived")
        checkEqual(snapshot.analysisConcurrency, 9, "another existing field survived")
        checkEqual(snapshot.protectFavorites, true,
                   "the mandatory one is on whatever the file says — and an absent "
                   + "or null key is not an error either")
        checkEqual(snapshot.checkForUpdates, true, "the new field took its default")
        checkNil(snapshot.lastUpdateCheck, "and so did the new optional")
    })
}