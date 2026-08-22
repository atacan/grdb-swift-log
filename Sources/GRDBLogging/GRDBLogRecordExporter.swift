import SwiftLogExport

/// A ``LogRecordExporter`` that persists every batch of ``GRDBLogRecord``s as rows in a GRDB-managed SQLite database.
///
/// Each record of a batch becomes exactly one row, and the whole batch is inserted inside a single write transaction,
/// giving one durability point per batch. Rows are appended to the table named by the destination's configuration;
/// the schema itself is ensured lazily on first export (see `DatabaseStore`).
///
/// - Note: Export failures are handled internally by the store (the batch is dropped with a one-time stderr notice);
///   this exporter never throws from `export(_:)`, mirroring how SwiftLogExport's ``BatchLogRecordProcessor``
///   swallows exporter errors.
public struct GRDBLogRecordExporter: LogRecordExporter, Sendable {
    // MARK: - Properties

    /// The record type exported by this exporter.
    public typealias T = GRDBLogRecord

    /// The store all records are persisted through.
    ///
    /// Internal on purpose: tests drive it directly to assert what landed in storage, which is the only way to read
    /// back an `.inMemory` destination (a second in-memory database would be a different database).
    let store: DatabaseStore

    // MARK: - Initialization

    /// Creates an exporter persisting into the default ``GRDBLoggingConfiguration/defaultTableName`` table of the
    /// given destination.
    ///
    /// - Parameter destination: A SQLite database file opened in WAL mode, or a private in-memory database.
    public init(destination: GRDBDestination) {
        self.init(destination: destination, tableName: GRDBLoggingConfiguration.defaultTableName)
    }

    /// Creates an exporter persisting into the given table of the given destination.
    ///
    /// - Parameters:
    ///   - destination: A SQLite database file opened in WAL mode, or a private in-memory database.
    ///   - tableName: The SQL table name records are inserted into. Must match `[A-Za-z_][A-Za-z0-9_]*`; invalid
    ///     names trap here, since ``GRDBLoggingConfiguration`` normally validates them before an exporter is built.
    public init(destination: GRDBDestination, tableName: String) {
        precondition(
            GRDBLoggingConfiguration.isValidTableName(tableName),
            "GRDBLogging: '\(tableName)' is not a valid table name"
        )
        self.store = DatabaseStore(destination: destination, tableName: tableName)
    }

    // MARK: - LogRecordExporter

    /// Persists the given batch as rows of the configured table, preserving the record order *within the batch*.
    ///
    /// Across batches, primary keys can invert relative to emission order — upstream drains split large buffers into
    /// concurrently exported chunks — so chronological reads should sort by `timestamp, id`.
    ///
    /// - Parameter batch: The records to persist; each becomes exactly one row whose auto-incremented primary key
    ///   preserves the batch order.
    /// - Throws: Never for records produced by this package; persistence failures are handled internally by the
    ///   store, which drops the affected batch instead of surfacing an error.
    public func export(_ batch: some Collection<T> & Sendable) async throws {
        guard !batch.isEmpty else { return }
        await store.append(Array(batch))
    }

    /// Ensures previously exported batches are committed and durable against process crashes.
    ///
    /// A no-op in practice: every batch already commits its own transaction on append. Note that `.file` destinations
    /// are WAL-mode pools running with `PRAGMA synchronous = NORMAL`, so commits survive process crashes; only a full
    /// OS crash or power loss before the next checkpoint can lose them.
    public func forceFlush() async throws {
        await store.sync()
    }

    /// Closes the underlying store; further exports are ignored afterwards.
    public func shutdown() async {
        await store.close()
    }
}
