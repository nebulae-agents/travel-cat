import Darwin
import Foundation
import SQLite3
@testable import TravelStorage
import XCTest

final class PetTravelPromptStoreTests: XCTestCase {
    private enum InjectedFailure: Error { case stop }

    func testMissingDatabaseIsEmptyAndCommitsReplaceOneStrictRow() throws {
        try withStore { store, directory, root in
            XCTAssertNil(try store.load(from: directory))
            var installed = false
            let first = Data(#"{"value":1}"#.utf8)
            try store.commit(first, in: directory, didInstall: &installed)
            XCTAssertTrue(installed)
            XCTAssertEqual(try store.load(from: directory), first)

            installed = false
            let second = Data(#"{"value":2}"#.utf8)
            try store.commit(second, in: directory, didInstall: &installed)
            XCTAssertTrue(installed)
            XCTAssertEqual(try store.load(from: directory), second)

            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasPrefix("pet-travel-prompts.sqlite3") }
            XCTAssertTrue(Set(names).isSubset(of: [
                "pet-travel-prompts.sqlite3",
                "pet-travel-prompts.sqlite3-journal",
            ]))
            XCTAssertLessThanOrEqual(names.count, 2)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent(PetTravelPromptStore.databaseName).path
            )
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testZeroByteMainIsCorruptButSafeFixedBootstrapOrphansAreCleaned() throws {
        try withStore { store, directory, root in
            let database = root.appendingPathComponent(PetTravelPromptStore.databaseName)
            FileManager.default.createFile(atPath: database.path, contents: Data())
            XCTAssertEqual(chmod(database.path, 0o600), 0)
            XCTAssertThrowsError(try store.load(from: directory))
        }

        for initialized in [false, true] {
            try withStore { store, directory, root in
                let database = root.appendingPathComponent(PetTravelPromptStore.databaseName)
                let bootstrap = root.appendingPathComponent(".pet-travel-prompts.sqlite3.bootstrap")
                if initialized {
                    var installed = false
                    try store.commit(Data(#"{"value":1}"#.utf8), in: directory, didInstall: &installed)
                    try executeSQL(
                        "UPDATE prompt_state SET generation = 0, payload = NULL, digest = NULL WHERE id = 1",
                        at: database
                    )
                    try FileManager.default.moveItem(at: database, to: bootstrap)
                } else {
                    FileManager.default.createFile(atPath: bootstrap.path, contents: Data())
                    XCTAssertEqual(chmod(bootstrap.path, 0o600), 0)
                }
                XCTAssertNil(try store.load(from: directory))
                XCTAssertFalse(FileManager.default.fileExists(atPath: bootstrap.path))

                var installed = false
                let value = Data(#"{"value":2}"#.utf8)
                try store.commit(value, in: directory, didInstall: &installed)
                XCTAssertEqual(try store.load(from: directory), value)
            }
        }
    }

    func testUnsafeBootstrapOrphanFailsClosedWithoutTouchingTarget() throws {
        for hardlink in [false, true] {
            try withStore { store, directory, root in
                let bootstrap = root.appendingPathComponent(".pet-travel-prompts.sqlite3.bootstrap")
                let target = root.appendingPathComponent("bootstrap-target")
                let bytes = Data("untouched".utf8)
                try bytes.write(to: target)
                XCTAssertEqual(chmod(target.path, 0o600), 0)
                if hardlink {
                    try FileManager.default.linkItem(at: target, to: bootstrap)
                } else {
                    try FileManager.default.createSymbolicLink(at: bootstrap, withDestinationURL: target)
                }
                XCTAssertThrowsError(try store.load(from: directory))
                XCTAssertEqual(try Data(contentsOf: target), bytes)
            }
        }
    }

    func testBootstrapReplacementAfterInitializationFailsWithoutInstallingPayload() throws {
        try withStore { store, directory, root in
            let bootstrap = root.appendingPathComponent(".pet-travel-prompts.sqlite3.bootstrap")
            let displaced = root.appendingPathComponent("initialized-bootstrap")
            store.beforeInstallingBootstrap = {
                try FileManager.default.moveItem(at: bootstrap, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: bootstrap)
                XCTAssertEqual(chmod(bootstrap.path, 0o600), 0)
            }

            var installed = false
            XCTAssertThrowsError(
                try store.commit(
                    Data(#"{"value":"must-not-install"}"#.utf8),
                    in: directory,
                    didInstall: &installed
                )
            )
            XCTAssertFalse(installed)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(PetTravelPromptStore.databaseName).path
                )
            )
            XCTAssertNil(try store.load(from: directory))
        }
    }

    func testZeroByteJournalCrashArtifactIsRemovedWithoutTreatingZeroByteMainAsEmpty() throws {
        try withStore { store, directory, root in
            var installed = false
            let value = Data(#"{"value":1}"#.utf8)
            try store.commit(value, in: directory, didInstall: &installed)
            let journal = root.appendingPathComponent(PetTravelPromptStore.databaseName + "-journal")
            FileManager.default.createFile(atPath: journal.path, contents: Data())
            XCTAssertEqual(chmod(journal.path, 0o600), 0)

            XCTAssertEqual(try store.load(from: directory), value)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        }
    }

    func testStrictSchemaVersionDigestAndSingleRowFailClosed() throws {
        for mutation in [
            "PRAGMA ignore_check_constraints = ON; UPDATE prompt_state SET schema_version = 2 WHERE id = 1",
            "UPDATE prompt_state SET digest = printf('%064d', 0) WHERE id = 1",
            "UPDATE prompt_state SET digest = digest || char(0) || 'extra' WHERE id = 1",
            "PRAGMA user_version = 2",
            "CREATE TABLE unexpected(value TEXT)",
            "ALTER TABLE prompt_state ADD COLUMN surprise TEXT",
        ] {
            try withStore { store, directory, root in
                var installed = false
                try store.commit(Data(#"{"value":1}"#.utf8), in: directory, didInstall: &installed)
                let database = root.appendingPathComponent(PetTravelPromptStore.databaseName)
                try executeSQL(mutation, at: database)
                let before = try Data(contentsOf: database)
                XCTAssertThrowsError(try store.load(from: directory))
                XCTAssertEqual(try Data(contentsOf: database), before)
            }
        }
    }

    func testFailureInsideImmediateTransactionRollsBackOldValue() throws {
        try withStore { store, directory, _ in
            var installed = false
            let old = Data(#"{"value":1}"#.utf8)
            try store.commit(old, in: directory, didInstall: &installed)
            store.beforeCommittingTransaction = { throw InjectedFailure.stop }
            installed = false
            XCTAssertThrowsError(
                try store.commit(Data(#"{"value":2}"#.utf8), in: directory, didInstall: &installed)
            )
            XCTAssertFalse(installed)
            XCTAssertEqual(try store.load(from: directory), old)
        }
    }

    func testFailureAfterCommitReportsInstalledAndNewValueSurvivesRelaunch() throws {
        try withStore { store, directory, root in
            var installed = false
            let old = Data(#"{"value":1}"#.utf8)
            try store.commit(old, in: directory, didInstall: &installed)
            store.afterCommittingTransaction = { throw InjectedFailure.stop }
            installed = false
            let new = Data(#"{"value":2}"#.utf8)
            XCTAssertThrowsError(try store.commit(new, in: directory, didInstall: &installed))
            XCTAssertTrue(installed)
            let relaunched = PetTravelPromptStore(
                statePath: root.appendingPathComponent(PetTravelPromptStore.databaseName).path
            )
            XCTAssertEqual(try relaunched.load(from: directory), new)
        }
    }

    func testDatabaseSymlinkHardlinkAndUnsafePermissionsFailClosed() throws {
        for mutation in ["symlink", "hardlink", "permissions"] {
            try withStore { store, directory, root in
                var installed = false
                let value = Data(#"{"value":1}"#.utf8)
                try store.commit(value, in: directory, didInstall: &installed)
                let database = root.appendingPathComponent(PetTravelPromptStore.databaseName)
                let displaced = root.appendingPathComponent("displaced.sqlite3")
                switch mutation {
                case "symlink":
                    try FileManager.default.moveItem(at: database, to: displaced)
                    try FileManager.default.createSymbolicLink(at: database, withDestinationURL: displaced)
                case "hardlink":
                    try FileManager.default.linkItem(at: database, to: displaced)
                default:
                    XCTAssertEqual(chmod(database.path, 0o644), 0)
                }
                XCTAssertThrowsError(try store.load(from: directory))
            }
        }
    }

    func testDatabasePathReplacementAfterOpenFailsClosed() throws {
        try withStore { store, directory, root in
            var installed = false
            let old = Data(#"{"value":1}"#.utf8)
            try store.commit(old, in: directory, didInstall: &installed)
            let database = root.appendingPathComponent(PetTravelPromptStore.databaseName)
            let detached = root.appendingPathComponent("detached.sqlite3")
            let replacement = try Data(contentsOf: database)
            store.afterBeginningTransaction = {
                try FileManager.default.moveItem(at: database, to: detached)
                try replacement.write(to: database, options: .atomic)
                XCTAssertEqual(chmod(database.path, 0o600), 0)
            }
            installed = false
            XCTAssertThrowsError(
                try store.commit(Data(#"{"value":2}"#.utf8), in: directory, didInstall: &installed)
            )
            XCTAssertFalse(installed)
            XCTAssertEqual(try Data(contentsOf: database), replacement)
        }
    }

    func testDatabasePathReplacementBeforeOpenFailsWithoutStartingTransaction() throws {
        try withStore { store, directory, root in
            var installed = false
            let old = Data(#"{"value":1}"#.utf8)
            try store.commit(old, in: directory, didInstall: &installed)
            let database = root.appendingPathComponent(PetTravelPromptStore.databaseName)
            let displaced = root.appendingPathComponent("displaced-before-open.sqlite3")
            let replacement = try Data(contentsOf: database)
            store.beforeOpeningDatabase = {
                try FileManager.default.moveItem(at: database, to: displaced)
                try replacement.write(to: database)
                XCTAssertEqual(chmod(database.path, 0o600), 0)
            }
            installed = false
            XCTAssertThrowsError(
                try store.commit(Data(#"{"value":2}"#.utf8), in: directory, didInstall: &installed)
            )
            XCTAssertFalse(installed)
            XCTAssertEqual(try Data(contentsOf: database), replacement)
        }
    }

    func testUnexpectedOrUnsafeSQLiteSidecarsFailClosed() throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            try withStore { store, directory, root in
                var installed = false
                try store.commit(Data(#"{"value":1}"#.utf8), in: directory, didInstall: &installed)
                let sidecar = root.appendingPathComponent(PetTravelPromptStore.databaseName + suffix)
                let target = root.appendingPathComponent("outside-sidecar")
                try Data("untouched".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
                XCTAssertThrowsError(try store.load(from: directory))
                XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
            }
        }
    }

    func testSQLiteDatabaseAndJournalDescriptorsAreCloseOnExec() throws {
        try withStore { store, directory, _ in
            var installed = false
            store.beforeCommittingTransaction = {
                var matched = 0
                for descriptor in 0..<Int32(getdtablesize()) {
                    var path = [CChar](repeating: 0, count: Int(PATH_MAX))
                    guard fcntl(descriptor, F_GETPATH, &path) == 0 else { continue }
                    let end = path.firstIndex(of: 0) ?? path.endIndex
                    let value = String(decoding: path[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
                    guard value.contains(PetTravelPromptStore.databaseName) else { continue }
                    matched += 1
                    XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0, value)
                }
                XCTAssertGreaterThanOrEqual(matched, 1)
            }
            try store.commit(Data(#"{"value":1}"#.utf8), in: directory, didInstall: &installed)
        }
    }

    func testPersistentJournalModeAndConnectionDefaultAreDeleteAndFull() throws {
        try withStore { store, directory, root in
            var installed = false
            try store.commit(Data(#"{"value":1}"#.utf8), in: directory, didInstall: &installed)
            let database = root.appendingPathComponent(PetTravelPromptStore.databaseName)
            XCTAssertEqual(try queryText("PRAGMA journal_mode", at: database), "delete")
            XCTAssertEqual(try queryInteger("PRAGMA synchronous", at: database), 2)
        }
    }

    private func withStore(
        _ body: (PetTravelPromptStore, Int32, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetTravelPromptStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directory, 0)
        defer { _ = close(directory) }
        let path = root.appendingPathComponent(PetTravelPromptStore.databaseName).path
        try body(PetTravelPromptStore(statePath: path), directory, root)
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw InjectedFailure.stop
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw InjectedFailure.stop
        }
    }

    private func queryText(_ sql: String, at url: URL) throws -> String {
        let (database, statement) = try prepared(sql, at: url)
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { throw InjectedFailure.stop }
        return String(cString: value)
    }

    private func queryInteger(_ sql: String, at url: URL) throws -> Int64 {
        let (database, statement) = try prepared(sql, at: url)
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw InjectedFailure.stop }
        return sqlite3_column_int64(statement, 0)
    }

    private func prepared(_ sql: String, at url: URL) throws -> (OpaquePointer, OpaquePointer) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw InjectedFailure.stop }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_close(database)
            throw InjectedFailure.stop
        }
        return (database, statement)
    }
}
