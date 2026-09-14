import Darwin
import Foundation

public enum AtomicFileWriterError: Error, Sendable {
    case operationFailed(operation: String, code: Int32)
}

extension AtomicFileWriterError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .operationFailed(operation, code):
            "atomic file \(operation) failed with errno \(code)"
        }
    }
}

public struct AtomicFileWriter: Sendable {
    public init() {}

    public func write(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        var temporaryMayExist = true
        defer {
            if temporaryMayExist {
                try? fileManager.removeItem(at: temporary)
            }
        }

        let temporaryDescriptor = try openFile(
            at: temporary,
            flags: O_WRONLY | O_CREAT | O_EXCL,
            mode: S_IRUSR | S_IWUSR,
            operation: "temporary open"
        )
        do {
            try writeAll(data, to: temporaryDescriptor)
            try sync(temporaryDescriptor, operation: "temporary fsync")
        } catch {
            _ = close(temporaryDescriptor)
            throw error
        }
        guard close(temporaryDescriptor) == 0 else {
            throw failure("temporary close")
        }

        try renameAtomically(from: temporary, to: destination)
        temporaryMayExist = false

        let directoryDescriptor = try openFile(
            at: directory,
            flags: O_RDONLY | O_DIRECTORY,
            mode: 0,
            operation: "directory open"
        )
        do {
            try sync(directoryDescriptor, operation: "directory fsync")
        } catch {
            _ = close(directoryDescriptor)
            throw error
        }
        guard close(directoryDescriptor) == 0 else {
            throw failure("directory close")
        }
    }

    private func openFile(
        at url: URL,
        flags: Int32,
        mode: mode_t,
        operation: String
    ) throws -> Int32 {
        while true {
            let descriptor = open(url.path, flags, mode)
            if descriptor >= 0 { return descriptor }
            if errno != EINTR { throw failure(operation) }
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("temporary write")
                }
                guard count > 0 else {
                    throw AtomicFileWriterError.operationFailed(
                        operation: "temporary write",
                        code: EIO
                    )
                }
                written += count
            }
        }
    }

    private func sync(_ descriptor: Int32, operation: String) throws {
        while fsync(descriptor) != 0 {
            if errno != EINTR { throw failure(operation) }
        }
    }

    private func renameAtomically(from source: URL, to destination: URL) throws {
        while rename(source.path, destination.path) != 0 {
            if errno != EINTR { throw failure("rename") }
        }
    }

    private func failure(_ operation: String) -> AtomicFileWriterError {
        .operationFailed(operation: operation, code: errno)
    }
}
