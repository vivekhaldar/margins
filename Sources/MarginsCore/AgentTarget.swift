import Foundation

public enum AgentTarget: Equatable, Hashable, Codable, Sendable {
    case local(UUID)
    case cloud(CloudBackend)

    public static func localFallback(preferred: UUID?, providers: [ProviderConfig]) -> UUID? {
        let enabled = providers.filter(\.enabled)
        return enabled.first { $0.id == preferred }?.id ?? enabled.first?.id
    }

    public func resolvingDisabledCloud(lastLocal: UUID, enabledCloud: Set<CloudBackend>) -> Self {
        guard case .cloud(let backend) = self, !enabledCloud.contains(backend) else { return self }
        return .local(lastLocal)
    }

    public func toggled(lastLocal: UUID, lastCloud: CloudBackend, enabledCloud: Set<CloudBackend>) -> Self {
        if case .cloud = self { return .local(lastLocal) }
        let backend = enabledCloud.contains(lastCloud) ? lastCloud : CloudBackend.allCases.first(where: enabledCloud.contains)
        return backend.map(Self.cloud) ?? self
    }

    public func cloudBackendForSubmission(continuingAmpThread: Bool, enabledCloud: Set<CloudBackend>) -> CloudBackend? {
        guard case .cloud(let selected) = self else { return nil }
        let backend: CloudBackend = continuingAmpThread ? .amp : selected
        return enabledCloud.contains(backend) ? backend : nil
    }
}
