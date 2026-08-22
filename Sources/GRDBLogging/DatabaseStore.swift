import GRDB

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// An actor that owns the SQLite writer and appends whole batches of log records inside a single write transaction.
///
/// The actor isolation removes the need for locks: every append, sync and close is serialized by the actor. The
/// writer is created *lazily* on the first append — `.file` destinations open a `DatabasePool` in WAL mode,
/// `.inMemory` destinations a `DatabaseQueue` — so an exporter that never receives a record never touches disk. The
/// schema is ensured with a `DatabaseMigrator` right after the writer is created.
///
/// - Note: All failure handling happens *inside* the store. A failed append drops its batch, counts the drop and
///   emits a one-time notice to standard error; errors are never rethrown, mirroring how SwiftLogExport's
///   ``BatchLogRecordProcessor`` swallows exporter errors.
actor DatabaseStore {
    // MARK: - Properties

    /// The table name every record of this store is inserted into and read from.
    ///
    /// Interpolated into DDL and DML statements; ``GRDBLoggingConfiguration`` validates it against
    /// `^[A-Za-z_][A-Za-z0-9_]*$` before a store is ever created.
    let tableName: String

    /// Where records are persisted; decides which writer flavor is created lazily.
    private let destination: GRDBDestination

    /// The currently open writer, or `nil` until the first append touches storage (writers open lazily).
    private var writer: (any DatabaseWriter)?

    /// Whether ``close()`` has been called; appends arriving afterwards are silently ignored.
    private var closed = false

    /// The number of batches dropped so far, counted for the one-time drop notice.
    private var droppedBatchCount = 0

    /// Whether the one-time drop notice has already been emitted.
    private var hasEmittedDropNotice = false

    /// The default table name used when a configuration does not select one.
    static let defaultTableName = GRDBLoggingConfiguration.defaultTableName

    /// The identifier of the single schema migration.
    private static let migrationIdentifier = "v1"

    // MARK: - Initialization

    /// Creates a store persisting records into the given destination and table.
    ///
    /// Neither the database nor its schema is touched until the first append (see ``append(_:)``).
    ///
    /// - Parameters:
    ///   - destination: Where records are persisted: a WAL-mode database file or a private in-memory database.
    ///   - tableName: The SQL table name records are inserted into. Must match `[A-Za-z_][A-Za-z0-9_]*`; the
    ///     configuration validates this before creating a store, since the name is interpolated into statements.
    init(destination: GRDBDestination, tableName: String) {
        self.destination = destination
        self.tableName = tableName
    }

    // MARK: - Appending

    /// Inserts the given batch inside one write transaction, giving the batch exactly one durability point.
    ///
    /// An empty batch returns without touching storage, so an idle pipeline never creates a file or opens a database.
    /// Appends arriving after ``close()`` are silently ignored, since shutdown has already happened.
    ///
    /// The write deliberately uses the *synchronous* GRDB API: the asynchronous one checks task cancellation and
    /// would drop every batch drained during graceful shutdown, because the processor's `run()` flushes its buffer
    /// from an already-cancelled task. Blocking the actor for the duration of one small transaction is the same
    /// trade-off the POSIX `write(2)` in comparable backends makes.
    ///
    /// - Parameter records: The records to persist, in insertion order; each becomes exactly one row whose
    ///   auto-incremented primary key preserves that order.
    func append(_ records: [GRDBLogRecord]) {
        guard !closed, !records.isEmpty else { return }

        do {
            let writer = try setUpWriterIfNeeded()
            let tableName = self.tableName
            try writer.write { db in
                for record in records {
                    try Self.insert(record, into: db, tableName: tableName)
                }
            }
        } catch {
            noteDroppedBatch(reason: "\(error)")
        }
    }

    // MARK: - Flushing and shutting down

    /// A no-op: every append already commits its own transaction, so there is nothing extra to flush.
    ///
    /// Exists so the exporter's `forceFlush()` maps onto the same lifecycle as backends with buffered writes.
    func sync() {}

    /// Marks the store closed; further appends are silently ignored.
    ///
    /// GRDB has no explicit close API: dropping the last reference to the pool or queue releases its connections and
    /// file handles. This method therefore only stops future appends.
    func close() {
        guard !closed else { return }
        closed = true
    }

    // MARK: - Introspection

    /// Returns every stored record, oldest insertion first (ordered by the auto-incremented primary key).
    ///
    /// Internal on purpose: tests use it to assert exactly what landed in storage without reaching into the writer.
    /// Reading also sets up storage lazily, exactly like appending does, and uses the synchronous GRDB API for the
    /// same cancellation reasoning documented on ``append(_:)``.
    ///
    /// - Returns: The stored records ordered by their primary key.
    /// - Throws: When storage cannot be set up or read.
    func fetchAllRecords() throws -> [GRDBLogRecord] {
        let tableName = self.tableName
        return try read { db in
            try GRDBLogRecord.fetchAll(
                db,
                sql: "SELECT * FROM \(tableName.quotedDatabaseIdentifier) ORDER BY id"
            )
        }
    }

    /// Reads from the underlying database, setting up storage lazily exactly like ``append(_:)`` does.
    ///
    /// Internal escape hatch letting tests run raw queries (for example asserting raw column encodings) without
    /// exposing the mutable writer itself. Results must be `Sendable`, since they cross the actor boundary.
    ///
    /// - Parameter body: The read-only work to run against the connection.
    /// - Returns: Whatever `body` returns.
    /// - Throws: When storage cannot be set up or `body` throws.
    func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        let writer = try setUpWriterIfNeeded()
        return try writer.read(body)
    }

    // MARK: - Private

    /// Returns the writer, creating it and applying the schema migration on first use.
    ///
    /// `.file` destinations open a `DatabasePool`, which GRDB runs in write-ahead logging (WAL) mode so concurrent
    /// readers never block the writer. The parent directory of the path must already exist; it is not created, since
    /// a logging backend must not invent directory structures next to whatever it was pointed at. `.inMemory`
    /// destinations open a private `DatabaseQueue`.
    ///
    /// - Returns: The writer to persist through.
    /// - Throws: When opening the database or running the migration fails.
    private func setUpWriterIfNeeded() throws -> any DatabaseWriter {
        if let writer {
            return writer
        }
        let newWriter: any DatabaseWriter
        switch destination {
        case .file(let path):
            newWriter = try DatabasePool(path: path)
        case .inMemory:
            newWriter = try DatabaseQueue()
        }
        try Self.migrator(tableName: tableName).migrate(newWriter)
        writer = newWriter
        return newWriter
    }

    /// Builds the migrator ensuring the schema for the given table exists.
    ///
    /// - Parameter tableName: The table name interpolated into the migration's DDL; validated upstream.
    /// - Returns: A migrator registering the `"v1"` schema creation.
    private static func migrator(tableName: String) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(migrationIdentifier) { db in
            try db.create(table: tableName) { definition in
                // INTEGER PRIMARY KEY AUTOINCREMENT keeps rows ordered by insertion time even when timestamps tie.
                definition.autoIncrementedPrimaryKey("id")
                definition.column("timestamp", .text).notNull()
                definition.column("level", .text).notNull()
                definition.column("label", .text).notNull()
                definition.column("message", .text).notNull()
                definition.column("metadata", .text)
                definition.column("source", .text).notNull()
                definition.column("file", .text).notNull()
                definition.column("function", .text).notNull()
                definition.column("line", .integer).notNull()
            }
        }
        return migrator
    }

    /// Inserts one record into the named table.
    ///
    /// Column values are produced by the very helpers the record's hand-written `Codable` conformance uses, so the
    /// encoded representation and the schema cannot drift apart. The statement targets `tableName` explicitly instead
    /// of going through `record.insert(db)`: GRDB resolves the latter from a *static* table name, which cannot follow
    /// a runtime-configured one. The identifier is quoted even though it is regex-validated upstream.
    ///
    /// - Parameters:
    ///   - record: The record to insert; a `nil` ``GRDBLogRecord/id`` lets SQLite assign the next auto-incremented key.
    ///   - db: The write connection inside the caller's transaction.
    ///   - tableName: The table to insert into.
    /// - Throws: Any SQLite error, which aborts the surrounding transaction and drops the whole batch.
    private static func insert(_ record: GRDBLogRecord, into db: Database, tableName: String) throws {
        try db.execute(
            sql: """
                INSERT INTO \(tableName.quotedDatabaseIdentifier) \
                (timestamp, level, label, message, metadata, source, file, function, line) \
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                GRDBLogRecord.storedTimestamp(record.timestamp),
                record.level.rawValue,
                record.label,
                record.message,
                GRDBLogRecord.storedMetadata(record.metadata),
                record.source,
                record.file,
                record.function,
                record.line,
            ]
        )
    }

    /// Records a dropped batch and emits a one-time notice to standard error.
    ///
    /// The notice goes straight to descriptor 2 rather than through C's `stderr`: on Linux/Glibc that global is
    /// imported as shared mutable state, which strict concurrency forbids referencing from actor-isolated code.
    ///
    /// - Parameter reason: A short human-readable explanation for the drop.
    private func noteDroppedBatch(reason: String) {
        droppedBatchCount += 1
        guard !hasEmittedDropNotice else { return }
        hasEmittedDropNotice = true
        let message =
            "GRDBLogging: dropped \(droppedBatchCount) log batch so far (\(reason)); further write failures are silent.\n"
        _ = Self.wroteAll([UInt8](message.utf8), to: STDERR_FILENO)
    }

    /// Best-effort synchronous write of the whole buffer to the given descriptor.
    ///
    /// - Parameters:
    ///   - buffer: The bytes to write.
    ///   - descriptor: The descriptor to write to, expected to be standard error.
    /// - Returns: `true` when the whole buffer landed, `false` otherwise.
    private static func wroteAll(_ buffer: [UInt8], to descriptor: Int32) -> Bool {
        guard !buffer.isEmpty else { return true }
        return buffer.withUnsafeBufferPointer { bytes in
            guard let start = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, start + offset, size_t(bytes.count - offset))
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}
