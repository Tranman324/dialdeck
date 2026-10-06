import Foundation

public enum ActionResolutionSource: Equatable, Sendable {
    case applicationOverride(profileID: ProfileID)
    case inheritedDefault(profileID: ProfileID)
    case defaultProfile(profileID: ProfileID)
}

public struct ResolvedAction: Equatable, Sendable {
    public let action: ConfiguredAction
    public let source: ActionResolutionSource

    public init(action: ConfiguredAction, source: ActionResolutionSource) {
        self.action = action
        self.source = source
    }
}

public enum DialModeActionTarget: Equatable, Sendable {
    case counterclockwise
    case clockwise
    case press
}

public struct ResolvedDialModeAction: Equatable, Sendable {
    public let action: ConfiguredAction
    public let profileID: ProfileID
    public let modeID: DialModeID

    public init(action: ConfiguredAction, profileID: ProfileID, modeID: DialModeID) {
        self.action = action
        self.profileID = profileID
        self.modeID = modeID
    }
}

/// Pure profile selection and assignment resolution. This type only returns
/// configuration data; it does not synthesize input or execute actions.
public enum ProfileActionResolver {
    public static func resolve(
        bundleIdentifier: ApplicationBundleIdentifier?,
        target: ActionAssignmentTarget,
        in configuration: Configuration
    ) -> ResolvedAction {
        let selectedProfile = profile(for: bundleIdentifier, in: configuration)
        let defaultProfile = configuration.defaultProfile
        guard selectedProfile.id != defaultProfile.id else {
            return ResolvedAction(
                action: configuredAction(in: defaultProfile, for: target),
                source: .defaultProfile(profileID: defaultProfile.id)
            )
        }

        switch selectedProfile.assignments[target] ?? .inherit {
        case .set(let action):
            return ResolvedAction(
                action: action,
                source: .applicationOverride(profileID: selectedProfile.id)
            )
        case .inherit:
            return ResolvedAction(
                action: configuredAction(in: defaultProfile, for: target),
                source: .inheritedDefault(profileID: defaultProfile.id)
            )
        }
    }

    public static func resolveDialModeAction(
        bundleIdentifier: ApplicationBundleIdentifier?,
        target: DialModeActionTarget,
        in configuration: Configuration
    ) -> ResolvedDialModeAction {
        let profile = profile(for: bundleIdentifier, in: configuration)
        let mode = profile.selectedDialMode
        let action: ConfiguredAction
        switch target {
        case .counterclockwise:
            action = mode.counterclockwise
        case .clockwise:
            action = mode.clockwise
        case .press:
            action = mode.press
        }
        return ResolvedDialModeAction(action: action, profileID: profile.id, modeID: mode.id)
    }

    private static func profile(
        for bundleIdentifier: ApplicationBundleIdentifier?,
        in configuration: Configuration
    ) -> Profile {
        guard let bundleIdentifier,
              let applicationProfile = configuration.profiles.first(where: {
                  $0.scope == .application(bundleIdentifier)
              })
        else {
            return configuration.defaultProfile
        }
        return applicationProfile
    }

    private static func configuredAction(
        in profile: Profile,
        for target: ActionAssignmentTarget
    ) -> ConfiguredAction {
        guard case let .set(action)? = profile.assignments[target] else {
            return .primitive(.doNothing)
        }
        return action
    }
}
