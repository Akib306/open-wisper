import Darwin
import Dispatch
import Foundation

struct ProcessOutput: Sendable {
    let stdout: Data
    let elapsed: TimeInterval
}

/// Uses posix_spawn instead of Foundation.Process so creation of a new process group is
/// atomic. No shell, inherited environment, blocking read-to-EOF, or detached timer tasks.
struct ProcessSupervisor: Sendable {
    func run(
        executable: URL, arguments: [String], directory: URL, environment: [String: String],
        timeout: TimeInterval, stdoutLimit: Int = 1_048_576, stderrLimit: Int = 262_144
    ) async throws -> ProcessOutput {
        guard timeout.isFinite, timeout > 0, timeout <= 3_600 else { throw EngineError.invalidTimeout }
        guard (1...16_777_216).contains(stdoutLimit), (1...16_777_216).contains(stderrLimit),
              executable.isFileURL, directory.isFileURL,
              !arguments.contains(where: { $0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) })
        else { throw EngineError.launchFailed }
        let state = ProcessRunState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output: ProcessOutput = try await withCheckedThrowingContinuation { continuation in
                // Blocking OS supervision belongs on a dispatch worker, not Swift's cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try state.execute(
                            executable: executable, arguments: arguments, directory: directory,
                            environment: environment, timeout: timeout,
                            stdoutLimit: stdoutLimit, stderrLimit: stderrLimit
                        ))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return output
        } onCancel: {
            state.stop(.cancelled)
        }
    }
}

private enum ProcessStop: Sendable {
    case cancelled
    case failure(EngineError)

    var error: any Error {
        switch self {
        case .cancelled: CancellationError()
        case .failure(let error): error
        }
    }
}

/// Only pid and stopState cross threads, always under lock. All descriptors, buffers,
/// wait/reap operations and escalation deadlines belong exclusively to execute().
private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stopState: (reason: ProcessStop, time: UInt64)?

    func stop(_ reason: ProcessStop) {
        lock.withLock {
            if stopState == nil {
                stopState = (reason, DispatchTime.now().uptimeNanoseconds)
                if pid > 0 { kill(-pid, SIGTERM) }
            }
        }
    }

    private func stopped() -> (reason: ProcessStop, time: UInt64)? { lock.withLock { stopState } }

    func execute(
        executable: URL, arguments: [String], directory: URL, environment: [String: String],
        timeout: TimeInterval, stdoutLimit: Int, stderrLimit: Int
    ) throws -> ProcessOutput {
        let stdoutPipe = try makePipe()
        defer { close(stdoutPipe.read) }
        var stdoutWrite = stdoutPipe.write
        defer { if stdoutWrite >= 0 { close(stdoutWrite) } }
        let stderrPipe = try makePipe()
        defer { close(stderrPipe.read) }
        var stderrWrite = stderrPipe.write
        defer { if stderrWrite >= 0 { close(stderrWrite) } }
        let cwd = try EngineFiles.openDirectory(directory)
        defer { close(cwd) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw EngineError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw EngineError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t()
        var defaults = sigset_t()
        sigemptyset(&mask)
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGPIPE, SIGQUIT, SIGHUP] { sigaddset(&defaults, signal) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO) == 0,
              addWorkingDirectory(&actions, cwd) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { throw EngineError.launchFailed }

        let argv = CStringVector([executable.path] + arguments)
        let env = CStringVector(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" })
        var child: pid_t = 0
        try lock.withLock {
            if let stopState { throw stopState.reason.error }
            let result = argv.withPointer { args in
                env.withPointer { variables in
                    posix_spawn(&child, executable.path, &actions, &attributes, args, variables)
                }
            }
            guard result == 0 else { throw EngineError.launchFailed }
            pid = child
        }
        close(stdoutWrite); stdoutWrite = -1
        close(stderrWrite); stderrWrite = -1
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + UInt64(timeout * 1_000_000_000)
        var stdout = Data()
        var stdoutBytes = 0
        var stderrBytes = 0
        var stdoutEOF = false
        var stderrEOF = false
        var leaderExited = false
        var exitObservedAt: UInt64?
        var escalated = false
        var waitFailed = false

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { stop(.failure(.timedOut)) }
            drain(stdoutPipe.read, eof: &stdoutEOF, bytes: &stdoutBytes, limit: stdoutLimit, output: &stdout, retain: true)
            // stderr is drained concurrently but never retained or included in a thrown error.
            drain(stderrPipe.read, eof: &stderrEOF, bytes: &stderrBytes, limit: stderrLimit, output: &stdout, retain: false)

            if !leaderExited && !waitFailed {
                var info = siginfo_t()
                if waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                    if info.si_pid == child {
                        leaderExited = true
                        exitObservedAt = now
                    }
                } else if errno != EINTR {
                    waitFailed = true
                    stop(.failure(.supervisionFailed))
                }
            }
            if leaderExited {
                if groupHasOtherMembers(child) {
                    stop(.failure(.supervisionFailed))
                } else if stdoutEOF && stderrEOF {
                    break
                } else if let exited = exitObservedAt, now - exited > 100_000_000 {
                    // A process that escaped the group must not hold this operation hostage.
                    stop(.failure(.supervisionFailed))
                }
            }
            if let stopped = stopped(), now >= stopped.time + 2_000_000_000 {
                if !escalated {
                    // The leader remains waitable (WNOWAIT) until after the last group signal,
                    // so its PID cannot be recycled into an unrelated process group.
                    lock.withLock { if pid == child { kill(-child, SIGKILL) } }
                    escalated = true
                }
                if leaderExited || now >= stopped.time + 2_500_000_000 { break }
            }
            var descriptors = [
                pollfd(fd: stdoutEOF ? -1 : stdoutPipe.read, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stderrEOF ? -1 : stderrPipe.read, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&descriptors, nfds_t(descriptors.count), 20)
            if ready < 0 && errno != EINTR { stop(.failure(.supervisionFailed)) }
        }

        var status: Int32 = 0
        let reaped: pid_t = lock.withLock {
            // Serialize reap/detachment with onCancel to avoid signalling a recycled PID.
            let result = waitpid(child, &status, WNOHANG)
            pid = 0
            return result
        }
        if reaped != child {
            stop(.failure(.supervisionFailed))
            // SIGKILL normally makes waitpid ready immediately. A kernel-uninterruptible
            // process is reaped separately; no pipe read or UI task waits indefinitely.
            let unreapedPID = child
            DispatchQueue.global(qos: .utility).async {
                var ignored: Int32 = 0
                while waitpid(unreapedPID, &ignored, 0) < 0 && errno == EINTR {}
            }
        }
        if let stopped = stopped() { throw stopped.reason.error }
        let signal = status & 0x7f
        if signal != 0 { throw EngineError.processSignalled(signal) }
        let exitCode = (status >> 8) & 0xff
        guard exitCode == 0 else { throw EngineError.processFailed(exitCode) }
        return ProcessOutput(stdout: stdout, elapsed: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000)
    }

    private func drain(_ fd: Int32, eof: inout Bool, bytes: inout Int, limit: Int, output: inout Data, retain: Bool) {
        guard !eof else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Fairness matters: continuous stdout must not starve stderr, cancellation, or deadlines.
        for _ in 0..<4 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { eof = true; return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { stop(.failure(.supervisionFailed)); eof = true }
                return
            }
            if count > limit - bytes {
                bytes = limit
                stop(.failure(.outputLimitExceeded))
            } else {
                bytes += count
                if retain { output.append(contentsOf: buffer.prefix(count)) }
            }
        }
    }

    private func groupHasOtherMembers(_ group: pid_t) -> Bool {
        var members = [pid_t](repeating: 0, count: 256)
        let capacity = members.count * MemoryLayout<pid_t>.stride
        let size = proc_listpgrppids(group, &members, Int32(capacity))
        if size < 0 || size >= capacity { return true }
        return members.prefix(Int(size) / MemoryLayout<pid_t>.stride).contains { $0 != 0 && $0 != group }
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw EngineError.launchFailed }
        // Avoid collisions with child stdio even when the host has closed fd 0, 1, or 2.
        for index in 0..<2 {
            let replacement = fcntl(fds[index], F_DUPFD_CLOEXEC, 3)
            guard replacement >= 0 else { close(fds[0]); close(fds[1]); throw EngineError.launchFailed }
            close(fds[index])
            fds[index] = replacement
        }
        guard fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0 else {
            close(fds[0]); close(fds[1]); throw EngineError.launchFailed
        }
        return (fds[0], fds[1])
    }

    private func addWorkingDirectory(_ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>, _ fd: Int32) -> Int32 {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return posix_spawn_file_actions_addfchdir(actions, fd) }
        #endif
        return posix_spawn_file_actions_addfchdir_np(actions, fd)
    }
}

private final class CStringVector {
    private var values: [UnsafeMutablePointer<CChar>?]
    init(_ strings: [String]) { values = strings.map { strdup($0) } + [nil] }
    deinit { for value in values { free(value) } }
    func withPointer<T>(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        values.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
