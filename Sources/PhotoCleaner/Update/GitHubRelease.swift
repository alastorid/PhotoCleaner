import Foundation

/// One file attached to a GitHub release.
///
/// Decoded rather than read out of `JSONSerialization` so an unexpected shape is
/// a decode error naming the field, and so nothing else in the payload can reach
/// the installer.
struct ReleaseAsset: Decodable, Sendable, Equatable {
    let name: String
    let size: Int?
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name, size
        case browserDownloadURL = "browser_download_url"
    }
}

/// The parts of `GET /repos/{owner}/{repo}/releases/latest` this tool reads.
///
/// A `struct` rather than a dictionary walk, and *only* these fields: the
/// endpoint is unauthenticated and its body is writable by anyone who can open a
/// pull request, so the release notes are attacker-adjacent text. The updater
/// acts on `tagName` and the asset's `browser_download_url` and on nothing else —
/// the notes are shown to a human, never executed, and `assets` names are matched
/// exactly rather than pattern-matched.
struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let htmlURL: String?
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// A published release this Mac can install, resolved to one concrete asset.
struct AvailableUpdate: Sendable, Equatable {
    let version: UpdateVersion
    let asset: ReleaseAsset
    /// The release page, so the notes are one click away.
    let releasePage: String?

    /// The filename `make-dmg.sh` writes and `release.yml` attaches.
    ///
    /// Spelled out rather than matched against a pattern so a release carrying
    /// two DMGs cannot have the wrong one chosen: the name carries the version, so
    /// an asset whose name disagrees with the tag is a packaging mistake worth
    /// refusing rather than guessing at.
    static func assetName(version: UpdateVersion, architecture: String) -> String {
        "PhotoCleaner-\(version)-\(architecture).dmg"
    }
}

/// Everything that can go wrong on the way to a new version.
///
/// `CustomStringConvertible` because every one of these ends up in the title bar's
/// tooltip, in an alert the user clicked their way into, or in the log — and a
/// bare enum case name is not an answer to "why did the update fail?".
enum UpdateError: Error, Equatable, CustomStringConvertible {
    /// The release endpoint answered with something not usable as a release.
    case malformedRelease(String)
    /// No asset in the release matches what this Mac would install.
    case noSuitableAsset(named: String, offered: [String])
    /// This build cannot replace itself from where it is.
    case notSelfInstallable(String)
    /// A bundle on disk has no readable `CFBundleShortVersionString`.
    ///
    /// Its own case rather than folded into `installFailed`, because it is a
    /// different fact with a different consequence: `installFailed` says the install
    /// broke, while this says the thing on disk is not a PhotoCleaner bundle at
    /// all. Collapsing them would turn "the download contained a directory called
    /// PhotoCleaner.app" into "the update failed", which is vaguer and wrong about
    /// whose fault it was.
    case unreadableBundle(name: String)
    /// The DMG could not be fetched or read.
    case downloadFailed(String)
    /// The image mounted, but the app inside it was not what the tag promised.
    case wrongPayload(expected: String, found: String)
    /// The swap failed. Nothing was changed when this is thrown from the staging
    /// step; once it is thrown from the swap step the outgoing bundle has already
    /// been moved aside.
    case installFailed(String)
    /// The relaunch could not be scheduled, so the app is now new but stopped.
    case restartFailed(String)

    var description: String {
        switch self {
        case .malformedRelease(let detail):
            return "Could not read the update feed: \(detail)."
        case .noSuitableAsset(let named, let offered):
            // Naming what *is* there is what makes this actionable: the usual
            // cause is that the release was cut for the other architecture.
            let list = offered.isEmpty ? "it has no files attached" : "it has \(offered.joined(separator: ", "))"
            return "PhotoCleaner \(named.replacingOccurrences(of: ".dmg", with: "")) is not published for this Mac — \(list)."
        case .notSelfInstallable(let detail):
            return "This copy of PhotoCleaner cannot update itself: \(detail)."
        case .downloadFailed(let detail):
            return "The download did not finish: \(detail)."
        case .unreadableBundle(let name):
            return "\(name) is not a PhotoCleaner application bundle, so there is no version in it to check. It was not installed."
        case .wrongPayload(let expected, let found):
            return "The downloaded disk image contains PhotoCleaner \(found.isEmpty ? "with no version" : found), but the release is \(expected). It was not installed."
        case .installFailed(let detail):
            return "PhotoCleaner could not be replaced: \(detail)."
        case .restartFailed(let detail):
            return "PhotoCleaner was updated but could not be restarted: \(detail). Open it again from Applications."
        }
    }
}

/// What a reply from the release feed means, before it is looked at.
///
/// Separated from the fetch so the rule is testable without a network. The
/// distinction that matters is `noReleases`: GitHub answers 404 for a repository
/// that has never published a release, which is a normal state for a project built
/// from source — PhotoCleaner's own state, today — and not a failure to report.
enum FeedOutcome: Sendable, Equatable {
    /// The repository exists and has published nothing yet.
    case noReleases
    /// A release document, to be decoded.
    case release(Data)
}

extension UpdateCheck {
    /// Classify a reply from `GET /releases/latest`.
    ///
    /// 404 becomes `noReleases` rather than an error. Everything else that is not
    /// 200 stays an error, including 403, 429 and 304: those are GitHub declining
    /// to hand over the document — a rate limit, a missing token, or a conditional
    /// response to a request that carried no validators — and reporting "you are up
    /// to date" for a question that was never answered would be a lie, and a silent
    /// one.
    ///
    /// Only 200 rather than the whole 2xx range, because this endpoint answers 200
    /// or nothing, and treating a 204 or a 206 as a release document would hand the
    /// decoder an empty body to fail on instead of naming the status here.
    static func outcome(statusCode: Int, body: Data) throws -> FeedOutcome {
        if statusCode == 404 { return .noReleases }
        guard statusCode == 200 else {
            throw UpdateError.malformedRelease("the feed answered HTTP \(statusCode)")
        }
        return .release(body)
    }
}

/// Turns a release feed into an offer, or into nothing to do.
enum UpdateCheck {
    /// What the feed says, resolved against what is installed.
    ///
    /// Returns `nil` when there is nothing to offer — already current, or a
    /// pre-release, which `/releases/latest` excludes but which is refused here
    /// as well so no future caller can install one by asking the wrong endpoint.
    /// Throws when the answer is not something the updater may act on: a
    /// non-release body, a tag that is not `vN.N.N`, an asset whose URL is not
    /// https, or no asset for this architecture.
    static func offer(from data: Data, installed: UpdateVersion, architecture: String) throws -> AvailableUpdate? {
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.malformedRelease("\(error)")
        }

        if release.draft {
            throw UpdateError.malformedRelease("it describes a draft release, which is never installable")
        }
        if release.prerelease { return nil }

        guard let version = UpdateVersion(release.tagName) else {
            throw UpdateError.malformedRelease("\"\(release.tagName)\" is not a vN.N.N tag")
        }
        // Strictly greater, never unequal: an equal version means current, and a
        // tag *behind* the running build happens whenever someone rolls back by
        // installing an older DMG by hand. Neither is an update.
        guard version > installed else { return nil }

        let wanted = AvailableUpdate.assetName(version: version, architecture: architecture)
        guard let asset = release.assets.first(where: { $0.name == wanted }) else {
            throw UpdateError.noSuitableAsset(named: wanted, offered: release.assets.map(\.name))
        }
        // Cheap, and it is the one thing about the asset that is worth refusing
        // before a byte is written to disk: `browser_download_url` is the field a
        // compromised feed would use to redirect the download. The host is not
        // pinned, because GitHub legitimately serves assets from
        // objects.githubusercontent.com; the scheme is the part that must not move.
        guard let remote = URL(string: asset.browserDownloadURL), remote.scheme == "https" else {
            throw UpdateError.malformedRelease("the asset URL is not https")
        }

        return AvailableUpdate(version: version, asset: asset, releasePage: release.htmlURL)
    }
}
