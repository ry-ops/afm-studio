import Foundation
import AFMKit

/// GitHub data kept on this Mac (integrations/github.json). Never credentials.
public struct GitHubSettings: Codable, Sendable, Equatable {
    public var blog: BlogProfile?
    public var localRepos: [String] = []

    public init() {}

    public static func load() -> GitHubSettings { IntegrationStore.load(GitHubIntegration.integrationID, as: GitHubSettings.self) ?? GitHubSettings() }
    public func save() { IntegrationStore.save(GitHubIntegration.integrationID, self) }

    public mutating func remember(localRepo path: String) {
        localRepos.removeAll { $0 == path }
        localRepos.insert(path, at: 0)
        localRepos = Array(localRepos.prefix(8))
    }
}
