import Logging
import SwiftLogExport

/// The namespace for installing SQLite-backed logging into swift-log.
public enum GRDBLogging {
    /// Installs a SQLite logging backend into swift-log and returns the processor that drives it.
    ///
    /// The backend routes every log call through a `BatchLogRecordProcessor` into a ``GRDBLogRecordExporter``
    /// persisting one row per record in the table named by ``GRDBLoggingConfiguration/tableName`` of the configured
    /// ``GRDBLoggingConfiguration/destination``.
    ///
    /// **Call this before the first `Logger` use** in your process, ideally at the very top of your entry point:
    ///
    /// ```swift
    /// let processor = GRDBLogging.bootstrap(
    ///     try GRDBLoggingConfiguration(destination: .file(path: "logs/app.sqlite"))
    /// )
    /// ```
    ///
    /// **You MUST drive the returned processor**, or buffered records are never flushed and never written. Prefer
    /// running it in a `ServiceGroup` so graceful shutdown drains the buffer and closes the store:
    ///
    /// ```swift
    /// let serviceGroup = ServiceGroup(services: [processor])
    /// try await serviceGroup.run()
    /// ```
    ///
    /// If you do not use `ServiceLifecycle`, run it on a task instead (`Task { try await processor.run() }`) and
    /// cancel that task on shutdown for a final flush.
    ///
    /// - Warning: Calling this function more than once traps, because `LoggingSystem.bootstrap` traps when invoked
    ///   twice in one process. Tests should construct `LoggingHandler` and `BatchLogRecordProcessor` instances
    ///   directly instead of bootstrapping globally.
    ///
    /// - Parameter configuration: Where and how to log. The `destination` is required; `.info` level records in a
    ///   `"logs"` table are the remaining defaults.
    /// - Returns: The batching processor feeding the exporter. Keep it alive and run it as shown above.
    @discardableResult
    public static func bootstrap(
        _ configuration: GRDBLoggingConfiguration
    ) -> BatchLogRecordProcessor<GRDBLogRecord, GRDBLogRecordExporter, ContinuousClock> {
        let exporter = GRDBLogRecordExporter(
            destination: configuration.destination,
            tableName: configuration.tableName
        )
        let processor = BatchLogRecordProcessor<GRDBLogRecord, GRDBLogRecordExporter, ContinuousClock>(
            exporter: exporter,
            configuration: configuration.processorConfiguration
        )

        LoggingSystem.bootstrap { label in
            LoggingHandler(
                label: label,
                processor: processor,
                level: configuration.level,
                metadata: configuration.baseMetadata
            )
        }

        return processor
    }
}
