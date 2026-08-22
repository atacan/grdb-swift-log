import Foundation
import GRDB
import GRDBLogging
import Testing

@testable import GRDBLogging

/// Tests for ``GRDBLogRecordExporter`` and the underlying ``DatabaseStore``: row layout, lifecycle and destinations.
///
/// - Note: The tests reach the internal `store` seam with `@testable import`, since it is the only way to read back an
///   `.inMemory` destination — a second in-memory database would be a different database.
@Suite struct GRDBLogRecordExporterTests {
    // MARK: - Row layout

    @Test func exportPersistsExactlyOneRowPerRecordInOrder() async throws {
        let exporter = GRDBLogRecordExporter(destination: .inMemory)

        let records = [
            makeRecord(message: "one"),
            makeRecord(message: "two\nlines"),
            makeRecord(message: "three"),
        ]
        try await exporter.export(records)

        let stored = try await exporter.store.fetchAllRecords()
        #expect(stored.count == 3)  // exactly one row per record, no partial writes, no duplicates
        #expect(stored.map(\.message) == ["one", "two\nlines", "three"])  // embedded newlines stay inside the row
        #expect(stored.map(\.id) == [Int64(1), Int64(2), Int64(3)])  // batch order is preserved by the primary key
    }

    @Test func exportingAnEmptyBatchCreatesNoFile() async throws {
        let database = TemporaryDatabaseFile(testName: #function)
        let exporter = GRDBLogRecordExporter(destination: .file(path: database.path))

        try await exporter.export([])

        // The store opens its writer lazily; an empty batch must not even trigger the open, so neither the main
        // database file nor its WAL sidecar files may exist.
        #expect(!FileManager.default.fileExists(atPath: database.path))
        #expect(!FileManager.default.fileExists(atPath: database.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: database.path + "-shm"))
    }

    // MARK: - Lifecycle

    @Test func shutdownIgnoresFurtherExports() async throws {
        let exporter = GRDBLogRecordExporter(destination: .inMemory)

        try await exporter.export([makeRecord(message: "before shutdown")])
        await exporter.shutdown()
        try await exporter.export([makeRecord(message: "after shutdown")])

        let stored = try await exporter.store.fetchAllRecords()
        #expect(stored.count == 1)
        #expect(stored.map(\.message) == ["before shutdown"])
    }

    @Test func forceFlushKeepsCommittedRowsAvailableWithoutDuplicatingThem() async throws {
        let exporter = GRDBLogRecordExporter(destination: .inMemory)
        try await exporter.export([makeRecord(message: "committed")])

        try await exporter.forceFlush()  // a no-op in practice; must not fail nor re-write anything

        let stored = try await exporter.store.fetchAllRecords()
        #expect(stored.map(\.message) == ["committed"])
    }

    // MARK: - Destinations

    @Test func exportingTargetsTheConfiguredTable() async throws {
        let exporter = GRDBLogRecordExporter(destination: .inMemory, tableName: "app_events")

        try await exporter.export([makeRecord(message: "routed"), makeRecord(message: "second")])

        let stored = try await exporter.store.fetchAllRecords()
        #expect(stored.map(\.message) == ["routed", "second"])  // the DML reached the configured table

        let logsTableRowCount = try await rawInteger(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'logs'",
            in: exporter.store
        )
        #expect(logsTableRowCount == 0)  // the default table must not spring into existence alongside it
    }

    @Test func fileDestinationPersistsAcrossConnections() async throws {
        let database = TemporaryDatabaseFile(testName: #function)
        let writer = GRDBLogRecordExporter(destination: .file(path: database.path))
        try await writer.export([
            makeRecord(message: "durable", level: .error),
            makeRecord(message: "also durable"),
        ])

        // A second store over the same file sees the committed rows, so the WAL pool really wrote them to disk.
        let reader = DatabaseStore(
            destination: .file(path: database.path),
            tableName: GRDBLoggingConfiguration.defaultTableName
        )
        let stored = try await reader.fetchAllRecords()
        #expect(stored.map(\.message) == ["durable", "also durable"])
        #expect(stored.map(\.level) == [.error, .info])
    }
}
