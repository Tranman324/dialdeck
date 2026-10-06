import Foundation
import XCTest
@testable import DialDeckCore

final class ConfigurationStoreTests: XCTestCase {
    func testApplicationInheritanceAndExplicitDoNothingRemainDistinct() throws {
        let shortcut = ConfiguredAction.primitive(.keyboardShortcut(
            KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command])
        ))
        let (configuration, defaultID, appID, _, _) = try makeConfiguration(
            defaultAssignment: .set(shortcut),
            appAssignment: .inherit
        )

        let inherited = ProfileActionResolver.resolve(
            bundleIdentifier: try bundleID(),
            target: .button1,
            in: configuration
        )
        XCTAssertEqual(inherited, ResolvedAction(
            action: shortcut,
            source: .inheritedDefault(profileID: defaultID)
        ))

        let explicitNoOpConfig = try makeConfiguration(
            defaultAssignment: .set(shortcut),
            appAssignment: .set(.primitive(.doNothing))
        ).configuration
        let explicitNoOp = ProfileActionResolver.resolve(
            bundleIdentifier: try bundleID(),
            target: .button1,
            in: explicitNoOpConfig
        )
        XCTAssertEqual(explicitNoOp, ResolvedAction(
            action: .primitive(.doNothing),
            source: .applicationOverride(profileID: appID)
        ))
    }

    func testResolverSelectsDefaultForUnknownAppAndMissingActionIsDoNothing() throws {
        let (configuration, defaultID, _, _, _) = try makeConfiguration(
            defaultAssignment: nil,
            appAssignment: .inherit
        )
        let result = ProfileActionResolver.resolve(
            bundleIdentifier: try XCTUnwrap(ApplicationBundleIdentifier("com.example.unknown")),
            target: .button2,
            in: configuration
        )
        XCTAssertEqual(result, ResolvedAction(
            action: .primitive(.doNothing),
            source: .defaultProfile(profileID: defaultID)
        ))
    }

    func testModeIdentityOrderAndRememberedSelectionSurviveRoundTrip() async throws {
        let (configuration, defaultID, _, firstModeID, secondModeID) = try makeConfiguration(
            defaultAssignment: nil,
            appAssignment: .inherit
        )
        let selected = try configuration.rememberingDialMode(secondModeID, for: defaultID)
        let reordered = try selected.reorderingDialModes(
            for: defaultID,
            orderedIDs: [secondModeID, firstModeID]
        )
        let profile = try XCTUnwrap(reordered.profile(id: defaultID))
        let renamedModes = profile.dialModes.map {
            mode(id: $0.id, name: "Renamed \($0.id.rawValue.uuidString)")
        }
        let renamedProfile = try Profile(
            id: profile.id,
            name: profile.name,
            scope: profile.scope,
            assignments: profile.assignments,
            dialModes: renamedModes,
            defaultDialModeID: profile.defaultDialModeID,
            rememberedDialModeID: profile.rememberedDialModeID
        )
        let renamedConfiguration = try reordered.replacingProfile(renamedProfile)
        let (store, files, url) = makeStore()
        try await store.save(renamedConfiguration)
        let exported = try await store.exportConfiguration()
        let reloadedStore = ConfigurationStore(primaryURL: url, fileAccess: files)
        let reloaded = try await reloadedStore.load()
        let reloadedExport = try await reloadedStore.exportConfiguration()

        XCTAssertEqual(reloaded, renamedConfiguration)
        XCTAssertEqual(reloadedExport, exported)
        XCTAssertEqual(reloaded.profile(id: defaultID)?.rememberedDialModeID, secondModeID)
        XCTAssertEqual(reloaded.profile(id: defaultID)?.dialModes.map(\.id), [secondModeID, firstModeID])
        XCTAssertEqual(
            ProfileActionResolver.resolveDialModeAction(
                bundleIdentifier: nil,
                target: .press,
                in: reloaded
            ).modeID,
            secondModeID
        )
    }

    func testDeletingRememberedModeFallsBackToDefaultAndDeletingDefaultPromotesFirstRemaining() throws {
        let (configuration, defaultID, _, firstModeID, secondModeID) = try makeConfiguration(
            defaultAssignment: nil,
            appAssignment: .inherit
        )
        let remembered = try configuration.rememberingDialMode(secondModeID, for: defaultID)
        let removedRemembered = try remembered.deletingDialMode(secondModeID, from: defaultID)
        let rememberedFallback = try XCTUnwrap(removedRemembered.profile(id: defaultID))
        XCTAssertEqual(rememberedFallback.rememberedDialModeID, firstModeID)
        XCTAssertEqual(rememberedFallback.defaultDialModeID, firstModeID)

        let removedDefault = try configuration.deletingDialMode(firstModeID, from: defaultID)
        let defaultFallback = try XCTUnwrap(removedDefault.profile(id: defaultID))
        XCTAssertEqual(defaultFallback.defaultDialModeID, secondModeID)
        XCTAssertThrowsError(try removedDefault.deletingDialMode(secondModeID, from: defaultID))
    }

    func testVersionedSaveExportAndImportRoundTrip() async throws {
        let (configuration, _, _, _, _) = try makeConfiguration(
            defaultAssignment: .set(.sequence(try ActionSequence(steps: [
                .action(.zoom(.`in`)), .pause(milliseconds: 250), .action(.nextDialMode)
            ]))),
            appAssignment: .inherit
        )
        let (store, _, _) = makeStore()
        try await store.save(configuration)
        let data = try await store.exportConfiguration()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\":1"))

        let (importStore, _, _) = makeStore()
        let imported = try await importStore.importConfiguration(data)
        XCTAssertEqual(imported, configuration)
        let loaded = try await importStore.load()
        XCTAssertEqual(loaded, configuration)
    }

    func testMalformedAndUnsupportedImportsDoNotReplaceUsableConfiguration() async throws {
        let shortcut = ConfiguredAction.primitive(.keyboardShortcut(
            KeyboardChord(key: try XCTUnwrap(MacVirtualKeyCode(8)), modifiers: [.command])
        ))
        let (configuration, _, _, _, _) = try makeConfiguration(
            defaultAssignment: .set(shortcut),
            appAssignment: .inherit
        )
        let (store, files, url) = makeStore()
        try await store.save(configuration)

        do {
            _ = try await store.importConfiguration(Data("{".utf8))
            XCTFail("Malformed JSON must be rejected")
        } catch let error as ConfigurationImportError {
            guard case .malformed = error else { return XCTFail("Expected structured malformed error") }
        }

        let encodedConfiguration = try JSONEncoder().encode(configuration)
        let parsedConfiguration = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedConfiguration) as? [String: Any]
        )
        let (invalidChordConfiguration, changedChord) = replacingFirstChordKey(in: parsedConfiguration)
        XCTAssertTrue(changedChord)
        let invalidChordDocument = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": ConfigurationStore.currentSchemaVersion,
            "configuration": invalidChordConfiguration,
        ])
        do {
            _ = try await store.importConfiguration(invalidChordDocument)
            XCTFail("Out-of-range imported chord must be rejected")
        } catch let error as ConfigurationImportError {
            guard case let .malformed(issues) = error else {
                return XCTFail("Expected structured chord validation error")
            }
            XCTAssertTrue(issues.contains { $0.code == .invalidKeyCode })
        }

        var duplicateConfiguration = parsedConfiguration
        var profiles = try XCTUnwrap(duplicateConfiguration["profiles"] as? [[String: Any]])
        var assignments = try XCTUnwrap(profiles[0]["assignments"] as? [[String: Any]])
        assignments.append(try XCTUnwrap(assignments.first))
        profiles[0]["assignments"] = assignments
        duplicateConfiguration["profiles"] = profiles
        let duplicateAssignmentDocument = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": ConfigurationStore.currentSchemaVersion,
            "configuration": duplicateConfiguration,
        ])
        do {
            _ = try await store.importConfiguration(duplicateAssignmentDocument)
            XCTFail("Duplicate imported assignments must be rejected")
        } catch let error as ConfigurationImportError {
            guard case let .malformed(issues) = error else {
                return XCTFail("Expected structured duplicate assignment error")
            }
            XCTAssertTrue(issues.contains { $0.code == .duplicateAssignment })
        }

        do {
            _ = try await store.importConfiguration(Data("{\"schemaVersion\":99}".utf8))
            XCTFail("Unsupported schema must be rejected")
        } catch let error as ConfigurationImportError {
            XCTAssertEqual(error, .unsupportedVersion(99))
        }

        let verifyStore = ConfigurationStore(primaryURL: url, fileAccess: files)
        let loaded = try await verifyStore.load()
        XCTAssertEqual(loaded, configuration)
    }

    func testInterruptedAtomicSaveRetainsLastCommittedSnapshot() async throws {
        let files = MemoryConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/configuration.json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        let (first, _, _, _, _) = try makeConfiguration(
            defaultAssignment: nil,
            appAssignment: .inherit
        )
        let (second, _, _, _, _) = try makeConfiguration(
            defaultAssignment: .set(.primitive(.zoom(.out))),
            appAssignment: .inherit
        )
        try await store.save(first)
        try await store.save(second)
        files.failNextAtomicWrite(to: url)

        do {
            try await store.save(first)
            XCTFail("Injected interruption must fail the atomic primary replacement")
        } catch let error as ConfigurationStoreError {
            XCTAssertEqual(error, .writeFailed)
        }

        let recoveredStore = ConfigurationStore(primaryURL: url, fileAccess: files)
        let recovered = try await recoveredStore.load()
        XCTAssertEqual(recovered, second)
    }

    func testCancellationAfterBackupDoesNotInstallCandidate() async throws {
        let files = MemoryConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/cancel.json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        let (first, _, _, _, _) = try makeConfiguration(
            defaultAssignment: nil,
            appAssignment: .inherit
        )
        let (candidate, _, _, _, _) = try makeConfiguration(
            defaultAssignment: .set(.primitive(.zoom(.out))),
            appAssignment: .inherit
        )
        try await store.save(first)
        files.cancelCurrentTaskOnAtomicWrite(to: url.appendingPathExtension("backup"))
        let saveTask = Task.detached {
            try await store.save(candidate)
        }

        do {
            try await saveTask.value
            XCTFail("Cancellation before primary replacement must stop the save")
        } catch is CancellationError {
            // Expected: the backup write completed, but the primary was retained.
        }

        let recoveredStore = ConfigurationStore(primaryURL: url, fileAccess: files)
        let recovered = try await recoveredStore.load()
        XCTAssertEqual(recovered, first)
    }

    func testCorruptPrimaryRecoversPreviousValidBackup() async throws {
        let files = MemoryConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/recovery.json")
        let store = ConfigurationStore(primaryURL: url, fileAccess: files)
        let (first, _, _, _, _) = try makeConfiguration(
            defaultAssignment: nil,
            appAssignment: .inherit
        )
        let (second, _, _, _, _) = try makeConfiguration(
            defaultAssignment: .set(.primitive(.zoom(.out))),
            appAssignment: .inherit
        )
        try await store.save(first)
        try await store.save(second)
        files.replaceData(Data("not-json".utf8), at: url)

        let recoveredStore = ConfigurationStore(primaryURL: url, fileAccess: files)
        let recovered = try await recoveredStore.load()
        XCTAssertEqual(recovered, first)
    }

    func testInvalidChordsAndSequencesAreRejectedAndHostBoundsAreIndependent() throws {
        XCTAssertNil(MacVirtualKeyCode(128))
        let duplicateModifierChord = Data("{\"key\":8,\"modifiers\":[\"command\",\"command\"]}".utf8)
        do {
            _ = try JSONDecoder().decode(KeyboardChord.self, from: duplicateModifierChord)
            XCTFail("Duplicate modifiers must be rejected")
        } catch let error as ConfigurationValidationError {
            XCTAssertTrue(error.issues.contains { $0.code == .invalidChord })
        }

        XCTAssertThrowsError(try ActionSequence(steps: []))
        XCTAssertThrowsError(try ActionSequence(steps: [.pause(milliseconds: 10_001)]))
        let invalidPauseDocument = Data("{\"steps\":[{\"pause\":{\"milliseconds\":0}}]}".utf8)
        do {
            _ = try JSONDecoder().decode(ActionSequence.self, from: invalidPauseDocument)
            XCTFail("Decoded out-of-range pause must be rejected")
        } catch let error as ConfigurationValidationError {
            XCTAssertTrue(error.issues.contains { $0.code == .sequenceDelayLimitExceeded })
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            ActionSequenceStep.self,
            from: Data("{\"sequence\":{}}".utf8)
        ))
        XCTAssertThrowsError(try ActionSequence(steps: Array(
            repeating: .action(.doNothing),
            count: HostSequenceSafetyLimits.maximumSteps + 1
        )))
        XCTAssertThrowsError(try ActionSequence(steps: [
            .pause(milliseconds: 10_000), .pause(milliseconds: 10_000),
            .pause(milliseconds: 10_000), .pause(milliseconds: 10_000),
            .pause(milliseconds: 10_000), .pause(milliseconds: 10_000),
            .pause(milliseconds: 1)
        ]))

        let sixHostSteps = try ActionSequence(steps: Array(
            repeating: .action(.doNothing), count: 6
        ))
        XCTAssertEqual(sixHostSteps.steps.count, 6)
    }

    private func makeConfiguration(
        defaultAssignment: ActionOverride?,
        appAssignment: ActionOverride,
        rememberedMode: DialModeID? = nil
    ) throws -> (configuration: Configuration, defaultID: ProfileID, appID: ProfileID, firstModeID: DialModeID, secondModeID: DialModeID) {
        let defaultID = ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let appID = ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let firstModeID = DialModeID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
        let secondModeID = DialModeID(UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
        let appModeID = DialModeID(UUID(uuidString: "00000000-0000-0000-0000-000000000013")!)
        let name = try XCTUnwrap(DisplayName("Default"))
        let defaultAssignments: [ActionAssignmentTarget: ActionOverride] = defaultAssignment.map {
            [.button1: $0]
        } ?? [:]
        let defaultProfile = try Profile(
            id: defaultID,
            name: name,
            scope: .default,
            assignments: defaultAssignments,
            dialModes: [
                mode(id: firstModeID, name: "Mode A"),
                mode(id: secondModeID, name: "Mode B"),
            ],
            defaultDialModeID: firstModeID,
            rememberedDialModeID: rememberedMode
        )
        let appProfile = try Profile(
            id: appID,
            name: try XCTUnwrap(DisplayName("Target")),
            scope: .application(try bundleID()),
            assignments: [.button1: appAssignment],
            dialModes: [mode(id: appModeID, name: "App mode")],
            defaultDialModeID: appModeID
        )
        let config = try Configuration(defaultProfileID: defaultID, profiles: [defaultProfile, appProfile])
        return (config, defaultID, appID, firstModeID, secondModeID)
    }

    private func mode(id: DialModeID, name: String) -> DialMode {
        DialMode(
            id: id,
            name: DisplayName(name)!,
            counterclockwise: .primitive(.doNothing),
            clockwise: .primitive(.doNothing),
            press: .primitive(.doNothing)
        )
    }

    private func bundleID() throws -> ApplicationBundleIdentifier {
        try XCTUnwrap(ApplicationBundleIdentifier("com.example.target"))
    }

    private func makeStore() -> (ConfigurationStore, MemoryConfigurationFiles, URL) {
        let files = MemoryConfigurationFiles()
        let url = URL(fileURLWithPath: "/virtual/\(UUID().uuidString).json")
        return (ConfigurationStore(primaryURL: url, fileAccess: files), files, url)
    }

    private func replacingFirstChordKey(in value: Any) -> (Any, Bool) {
        if var object = value as? [String: Any] {
            if object["key"] != nil, object["modifiers"] != nil {
                object["key"] = 128
                return (object, true)
            }
            for key in Array(object.keys) {
                guard let child = object[key] else { continue }
                let (replacement, changed) = replacingFirstChordKey(in: child)
                if changed {
                    object[key] = replacement
                    return (object, true)
                }
            }
            return (object, false)
        }
        if let array = value as? [Any] {
            var replacement = array
            for index in replacement.indices {
                let (item, changed) = replacingFirstChordKey(in: replacement[index])
                if changed {
                    replacement[index] = item
                    return (replacement, true)
                }
            }
            return (replacement, false)
        }
        return (value, false)
    }

}

private enum MemoryFileFailure: Error {
    case interrupted
}

private final class MemoryConfigurationFiles: ConfigurationFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var failingWritePath: String?
    private var cancellingWritePath: String?

    func exists(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return files[url.path] != nil
    }

    func read(from url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data = files[url.path] else { throw MemoryFileFailure.interrupted }
        return data
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if failingWritePath == url.path {
            failingWritePath = nil
            throw MemoryFileFailure.interrupted
        }
        files[url.path] = data
        if cancellingWritePath == url.path {
            cancellingWritePath = nil
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func failNextAtomicWrite(to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        failingWritePath = url.path
    }

    func cancelCurrentTaskOnAtomicWrite(to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        cancellingWritePath = url.path
    }

    func replaceData(_ data: Data, at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        files[url.path] = data
    }
}
