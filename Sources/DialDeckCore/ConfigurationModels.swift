import Foundation

public enum ConfigurationIssueCode: String, Codable, Equatable, Sendable {
    case malformedDocument
    case invalidName
    case invalidBundleIdentifier
    case invalidChord
    case invalidKeyCode
    case invalidScrollSpeed
    case invalidSequence
    case sequenceStepLimitExceeded
    case sequenceDelayLimitExceeded
    case invalidProfileSet
    case invalidDefaultProfile
    case invalidInheritance
    case invalidDialModes
    case invalidModeReference
    case invalidProfileReference
    case duplicateAssignment
}

public struct ConfigurationIssue: Codable, Equatable, Sendable {
    public let code: ConfigurationIssueCode
    public let path: String

    public init(code: ConfigurationIssueCode, path: String) {
        self.code = code
        self.path = path
    }
}

public struct ConfigurationValidationError: Error, Equatable, Sendable {
    public let issues: [ConfigurationIssue]

    public init(_ issues: [ConfigurationIssue]) {
        self.issues = issues
    }
}

/// App-side sequence limits. These bound saved host actions and are independent
/// of any device encoder's serialization format or firmware capacity.
public enum HostSequenceSafetyLimits {
    public static let maximumSteps = 32
    public static let maximumPauseMilliseconds: UInt32 = 10_000
    /// Sum of explicit waits in one configured sequence. Primitive actions are
    /// descriptors only; their eventual executor must enforce its own timeout.
    public static let maximumTotalDurationMilliseconds: UInt64 = 60_000
    public static let maximumImportBytes = 1_048_576
    public static let maximumProfiles = 128
    public static let maximumDialModesPerProfile = 32
}

/// Stable identity for a user profile; names and list positions may change.
public struct ProfileID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Stable identity for a dial mode; display names and ordering are separate.
public struct DialModeID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct DisplayName: Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        rawValue = trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let name = Self(value) else {
            throw ConfigurationValidationError([.init(code: .invalidName, path: decoder.codingPath.map(\.stringValue).joined(separator: "."))])
        }
        self = name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Validated reverse-DNS application identity. Localized application names are
/// deliberately not used for profile matching.
public struct ApplicationBundleIdentifier: Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy { character in
                      character.isASCII && (character.isLetter || character.isNumber || character == "-")
                  } && part.first != "-" && part.last != "-"
              })
        else { return nil }
        rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = Self(value) else {
            throw ConfigurationValidationError([.init(code: .invalidBundleIdentifier, path: decoder.codingPath.map(\.stringValue).joined(separator: "."))])
        }
        self = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AppleShortcutName: Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255 else { return nil }
        rawValue = trimmed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let name = Self(value) else {
            throw ConfigurationValidationError([.init(code: .invalidName, path: decoder.codingPath.map(\.stringValue).joined(separator: "."))])
        }
        self = name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// macOS virtual key code with a bounded value before it can enter a chord.
public struct MacVirtualKeyCode: Codable, Hashable, Sendable {
    public static let maximumDefinedValue: UInt16 = 127
    public let rawValue: UInt16

    public init?(_ rawValue: UInt16) {
        guard rawValue <= Self.maximumDefinedValue else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt16.self)
        guard let code = Self(value) else {
            throw ConfigurationValidationError([.init(code: .invalidKeyCode, path: decoder.codingPath.map(\.stringValue).joined(separator: "."))])
        }
        self = code
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum KeyboardModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case command
    case shift
    case option
    case control
    case function
}

public struct KeyboardChord: Codable, Equatable, Sendable {
    public let key: MacVirtualKeyCode
    public let modifiers: Set<KeyboardModifier>

    public init(key: MacVirtualKeyCode, modifiers: Set<KeyboardModifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(MacVirtualKeyCode.self, forKey: .key)
        let rawModifiers = try container.decode([KeyboardModifier].self, forKey: .modifiers)
        guard Set(rawModifiers).count == rawModifiers.count else {
            throw ConfigurationValidationError([.init(code: .invalidChord, path: "modifiers")])
        }
        self.init(key: key, modifiers: Set(rawModifiers))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers.sorted { $0.rawValue < $1.rawValue }, forKey: .modifiers)
    }
}

public struct ScrollSpeed: Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init?(_ rawValue: UInt8) {
        guard (1...10).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt8.self)
        guard let speed = Self(value) else {
            throw ConfigurationValidationError([.init(code: .invalidScrollSpeed, path: decoder.codingPath.map(\.stringValue).joined(separator: "."))])
        }
        self = speed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ScrollAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum ZoomDirection: String, Codable, Equatable, Sendable {
    case `in`
    case out
}

/// Leaf actions allowed both as direct assignments and as sequence entries.
/// The type intentionally has no sequence reference, so recursive/cyclic
/// sequence graphs cannot be represented.
public enum PrimitiveAction: Codable, Equatable, Sendable {
    case doNothing
    case keyboardShortcut(KeyboardChord)
    case holdKeys(KeyboardChord)
    case openApplication(ApplicationBundleIdentifier)
    case runAppleShortcut(AppleShortcutName)
    case clipboardManagerShortcut(KeyboardChord)
    case scroll(axis: ScrollAxis, speed: ScrollSpeed)
    case zoom(ZoomDirection)
    case nextDialMode
}

public enum ActionSequenceStep: Codable, Equatable, Sendable {
    case action(PrimitiveAction)
    case pause(milliseconds: UInt32)
}

public struct ActionSequence: Codable, Equatable, Sendable {
    public let steps: [ActionSequenceStep]

    public init(steps: [ActionSequenceStep]) throws {
        let issues = Self.validate(steps)
        guard issues.isEmpty else { throw ConfigurationValidationError(issues) }
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case steps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(steps: container.decode([ActionSequenceStep].self, forKey: .steps))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steps, forKey: .steps)
    }

    private static func validate(_ steps: [ActionSequenceStep]) -> [ConfigurationIssue] {
        guard !steps.isEmpty, steps.count <= HostSequenceSafetyLimits.maximumSteps else {
            return [.init(code: .sequenceStepLimitExceeded, path: "steps")]
        }
        var totalPause: UInt64 = 0
        var issues: [ConfigurationIssue] = []
        for (index, step) in steps.enumerated() {
            guard case let .pause(milliseconds) = step else { continue }
            let path = "steps[\(index)].pause"
            guard milliseconds > 0,
                  milliseconds <= HostSequenceSafetyLimits.maximumPauseMilliseconds
            else {
                issues.append(.init(code: .sequenceDelayLimitExceeded, path: path))
                continue
            }
            totalPause += UInt64(milliseconds)
            if totalPause > HostSequenceSafetyLimits.maximumTotalDurationMilliseconds {
                issues.append(.init(code: .sequenceDelayLimitExceeded, path: path))
            }
        }
        return issues
    }
}

public enum ConfiguredAction: Codable, Equatable, Sendable {
    case primitive(PrimitiveAction)
    case sequence(ActionSequence)
}

public enum ActionAssignmentTarget: String, Codable, CaseIterable, Hashable, Sendable {
    case button1
    case button2
    case button3
    case button4
    case button5
    case button6
}

public enum ActionOverride: Codable, Equatable, Sendable {
    case inherit
    case set(ConfiguredAction)
}

public enum ProfileScope: Codable, Equatable, Sendable {
    case `default`
    case application(ApplicationBundleIdentifier)
}

public struct DialMode: Codable, Equatable, Sendable {
    public let id: DialModeID
    public let name: DisplayName
    public let counterclockwise: ConfiguredAction
    public let clockwise: ConfiguredAction
    public let press: ConfiguredAction

    public init(
        id: DialModeID = DialModeID(),
        name: DisplayName,
        counterclockwise: ConfiguredAction,
        clockwise: ConfiguredAction,
        press: ConfiguredAction
    ) {
        self.id = id
        self.name = name
        self.counterclockwise = counterclockwise
        self.clockwise = clockwise
        self.press = press
    }
}

public struct Profile: Codable, Equatable, Sendable {
    public let id: ProfileID
    public let name: DisplayName
    public let scope: ProfileScope
    public let assignments: [ActionAssignmentTarget: ActionOverride]
    /// Array position defines display order; each mode's UUID remains stable.
    public let dialModes: [DialMode]
    public let defaultDialModeID: DialModeID
    public let rememberedDialModeID: DialModeID?

    /// The persisted selection is already validated against the mode list.
    /// Until the user selects a mode, the profile's default is active.
    public var selectedDialMode: DialMode {
        let selectedID = rememberedDialModeID ?? defaultDialModeID
        return dialModes.first { $0.id == selectedID }!
    }

    public init(
        id: ProfileID = ProfileID(),
        name: DisplayName,
        scope: ProfileScope,
        assignments: [ActionAssignmentTarget: ActionOverride] = [:],
        dialModes: [DialMode],
        defaultDialModeID: DialModeID,
        rememberedDialModeID: DialModeID? = nil
    ) throws {
        let issues = Self.validate(
            assignments: assignments,
            dialModes: dialModes,
            defaultDialModeID: defaultDialModeID,
            rememberedDialModeID: rememberedDialModeID
        )
        guard issues.isEmpty else { throw ConfigurationValidationError(issues) }
        self.id = id
        self.name = name
        self.scope = scope
        self.assignments = assignments
        self.dialModes = dialModes
        self.defaultDialModeID = defaultDialModeID
        self.rememberedDialModeID = rememberedDialModeID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case scope
        case assignments
        case dialModes
        case defaultDialModeID
        case rememberedDialModeID
    }

    private struct AssignmentEntry: Codable {
        let target: ActionAssignmentTarget
        let override: ActionOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let assignmentEntries = try container.decode([AssignmentEntry].self, forKey: .assignments)
        guard Set(assignmentEntries.map(\.target)).count == assignmentEntries.count else {
            throw ConfigurationValidationError([.init(
                code: .duplicateAssignment,
                path: decoder.codingPath.map(\.stringValue).joined(separator: ".") + ".assignments"
            )])
        }
        try self.init(
            id: container.decode(ProfileID.self, forKey: .id),
            name: container.decode(DisplayName.self, forKey: .name),
            scope: container.decode(ProfileScope.self, forKey: .scope),
            assignments: Dictionary(uniqueKeysWithValues: assignmentEntries.map { ($0.target, $0.override) }),
            dialModes: container.decode([DialMode].self, forKey: .dialModes),
            defaultDialModeID: container.decode(DialModeID.self, forKey: .defaultDialModeID),
            rememberedDialModeID: container.decodeIfPresent(DialModeID.self, forKey: .rememberedDialModeID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(scope, forKey: .scope)
        let assignmentEntries = assignments.map { AssignmentEntry(target: $0.key, override: $0.value) }
            .sorted { $0.target.rawValue < $1.target.rawValue }
        try container.encode(assignmentEntries, forKey: .assignments)
        try container.encode(dialModes, forKey: .dialModes)
        try container.encode(defaultDialModeID, forKey: .defaultDialModeID)
        try container.encodeIfPresent(rememberedDialModeID, forKey: .rememberedDialModeID)
    }

    private static func validate(
        assignments: [ActionAssignmentTarget: ActionOverride],
        dialModes: [DialMode],
        defaultDialModeID: DialModeID,
        rememberedDialModeID: DialModeID?
    ) -> [ConfigurationIssue] {
        guard !dialModes.isEmpty,
              dialModes.count <= HostSequenceSafetyLimits.maximumDialModesPerProfile
        else {
            return [.init(code: .invalidDialModes, path: "dialModes")]
        }
        let ids = dialModes.map(\.id)
        guard Set(ids).count == ids.count,
              ids.contains(defaultDialModeID),
              rememberedDialModeID.map(ids.contains) ?? true
        else {
            return [.init(code: .invalidModeReference, path: "dialModes")]
        }
        return []
    }
}

public struct Configuration: Codable, Equatable, Sendable {
    public let defaultProfileID: ProfileID
    public let profiles: [Profile]

    public init(defaultProfileID: ProfileID, profiles: [Profile]) throws {
        let issues = Self.validate(defaultProfileID: defaultProfileID, profiles: profiles)
        guard issues.isEmpty else { throw ConfigurationValidationError(issues) }
        self.defaultProfileID = defaultProfileID
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey {
        case defaultProfileID
        case profiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            defaultProfileID: container.decode(ProfileID.self, forKey: .defaultProfileID),
            profiles: container.decode([Profile].self, forKey: .profiles)
        )
    }

    public var defaultProfile: Profile {
        profiles.first { $0.id == defaultProfileID }!
    }

    public func profile(id: ProfileID) -> Profile? {
        profiles.first { $0.id == id }
    }

    public func replacingProfile(_ profile: Profile) throws -> Configuration {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ConfigurationValidationError([.init(code: .invalidProfileReference, path: "profiles")])
        }
        var updated = profiles
        updated[index] = profile
        return try Configuration(defaultProfileID: defaultProfileID, profiles: updated)
    }

    public func rememberingDialMode(_ modeID: DialModeID, for profileID: ProfileID) throws -> Configuration {
        guard let profile = profile(id: profileID), profile.dialModes.contains(where: { $0.id == modeID }) else {
            throw ConfigurationValidationError([.init(code: .invalidModeReference, path: "rememberedDialModeID")])
        }
        let updated = try Profile(
            id: profile.id,
            name: profile.name,
            scope: profile.scope,
            assignments: profile.assignments,
            dialModes: profile.dialModes,
            defaultDialModeID: profile.defaultDialModeID,
            rememberedDialModeID: modeID
        )
        return try replacingProfile(updated)
    }

    public func reorderingDialModes(for profileID: ProfileID, orderedIDs: [DialModeID]) throws -> Configuration {
        guard let profile = profile(id: profileID),
              orderedIDs.count == profile.dialModes.count,
              Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(profile.dialModes.map(\.id))
        else {
            throw ConfigurationValidationError([.init(code: .invalidModeReference, path: "dialModes.order")])
        }
        let byID = Dictionary(uniqueKeysWithValues: profile.dialModes.map { ($0.id, $0) })
        let orderedModes = orderedIDs.compactMap { byID[$0] }
        let updated = try Profile(
            id: profile.id,
            name: profile.name,
            scope: profile.scope,
            assignments: profile.assignments,
            dialModes: orderedModes,
            defaultDialModeID: profile.defaultDialModeID,
            rememberedDialModeID: profile.rememberedDialModeID
        )
        return try replacingProfile(updated)
    }

    public func deletingDialMode(_ modeID: DialModeID, from profileID: ProfileID) throws -> Configuration {
        guard let profile = profile(id: profileID),
              let deletedIndex = profile.dialModes.firstIndex(where: { $0.id == modeID })
        else {
            throw ConfigurationValidationError([.init(code: .invalidModeReference, path: "dialModes")])
        }
        guard profile.dialModes.count > 1 else {
            throw ConfigurationValidationError([.init(code: .invalidDialModes, path: "dialModes.lastMode")])
        }
        var remainingModes = profile.dialModes
        remainingModes.remove(at: deletedIndex)
        let fallbackDefault = remainingModes[0].id
        let newDefault = profile.defaultDialModeID == modeID ? fallbackDefault : profile.defaultDialModeID
        let newRemembered = profile.rememberedDialModeID == modeID ? newDefault : profile.rememberedDialModeID
        let updated = try Profile(
            id: profile.id,
            name: profile.name,
            scope: profile.scope,
            assignments: profile.assignments,
            dialModes: remainingModes,
            defaultDialModeID: newDefault,
            rememberedDialModeID: newRemembered
        )
        return try replacingProfile(updated)
    }

    private static func validate(defaultProfileID: ProfileID, profiles: [Profile]) -> [ConfigurationIssue] {
        guard !profiles.isEmpty,
              profiles.count <= HostSequenceSafetyLimits.maximumProfiles,
              Set(profiles.map(\.id)).count == profiles.count
        else {
            return [.init(code: .invalidProfileSet, path: "profiles")]
        }
        let defaults = profiles.filter { $0.scope == .default }
        guard defaults.count == 1, defaults[0].id == defaultProfileID else {
            return [.init(code: .invalidDefaultProfile, path: "defaultProfileID")]
        }
        let appIDs = profiles.compactMap { profile -> ApplicationBundleIdentifier? in
            guard case let .application(identifier) = profile.scope else { return nil }
            return identifier
        }
        guard Set(appIDs).count == appIDs.count else {
            return [.init(code: .invalidProfileSet, path: "profiles.scope")]
        }
        guard !defaults[0].assignments.values.contains(.inherit) else {
            return [.init(code: .invalidInheritance, path: "profiles.default.assignments")]
        }
        return []
    }
}
