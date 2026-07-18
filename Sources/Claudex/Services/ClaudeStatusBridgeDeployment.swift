import CryptoKit
import Foundation

/// Copies the signed bridge out of a potentially versioned app bundle into a stable,
/// owner-only path. Claude settings can then survive Homebrew/app bundle upgrades.
struct ClaudeStatusBridgeDeployment {
    enum DeploymentError: Error, LocalizedError, Equatable {
        case sourceMissing
        case unsafeDestination
        case sourceTooLarge
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing: return "The bundled Claude status-line helper is missing."
            case .unsafeDestination: return "The local helper path is unsafe and was left unchanged."
            case .sourceTooLarge: return "The bundled Claude status-line helper is unexpectedly large."
            case let .writeFailed(message): return "Could not install the local helper: \(message)"
            }
        }
    }

    private static let maximumBytes = 50 * 1_024 * 1_024
    private let fileManager: FileManager
    private let applicationSupportDirectory: URL

    init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let applicationSupportDirectory {
            self.applicationSupportDirectory = applicationSupportDirectory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
                    .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            self.applicationSupportDirectory = base
                .appending(path: "Claudex", directoryHint: .isDirectory)
        }
    }

    var executableURL: URL {
        applicationSupportDirectory
            .appending(path: "bin", directoryHint: .isDirectory)
            .appending(path: "ClaudexStatusBridge", directoryHint: .notDirectory)
    }

    /// The helper beside a SwiftPM development executable or nested in an assembled app.
    static var bundledExecutableURL: URL {
        let bundleCandidate = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/ClaudexStatusBridge", directoryHint: .notDirectory)
        if FileManager.default.isExecutableFile(atPath: bundleCandidate.path) {
            return bundleCandidate
        }
        if let executable = Bundle.main.executableURL {
            let sibling = executable.deletingLastPathComponent()
                .appending(path: "ClaudexStatusBridge", directoryHint: .notDirectory)
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }
        return bundleCandidate
    }

    func deploy(from source: URL) throws(DeploymentError) {
        guard fileManager.isExecutableFile(atPath: source.path),
              let sourceValues = try? source.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
              ]),
              sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true
        else { throw .sourceMissing }
        guard (sourceValues.fileSize ?? Self.maximumBytes + 1) <= Self.maximumBytes else {
            throw .sourceTooLarge
        }

        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: source, options: [.mappedIfSafe])
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        guard sourceData.count <= Self.maximumBytes else { throw .sourceTooLarge }

        let destination = executableURL
        if fileManager.fileExists(atPath: destination.path) {
            guard let values = try? destination.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? Self.maximumBytes + 1) <= Self.maximumBytes
            else { throw .unsafeDestination }
            if let current = try? Data(contentsOf: destination, options: [.mappedIfSafe]),
               SHA256.hash(data: current) == SHA256.hash(data: sourceData) {
                try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
                return
            }
        }

        do {
            try ensurePrivateDirectory(applicationSupportDirectory)
            try ensurePrivateDirectory(destination.deletingLastPathComponent())
            try sourceData.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        } catch let error as DeploymentError {
            throw error
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws(DeploymentError) {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { throw .unsafeDestination }
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw .writeFailed(error.localizedDescription)
            }
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }
}
