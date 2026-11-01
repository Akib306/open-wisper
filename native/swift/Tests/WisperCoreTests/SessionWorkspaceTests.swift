import Darwin
import Foundation
import Testing
@testable import WisperCore

@Suite("Private session recovery")
struct SessionWorkspaceTests {
    @Test func liveSessionsAreLockedAndNormalCleanupIsIdempotent() throws {
        let fixture = try EngineFixture()
        let workspace = try SessionWorkspace(rootURL: fixture.sessions)
        try workspace.writeAudio(Data("original synthetic audio fixture".utf8))
        #expect(try SessionWorkspace.recoverStale(rootURL: fixture.sessions, olderThan: 0) == 0)
        #expect(FileManager.default.fileExists(atPath: workspace.audioURL.path))
        try workspace.cleanup()
        try workspace.cleanup()
        #expect(try fixture.sessionsAreEmpty())
    }

    @Test func recoveryOnlyRemovesRecognizedOwnedDirectories() throws {
        let fixture = try EngineFixture()
        try FileManager.default.createDirectory(at: fixture.sessions, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func stale(extraFile: Bool = false) throws -> URL {
            let id = UUID().uuidString.lowercased()
            let directory = fixture.sessions.appendingPathComponent("session-\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let marker = directory.appendingPathComponent(".owner")
            try Data("open-wisper-swift-session-v1\n\(id)\n".utf8).write(to: marker)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            let audio = directory.appendingPathComponent("audio.wav")
            try Data("synthetic fixture".utf8).write(to: audio)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
            if extraFile { try Data("do not remove".utf8).write(to: directory.appendingPathComponent("unrecognized.txt")) }
            return directory
        }
        let owned = try stale()
        let unknownContents = try stale(extraFile: true)
        let symlink = fixture.sessions.appendingPathComponent("session-\(UUID().uuidString.lowercased())")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.root)
        #expect(try SessionWorkspace.recoverStale(rootURL: fixture.sessions, olderThan: 0) == 1)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: unknownContents.appendingPathComponent("unrecognized.txt").path))
        #expect(FileManager.default.fileExists(atPath: fixture.model.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == fixture.root.path)
    }

    @Test func cleanupDoesNotFollowAudioSymlinks() throws {
        let fixture = try EngineFixture()
        let workspace = try SessionWorkspace(rootURL: fixture.sessions)
        try FileManager.default.createSymbolicLink(at: workspace.audioURL, withDestinationURL: fixture.model)
        #expect(throws: EngineError.cleanupFailed) { try workspace.cleanup() }
        #expect(FileManager.default.fileExists(atPath: fixture.model.path))
    }
}
