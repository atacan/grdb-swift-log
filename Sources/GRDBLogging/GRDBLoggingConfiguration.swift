import Logging
import SwiftLogExport

/// The configuration options for the SQLite logging backend installed by ``GRDBLogging``.
public struct GRDBLoggingConfiguration: Sendable {
    // MARK: - Properties

    /// The name of the SQL table records are inserted into unless configured otherwise.
    ///
    /// Also the static table name of ``GRDBLogRecord``, so a database created with the defaults is fully usable
    /// through plain GRDB record APIs.
    public static let defaultTableName = "logs"

    /// Where records are persisted.
    ///
    /// There is deliberately **no default value**: an implicit default would either surprise users with files on disk
    /// (`.file`) or silently discard logs at process exit (`.inMemory`), so every caller has to make an explicit
    /// storage decision.
    public var destination: GRDBDestination

    /// The minimum level a message needs to be logged by handlers created during bootstrap.
    ///
    /// Defaults to `.info`.
    public var level: Logger.Level

    /// Metadata merged into every handler created during bootstrap; individual log calls can override it.
    ///
    /// - Note: Values may be nested (`Logger.MetadataValue.dictionary` or `.array`); ``GRDBLogRecord`` flattens them
    ///   lossily when persisting.
    public var baseMetadata: Logger.Metadata

    /// The name of the SQL table records are inserted into.
    ///
    /// Defaults to `"logs"`. Validated in the initializer against `^[A-Za-z_][A-Za-z0-9_]*$`.
    public var tableName: String

    /// Tuning parameters for the batching processor between the handlers and the exporter.
    ///
    /// Defaults to the `BatchLogRecordProcessorConfiguration` defaults (queue of 2048, 1 second schedule delay,
    /// batches of up to 512).
    public var processorConfiguration: BatchLogRecordProcessorConfiguration

    // MARK: - Initialization

    /// Creates a logging configuration.
    ///
    /// - Parameters:
    ///   - destination: Where records are persisted. Required; see the property's discussion for why there is no
    ///     default.
    ///   - level: The minimum level handled by bootstrapped loggers. Defaults to `.info`.
    ///   - baseMetadata: Metadata attached to every record unless overridden per call. Defaults to `[:]`.
    ///   - tableName: The SQL table name records are inserted into. Must match `[A-Za-z_][A-Za-z0-9_]*`; anything
    ///     else makes the initializer throw. Defaults to `"logs"`.
    ///   - processorConfiguration: Batching behavior of the processor driving the exporter. Defaults to the
    ///     `BatchLogRecordProcessorConfiguration` defaults.
    /// - Throws: ``ValidationError/invalidTableName(_:)`` when `tableName` does not match `[A-Za-z_][A-Za-z0-9_]*`.
    public init(
        destination: GRDBDestination,
        level: Logger.Level = .info,
        baseMetadata: Logger.Metadata = [:],
        tableName: String = GRDBLoggingConfiguration.defaultTableName,
        processorConfiguration: BatchLogRecordProcessorConfiguration = BatchLogRecordProcessorConfiguration()
    ) throws {
        guard Self.isValidTableName(tableName) else {
            throw ValidationError.invalidTableName(tableName)
        }
        self.destination = destination
        self.level = level
        self.baseMetadata = baseMetadata
        self.tableName = tableName
        self.processorConfiguration = processorConfiguration
    }
}

// MARK: - Table name validation

extension GRDBLoggingConfiguration {
    /// Why a configuration could not be created.
    public enum ValidationError: Error, Equatable {
        /// The given table name does not match `[A-Za-z_][A-Za-z0-9_]*`.
        ///
        /// - Parameter name: The rejected table name.
        case invalidTableName(String)
    }

    /// Whether the given name is a safe SQL table name, i.e. matches `^[A-Za-z_][A-Za-z0-9_]*$`.
    ///
    /// The name ends up interpolated into DDL (`CREATE TABLE <name> …`) and DML statements, because SQLite has no
    /// bindable parameters for identifiers. Restricting it to ASCII letters, digits and underscores — and *quoting*
    /// it on top of that — closes both the injection hole and the "accidental keyword or quoted identifier" trap.
    ///
    /// - Parameter name: The candidate table name.
    /// - Returns: `true` when the name may be used as a table name.
    static func isValidTableName(_ name: String) -> Bool {
        func isAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
            ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar)
        }
        func isAsciiLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
            isAsciiLetter(scalar) || ("0" ... "9").contains(scalar)
        }

        var iterator = name.unicodeScalars.makeIterator()
        guard let head = iterator.next(), head == "_" || isAsciiLetter(head) else {
            return false
        }
        while let tail = iterator.next() {
            guard tail == "_" || isAsciiLetterOrDigit(tail) else {
                return false
            }
        }
        return true
    }
}
