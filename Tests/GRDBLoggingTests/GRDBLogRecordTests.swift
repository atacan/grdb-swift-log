import Foundation
import GRDB
import GRDBLogging
import Logging
import Testing

@testable import GRDBLogging

/// Unit tests for ``GRDBLogRecord``: metadata flattening, encoding rules, decoding tolerance and round-trips through a
/// real database.
@Suite struct GRDBLogRecordTests {
    // MARK: - Metadata flattening

    /// - Note: Flattening is documented as lossy; these are the exact renderings the implementation promises.
    @Test func flatteningRendersEveryMetadataValueCase() {
        let record = makeRecord(
            message: "flattening",
            metadata: [
                "plain": "value",
                "convertible": .stringConvertible(42),
                "nested": ["child": "1", "deeper": ["leaf": "true"]],
                "list": .array(["first", "second"]),
            ]
        )
        #expect(
            record.metadata == [
                "plain": "value",
                "convertible": "42",
                "nested.child": "1",
                "nested.deeper.leaf": "true",
                "list": "first,second",
            ]
        )
    }

    // MARK: - Encoding rules

    @Test func encodingOmitsEmptyMetadataKeyAndWritesLowercaseLevelRawValues() throws {
        let object = try jsonObject(from: encodedJSON(makeRecord(message: "no extra fields", level: .warning)))
        #expect(object["metadata"] == nil)  // an empty dictionary is omitted so the column stores NULL
        #expect(object["level"] as? String == "warning")
        #expect(object["level"] as? String != "Warning")
    }

    @Test func encodingOmitsTheIdentifierUntilTheRecordHasBeenStored() throws {
        let freshObject = try jsonObject(from: encodedJSON(makeRecord(message: "fresh")))
        #expect(freshObject["id"] == nil)  // a nil id is omitted so SQLite assigns the auto-incremented key

        var stored = makeRecord(message: "assigned")
        stored.id = 7
        let assignedObject = try jsonObject(from: encodedJSON(stored))
        #expect(assignedObject["id"] as? Int64 == 7)
    }

    @Test func encodingWritesUTCTimestampWithFractionalSecondsAndZSuffix() throws {
        let timestamp = Date(timeIntervalSince1970: 1_768_000_000.25)
        let json = try encodedJSON(makeRecord(message: "timestamp shape", timestamp: timestamp))

        let raw = try jsonObject(from: json)["timestamp"] as? String
        #expect(raw?.count == 24)  // e.g. 2026-01-09T03:46:40.250Z
        #expect(raw?.hasSuffix(".250Z") == true)

        #expect(try decodedRecord(from: json).timestamp == timestamp)
    }

    // MARK: - Decoding tolerance

    @Test func decodingAcceptsTimestampsWithoutFractionalSecondsAndMissingMetadata() throws {
        let json = """
            {"timestamp":"2026-08-21T22:30:23Z","level":"notice","label":"legacy","message":"hello","source":"s","file":"f.swift","function":"f()","line":3}
            """
        let record = try decodedRecord(from: json)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        #expect(record.timestamp == formatter.date(from: "2026-08-21T22:30:23Z"))
        #expect(record.level == .notice)
        #expect(record.label == "legacy")
        #expect(record.message == "hello")
        #expect(record.metadata.isEmpty)  // a missing metadata key decodes to an empty dictionary
        #expect(record.line == 3)
        #expect(record.id == nil)
    }

    @Test func decodingRejectsUnparseableTimestampsAndUnknownLevels() {
        let badTimestamp = """
            {"timestamp":"1768000000","level":"info","label":"l","message":"m","source":"s","file":"f","function":"f","line":1}
            """
        #expect(throws: DecodingError.self) {
            try decodedRecord(from: badTimestamp)
        }

        let badLevel = """
            {"timestamp":"2026-08-21T22:30:23Z","level":"loud","label":"l","message":"m","source":"s","file":"f","function":"f","line":1}
            """
        #expect(throws: DecodingError.self) {
            try decodedRecord(from: badLevel)
        }
    }

    // MARK: - Round-trip through a real database

    @Test func roundTrippingThroughAnInMemoryDatabaseReproducesEveryField() async throws {
        let store = DatabaseStore(destination: .inMemory, tableName: GRDBLoggingConfiguration.defaultTableName)
        let record = makeRecord(
            label: "roundtrip-label",
            message: "full round trip",
            level: .critical,
            metadata: ["key": "value", "nested.key": "2"],
            source: "roundtrip-source",
            file: "/tmp/RoundTrip.swift",
            function: "roundTrip()",
            line: 99,
            timestamp: Date(timeIntervalSince1970: 1_768_000_000.25)
        )

        await store.append([record])

        let fetched = try await store.fetchAllRecords()
        #expect(fetched.count == 1)
        let stored = try #require(fetched.first)
        #expect(stored.id == Int64(1))  // the first auto-incremented primary key was assigned

        var expected = record
        expected.id = stored.id
        #expect(stored == expected)  // every field survives, including the flattened metadata
    }

    @Test func appendingRecordsWithIdenticalTimestampsPreservesInsertionOrderInThePrimaryKey() async throws {
        let store = DatabaseStore(destination: .inMemory, tableName: GRDBLoggingConfiguration.defaultTableName)
        let stamp = Date(timeIntervalSince1970: 1_768_000_000.25)  // deliberately identical for every record
        let messages = (0 ..< 5).map { "tied-timestamp-\($0)" }
        await store.append(messages.map { makeRecord(message: "\($0)", timestamp: stamp) })

        let fetched = try await store.fetchAllRecords()
        #expect(fetched.map(\.message) == messages)  // ORDER BY id, so insertion order wins over the tied timestamps
        #expect(fetched.map(\.id) == [Int64(1), Int64(2), Int64(3), Int64(4), Int64(5)])
        #expect(fetched.allSatisfy { $0.timestamp == stamp })
    }

    @Test func emptyMetadataIsStoredAsNullAndDecodedBackToAnEmptyDictionary() async throws {
        let store = DatabaseStore(destination: .inMemory, tableName: GRDBLoggingConfiguration.defaultTableName)
        await store.append([
            makeRecord(message: "no metadata"),
            makeRecord(message: "with metadata", metadata: ["key": "value"]),
        ])

        let nullMetadataRowCount = try await rawInteger("SELECT COUNT(*) FROM logs WHERE metadata IS NULL", in: store)
        #expect(nullMetadataRowCount == 1)  // only the record without metadata stores NULL

        let rawMetadata = try await rawTexts("SELECT metadata FROM logs WHERE message = 'with metadata'", in: store)
        #expect(rawMetadata == ["{\"key\":\"value\"}"])  // non-empty metadata is a sorted-key JSON object

        let fetched = try await store.fetchAllRecords()
        #expect(fetched.map(\.metadata) == [[:], ["key": "value"]])
    }

    @Test func storedTimestampsAreISO8601UTCStringsWithFractionalSeconds() async throws {
        let store = DatabaseStore(destination: .inMemory, tableName: GRDBLoggingConfiguration.defaultTableName)
        let timestamp = Date(timeIntervalSince1970: 1_768_000_000.25)
        await store.append([makeRecord(message: "stamp", timestamp: timestamp)])

        let rawTimestamp = try await rawTexts("SELECT timestamp FROM logs", in: store).first
        #expect(rawTimestamp?.count == 24)  // e.g. 2026-01-09T03:46:40.250Z
        #expect(rawTimestamp?.hasSuffix(".250Z") == true)  // UTC suffix and millisecond fraction

        let fetched = try await store.fetchAllRecords()
        #expect(fetched.map(\.timestamp) == [timestamp])  // the string parses back to the same instant
    }

    @Test func storedLevelsAreLowercaseRawValues() async throws {
        let store = DatabaseStore(destination: .inMemory, tableName: GRDBLoggingConfiguration.defaultTableName)
        await store.append([makeRecord(message: "loud", level: .warning)])

        let rawLevel = try await rawTexts("SELECT level FROM logs", in: store).first
        #expect(rawLevel == "warning")
    }

    @Test func decodingALegacyRowWrittenWithoutFractionalSecondsOrMetadata() async throws {
        // A file destination lets this test plant the legacy row through its own connection, because the store only
        // ever hands out read connections itself (`read` cannot write) and `append` would encode in today's format.
        let database = TemporaryDatabaseFile(testName: #function)
        let store = DatabaseStore(destination: .file(path: database.path), tableName: GRDBLoggingConfiguration.defaultTableName)
        _ = try await store.fetchAllRecords()  // sets the schema up lazily, exactly like an append would

        let writer = try DatabaseQueue(path: database.path)
        try await writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO logs \
                    (timestamp, level, label, message, metadata, source, file, function, line) \
                    VALUES ('2026-08-21T22:30:23Z', 'notice', 'legacy', 'hello', NULL, 's', 'f.swift', 'f()', 3)
                    """
            )
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let fetched = try await store.fetchAllRecords()
        #expect(fetched.count == 1)
        let record = try #require(fetched.first)
        #expect(record.timestamp == formatter.date(from: "2026-08-21T22:30:23Z"))  // the plain-format fallback parses
        #expect(record.level == .notice)
        #expect(record.metadata.isEmpty)  // a NULL metadata column decodes to an empty dictionary
        #expect(record.id == Int64(1))
        #expect(record.line == 3)
    }
}
