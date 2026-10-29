import Foundation

/// Decides whether a browser URL belongs to a website trigger such as
/// `slack.com` or `icloud.com/mail`.
///
/// The trigger's host matches the URL's host or any of its subdomains, so
/// `slack.com` matches `team.slack.com` but not `slack.com.example.net` or
/// `example.net/?slack.com`. A trigger path matches whole path segments, so
/// `icloud.com/mail` matches `/mail/inbox` but not `/mailbox`.
enum ModeWebsiteMatcher {
    static func matches(url: String, website: String) -> Bool {
        guard let pattern = Pattern(website), let target = Target(url) else { return false }

        let hostMatches = target.hosts.contains { host in
            host == pattern.host || host.hasSuffix("." + pattern.host)
        }
        guard hostMatches else { return false }
        guard !pattern.path.isEmpty else { return true }
        return target.path == pattern.path || target.path.hasPrefix(pattern.path + "/")
    }

    /// A website trigger split into host and path, without scheme or `www.`.
    private struct Pattern {
        let host: String
        let path: String

        init?(_ website: String) {
            var value = website.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
                value.removeFirst(scheme.count)
            }
            if value.hasPrefix("www.") {
                value.removeFirst(4)
            }

            let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let host = parts.first.map(String.init) ?? ""
            guard !host.isEmpty else { return nil }
            self.host = host
            self.path = parts.count > 1 ? Self.trimmedPath(String(parts[1])) : ""
        }

        static func trimmedPath(_ path: String) -> String {
            path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    /// The parsed browser URL. `hosts` includes `host:port` so `localhost:3000`
    /// triggers keep working.
    private struct Target {
        let hosts: [String]
        let path: String

        init?(_ url: String) {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
            guard let components = URLComponents(string: withScheme),
                let rawHost = components.host?.lowercased(),
                !rawHost.isEmpty
            else { return nil }

            let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
            hosts = components.port.map { [host, "\(host):\($0)"] } ?? [host]
            path = Pattern.trimmedPath(components.path.lowercased())
        }
    }
}
