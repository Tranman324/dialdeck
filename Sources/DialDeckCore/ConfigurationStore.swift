import Foundation

public enum ConfigurationImportError: Error, Equatable, Sendable {
    case tooLarge
    case malformed([ConfigurationIssue])
    case unsupportedVersion(Int)
}

public enum ConfigurationStoreError: Error, Equatable, Sendable {
    case notFound
    case readFailed
    case writeFailed
    case malformed([ConfigurationIssue])
    case unsupportedVersion(Int)
    case tooLarge
}

/// Synchronous file access used only from the store actor. Implementations must
/// make a failed atomic write leave the destination unchanged.
public protocol ConfigurationFileAccess: Sendable {
    func exists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
}

public struct LocalConfigurationFileAccess: ConfigurationFileAccess {
    public init() {}

    public func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }
}

/// Versioned JSON persistence with a previous-valid snapshot for recovery.
/// The actor serializes file transactions; consumers await public operations
/// instead of doing blocking file work on the UI actor.
public actor ConfigurationStore {
    public static let currentSchemaVersion = 1

    private struct Envelope: Codable {
        let schemaVersion: Int
        let configuration: Configuration
    }

    private struct VersionHeader: Decodable {
        let schemaVersion: Int
    }

    private struct Snapshot {
        let configuration: Configuration
        let data: Data
    }

    private let fileAccess: any ConfigurationFileAccess
    private let primaryURL: URL
    private let backupURL: URL
    private var cachedConfiguration: Configuration?

    public init(
        primaryURL: URL,
        fileAccess: any ConfigurationFileAccess = LocalConfigurationFileAccess()
    ) {
        self.primaryURL = primaryURL
        self.backupURL = primaryURL.appendingPathExtension("backup")
        self.fileAccess = fileAccess
    }

    public func load() throws -> Configuration {
        if let cachedConfiguration {
            return cachedConfiguration
        }
        let snapshot = try readBestSnapshot()
        cachedConfiguration = snapshot.configuration
        return snapshot.configuration
    }

    public func save(_ configuration: Configuration) throws {
        let candidateData = try Self.encode(configuration)
        try Task.checkCancellation()
        let previous: Snapshot?
        if let cachedConfiguration {
            previous = Snapshot(
                configuration: cachedConfiguration,
                data: try Self.encode(cachedConfiguration)
            )
        } else {
            do {
                previous = try readBestSnapshot()
            } catch ConfigurationStoreError.notFound {
                previous = nil
            } catch ConfigurationStoreError.malformed {
                previous = nil
            }
        }

        if let previous {
            do {
                try fileAccess.writeAtomically(previous.data, to: backupURL)
            } catch {
                throw ConfigurationStoreError.writeFailed
            }
        }
        // If cancellation arrived during the backup write, the current primary
        // remains the committed snapshot and the candidate is not installed.
        try Task.checkCancellation()

        do {
            try fileAccess.writeAtomically(candidateData, to: primaryURL)
        } catch {
            if let previous { cachedConfiguration = previous.configuration }
            throw ConfigurationStoreError.writeFailed
        }
        cachedConfiguration = configuration
    }

    /// Validates the complete import before changing disk or cached state.
    @discardableResult
    public func importConfiguration(_ data: Data) throws -> Configuration {
        let configuration: Configuration
        do {
            configuration = try Self.decode(data)
        } catch let error as ConfigurationImportError {
            throw error
        }
        try save(configuration)
        return configuration
    }

    public func exportConfiguration() throws -> Data {
        let configuration = try load()
        return try Self.encode(configuration)
    }

    private func readBestSnapshot() throws -> Snapshot {
        var foundFile = false
        var malformedIssues: [ConfigurationIssue] = []
        for url in [primaryURL, backupURL] where fileAccess.exists(at: url) {
            foundFile = true
            let data: Data
            do {
                data = try fileAccess.read(from: url)
            } catch {
                continue
            }
            do {
                return Snapshot(configuration: try Self.decode(data), data: data)
            } catch ConfigurationImportError.unsupportedVersion(let version) {
                // Never silently downgrade a future schema from a backup.
                throw ConfigurationStoreError.unsupportedVersion(version)
            } catch ConfigurationImportError.malformed(let issues) {
                malformedIssues.append(contentsOf: issues)
            } catch ConfigurationImportError.tooLarge {
                malformedIssues.append(.init(code: .malformedDocument, path: "document.size"))
            } catch {
                malformedIssues.append(.init(code: .malformedDocument, path: "document"))
            }
        }
        if !malformedIssues.isEmpty {
            throw ConfigurationStoreError.malformed(malformedIssues)
        }
        if foundFile {
            throw ConfigurationStoreError.readFailed
        }
        throw ConfigurationStoreError.notFound
    }

    private static func encode(_ configuration: Configuration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(Envelope(
                schemaVersion: currentSchemaVersion,
                configuration: configuration
            ))
            guard data.count <= HostSequenceSafetyLimits.maximumImportBytes else {
                throw ConfigurationStoreError.tooLarge
            }
            return data
        } catch let error as ConfigurationStoreError {
            throw error
        } catch {
            throw ConfigurationStoreError.malformed([
                .init(code: .malformedDocument, path: "document")
            ])
        }
    }

    private static func decode(_ data: Data) throws -> Configuration {
        guard data.count <= HostSequenceSafetyLimits.maximumImportBytes else {
            throw ConfigurationImportError.tooLarge
        }
        do {
            let header = try JSONDecoder().decode(VersionHeader.self, from: data)
            guard header.schemaVersion == currentSchemaVersion else {
                throw ConfigurationImportError.unsupportedVersion(header.schemaVersion)
            }
            return try JSONDecoder().decode(Envelope.self, from: data).configuration
        } catch let error as ConfigurationImportError {
            throw error
        } catch let error as ConfigurationValidationError {
            throw ConfigurationImportError.malformed(error.issues)
        } catch let error as DecodingError {
            throw ConfigurationImportError.malformed([.init(
                code: .malformedDocument,
                path: Self.path(for: error)
            )])
        } catch {
            throw ConfigurationImportError.malformed([.init(
                code: .malformedDocument,
                path: "document"
            )])
        }
    }

    private static func path(for error: DecodingError) -> String {
        let codingPath: [CodingKey]
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .keyNotFound(_, let context), .dataCorrupted(let context):
            codingPath = context.codingPath
        @unknown default:
            codingPath = []
        }
        return codingPath.map(\.stringValue).joined(separator: ".")
    }
}
