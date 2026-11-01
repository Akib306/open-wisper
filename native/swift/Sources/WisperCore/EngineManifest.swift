import CryptoKit
import Darwin
import Foundation

/// Content-free failures: subprocess output, audio, and user paths never appear here.
public enum EngineError: Error, LocalizedError, Sendable, Equatable {
    case invalidManifest
    case unsupportedProfile
    case artifactUnavailable
    case integrityMismatch
    case invalidAudio
    case invalidTimeout
    case workspaceUnavailable
    case cleanupFailed
    case launchFailed
    case timedOut
    case outputLimitExceeded
    case invalidOutput
    case processFailed(Int32)
    case processSignalled(Int32)
    case supervisionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "The engine profile is invalid."
        case .unsupportedProfile: "This engine profile is not supported on this computer."
        case .artifactUnavailable: "An engine artifact is missing, unsafe, or unreadable."
        case .integrityMismatch: "An engine artifact does not match its recorded SHA-256."
        case .invalidAudio: "The recording is not a supported bounded PCM WAV."
        case .invalidTimeout: "The inference timeout must be between zero and one hour."
        case .workspaceUnavailable: "A private inference workspace could not be created or written."
        case .cleanupFailed: "An inference workspace could not be safely removed."
        case .launchFailed: "The local inference worker could not start."
        case .timedOut: "Local inference exceeded its time limit."
        case .outputLimitExceeded: "The local inference worker exceeded its output limit."
        case .invalidOutput: "The local inference worker returned invalid text."
        case .processFailed(let code): "The local inference worker exited with code \(code)."
        case .processSignalled(let signal): "The local inference worker stopped with signal \(signal)."
        case .supervisionFailed: "The local inference worker could not be supervised safely."
        }
    }
}

/// Version 1 is deliberately a single reproducible English, CPU, short-lived profile.
/// See tools/engine/README.md for the complete required JSON schema and provenance limits.
public struct EngineManifest: Codable, Sendable, Equatable {
    public struct Artifact: Codable, Sendable, Equatable {
        public let path: String
        public let sha256: String
    }

    public struct Model: Codable, Sendable, Equatable {
        public let path: String
        public let sha256: String
        public let name: String
        public let license: String
        public let licenseURL: String
    }

    public struct Provenance: Codable, Sendable, Equatable {
        public let kind: String
        public let evidence: [String: String]
        public let limitations: String
    }

    public static let pinnedCommit = "a91dd3be72f70dd1b3cb6e252f35fa17b93f596c"
    public static let decodingArguments = [
        "--no-prints", "--no-timestamps", "--no-gpu", "--beam-size", "5",
        "--best-of", "5", "--temperature", "0", "--temperature-inc", "0.2", "--flash-attn"
    ]

    public let schemaVersion: Int
    public let engine: String
    public let sourceVersion: String
    public let sourceCommit: String
    public let executable: Artifact
    public let model: Model
    public let architecture: String
    public let buildFlags: [String]
    public let threads: Int
    public let acceleration: String
    public let decodeArguments: [String]
    public let language: String
    public let residency: String
    public let provenance: Provenance

    /// Decode and validate the schema, without executing the engine or reading model weights.
    /// Unknown JSON fields and unsupported argument combinations are rejected.
    public static func load(from profileURL: URL) throws -> EngineManifest {
        let data: Data
        do {
            let fd = try EngineFiles.openRegular(profileURL)
            defer { close(fd) }
            data = try EngineFiles.read(fd, limit: 65_536)
        } catch is CancellationError { throw CancellationError() }
        catch { throw EngineError.invalidManifest }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(json.keys) == Set([
                    "schemaVersion", "engine", "sourceVersion", "sourceCommit", "executable", "model",
                    "architecture", "buildFlags", "threads", "acceleration", "decodeArguments",
                    "language", "residency", "provenance"
                  ]),
                  let executable = json["executable"] as? [String: Any],
                  Set(executable.keys) == Set(["path", "sha256"]),
                  let model = json["model"] as? [String: Any],
                  Set(model.keys) == Set(["path", "sha256", "name", "license", "licenseURL"]),
                  let provenance = json["provenance"] as? [String: Any],
                  Set(provenance.keys) == Set(["kind", "evidence", "limitations"])
            else { throw EngineError.invalidManifest }
            let manifest = try JSONDecoder().decode(EngineManifest.self, from: data)
            try manifest.validateSchema()
            return manifest
        } catch let error as EngineError { throw error }
        catch { throw EngineError.invalidManifest }
    }

    /// Load a profile and stream-hash both artifacts. Call off the UI thread for large models.
    /// Validation is a snapshot, not an authenticity/signature check. Inference revalidates it.
    public static func loadValidated(from profileURL: URL) throws -> ValidatedEngineProfile {
        let manifest = try load(from: profileURL)
        guard manifest.architecture == hostArchitecture else { throw EngineError.unsupportedProfile }
        let executableURL = try resolve(manifest.executable.path, relativeTo: profileURL)
        let modelURL = try resolve(manifest.model.path, relativeTo: profileURL)
        try EngineFiles.verify(executableURL, sha256: manifest.executable.sha256, executable: true)
        try EngineFiles.verify(modelURL, sha256: manifest.model.sha256, executable: false)
        return ValidatedEngineProfile(manifest: manifest, executableURL: executableURL, modelURL: modelURL)
    }

    static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
    }

    private static func resolve(_ path: String, relativeTo profile: URL) throws -> URL {
        guard profile.isFileURL, validPath(path) else { throw EngineError.invalidManifest }
        return URL(fileURLWithPath: path, relativeTo: profile.deletingLastPathComponent())
            .standardizedFileURL
    }

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.unicodeScalars.contains(where: { $0.value < 32 })
    }

    private func validateSchema() throws {
        guard schemaVersion == 1, engine == "whisper.cpp", sourceVersion == "v1.8.1",
              sourceCommit == Self.pinnedCommit,
              ["arm64", "x86_64"].contains(architecture), (1...64).contains(threads),
              ["cpu", "cpu-accelerate"].contains(acceleration), language == "en", residency == "short-lived",
              decodeArguments == Self.decodingArguments,
              model.name == "tiny.en-q5_1", model.license == "MIT",
              model.licenseURL == "https://github.com/openai/whisper/blob/main/LICENSE",
              Self.validPath(executable.path), Self.validPath(model.path),
              EngineFiles.isDigest(executable.sha256), EngineFiles.isDigest(model.sha256),
              ["local-build-metadata", "operator-attested"].contains(provenance.kind),
              !provenance.evidence.isEmpty, provenance.evidence.count <= 32,
              provenance.evidence.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && EngineFiles.isDigest($0.value) }),
              !provenance.limitations.isEmpty, provenance.limitations.utf8.count <= 2_048,
              !buildFlags.isEmpty, buildFlags.count <= 256 else { throw EngineError.invalidManifest }
        var flags: [String: String] = [:]
        for flag in buildFlags {
            guard flag.hasPrefix("-D"), flag.utf8.count <= 512,
                  !flag.unicodeScalars.contains(where: { $0.value < 32 }),
                  let separator = flag.firstIndex(of: "=") else { throw EngineError.invalidManifest }
            let key = String(flag[flag.index(flag.startIndex, offsetBy: 2)..<separator])
            let value = String(flag[flag.index(after: separator)...])
            guard !key.isEmpty, !value.isEmpty, flags[key] == nil else { throw EngineError.invalidManifest }
            flags[key] = value
        }
        let required = [
            "CMAKE_BUILD_TYPE": "Release", "BUILD_SHARED_LIBS": "OFF", "GGML_CPU": "ON",
            "GGML_BACKEND_DL": "OFF", "GGML_METAL": "OFF", "GGML_CUDA": "OFF",
            "WHISPER_COREML": "OFF", "WHISPER_OPENVINO": "OFF", "WHISPER_CURL": "OFF",
            "GGML_ACCELERATE": acceleration == "cpu-accelerate" ? "ON" : "OFF",
            "GGML_BLAS": acceleration == "cpu-accelerate" ? "ON" : "OFF"
        ]
        guard required.allSatisfy({ flags[$0.key] == $0.value }) else { throw EngineError.invalidManifest }
        // No additional accelerated or remotely loaded backend is admitted by this schema.
        for key in ["GGML_HIP", "GGML_VULKAN", "GGML_SYCL", "GGML_RPC", "GGML_OPENCL", "GGML_WEBGPU", "GGML_MUSA"] {
            guard flags[key] == "OFF" else { throw EngineError.invalidManifest }
        }
    }
}

public struct ValidatedEngineProfile: Sendable {
    public let manifest: EngineManifest
    public let executableURL: URL
    public let modelURL: URL
}

/// Descriptor-relative opening rejects symlinks in every component, including the final one.
/// Foundation canonicalizes /private/var back to /var, including after resolving
/// symlinks. Expand only macOS's fixed system aliases before descriptor traversal.
enum EngineFiles {
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw EngineError.artifactUnavailable }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw EngineError.artifactUnavailable }
        do {
            var components = url.standardizedFileURL.path.split(separator: "/").map(String.init)
            if let first = components.first, ["var", "tmp", "etc"].contains(first) { components.insert("private", at: 0) }
            for component in components {
                let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw EngineError.artifactUnavailable }
                close(fd)
                fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    static func openRegular(_ url: URL) throws -> Int32 {
        let parent = try openDirectory(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw EngineError.artifactUnavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw EngineError.artifactUnavailable
        }
        return fd
    }

    static func read(_ fd: Int32, limit: Int, checkCancellation: Bool = true) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: min(limit + 1, 65_536))
        while true {
            if checkCancellation { try Task.checkCancellation() }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw EngineError.artifactUnavailable }
            if count == 0 { return output }
            guard count <= limit - output.count else { throw EngineError.artifactUnavailable }
            output.append(contentsOf: buffer.prefix(count))
        }
    }

    static func verify(_ url: URL, sha256: String, executable: Bool) throws {
        let fd = try openRegular(url)
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size > 0, before.st_size <= 5_368_709_120,
              before.st_mode & 0o022 == 0,
              !executable || before.st_mode & 0o111 != 0 else { throw EngineError.artifactUnavailable }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw EngineError.artifactUnavailable }
            if count == 0 { break }
            total += Int64(count)
            guard total <= before.st_size else { throw EngineError.integrityMismatch }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == total,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw EngineError.integrityMismatch }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw EngineError.integrityMismatch }
    }
}
