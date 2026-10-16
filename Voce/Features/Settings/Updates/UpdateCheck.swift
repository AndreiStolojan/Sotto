import Foundation

/// A release channel. Each one follows a branch of the public repository and has its own install command.
enum UpdateChannel: String {
    case stable
    case beta

    var branch: String { self == .beta ? "beta" : "main" }
    var appName: String { self == .beta ? "Sotto Beta" : "Sotto" }

    /// The README's install command for this channel. Running it again rebuilds and replaces the app.
    var installCommand: String {
        let command = "curl -fsSL https://raw.githubusercontent.com/\(UpdateCheck.repository)/main/install.sh | bash"
        return self == .beta ? command + " -s -- --beta" : command
    }
}

/// What scripts/build.sh embedded in Info.plist. A build made without it, or without git, has no commit.
struct AppBuild: Equatable {
    let version: String
    let channel: UpdateChannel?
    let commit: String?

    static let current = AppBuild(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        channel = (info["SottoChannel"] as? String).flatMap(UpdateChannel.init(rawValue:))
        commit = (info["SottoCommit"] as? String).flatMap(UpdateCheck.normalizedCommit)
    }

    /// For example "0.1.0 · beta · 3c2a404", or "0.1.0 · local build" without a commit.
    var summary: String {
        [version, channel?.rawValue, commit.map(UpdateCheck.shortCommit) ?? "local build"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// The manual update check: one unauthenticated GET for the head commit of the channel's branch.
enum UpdateCheck {
    static let repository = "AndreiStolojan/Sotto"

    enum Outcome: Equatable {
        case upToDate
        case updateAvailable(commit: String)
    }

    enum Failure: Error, Equatable {
        case offline
        case timedOut
        case rateLimited
        case httpStatus(Int)
        case unexpectedResponse
        case network(String)

        var message: String {
            switch self {
            case .offline: "Could not reach GitHub. Check your connection."
            case .timedOut: "GitHub did not answer in time."
            case .rateLimited: "GitHub's rate limit was reached. Try again later."
            case .httpStatus(let status): "GitHub answered with HTTP \(status)."
            case .unexpectedResponse: "GitHub sent an unexpected answer."
            case .network(let description): description
            }
        }
    }

    /// No cookies, cache, credentials or redirects, so the check stays one request to GitHub that carries nothing
    /// beyond its headers.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Refuses every redirect; a 3xx answer then fails the check as an unexpected HTTP status.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    static func request(for channel: UpdateChannel) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/commits/\(channel.branch)")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // The sha media type makes GitHub answer with the bare 40-character SHA instead of the full commit.
        request.setValue("application/vnd.github.sha", forHTTPHeaderField: "Accept")
        // GitHub requires a User-Agent. A fixed one keeps the macOS and app versions out of the request.
        request.setValue("Sotto", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func check(commit: String, channel: UpdateChannel) async -> Result<Outcome, Failure> {
        do {
            let (body, response) = try await session.data(for: request(for: channel))
            guard let http = response as? HTTPURLResponse else { return .failure(.unexpectedResponse) }
            return outcome(
                localCommit: commit,
                status: http.statusCode,
                rateLimitRemaining: http.value(forHTTPHeaderField: "x-ratelimit-remaining"),
                body: body
            )
        } catch let error as URLError {
            return .failure(failure(for: error))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// Reads GitHub's answer. Any difference from the local commit counts as an update, since the branch
    /// head is what the install command would build.
    static func outcome(localCommit: String, status: Int, rateLimitRemaining: String?, body: Data) -> Result<Outcome, Failure> {
        switch status {
        case 200:
            guard let remote = normalizedCommit(String(decoding: body, as: UTF8.self)) else {
                return .failure(.unexpectedResponse)
            }
            return .success(remote == localCommit.lowercased() ? .upToDate : .updateAvailable(commit: remote))
        case 429:
            return .failure(.rateLimited)
        case 403 where rateLimitRemaining == "0":
            return .failure(.rateLimited)
        default:
            return .failure(.httpStatus(status))
        }
    }

    static func failure(for error: URLError) -> Failure {
        switch error.code {
        case .timedOut:
            .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            .offline
        default:
            .network(error.localizedDescription)
        }
    }

    /// The trimmed, lowercased SHA if the text is exactly one full 40-character hex SHA.
    static func normalizedCommit(_ text: String) -> String? {
        let sha = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sha.count == 40 && sha.allSatisfy(\.isHexDigit) ? sha : nil
    }

    static func shortCommit(_ sha: String) -> String { String(sha.prefix(7)) }

    /// A Terminal script that runs the channel's install command. Opening a `.command` file runs it in
    /// Terminal, which needs no Automation permission.
    static func updateScript(for channel: UpdateChannel) -> String {
        """
        #!/bin/bash
        # \(channel.appName) wrote this file to update itself. It is safe to delete.
        set -euo pipefail
        \(channel.installCommand)

        """
    }

    /// Writes the update script to the temporary folder and returns its URL.
    static func writeUpdateScript(for channel: UpdateChannel) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Update \(channel.appName).command")
        try updateScript(for: channel).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
