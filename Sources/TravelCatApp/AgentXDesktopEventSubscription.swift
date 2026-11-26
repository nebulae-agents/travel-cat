import CryptoKit
import Foundation
@preconcurrency import Network

/// One receive-only run subscription on an already authenticated loopback connection.
@MainActor
final class AgentXDesktopEventSubscription {
    let app: AgentXDesktopAppRuns
    let runID: String
    private let connection: NWConnection
    private var cursor: UInt64
    private var open = false
    private var sending = false

    init(connection: NWConnection, app: AgentXDesktopAppRuns, runID: String, cursor: UInt64) {
        self.connection = connection
        self.app = app
        self.runID = runID
        self.cursor = cursor
    }

    static func handshake(_ headers: [String: String]) -> Data? {
        let tokens = headers["connection"]?.lowercased().split(separator: ",")
        guard tokens?.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              headers["sec-websocket-version"] == "13", let key = headers["sec-websocket-key"],
              Data(base64Encoded: key)?.count == 16 else { return nil }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        return Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
    }

    func start(_ handshake: Data) {
        Task {
            do {
                try await send(handshake)
                open = true
                drain()
                try await readControls()
            } catch { /* Peer disconnected or the listener shut down. */ }
            stop()
        }
    }

    func stop() {
        open = false
        connection.cancel()
    }

    // Send from the last transmitted revision. A save during an outstanding send is
    // picked up on the next iteration, without queuing an unbounded list of frames.
    func drain() {
        guard open, !sending else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                while open {
                    let batch = app.events(runID, after: cursor)
                    switch batch {
                    case let .available(revision, events):
                        if events.isEmpty { return }
                        for event in events {
                            guard open else { return }
                            try await frame(1, JSONSerialization.data(withJSONObject: event))
                        }
                        cursor = UInt64(revision)
                    case .snapshotRequired, .missing:
                        try await frame(1, batch.response().1)
                        try await close(Data([3, 232]))
                        return
                    }
                }
            } catch { stop() }
        }
    }

    private func send(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func frame(_ opcode: UInt8, _ payload: Data) async throws {
        var bytes = Data([0x80 | opcode])
        switch payload.count {
        case 0...125: bytes.append(UInt8(payload.count))
        case 126...65535:
            bytes.append(126)
            withUnsafeBytes(of: UInt16(payload.count).bigEndian) { bytes.append(contentsOf: $0) }
        default:
            bytes.append(127)
            withUnsafeBytes(of: UInt64(payload.count).bigEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(payload)
        try await send(bytes)
    }

    private func receive(_ length: Int) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                if let data, data.count == length { continuation.resume(returning: Array(data)) }
                else { continuation.resume(throwing: error ?? NWError.posix(.ECONNRESET)) }
            }
        }
    }

    private func close(_ payload: Data) async throws {
        guard open else { return }
        open = false
        defer { connection.cancel() }
        try await frame(8, payload)
    }

    private static func validClose(_ payload: [UInt8]) -> Bool {
        if payload.isEmpty { return true }
        guard payload.count >= 2 else { return false }
        let code = Int(payload[0]) * 256 + Int(payload[1])
        return ((1000...1014).contains(code) && ![1004, 1005, 1006].contains(code) || (3000...4999).contains(code))
            && String(bytes: payload.dropFirst(2), encoding: .utf8) != nil
    }

    private func readControls() async throws {
        while open {
            let header = try await receive(2)
            let opcode = header[0] & 0x0f
            let length = Int(header[1] & 0x7f)
            guard header[0] & 0x70 == 0, header[1] & 0x80 != 0 else { break }
            if opcode == 1 || opcode == 2 {
                try await close(Data([3, 235])) // 1003: subscriptions receive server events only.
                return
            }
            guard header[0] & 0x80 != 0, (8...10).contains(opcode), length <= 125 else { break }
            let masked = try await receive(4 + length)
            let payload = (0..<length).map { masked[4 + $0] ^ masked[$0 % 4] }
            if opcode == 8 {
                guard Self.validClose(payload) else { break }
                try await close(Data(payload))
                return
            }
            if opcode == 9 { try await frame(10, Data(payload)) }
        }
        try await close(Data([3, 234])) // 1002: invalid control frame.
    }
}
