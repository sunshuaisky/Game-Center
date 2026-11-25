import Darwin
import Foundation

public struct CoreOptionChoiceDTO: Codable, Hashable, Sendable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

public struct CoreOptionDTO: Codable, Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let description: String
    public let currentValue: String
    public let defaultValue: String
    public let choices: [CoreOptionChoiceDTO]

    public init(
        key: String,
        description: String,
        currentValue: String,
        defaultValue: String,
        choices: [CoreOptionChoiceDTO]
    ) {
        self.key = key
        self.description = description
        self.currentValue = currentValue
        self.defaultValue = defaultValue
        self.choices = choices
    }
}

public struct CoreLoadRequest: Codable, Sendable {
    public let corePath: String
    public let romPath: String
    public let systemDir: String
    public let saveDir: String
    public let batteryPath: String?
    public let moltenVKPath: String?
    public let initialOptions: [String: String]

    public init(
        corePath: String,
        romPath: String,
        systemDir: String,
        saveDir: String,
        batteryPath: String?,
        moltenVKPath: String? = nil,
        initialOptions: [String: String] = [:]
    ) {
        self.corePath = corePath
        self.romPath = romPath
        self.systemDir = systemDir
        self.saveDir = saveDir
        self.batteryPath = batteryPath
        self.moltenVKPath = moltenVKPath
        self.initialOptions = initialOptions
    }
}

public struct CoreLoadedInfo: Codable, Sendable {
    public let fps: Double
    public let sampleRate: Double
    public let baseWidth: Int
    public let baseHeight: Int
    public let aspectRatio: Float
    public let options: [CoreOptionDTO]

    public init(
        fps: Double,
        sampleRate: Double,
        baseWidth: Int,
        baseHeight: Int,
        aspectRatio: Float,
        options: [CoreOptionDTO]
    ) {
        self.fps = fps
        self.sampleRate = sampleRate
        self.baseWidth = baseWidth
        self.baseHeight = baseHeight
        self.aspectRatio = aspectRatio
        self.options = options
    }
}

public enum HostCommand: Codable, Sendable {
    case load(CoreLoadRequest)
    case setPaused(Bool)
    case reset
    case setAudio(volume: Float, muted: Bool)
    case saveState(requestID: String, path: String)
    case loadState(requestID: String, path: String)
    case setOption(key: String, value: String)
    case flushSave(requestID: String)
    case shutdown
}

public enum HelperEvent: Codable, Sendable {
    case ready
    case loaded(CoreLoadedInfo)
    case optionsUpdated([CoreOptionDTO])
    case actionResult(requestID: String, ok: Bool, message: String?)
    case fatalError(String)
}

public enum ControlSocketError: LocalizedError {
    case socketPairFailed(Int32)
    case closed
    case ioFailed(Int32)
    case frameTooLarge(UInt32)

    public var errorDescription: String? {
        switch self {
        case .socketPairFailed(let code): "无法创建进程通信通道 (errno \(code))"
        case .closed: "模拟器子进程通信连接已断开"
        case .ioFailed(let code): "进程通信读写失败 (errno \(code))"
        case .frameTooLarge(let size): "控制消息体积异常 (\(size) bytes)"
        }
    }
}

/// Bidirectional length-prefixed JSON channel over a Unix domain socket pair.
public final class ControlSocketChannel: @unchecked Sendable {
    public let fileDescriptor: Int32
    private let writeLock = NSLock()
    private var isClosed = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public static func makePair() throws -> (parent: ControlSocketChannel, childFD: Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw ControlSocketError.socketPairFailed(errno)
        }
        var noSigPipe: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return (ControlSocketChannel(fileDescriptor: fds[0]), fds[1])
    }

    public init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fileDescriptor, SHUT_RDWR)
        Darwin.close(fileDescriptor)
    }

    public func send<T: Encodable>(_ message: T) throws {
        let payload = try encoder.encode(message)
        var length = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        var packet = Data(capacity: 4 + payload.count)
        packet.append(header)
        packet.append(payload)

        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { throw ControlSocketError.closed }
        try writeAll(packet)
    }

    public func receive<T: Decodable>(_ type: T.Type) throws -> T {
        let header = try readExact(count: 4)
        let length = header.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.load(as: UInt32.self))
        }
        guard length > 0 && length <= 16 * 1024 * 1024 else {
            throw ControlSocketError.frameTooLarge(length)
        }
        let body = try readExact(count: Int(length))
        return try decoder.decode(type, from: body)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fileDescriptor, base.advanced(by: written), data.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw ControlSocketError.ioFailed(errno)
                }
            }
        }
    }

    private func readExact(count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var received = 0
            while received < count {
                let n = Darwin.read(fileDescriptor, base.advanced(by: received), count - received)
                if n > 0 {
                    received += n
                } else if n == 0 {
                    throw ControlSocketError.closed
                } else if errno == EINTR {
                    continue
                } else {
                    throw ControlSocketError.ioFailed(errno)
                }
            }
        }
        return result
    }
}
