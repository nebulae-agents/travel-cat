import CryptoKit
import Darwin
import Foundation
import SQLite3

/// A single-row SQLite store. SQLite's rollback journal plus FULL synchronous
/// commits make the envelope switch atomic without application-managed recovery
/// names. DELETE journal mode bounds the namespace to the database and one
/// transient `-journal` sidecar.
final class PetTravelPromptStore {
    private struct FileIdentity {
        let device: dev_t
        let inode: ino_t
        let allowEmpty: Bool

        init(_ info: stat, allowEmpty: Bool = false) {
            device = info.st_dev
            inode = info.st_ino
            self.allowEmpty = allowEmpty
        }

        func matches(_ info: stat) -> Bool {
            info.st_dev == device && info.st_ino == inode
        }

        func matches(_ other: FileIdentity) -> Bool {
            device == other.device && inode == other.inode
        }
    }

    private struct StoredRow {
        let generation: Int64
        let payload: Data?
        let digest: String?
    }

    static let databaseName = "pet-travel-prompts.sqlite3"
    private static let bootstrapName = ".pet-travel-prompts.sqlite3.bootstrap"
    private static let maximumPayloadBytes = 16 * 1_048_576
    private static let maximumDatabaseBytes = 64 * 1_048_576
    private static let schemaSQL = """
        CREATE TABLE prompt_state(
          id INTEGER PRIMARY KEY CHECK(id = 1),
          schema_version INTEGER NOT NULL CHECK(schema_version = 1),
          generation INTEGER NOT NULL CHECK(generation >= 0),
          payload BLOB,
          digest TEXT,
          CHECK(
            (generation = 0 AND payload IS NULL AND digest IS NULL)
            OR (generation > 0 AND payload IS NOT NULL AND digest IS NOT NULL)
          )
        ) STRICT
        """

    let statePath: String
    var beforeOpeningDatabase: (() throws -> Void)?
    var afterBeginningTransaction: (() throws -> Void)?
    var beforeCommittingTransaction: (() throws -> Void)?
    var afterCommittingTransaction: (() throws -> Void)?
    var beforeInstallingBootstrap: (() throws -> Void)?

    init(statePath: String) {
        self.statePath = statePath
    }

    func load(
        from directory: Int32,
        validateReachability: (() throws -> Void)? = nil
    ) throws -> Data? {
        guard let expectedIdentity = try databaseIdentityIfExists(in: directory) else {
            try rejectUnexpectedSidecars(in: directory)
            try removeSafeBootstrapIfPresent(in: directory)
            return nil
        }
        try validateExistingSidecars(in: directory)
        let connection = try openDatabase(
            in: directory,
            expectedIdentity: expectedIdentity
        )
        defer { sqlite3_close(connection.database) }
        do {
            try validateReachability?()
            try validatePathIdentity(connection.identity, in: directory)
            try beginImmediate(connection.database)
            let row = try validateAndReadRow(connection.database)
            try validateReachability?()
            try validatePathIdentity(connection.identity, in: directory)
            try execute("COMMIT", on: connection.database)
            try validateReachability?()
            try validatePathIdentity(connection.identity, in: directory)
            return row.payload
        } catch {
            _ = sqlite3_exec(connection.database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func commit(
        _ data: Data,
        in directory: Int32,
        didInstall: inout Bool,
        validateReachability: (() throws -> Void)? = nil
    ) throws {
        guard !data.isEmpty, data.count <= Self.maximumPayloadBytes else { throw corrupt() }
        var expectedIdentity = try databaseIdentityIfExists(in: directory)
        if expectedIdentity == nil {
            try rejectUnexpectedSidecars(in: directory)
            try installInitializedDatabase(
                in: directory,
                validateReachability: validateReachability
            )
            expectedIdentity = try databaseIdentityIfExists(in: directory)
        } else {
            try validateExistingSidecars(in: directory)
        }
        if let hook = beforeOpeningDatabase {
            beforeOpeningDatabase = nil
            try hook()
        }
        let connection = try openDatabase(
            in: directory,
            expectedIdentity: expectedIdentity!
        )
        defer { sqlite3_close(connection.database) }
        var transactionOpen = false
        do {
            try validateReachability?()
            try validatePathIdentity(connection.identity, in: directory)
            try beginImmediate(connection.database)
            transactionOpen = true
            if let hook = afterBeginningTransaction {
                afterBeginningTransaction = nil
                try hook()
            }
            try validateReachability?()
            try validatePathIdentity(connection.identity, in: directory)

            let existing = try validateAndReadRow(connection.database)
            guard existing.generation < Int64.max else { throw corrupt() }
            let generation = existing.generation + 1
            try writeRow(data, generation: generation, on: connection.database)
            if let hook = beforeCommittingTransaction {
                beforeCommittingTransaction = nil
                try hook()
            }
            try validateReachability?()
            try validatePathIdentity(connection.identity, in: directory)
            try execute("COMMIT", on: connection.database)
            transactionOpen = false
            didInstall = true

            if let hook = afterCommittingTransaction {
                afterCommittingTransaction = nil
                try hook()
            }
            try validateReachability?()
            try validatePathIdentity(connection.identity, in: directory)
            let installed = try validateAndReadRow(connection.database)
            guard installed.generation == generation,
                  installed.payload == data,
                  installed.digest == digest(data) else { throw persistence() }
        } catch {
            if transactionOpen {
                _ = sqlite3_exec(connection.database, "ROLLBACK", nil, nil, nil)
            }
            throw error
        }
    }

    private func openDatabase(
        in directory: Int32,
        expectedIdentity: FileIdentity
    ) throws -> (database: OpaquePointer, identity: FileIdentity) {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let databasePath = try pathForDatabase(in: directory)
        guard sqlite3_open_v2(databasePath, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw corrupt()
        }
        do {
            let identity = try validatedIdentity(
                in: directory,
                allowEmpty: expectedIdentity.allowEmpty
            )
            guard expectedIdentity.device == identity.device,
                  expectedIdentity.inode == identity.inode else { throw corrupt() }
            try configure(database)
            try validatePathIdentity(identity, in: directory)
            return (database, identity)
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private func beginImmediate(_ database: OpaquePointer) throws {
        try execute("BEGIN IMMEDIATE", on: database)
    }

    private func validateAndReadRow(_ database: OpaquePointer) throws -> StoredRow {
        guard try integerValue("PRAGMA user_version", on: database) == 1 else { throw corrupt() }
        let schemaRows = try textRows(
            "SELECT type || ':' || name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
            on: database
        )
        guard schemaRows == ["table:prompt_state"] else { throw corrupt() }
        guard try textRows(
            "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = 'prompt_state'",
            on: database
        ) == [Self.schemaSQL] else { throw corrupt() }
        guard try integrityCheck(database) else { throw corrupt() }

        let sql = "SELECT id, schema_version, generation, payload, digest FROM prompt_state ORDER BY id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw corrupt() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 0) == 1,
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 1) == 1,
              sqlite3_column_type(statement, 2) == SQLITE_INTEGER else { throw corrupt() }
        let generation = sqlite3_column_int64(statement, 2)
        guard generation >= 0 else { throw corrupt() }
        if generation == 0 {
            guard sqlite3_column_type(statement, 3) == SQLITE_NULL,
                  sqlite3_column_type(statement, 4) == SQLITE_NULL,
                  sqlite3_step(statement) == SQLITE_DONE else { throw corrupt() }
            return StoredRow(generation: 0, payload: nil, digest: nil)
        }
        guard sqlite3_column_type(statement, 3) == SQLITE_BLOB,
              sqlite3_column_type(statement, 4) == SQLITE_TEXT else { throw corrupt() }
        let byteCount = Int(sqlite3_column_bytes(statement, 3))
        let digestByteCount = Int(sqlite3_column_bytes(statement, 4))
        guard byteCount > 0, byteCount <= Self.maximumPayloadBytes,
              let bytes = sqlite3_column_blob(statement, 3),
              digestByteCount == 64,
              let digestBytes = sqlite3_column_text(statement, 4) else { throw corrupt() }
        let payload = Data(bytes: bytes, count: byteCount)
        let digestData = Data(bytes: digestBytes, count: digestByteCount)
        guard let storedDigest = String(data: digestData, encoding: .utf8) else { throw corrupt() }
        guard storedDigest.count == 64,
              storedDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              storedDigest == digest(payload),
              sqlite3_step(statement) == SQLITE_DONE else { throw corrupt() }
        return StoredRow(generation: generation, payload: payload, digest: storedDigest)
    }

    private func configure(_ database: OpaquePointer) throws {
        guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else { throw persistence() }
        guard try textRows("PRAGMA journal_mode = DELETE", on: database) == ["delete"] else {
            throw persistence()
        }
        try execute("PRAGMA synchronous = FULL", on: database)
        guard try integerValue("PRAGMA synchronous", on: database) == 2 else {
            throw persistence()
        }
        try execute("PRAGMA foreign_keys = ON", on: database)
        try execute("PRAGMA trusted_schema = OFF", on: database)
    }

    private func writeRow(_ data: Data, generation: Int64, on database: OpaquePointer) throws {
        let sql = """
            INSERT INTO prompt_state(id, schema_version, generation, payload, digest)
            VALUES(1, 1, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              schema_version = excluded.schema_version,
              generation = excluded.generation,
              payload = excluded.payload,
              digest = excluded.digest
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw persistence() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, generation) == SQLITE_OK else { throw persistence() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let blobResult = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), transient)
        }
        guard blobResult == SQLITE_OK else { throw persistence() }
        let digest = digest(data)
        guard sqlite3_bind_text(statement, 3, digest, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw persistence() }
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw persistence() }
    }

    private func textRows(_ sql: String, on database: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw corrupt() }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                      let value = sqlite3_column_text(statement, 0) else { throw corrupt() }
                result.append(String(cString: value))
            case SQLITE_DONE:
                return result
            default:
                throw corrupt()
            }
        }
    }

    private func integerValue(_ sql: String, on database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw corrupt() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw corrupt() }
        let result = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw corrupt() }
        return result
    }

    private func integrityCheck(_ database: OpaquePointer) throws -> Bool {
        try textRows("PRAGMA quick_check(1)", on: database) == ["ok"]
    }

    private func databaseIdentityIfExists(in directory: Int32) throws -> FileIdentity? {
        var info = stat()
        if fstatat(directory, Self.databaseName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard strictDatabase(info) else { throw corrupt() }
            return FileIdentity(info)
        }
        guard errno == ENOENT else { throw corrupt() }
        return nil
    }

    private func installInitializedDatabase(
        in directory: Int32,
        validateReachability: (() throws -> Void)?
    ) throws {
        try validateReachability?()
        try removeSafeBootstrapIfPresent(in: directory)
        let descriptor = openat(
            directory,
            Self.bootstrapName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw persistence() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              strictDatabase(info, allowEmpty: true),
              fsync(descriptor) == 0 else {
            _ = close(descriptor)
            throw persistence()
        }
        let bootstrapIdentity = FileIdentity(info, allowEmpty: true)
        _ = close(descriptor)
        guard fsync(directory) == 0 else { throw persistence() }

        var database: OpaquePointer?
        let path = try pathForFile(Self.bootstrapName, in: directory)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw persistence()
        }
        var transactionOpen = false
        do {
            try validateNamedIdentity(
                bootstrapIdentity,
                name: Self.bootstrapName,
                in: directory
            )
            try configure(database)
            try beginImmediate(database)
            transactionOpen = true
            try execute(Self.schemaSQL, on: database)
            try execute("PRAGMA user_version = 1", on: database)
            try execute(
                "INSERT INTO prompt_state(id, schema_version, generation, payload, digest) VALUES(1, 1, 0, NULL, NULL)",
                on: database
            )
            try execute("COMMIT", on: database)
            transactionOpen = false
            _ = try validateAndReadRow(database)
        } catch {
            if transactionOpen { _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
            sqlite3_close(database)
            throw error
        }
        guard sqlite3_close(database) == SQLITE_OK else { throw persistence() }

        let initialized = try validatedIdentity(
            name: Self.bootstrapName,
            in: directory,
            allowEmpty: false
        )
        guard bootstrapIdentity.matches(initialized) else { throw corrupt() }
        let initializedDescriptor = openat(
            directory,
            Self.bootstrapName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard initializedDescriptor >= 0 else { throw persistence() }
        var initializedInfo = stat()
        let synced = fstat(initializedDescriptor, &initializedInfo) == 0
            && strictDatabase(initializedInfo)
            && bootstrapIdentity.matches(initializedInfo)
            && fsync(initializedDescriptor) == 0
        _ = close(initializedDescriptor)
        guard synced,
              fsync(directory) == 0 else { throw persistence() }
        try rejectBootstrapSidecars(in: directory)
        if let hook = beforeInstallingBootstrap {
            beforeInstallingBootstrap = nil
            try hook()
        }
        try validateReachability?()
        let renameSource = try validatedIdentity(
            name: Self.bootstrapName,
            in: directory,
            allowEmpty: false
        )
        guard bootstrapIdentity.matches(renameSource) else { throw corrupt() }
        guard renameatx_np(
            directory,
            Self.bootstrapName,
            directory,
            Self.databaseName,
            UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        ) == 0 else { throw persistence() }
        try validateNamedIdentity(renameSource, name: Self.databaseName, in: directory)
        try validateReachability?()
        guard fsync(directory) == 0 else { throw persistence() }
    }

    private func validatedIdentity(in directory: Int32, allowEmpty: Bool) throws -> FileIdentity {
        try validatedIdentity(
            name: Self.databaseName,
            in: directory,
            allowEmpty: allowEmpty
        )
    }

    private func validatedIdentity(
        name: String,
        in directory: Int32,
        allowEmpty: Bool
    ) throws -> FileIdentity {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw corrupt() }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              strictDatabase(info, allowEmpty: allowEmpty) else { throw corrupt() }
        return FileIdentity(info, allowEmpty: allowEmpty)
    }

    private func validatePathIdentity(_ identity: FileIdentity, in directory: Int32) throws {
        try validateNamedIdentity(identity, name: Self.databaseName, in: directory)
    }

    private func validateNamedIdentity(
        _ identity: FileIdentity,
        name: String,
        in directory: Int32
    ) throws {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              strictDatabase(info, allowEmpty: identity.allowEmpty),
              identity.matches(info) else { throw corrupt() }
    }

    private func strictDatabase(_ info: stat, allowEmpty: Bool = false) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && info.st_nlink == 1
            && info.st_uid == geteuid()
            && info.st_mode & mode_t(0o777) == mode_t(0o600)
            && (allowEmpty || info.st_size > 0)
            && info.st_size <= off_t(Self.maximumDatabaseBytes)
    }

    private func rejectUnexpectedSidecars(in directory: Int32) throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            var info = stat()
            if fstatat(directory, Self.databaseName + suffix, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                throw corrupt()
            }
            guard errno == ENOENT else { throw corrupt() }
        }
    }

    private func rejectBootstrapSidecars(in directory: Int32) throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            var info = stat()
            guard fstatat(
                directory,
                Self.bootstrapName + suffix,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) != 0, errno == ENOENT else { throw persistence() }
        }
    }

    private func removeSafeBootstrapIfPresent(in directory: Int32) throws {
        let names = [
            Self.bootstrapName + "-journal",
            Self.bootstrapName + "-wal",
            Self.bootstrapName + "-shm",
            Self.bootstrapName,
        ]
        var found: [(String, FileIdentity)] = []
        for name in names {
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard strictDatabase(info, allowEmpty: true) else { throw corrupt() }
                found.append((name, FileIdentity(info, allowEmpty: true)))
            } else {
                guard errno == ENOENT else { throw corrupt() }
            }
        }
        for (name, identity) in found {
            try validateNamedIdentity(identity, name: name, in: directory)
            guard unlinkat(directory, name, 0) == 0 else { throw persistence() }
        }
        if !found.isEmpty {
            guard fsync(directory) == 0 else { throw persistence() }
        }
    }

    private func validateExistingSidecars(in directory: Int32) throws {
        for suffix in ["-wal", "-shm"] {
            var info = stat()
            if fstatat(directory, Self.databaseName + suffix, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                throw corrupt()
            }
            guard errno == ENOENT else { throw corrupt() }
        }
        var journal = stat()
        if fstatat(
            directory,
            Self.databaseName + "-journal",
            &journal,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard strictDatabase(journal, allowEmpty: true) else { throw corrupt() }
            if journal.st_size == 0 {
                let identity = FileIdentity(journal, allowEmpty: true)
                let descriptor = openat(
                    directory,
                    Self.databaseName + "-journal",
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else { throw corrupt() }
                var opened = stat()
                let isSameEmptyFile = fstat(descriptor, &opened) == 0
                    && strictDatabase(opened, allowEmpty: true)
                    && opened.st_size == 0
                    && identity.matches(opened)
                _ = close(descriptor)
                guard isSameEmptyFile else { throw corrupt() }
                try validateNamedIdentity(
                    identity,
                    name: Self.databaseName + "-journal",
                    in: directory
                )
                guard unlinkat(directory, Self.databaseName + "-journal", 0) == 0,
                      fsync(directory) == 0 else { throw persistence() }
            }
        } else {
            guard errno == ENOENT else { throw corrupt() }
        }
    }

    private func pathForDatabase(in directory: Int32) throws -> String {
        try pathForFile(Self.databaseName, in: directory)
    }

    private func pathForFile(_ name: String, in directory: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(directory, F_GETPATH, &buffer) == 0 else { throw corrupt() }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let path = String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(name)
            .path
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func corrupt() -> PetTravelPromptCoordinatorError { .corruptValue(statePath) }
    private func persistence() -> PetTravelPromptCoordinatorError { .persistenceFailed(statePath) }
}
