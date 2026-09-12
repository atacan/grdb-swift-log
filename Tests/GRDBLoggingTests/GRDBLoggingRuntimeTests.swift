import GRDBLogging
import Logging
import SwiftLogExport
import Testing

@testable import GRDBLogging

@Suite struct GRDBLoggingRuntimeTests {
    private func makeRuntime(
        batchSize: UInt = 512
    ) -> (GRDBLoggingRuntime, Logger, DatabaseStore) {
        let exporter = GRDBLogRecordExporter(destination: .inMemory)
        let processor = GRDBLogRecordProcessor(
            exporter: exporter,
            configuration: BatchLogRecordProcessorConfiguration(
                maximumQueueSize: 10_000,
                scheduleDelay: .seconds(60),
                maximumExportBatchSize: batchSize
            )
        )
        let runtime = GRDBLoggingRuntime(processor: processor)
        let logger = Logger(label: "runtime-tests") { _ in
            LoggingHandler(label: "runtime-tests", processor: processor, level: .trace)
        }
        return (runtime, logger, exporter.store)
    }

    @Test func immediateEmitThenForceFlushIsABarrierAndLoggingContinues() async throws {
        let (runtime, logger, store) = makeRuntime()

        logger.info("before flush")
        await runtime.forceFlush()
        #expect(try await store.fetchAllRecords().map(\.message) == ["before flush"])

        logger.info("after flush")
        await runtime.forceFlush()
        #expect(try await store.fetchAllRecords().map(\.message) == ["before flush", "after flush"])

        await runtime.shutdown()
    }

    @Test func forceFlushDrainsEveryBatch() async throws {
        let (runtime, logger, store) = makeRuntime(batchSize: 7)
        let messages = (0 ..< 100).map { "record-\($0)" }

        for message in messages { logger.info("\(message)") }
        await runtime.forceFlush()

        #expect(try await store.fetchAllRecords().map(\.message).sorted() == messages.sorted())
        await runtime.shutdown()
    }

    @Test func immediateEmitThenShutdownDrainsEveryBatch() async throws {
        let (runtime, logger, store) = makeRuntime(batchSize: 5)
        let messages = (0 ..< 80).map { "shutdown-record-\($0)" }

        for message in messages { logger.info("\(message)") }
        await runtime.shutdown()

        #expect(try await store.fetchAllRecords().map(\.message).sorted() == messages.sorted())
    }

    @Test func repeatedConcurrentForceFlushesComplete() async throws {
        let (runtime, logger, store) = makeRuntime(batchSize: 3)
        for index in 0 ..< 20 { logger.info("flush-\(index)") }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 10 { group.addTask { await runtime.forceFlush() } }
        }

        #expect(try await store.fetchAllRecords().count == 20)
        await runtime.shutdown()
    }

    @Test func repeatedConcurrentShutdownsWaitForTheSameDrain() async throws {
        let (runtime, logger, store) = makeRuntime(batchSize: 4)
        for index in 0 ..< 75 { logger.info("shutdown-\(index)") }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 10 { group.addTask { await runtime.shutdown() } }
        }
        await runtime.shutdown()

        #expect(try await store.fetchAllRecords().count == 75)
    }
}
