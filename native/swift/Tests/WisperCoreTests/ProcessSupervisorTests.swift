import Darwin
import Foundation
import Testing
@testable import WisperCore

@Suite("Engine process supervision", .serialized)
struct ProcessSupervisorTests {
    @Test func literalArgumentsExplicitDirectoryAndEnvironment() async throws {
        let fixture = try EngineFixture(script: "#!/bin/sh\nprintf '%s\\n%s\\n%s' \"$1\" \"$PWD\" \"${HOME-unset}\"\n")
        let argument = "text ; $(touch should-not-exist) ' with spaces"
        let result = try await fixture.run(arguments: [argument])
        let lines = try #require(String(data: result.stdout, encoding: .utf8)).components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines.first == argument)
        #expect(URL(fileURLWithPath: lines[1]).standardizedFileURL == fixture.root.standardizedFileURL)
        #expect(lines.last == "unset")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("should-not-exist").path))
    }

    @Test func splitMultibyteUTF8() async throws {
        let fixture = try EngineFixture(script: "#!/bin/sh\nprintf '\\303'; /bin/sleep 0.02; printf '\\251\\n'\n")
        let result = try await fixture.run()
        #expect(String(data: result.stdout, encoding: .utf8) == "é\n")
    }

    @Test func nonzeroExitDoesNotExposeOutput() async throws {
        let fixture = try EngineFixture(script: "#!/bin/sh\nprintf 'private transcript'; printf 'private diagnostics' >&2; exit 17\n")
        await #expect(throws: EngineError.processFailed(17)) { try await fixture.run() }
        #expect(!EngineError.processFailed(17).localizedDescription.contains("private"))
    }

    @Test func timeoutEscalatesForTERMResistantWorker() async throws {
        let fixture = try EngineFixture(script: "#!/bin/sh\ntrap '' TERM\nprintf '%s' $$ > pid\nwhile :; do /bin/sleep 1; done\n")
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: EngineError.timedOut) { try await fixture.run(timeout: 2) }
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed >= .seconds(4))
        #expect(elapsed < .seconds(6))
        let pid = try #require(Int32(String(contentsOf: fixture.root.appendingPathComponent("pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func cancellationSendsTERMImmediately() async throws {
        let fixture = try EngineFixture(script: "#!/bin/sh\ntrap 'printf term > terminated; exit 0' TERM\nprintf ready > ready\nwhile :; do /bin/sleep 1; done\n")
        let task = Task { try await fixture.run(timeout: 20) }
        try await fixture.waitForFile("ready")
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("terminated").path))
    }

    @Test func cancellationBeforeSpawnRunsNothing() async throws {
        let fixture = try EngineFixture(script: "#!/bin/sh\nprintf unexpected > invoked\n")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.run()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("invoked").path))
    }

    @Test func hugeConcurrentOutputIsBounded() async throws {
        let fixture = try EngineFixture(script: """
        #!/bin/sh
        (while :; do printf '0123456789012345678901234567890123456789'; done) &
        while :; do printf 'abcdefghijklmnopqrstuvwxyz0123456789' >&2; done
        """)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: EngineError.outputLimitExceeded) { try await fixture.run(timeout: 10, limit: 4_096) }
        #expect(start.duration(to: clock.now) < .seconds(6))
    }

    @Test func grandchildCannotKeepPipesAlive() async throws {
        let fixture = try EngineFixture(script: "#!/bin/sh\n(trap '' TERM; exec /bin/sleep 30) &\nprintf '%s' $! > grandchild\nexit 0\n")
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: EngineError.supervisionFailed) { try await fixture.run(timeout: 10) }
        #expect(start.duration(to: clock.now) < .seconds(6))
        let pid = try #require(Int32(String(contentsOf: fixture.root.appendingPathComponent("grandchild"), encoding: .utf8)))
        // Give launchd a bounded opportunity to reap an adopted grandchild.
        for _ in 0..<50 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) == -1)
    }
}
