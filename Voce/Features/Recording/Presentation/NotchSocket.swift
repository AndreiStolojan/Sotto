#if VOCE_LOCAL
import Darwin
import Foundation

// Eclipse's local socket: newline-delimited UTF-8 JSON, one object per line, at most 4096 bytes.
// This file has no app dependencies so `scripts/test-core.sh` can compile it on its own.

/// Dictation state as Eclipse shows it. Voce's processing phases collapse into one.
enum NotchDictationState: String, Encodable, Sendable {
    case idle, starting, recording, processing

    init(_ state: RecordingState) {
        switch state {
        case .idle: self = .idle
        case .starting: self = .starting
        case .recording: self = .recording
        case .transcribing, .enhancing, .busy: self = .processing
        }
    }
}

/// The only line Voce sends: the state and the microphone level, never transcript text.
struct NotchDictationMessage: Encodable, Equatable, Sendable {
    private(set) var type = "dictation"
    let state: NotchDictationState
    /// Microphone level from 0 to 1, rounded to three decimals.
    let level: Double

    init(state: NotchDictationState, level: Double = 0) {
        self.state = state
        self.level = level.isFinite ? (min(max(level, 0), 1) * 1000).rounded() / 1000 : 0
    }

    /// The message as one JSON object followed by a newline.
    var line: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // A string enum and a clamped finite Double always encode.
        var data = try! encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

/// A line Eclipse sends. Unknown types and malformed lines decode to nil.
enum NotchCommand: Equatable, Sendable {
    /// Eclipse shows (or stopped showing) Voce's dictation.
    case presenting(Bool)
    case stop
    case cancel

    init?(line: Data) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: line) else { return nil }
        switch wire.type {
        case .presenting:
            guard let available = wire.available else { return nil }
            self = .presenting(available)
        case .stop: self = .stop
        case .cancel: self = .cancel
        }
    }

    private struct Wire: Decodable {
        enum Kind: String, Decodable { case presenting, stop, cancel }
        let type: Kind
        let available: Bool?
    }
}

/// Splits a byte stream into lines. A line longer than `maxLineBytes` is dropped whole.
struct NotchLineFramer {
    static let maxLineBytes = 4096
    private var buffer = Data()
    private var isDiscarding = false

    /// Appends received bytes and returns every line they complete, without the newline.
    mutating func append(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            if !isDiscarding && line.count <= Self.maxLineBytes { lines.append(line) }
            isDiscarding = false
            buffer = Data(buffer[(newline + 1)...])
        }
        if buffer.count > Self.maxLineBytes {
            buffer.removeAll()
            isDiscarding = true
        }
        return lines
    }
}

/// One connection to Eclipse's socket. Reads and writes run on a private serial queue;
/// commands and the close event arrive on the main actor in order.
final class NotchSocket: @unchecked Sendable {
    // `framer` and `isClosed` are only touched on `queue`.
    private let fd: Int32
    private let queue = DispatchQueue(label: "ro.andrei.Voce.NotchSocket")
    private let source: DispatchSourceRead
    private var framer = NotchLineFramer()
    private var isClosed = false
    private let onCommand: @MainActor @Sendable (NotchSocket, NotchCommand) -> Void
    private let onClose: @MainActor @Sendable (NotchSocket) -> Void

    /// Connects without blocking. Nil when nothing listens at `path` or the listener belongs to another user.
    init?(
        path: String,
        onCommand: @escaping @MainActor @Sendable (NotchSocket, NotchCommand) -> Void,
        onClose: @escaping @MainActor @Sendable (NotchSocket) -> Void
    ) {
        guard let fd = Self.connect(to: path) else { return nil }
        self.fd = fd
        self.onCommand = onCommand
        self.onClose = onClose
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        source.activate()
    }

    deinit {
        source.cancel()
    }

    /// Writes one line. A failed or short write closes the connection, since a half line would corrupt the stream.
    func send(_ line: Data) {
        queue.async { [self] in
            guard !isClosed else { return }
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written != line.count { finish(notify: true) }
        }
    }

    /// Closes the connection without reporting it back.
    func disconnect() {
        queue.async { [self] in finish(notify: false) }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !isClosed {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                let commands = framer.append(Data(chunk[0..<count])).compactMap(NotchCommand.init(line:))
                guard !commands.isEmpty else { continue }
                DispatchQueue.main.async { [self] in
                    MainActor.assumeIsolated { commands.forEach { onCommand(self, $0) } }
                }
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && errno == EAGAIN {
                return
            } else {
                // 0 is end of file: Eclipse closed the connection or quit.
                finish(notify: true)
            }
        }
    }

    /// Closes the connection once and, when `notify` is true, reports it on the main actor.
    private func finish(notify: Bool) {
        guard !isClosed else { return }
        isClosed = true
        source.cancel()
        guard notify else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onClose(self) }
        }
    }

    /// Opens a nonblocking stream socket with SIGPIPE disabled, connected to a listener owned by this user.
    private static func connect(to path: String) -> Int32? {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        var peerUID = uid_t()
        var peerGID = gid_t()
        let connected = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
            && fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0
            && withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            } == 0
            && getpeereid(fd, &peerUID, &peerGID) == 0
            && peerUID == getuid()
        guard connected else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
#endif
