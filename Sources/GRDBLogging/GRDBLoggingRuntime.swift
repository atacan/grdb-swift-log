import SwiftLogExport

/// A running SQLite logging pipeline intended for Apple application lifecycles.
///
/// Keep this object alive for as long as logging is needed. Use ``forceFlush()`` when an application backgrounds but
/// may resume, and ``shutdown()`` only for terminal lifecycle transitions.
public final class GRDBLoggingRuntime: Sendable {
    typealias Processor = BatchLogRecordProcessor<GRDBLogRecord, GRDBLogRecordExporter, ContinuousClock>

    private actor State {
        let runner: Task<Void, Never>
        var isShutDown = false

        init(processor: Processor) {
            runner = Task {
                try? await processor.run()
            }
        }

        func shutdown() async {
            if !isShutDown {
                isShutDown = true
                runner.cancel()
            }
            await runner.value
        }
    }

    private let processor: Processor
    private let state: State

    /// Creates and starts a runtime around an existing processor.
    ///
    /// This initializer avoids global `LoggingSystem.bootstrap` state in package tests.
    init(processor: Processor) {
        self.processor = processor
        state = State(processor: processor)
    }

    /// Waits until all records emitted before this call have completed the processor's export policy.
    ///
    /// Logging remains operational afterward. If terminal shutdown has already begun, this operation simply returns.
    public func forceFlush() async {
        try? await processor.forceFlush()
    }

    /// Terminally closes ingress, drains all accepted records, shuts down the exporter, and waits for completion.
    ///
    /// Repeated and concurrent calls are safe and wait for the same shutdown operation. Records emitted after
    /// shutdown begins are not expected to persist.
    public func shutdown() async {
        await state.shutdown()
    }
}
