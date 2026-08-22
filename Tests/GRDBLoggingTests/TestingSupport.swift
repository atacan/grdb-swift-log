import Foundation
import GRDB
import GRDBLogging
import Logging
import SwiftLogExport
import Testing

@testable import GRDBLogging

/// Convenience alias for the concrete processor type installed by ``GRDBLogging/bootstrap`` and driven throughout the tests.
typealias GRDBLogRecordProcessor = BatchLogRecordProcessor<GRDBLogRecord, GRDBLogRecordExporter, ContinuousClock>

// MARK: - Record construction

/// Creates a ``GRDBLogRecord`` with sensible defaults so individual tests only spell out the fields they care about.
///
/// - Parameters:
///   - label: The logger label. Defaults to `"test-label"`.
///   - message: The log message.
///   - level: The severity. Defaults to `.info`.
///   - metadata: The metadata tree to flatten onto the record. Defaults to empty.
///   - source: The source string. Defaults to `"test-source"`.
///   - file: The file path recorded on the record. Defaults to `"/tmp/TestFile.swift"`.
///   - function: The function name recorded on the record. Defaults to `"testFunction()"`.
///   - line: The line recorded on the record. Defaults to `42`.
///   - timestamp: The record timestamp. Defaults to a millisecond-aligned constant, since encoding truncates
///     sub-millisecond precision.
/// - Returns: The freshly built record.
func makeRecord(
    label: String = "test-label",
    message: Logger.Message,
    level: Logger.Level = .info,
    metadata: Logger.Metadata = [:],
    source: String = "test-source",
    file: String = "/tmp/TestFile.swift",
    function: String = "testFunction()",
    line: UInt = 42,
    timestamp: Date = Date(timeIntervalSince1970: 1_768_000_000.25)
) -> GRDBLogRecord {
    GRDBLogRecord(
        label: label,
        message: message,
        level: level,
        metadata: metadata,
        source: source,
        file: file,
        function: function,
        line: line,
        timestamp: timestamp
    )
}

// MARK: - JSON encoding

/// Encodes a single record the way the hand-written `Codable` conformance does: one compact, key-sorted JSON object.
///
/// The database columns are produced by the very same helpers this encoding exercises (`storedTimestamp`,
/// `storedMetadata`), so a JSON assertion pins the column layout without reimplementing either.
///
/// - Parameter record: The record to encode.
/// - Returns: The JSON object as a single-line string.
/// - Throws: When encoding fails, which cannot happen for well-formed records.
func encodedJSON(_ record: GRDBLogRecord) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(record), as: UTF8.self)
}

/// Parses an encoded record line into its top-level JSON keys and values.
///
/// - Parameter json: One encoded ``GRDBLogRecord`` as produced by ``encodedJSON(_:)``.
/// - Returns: The parsed object; absent keys are simply missing from the dictionary.
/// - Throws: When the string is not valid JSON.
func jsonObject(from json: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
        return [:]
    }
    return object
}

/// Decodes an encoded record back into a ``GRDBLogRecord`` through the hand-written initializer.
///
/// - Parameter json: One encoded record as produced by ``encodedJSON(_:)``.
/// - Returns: The decoded record.
/// - Throws: When decoding fails.
func decodedRecord(from json: String) throws -> GRDBLogRecord {
    let decoder = JSONDecoder()
    return try decoder.decode(GRDBLogRecord.self, from: Data(json.utf8))
}

// MARK: - Waiting for asynchronous pipelines

/// Flushes the processor repeatedly until storage holds at least the expected number of rows.
///
/// Records travel from `onEmit` through an `AsyncStream` into the processor's buffer asynchronously, so a single
/// `forceFlush()` right after logging can legitimately observe an empty buffer. Polling keeps the test independent of
/// scheduling latency while bounding the wait.
///
/// - Parameters:
///   - store: The store backing the processor's exporter; read back after every flush attempt.
///   - processor: The processor draining into the store.
///   - expectedRecordCount: The number of rows to wait for.
///   - timeout: How long to keep polling before giving up and returning what is there. Defaults to 10 seconds.
/// - Returns: The stored records ordered by their primary key; possibly fewer than `expectedRecordCount` when the
///   timeout elapsed first.
/// - Throws: When flushing or reading fails.
func flushedRecords(
    from store: DatabaseStore,
    processor: GRDBLogRecordProcessor,
    expectedRecordCount: Int,
    timeout: Duration = .seconds(10)
) async throws -> [GRDBLogRecord] {
    let deadline = ContinuousClock.now + timeout
    var records: [GRDBLogRecord] = []
    while ContinuousClock.now < deadline {
        try await processor.forceFlush()
        records = try await store.fetchAllRecords()
        if records.count >= expectedRecordCount {
            return records
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    return records
}

// MARK: - Raw column reads

/// Reads the raw text of one column for every row matching the given query, in query order.
///
/// Raw reads assert the *stored* column encodings (timestamp format, lowercase level text) rather than their decoded
/// projections. Scalars are extracted inside the closure because GRDB's `Row` is not `Sendable` and cannot cross the
/// store's actor boundary.
///
/// - Parameters:
///   - sql: A `SELECT` whose first column holds the texts to return.
///   - store: The store to read through; it sets its writer up lazily exactly like appending does.
/// - Returns: The first column of every matched row.
/// - Throws: When storage cannot be set up or the query fails.
func rawTexts(_ sql: String, in store: DatabaseStore) async throws -> [String] {
    try await store.read { db in
        try String.fetchAll(db, sql: sql)
    }
}

/// Reads a single integer value, such as a row count or a presence check against `sqlite_master`.
///
/// - Parameters:
///   - sql: A `SELECT` yielding exactly one integer, e.g. `SELECT COUNT(*) …`.
///   - store: The store to read through; it sets its writer up lazily exactly like appending does.
/// - Returns: The integer, or `nil` when the query yields no row.
/// - Throws: When storage cannot be set up or the query fails.
func rawInteger(_ sql: String, in store: DatabaseStore) async throws -> Int? {
    try await store.read { db in
        try Int.fetchOne(db, sql: sql)
    }
}

// MARK: - Temporary files

/// A unique temporary SQLite database file that deletes itself when the test finishes with it.
///
/// The deletion in `deinit` runs no matter how the test ends, including failed expectations and thrown errors, and
/// removes the `-wal`/`-shm` sidecar files GRDB creates next to a WAL-mode database as well.
final class TemporaryDatabaseFile {
    /// The full URL of the temporary database file.
    let url: URL

    /// The full path of the temporary database file, suitable for ``GRDBDestination/file(path:)``.
    var path: String {
        self.url.path
    }

    /// Creates a uniquely named database path inside the temporary directory.
    ///
    /// Neither the file nor its parent directory (the system temporary directory, which exists) is created; stores open
    /// their database lazily on the first append.
    ///
    /// - Parameter testName: The name of the requesting test, embedded for diagnosability of leftover files.
    init(testName: String) {
        let fileName = "grdb-logging-\(testName)-\(ProcessInfo.processInfo.globallyUniqueString).sqlite"
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
