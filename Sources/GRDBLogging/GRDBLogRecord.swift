import Foundation
import GRDB
import Logging
import SwiftLogExport

/// A ``LogRecord`` that captures a single log event and knows how to persist itself as one row of a GRDB database.
///
/// All values are stored as flat `Sendable` types so the record can be compared with `==`, fetched back from the
/// database with `FetchableRecord`, and encoded by any `JSONEncoder`.
///
/// - Note: The ``metadata`` stored on this record is a *flattened* `[String: String]` projection of swift-log's
///   recursive `Logger.Metadata` tree. See ``init(label:message:level:metadata:source:file:function:line:timestamp:)``
///   for the exact rules.
///
/// - Note: The hand-written `Codable` conformance defines the column encoding shared by the database schema and the
///   JSON representation: the `timestamp` column holds an ISO-8601 UTC string *with* fractional seconds, the `level`
///   column holds the lowercase `Logger.Level` raw value, the nullable `metadata` column holds a JSON object (absent
///   when there is no metadata), and `id` is omitted while it is still `nil` so SQLite assigns the auto-incremented
///   primary key.
public struct GRDBLogRecord: Codable, LogRecord, FetchableRecord, PersistableRecord, Equatable, Sendable {
    // MARK: - Properties

    /// The auto-incremented primary key assigned by SQLite on insertion, or `nil` until the record has been stored.
    ///
    /// An explicit `INTEGER PRIMARY KEY AUTOINCREMENT` (instead of an implicit rowid) guarantees that rows fetched
    /// ordered by ``id`` come back in insertion order even when several records share the same ``timestamp``.
    public var id: Int64?

    /// The moment the log record was created.
    ///
    /// - Note: Persisted with *millisecond* precision (ISO-8601 fractional seconds); anything finer is truncated,
    ///   so a fetched-back record equals its original only when the timestamp is millisecond-aligned.
    public var timestamp: Date

    /// The severity of the log message.
    public var level: Logger.Level

    /// The label of the `Logger` that produced this record.
    public var label: String

    /// The log message rendered as a plain string.
    public var message: String

    /// A flattened, string-only projection of the effective metadata (see the initializer's discussion).
    public var metadata: [String: String]

    /// The `source` parameter passed to the logging call, as forwarded by swift-log.
    public var source: String

    /// The file the log call was issued from.
    public var file: String

    /// The function the log call was issued from.
    public var function: String

    /// The line the log call was issued from.
    public var line: UInt

    // MARK: - Initialization

    /// Creates a log record from the raw pieces of a swift-log logging call.
    ///
    /// This is the initializer required by ``LogRecord``; it is called by SwiftLogExport's ``LoggingHandler`` for every
    /// emitted log event. The `message` is converted with `String(describing:)` and the `metadata` is flattened:
    ///
    /// - `.string` values are stored as-is.
    /// - `.stringConvertible` values are rendered with `String(describing:)`.
    /// - `.dictionary` values are recursed into, joining the nested keys to their parent key with a `.` separator
    ///   (`"parent.child"`).
    /// - `.array` values are rendered element-wise and joined with `,`.
    ///
    /// - Warning: The flattening is **lossy**. Nested keys can collide (later entries overwrite earlier ones), array
    ///   structure is reduced to a comma-separated string, and dictionary ordering is not preserved.
    ///
    /// - Parameters:
    ///   - label: The label identifying the logger instance that produced the record.
    ///   - message: The logged message.
    ///   - level: The severity of the logged message.
    ///   - metadata: The effective metadata of the logging call (handler, provider and call-site metadata merged).
    ///   - source: The source reported by the logging call.
    ///   - file: The file the logging call was issued from.
    ///   - function: The function the logging call was issued from.
    ///   - line: The line the logging call was issued from.
    ///   - timestamp: The moment the log record was created.
    public init(
        label: String,
        message: Logger.Message,
        level: Logger.Level,
        metadata: Logger.Metadata,
        source: String,
        file: String,
        function: String,
        line: UInt,
        timestamp: Date
    ) {
        self.id = nil
        self.label = label
        self.message = String(describing: message)
        self.level = level
        self.metadata = Self.flattenedMetadata(metadata)
        self.source = source
        self.file = file
        self.function = function
        self.line = line
        self.timestamp = timestamp
    }

    // MARK: - Metadata flattening

    /// Renders a metadata tree into a single-level `[String: String]` dictionary.
    ///
    /// Top-level `.dictionary` entries are recursed into using dotted key paths; every other value is rendered directly.
    ///
    /// - Parameter metadata: The metadata tree to flatten.
    /// - Returns: The flattened projection. Lossy; see the initializer's discussion.
    private static func flattenedMetadata(_ metadata: Logger.Metadata) -> [String: String] {
        var flattened: [String: String] = [:]
        for (key, value) in metadata {
            flatten(key: key, value: value, into: &flattened)
        }
        return flattened
    }

    /// Recursively flattens a single metadata entry into the given result dictionary.
    ///
    /// - Parameters:
    ///   - key: The (possibly already joined) key path for the entry.
    ///   - value: The metadata value to store under `key`.
    ///   - result: The dictionary accumulating the flattened entries.
    private static func flatten(
        key: String,
        value: Logger.MetadataValue,
        into result: inout [String: String]
    ) {
        switch value {
        case .string(let stringValue):
            result[key] = stringValue
        case .stringConvertible(let convertible):
            result[key] = String(describing: convertible)
        case .dictionary(let dictionary):
            for (nestedKey, nestedValue) in dictionary {
                flatten(key: "\(key).\(nestedKey)", value: nestedValue, into: &result)
            }
        case .array(let values):
            // Sorted for deterministic output; dictionaries are unordered.
            result[key] = values.map(renderedValue).joined(separator: ",")
        }
    }

    /// Renders an arbitrary metadata value as a plain string.
    ///
    /// Used for elements inside `.array` values, which cannot be represented as separate keys.
    ///
    /// - Parameter value: The metadata value to render.
    /// - Returns: The rendered string.
    private static func renderedValue(_ value: Logger.MetadataValue) -> String {
        switch value {
        case .string(let stringValue):
            return stringValue
        case .stringConvertible(let convertible):
            return String(describing: convertible)
        case .dictionary(let dictionary):
            let sortedPairs = dictionary.sorted { $0.key < $1.key }.map { "\($0.key)=\(renderedValue($0.value))" }
            return sortedPairs.joined(separator: ",")
        case .array(let values):
            return values.map(renderedValue).joined(separator: ",")
        }
    }
}

// MARK: - Codable

extension GRDBLogRecord {
    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case level
        case label
        case message
        case metadata
        case source
        case file
        case function
        case line
    }

    /// Encodes the record with the exact column layout of the database schema.
    ///
    /// The `id` key is omitted while it is still `nil`, and the `metadata` key is omitted entirely when there is no
    /// metadata, so both map to a `NULL`/auto-assigned column value in the database and to an absent key in JSON.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let id {
            try container.encode(id, forKey: .id)
        }
        try container.encode(Self.storedTimestamp(timestamp), forKey: .timestamp)
        try container.encode(level.rawValue, forKey: .level)
        try container.encode(label, forKey: .label)
        try container.encode(message, forKey: .message)
        if let encodedMetadata = Self.storedMetadata(metadata) {
            try container.encode(encodedMetadata, forKey: .metadata)
        }
        try container.encode(source, forKey: .source)
        try container.encode(file, forKey: .file)
        try container.encode(function, forKey: .function)
        try container.encode(line, forKey: .line)
    }

    /// Creates a record from its encoded representation, whether a database row or a JSON object.
    ///
    /// Decoding of the timestamp is tolerant: it first tries ISO-8601 with fractional seconds, then plain ISO-8601
    /// (`.withInternetDateTime`, both UTC). Any other shape fails decoding. A missing or `NULL` `metadata` value
    /// decodes to an empty dictionary, and a missing `id` decodes to `nil`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decodeIfPresent(Int64.self, forKey: .id)

        let rawTimestamp = try container.decode(String.self, forKey: .timestamp)
        guard
            let timestamp = Self.timestampFormatterWithFractionalSeconds.date(from: rawTimestamp)
                ?? Self.timestampFormatter.date(from: rawTimestamp)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "Expected an ISO-8601 UTC date string, got '\(rawTimestamp)'."
            )
        }
        self.timestamp = timestamp

        let rawLevel = try container.decode(String.self, forKey: .level)
        guard let level = Logger.Level(rawValue: rawLevel) else {
            throw DecodingError.dataCorruptedError(
                forKey: .level,
                in: container,
                debugDescription: "Unknown Logger.Level raw value '\(rawLevel)'."
            )
        }
        self.level = level

        self.label = try container.decode(String.self, forKey: .label)
        self.message = try container.decode(String.self, forKey: .message)

        if let rawMetadata = try container.decodeIfPresent(String.self, forKey: .metadata) {
            guard let metadata = try? Self.metadataDecoder.decode([String: String].self, from: Data(rawMetadata.utf8)) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .metadata,
                    in: container,
                    debugDescription: "Expected a JSON object with string values, got '\(rawMetadata)'."
                )
            }
            self.metadata = metadata
        } else {
            self.metadata = [:]
        }

        self.source = try container.decode(String.self, forKey: .source)
        self.file = try container.decode(String.self, forKey: .file)
        self.function = try container.decode(String.self, forKey: .function)
        self.line = try container.decode(UInt.self, forKey: .line)
    }
}

// MARK: - Column encoding

extension GRDBLogRecord {
    /// The name of the database table records are persisted to by default.
    ///
    /// Matches ``GRDBLoggingConfiguration/defaultTableName``. A configuration selecting another table name cannot be
    /// reflected here, because `TableRecord` table names are *static*: ``DatabaseStore`` therefore writes rows with
    /// an explicitly named statement instead of going through `record.insert(db)`.
    public static var databaseTableName: String {
        GRDBLoggingConfiguration.defaultTableName
    }

    /// Renders a date as the fixed-width ISO-8601 UTC string stored in the `timestamp` column.
    ///
    /// Fixed-width UTC strings sort chronologically as plain strings, so `ORDER BY timestamp` is correct even without
    /// parsing.
    ///
    /// - Parameter date: The date to render.
    /// - Returns: The ISO-8601 UTC string, always including fractional seconds, e.g. `2026-08-21T12:00:00.123Z`.
    static func storedTimestamp(_ date: Date) -> String {
        timestampFormatterWithFractionalSeconds.string(from: date)
    }

    /// Encodes metadata as the JSON text stored in the nullable `metadata` column.
    ///
    /// - Parameter metadata: The flattened metadata of a record.
    /// - Returns: A JSON object string, or `nil` for empty metadata, which is stored as `NULL`.
    static func storedMetadata(_ metadata: [String: String]) -> String? {
        guard !metadata.isEmpty else { return nil }
        guard let data = try? metadataJSONEncoder.encode(metadata) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Formats and parses timestamps as ISO-8601 UTC strings *with* fractional seconds, e.g. `2026-08-21T12:00:00.123Z`.
    ///
    /// `ISO8601DateFormatter` is thread-safe on all supported platforms (macOS 10.9+ / iOS 7+), so a single shared
    /// instance is used for every record; the unsafe annotation only silences the missing `Sendable` conformance in
    /// the SDK headers.
    private nonisolated(unsafe) static let timestampFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Parses timestamps written without fractional seconds when the fractional-second parse attempt fails.
    ///
    /// - Note: Only used for *decoding*; encoding always includes fractional seconds.
    private nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Encodes the `metadata` dictionary into JSON text, with sorted keys so identical metadata always produces the
    /// identical column value.
    private static let metadataJSONEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Decodes the JSON text of the `metadata` column back into a dictionary.
    private static let metadataDecoder: JSONDecoder = JSONDecoder()
}
