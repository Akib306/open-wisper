import Foundation
import Testing
@testable import WisperCore

@Suite("Engine profiles and transcription")
struct EngineManifestTests {
    @Test func publicLoadAndHashValidation() throws {
        let fixture = try EngineFixture()
        let manifest = try EngineManifest.load(from: fixture.profile)
        let validated = try EngineManifest.loadValidated(from: fixture.profile)
        #expect(validated.manifest == manifest)
        #expect(validated.executableURL == fixture.executable)
        #expect(validated.modelURL == fixture.model)
    }

    @Test func artifactMismatchAndMissingModel() throws {
        let fixture = try EngineFixture()
        try Data("changed weights".utf8).write(to: fixture.model)
        #expect(throws: EngineError.integrityMismatch) { try EngineManifest.loadValidated(from: fixture.profile) }
        try FileManager.default.removeItem(at: fixture.model)
        #expect(throws: EngineError.artifactUnavailable) { try EngineManifest.loadValidated(from: fixture.profile) }
    }

    @Test func invalidManifestsAreRejected() throws {
        let fixture = try EngineFixture()
        let cases: [(String, Any)] = [
            ("schemaVersion", 2), ("threads", 0), ("threads", 65), ("threads", "4"),
            ("residency", "resident"), ("sourceCommit", String(repeating: "a", count: 40)),
            ("language", "auto"), ("architecture", "mips"), ("unexpected", true),
            ("decodeArguments", ["--output-file", "/tmp/transcript"]), ("buildFlags", [])
        ]
        for (key, value) in cases {
            try fixture.writeManifest { $0[key] = value }
            #expect(throws: EngineError.invalidManifest) { try EngineManifest.load(from: fixture.profile) }
        }
        try fixture.writeManifest { $0.removeValue(forKey: "provenance") }
        #expect(throws: EngineError.invalidManifest) { try EngineManifest.load(from: fixture.profile) }
        try fixture.writeManifest {
            var model = $0["model"] as! [String: Any]
            model["license"] = ""
            $0["model"] = model
        }
        #expect(throws: EngineError.invalidManifest) { try EngineManifest.load(from: fixture.profile) }
        try Data(repeating: 32, count: 65_537).write(to: fixture.profile)
        #expect(throws: EngineError.invalidManifest) { try EngineManifest.load(from: fixture.profile) }
    }

    @Test func artifactSymlinksAreRejected() throws {
        let fixture = try EngineFixture()
        let alias = fixture.root.appendingPathComponent("alias.bin")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.model)
        try fixture.writeManifest {
            var model = $0["model"] as! [String: Any]
            model["path"] = alias.path
            $0["model"] = model
        }
        #expect(throws: EngineError.artifactUnavailable) { try EngineManifest.loadValidated(from: fixture.profile) }
    }

    @Test func transcriptOnlyFlagsAndPathsWithSpaces() async throws {
        let fixture = try EngineFixture(script: """
        #!/bin/sh
        set -eu
        prints=0; timestamps=0; audio=''; model=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --no-prints) prints=1;; --no-timestamps) timestamps=1;;
            --file) shift; audio="$1";; --model) shift; model="$1";;
          esac
          shift
        done
        [ "$prints" = 1 ] && [ "$timestamps" = 1 ] && [ -f "$audio" ] && [ -f "$model" ] || exit 8
        [ "$(/usr/bin/stat -f %Lp "$audio")" = 600 ] || exit 9
        [ "$(/usr/bin/stat -f %Lp "$PWD")" = 700 ] || exit 10
        printf '  café 世界\\n'
        """)
        let result = try await fixture.transcribe()
        #expect(result.text == "café 世界")
        #expect(result.elapsed >= 0)
        #expect(try #require(result.peakResidentBytes) > 0)
        #expect(try fixture.sessionsAreEmpty())
    }

    @Test func invalidUTF8CleansWorkspace() async throws {
        let fixture = try EngineFixture(script: "#!/bin/sh\nprintf '\\377'\n")
        await #expect(throws: EngineError.invalidOutput) { try await fixture.transcribe() }
        #expect(try fixture.sessionsAreEmpty())
    }

    @Test func failureAndTimeoutCleanWorkspaces() async throws {
        let failure = try EngineFixture(script: "#!/bin/sh\nexit 5\n")
        await #expect(throws: EngineError.processFailed(5)) { try await failure.transcribe() }
        #expect(try failure.sessionsAreEmpty())
        let timeout = try EngineFixture(script: "#!/bin/sh\nexec /bin/sleep 20\n")
        await #expect(throws: EngineError.timedOut) { try await timeout.transcribe(timeout: 0.05) }
        #expect(try timeout.sessionsAreEmpty())
        let launch = try EngineFixture(script: "not an executable file")
        await #expect(throws: EngineError.launchFailed) { try await launch.transcribe() }
        #expect(try launch.sessionsAreEmpty())
    }

    @Test func cancellationCleansWorkspace() async throws {
        let fixture = try EngineFixture(script: "#!/bin/sh\nexec /bin/sleep 20\n")
        let task = Task { try await fixture.transcribe(timeout: 20) }
        for _ in 0..<100 {
            if !(try fixture.sessionsAreEmpty()) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!(try fixture.sessionsAreEmpty()))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.sessionsAreEmpty())
    }

    @Test func corruptAudioNeverStartsWorker() async throws {
        let fixture = try EngineFixture()
        let invalid = RecordedAudio(wavData: Data("bad wav".utf8), duration: 0.1)
        await #expect(throws: EngineError.invalidAudio) {
            try await WhisperTranscriber().transcribe(audio: invalid, profileURL: fixture.profile, timeout: 1, workspaceRoot: fixture.sessions)
        }
        #expect(try fixture.sessionsAreEmpty())
    }
}
