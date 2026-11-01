import Darwin
import Foundation
import Testing
@testable import WisperCore

@Suite("One Swift app instance per user")
struct ApplicationInstanceLockTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wisper-instance-\(UUID())/instance.lock")
    }

    @Test func competingOwnersAreExcludedAndReleaseAllowsRelaunch() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try #require(try ApplicationInstanceLock.acquire(at: url))
        defer { withExtendedLifetime(first) {} }
        #expect(try ApplicationInstanceLock.acquire(at: url) == nil)
        #expect(try probeFromAnotherProcess(url) == 23)
    }

    @Test func staleFileDoesNotPreventLaunchAndNormalReleaseAllowsNextOwner() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale PID".utf8).write(to: url)
        do {
            let first = try #require(try ApplicationInstanceLock.acquire(at: url))
            withExtendedLifetime(first) {}
        }
        #expect(try probeFromAnotherProcess(url) == 0)
        #expect(try ApplicationInstanceLock.acquire(at: url) != nil)
    }

    @Test func processExitReleasesLockWithoutDeletingItsFile() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let child = Process()
        let ready = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,signal; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); signal.pause()", url.path]
        child.standardOutput = ready
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        #expect(try ready.fileHandleForReading.read(upToCount: 6) == Data("ready\n".utf8))
        #expect(try ApplicationInstanceLock.acquire(at: url) == nil)
        child.terminate()
        child.waitUntilExit()
        #expect(try ApplicationInstanceLock.acquire(at: url) != nil)
    }

    @Test func symlinkCannotRedirectTheLock() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = url.deletingLastPathComponent().appendingPathComponent("keep")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(throws: (any Error).self) { try ApplicationInstanceLock.acquire(at: url) }
        #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
    }

    private func probeFromAnotherProcess(_ url: URL) throws -> Int32 {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        probe.arguments = ["-c", "import fcntl,sys\nf=open(sys.argv[1],'a')\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(23)", url.path]
        try probe.run()
        probe.waitUntilExit()
        return probe.terminationStatus
    }
}

extension SettingsTests {
    @Test func movingTheAppRelocatesOnlyItsBundledEngineProfile() {
        let newProfile = URL(fileURLWithPath: "/Applications/Open Wisper Swift.app/Contents/Resources/engine-profile.json")
        var settings = AppSettings()
        settings.engineProfilePath = "/old/Open Wisper.app/Contents/Resources/engine-profile.json"
        settings.resolveBundledProfile(newProfile)
        #expect(settings.engineProfilePath == newProfile.path)
        settings.engineProfilePath = "/custom/manifest.json"
        settings.resolveBundledProfile(newProfile)
        #expect(settings.engineProfilePath == "/custom/manifest.json")
        settings.engineProfilePath = ""
        settings.resolveBundledProfile(newProfile)
        #expect(settings.engineProfilePath == newProfile.path)
    }
}
