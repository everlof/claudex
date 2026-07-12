import Foundation
import Testing
@testable import Claudex

@Suite struct ClaudeStatusBridgeDeploymentTests {
    @Test func deploysAndUpdatesAtAStableOwnerOnlyPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "claudex-deploy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "BundledBridge")
        try writeExecutable("first", to: source)
        let support = root.appending(path: "Support", directoryHint: .isDirectory)
        let deployment = ClaudeStatusBridgeDeployment(applicationSupportDirectory: support)

        try deployment.deploy(from: source)
        #expect(try String(contentsOf: deployment.executableURL, encoding: .utf8) == "first")
        let permissions = try #require(
            try FileManager.default.attributesOfItem(
                atPath: deployment.executableURL.path
            )[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o700)

        try writeExecutable("second", to: source)
        try deployment.deploy(from: source)
        #expect(try String(contentsOf: deployment.executableURL, encoding: .utf8) == "second")
    }

    @Test func refusesASymlinkDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "claudex-deploy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "Support", directoryHint: .isDirectory)
        let bin = support.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let source = root.appending(path: "BundledBridge")
        let target = root.appending(path: "target")
        try writeExecutable("source", to: source)
        try writeExecutable("target", to: target)
        try FileManager.default.createSymbolicLink(
            at: bin.appending(path: "ClaudexStatusBridge"),
            withDestinationURL: target
        )
        let deployment = ClaudeStatusBridgeDeployment(applicationSupportDirectory: support)

        #expect(throws: ClaudeStatusBridgeDeployment.DeploymentError.unsafeDestination) {
            try deployment.deploy(from: source)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "target")
    }

    private func writeExecutable(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
