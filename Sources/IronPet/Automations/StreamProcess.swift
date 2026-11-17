import Foundation

/// A long-running `/bin/sh -c command` in its own process group. Each stdout line goes to `onLine`, stderr to `onStderr`.
/// Stopping signals the whole group, so children of the command do not outlive it.
///
/// Callbacks run on the main queue, in the order the output arrived.
final class StreamProcess: @unchecked Sendable {
    enum Exit: Equatable {
        case code(Int32)
        case signal(Int32)

        var summary: String {
            switch self {
            case .code(let c): return "exit code \(c)"
            case .signal(let s): return "signal \(s)"
            }
        }
        var clean: Bool { self == .code(0) }
    }

    let pid: pid_t
    private let queue = DispatchQueue(label: "ironpet.stream-process")
    private let maxLine: Int
    private let grace: TimeInterval
    private var outSource: DispatchSourceRead?
    private var errSource: DispatchSourceRead?
    private var outFD: Int32
    private var errFD: Int32
    private var outBuffer = Data()
    private var errBuffer = Data()
    private var outSkipping = false
    private var finished = false
    private let onLine: (String) -> Void
    private let onStderr: (String) -> Void
    private let onLong: () -> Void
    private let onExit: (Exit) -> Void

    struct SpawnError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(command: String, environment: [String: String], maxLine: Int, grace: TimeInterval,
         onLine: @escaping (String) -> Void, onStderr: @escaping (String) -> Void,
         onLong: @escaping () -> Void, onExit: @escaping (Exit) -> Void) throws {
        self.maxLine = maxLine
        self.grace = grace
        self.onLine = onLine
        self.onStderr = onStderr
        self.onLong = onLong
        self.onExit = onExit

        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw SpawnError(message: "cannot create a pipe: \(String(cString: strerror(errno)))") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw SpawnError(message: "cannot create a pipe: \(String(cString: strerror(errno)))")
        }
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // A new process group (pgid = pid), default signal handlers and an empty mask, and nothing inherited but 0, 1 and 2.
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setpgroup(&attr, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | 0x4000 /* POSIX_SPAWN_CLOEXEC_DEFAULT */
        posix_spawnattr_setflags(&attr, Int16(flags))

        let argv: [String] = ["/bin/sh", "-c", command]
        let envp: [String] = environment.map { "\($0.key)=\($0.value)" }
        var args: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        var env: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) }
        args.append(nil)
        env.append(nil)
        defer { for p in args + env { free(p) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, "/bin/sh", &actions, &attr, args, env)
        close(outPipe[1])
        close(errPipe[1])
        guard status == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw SpawnError(message: "cannot run /bin/sh: \(String(cString: strerror(status)))")
        }
        pid = child
        outFD = outPipe[0]
        errFD = errPipe[0]
        queue.async { [self] in
            outSource = makeSource(outFD) { [self] data in feed(data, into: &outBuffer, line: true) }
            errSource = makeSource(errFD) { [self] data in feed(data, into: &errBuffer, line: false) }
        }
        DispatchQueue.global().async { [self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
            let exit: Exit = (raw & 0x7f) == 0 ? .code((raw >> 8) & 0xff) : .signal(raw & 0x7f)
            queue.async { [self] in finish(exit) }
        }
    }

    /// Whether any process of the command's group is still alive (a zombie leader counts until it is reaped).
    var groupAlive: Bool { killpg(pid, 0) == 0 }

    /// SIGTERM to the whole group, then SIGKILL to whatever is left after the grace time. Safe to call twice.
    func terminate() {
        killpg(pid, SIGTERM)
        scheduleKill()
    }

    /// Blocks until the group is gone or `deadline` passes, then sends SIGKILL to what is left. Call `terminate()` first. For app quit.
    func waitForGroup(until deadline: Date) {
        while groupAlive, Date() < deadline { usleep(20_000) }
        if groupAlive { killpg(pid, SIGKILL) }
    }

    /// SIGTERM, wait up to `timeout` seconds, then SIGKILL.
    func terminateAndWait(timeout: TimeInterval) {
        killpg(pid, SIGTERM)
        waitForGroup(until: Date().addingTimeInterval(timeout))
    }

    private func scheduleKill() {
        queue.asyncAfter(deadline: .now() + grace) { [pid] in
            // ESRCH when the group is already gone, so a reused pid is not signalled in practice.
            if killpg(pid, 0) == 0 { killpg(pid, SIGKILL) }
        }
    }

    private func makeSource(_ fd: Int32, _ handle: @escaping (Data) -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !finished else { return }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { handle(Data(chunk[0..<n])) } else if n == 0 { source.cancel() }
        }
        source.resume()
        return source
    }

    private func feed(_ data: Data, into buffer: inout Data, line isStdout: Bool) {
        var start = data.startIndex
        while start < data.endIndex {
            if let newline = data[start...].firstIndex(of: 0x0A) {
                if isStdout, outSkipping {
                    outSkipping = false
                } else {
                    buffer.append(data[start..<newline])
                    emit(&buffer, stdout: isStdout)
                }
                start = data.index(after: newline)
            } else {
                if !(isStdout && outSkipping) { buffer.append(data[start...]) }
                if isStdout, buffer.count > maxLine {
                    buffer.removeAll()
                    outSkipping = true
                    DispatchQueue.main.async { [onLong] in onLong() }
                } else if !isStdout, buffer.count > maxLine { buffer.removeFirst(buffer.count - maxLine) }
                start = data.endIndex
            }
        }
    }

    private func emit(_ buffer: inout Data, stdout: Bool) {
        var bytes = buffer
        buffer.removeAll()
        if bytes.last == 0x0D { bytes.removeLast() }
        let text = String(decoding: bytes, as: UTF8.self)
        if stdout {
            guard bytes.count <= maxLine else { DispatchQueue.main.async { [onLong] in onLong() }; return }
            DispatchQueue.main.async { [onLine] in onLine(text) }
        } else {
            DispatchQueue.main.async { [onStderr] in onStderr(text) }
        }
    }

    /// Runs on `queue` after the leader was reaped: reads what is left in the pipes, stops anything the command left behind,
    /// closes the pipes and reports the exit.
    private func finish(_ exit: Exit) {
        guard !finished else { return }
        for fd in [outFD, errFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        for (fd, isOut) in [(outFD, true), (errFD, false)] {
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                if isOut { feed(Data(chunk[0..<n]), into: &outBuffer, line: true) } else { feed(Data(chunk[0..<n]), into: &errBuffer, line: false) }
            }
        }
        if !outBuffer.isEmpty, !outSkipping { emit(&outBuffer, stdout: true) }
        if !errBuffer.isEmpty { emit(&errBuffer, stdout: false) }
        finished = true
        outSource?.cancel()
        errSource?.cancel()
        close(outFD)
        close(errFD)
        // Children that outlived the shell are stopped too.
        if killpg(pid, 0) == 0 {
            killpg(pid, SIGTERM)
            scheduleKill()
        }
        DispatchQueue.main.async { [onExit] in onExit(exit) }
    }
}
