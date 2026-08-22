import Foundation
import GRDBLogging
import Logging
@_spi(Testing) import SwiftLogExport
import Testing

@testable import GRDBLogging

/// End-to-end tests driving ``LoggingHandler`` through a real ``BatchLogRecordProcessor`` into an in-memory database.
///
/// No test here calls `LoggingSystem.bootstrap` (it traps when called twice per process); handlers and processors are
/// constructed directly instead.
@Suite struct BatchPipelineEndToEndTests {
    // MARK: - Handler to database

    @Test func loggingThroughAProcessorProducesExactlyNQueryableRowsOrderedById() async throws {
        let exporter = GRDBLogRecordExporter(destination: .inMemory)
        let store = exporter.store  // the only handle onto the exporter's private in-memory database
        // A one-minute schedule delay guarantees nothing is written except by the explicit flushes below.
        let processor = GRDBLogRecordProcessor(
            exporter: exporter,
            configuration: BatchLogRecordProcessorConfiguration(scheduleDelay: .seconds(60))
        )
        let runner = Task { try await processor.run() }  // run() must be active for records to reach the buffer

        let handler = LoggingHandler(
            label: "e2e-label",
            processor: processor,
            level: .debug,
            metadata: ["service": "grdb-tests", "host": "unit-test"]
        )
        let logger = Logger(label: "e2e-label") { _ in handler }

        let firstCallLine = #line + 1
        logger.info("starting up", metadata: ["attempt": .stringConvertible(1)])
        logger.warning("disk almost full\nplease clean\t\"var\"", metadata: ["path": "/var"])
        logger.error("failed to persist", metadata: ["service": "override-service"], source: "persistence")
        logger.debug("verbose detail")
        logger.notice("all done")
        let lastCallLine = #line - 1

        let records = try await flushedRecords(from: store, processor: processor, expectedRecordCount: 5)
        #expect(records.count == 5)  // exactly one row per record, no partial writes, no duplicates
        #expect(await processor.bufferedRecordCount == 0)  // every record left the buffer into the database

        #expect(
            records.map(\.message) == [
                "starting up",
                "disk almost full\nplease clean\t\"var\"",  // multi-line messages survive intact in their TEXT column
                "failed to persist",
                "verbose detail",
                "all done",
            ]
        )
        #expect(records.map(\.level) == [.info, .warning, .error, .debug, .notice])

        let identifiers = records.compactMap(\.id)
        #expect(identifiers.count == records.count)  // every row received its auto-incremented primary key
        #expect(identifiers == identifiers.sorted())  // fetched ordered by id, i.e. in insertion order

        // Base handler metadata merges with per-call metadata; a per-call value overrides the base value.
        #expect(records[0].metadata == ["service": "grdb-tests", "host": "unit-test", "attempt": "1"])
        #expect(records[1].metadata["path"] == "/var")
        #expect(records[1].metadata["service"] == "grdb-tests")
        #expect(records[2].metadata["service"] == "override-service")
        #expect(records[4].metadata == ["service": "grdb-tests", "host": "unit-test"])

        for record in records {
            #expect(record.label == "e2e-label")
            #expect(record.function == #function)
            #expect(record.line >= UInt(firstCallLine) && record.line <= UInt(lastCallLine))
            #expect(record.file.hasSuffix("BatchPipelineEndToEndTests.swift"))
            #expect(record.timestamp.timeIntervalSinceNow.magnitude < 60)  // stamped at emit time, not at flush time
        }
        #expect(records[2].source == "persistence")  // the explicitly passed source reaches the record

        runner.cancel()
        _ = try? await runner.value
    }

    // MARK: - Graceful shutdown drain

    @Test func cancellingRunDrainsBufferedRecordsIntoTheDatabase() async throws {
        let exporter = GRDBLogRecordExporter(destination: .inMemory)
        let store = exporter.store
        let processor = GRDBLogRecordProcessor(
            exporter: exporter,
            configuration: BatchLogRecordProcessorConfiguration(scheduleDelay: .seconds(60))  // never fires during the test
        )
        let runner = Task { try await processor.run() }
        let logger = Logger(label: "drain-label") { _ in
            LoggingHandler(label: "drain-label", processor: processor, level: .info)
        }

        let messages = (0 ..< 5).map { "drain-me-\($0)" }
        for message in messages {
            logger.info("\(message)")
        }

        // Records reach the processor's buffer asynchronously via an AsyncStream whose unconsumed elements are
        // discarded when the consuming task is cancelled, so wait until every record has actually crossed into the
        // buffer before cancelling. SwiftLogExport's Testing SPI (``BatchLogRecordProcessor/bufferedRecordCount``)
        // makes this deterministic — no sleep-and-hope timing margin that could flake on a loaded CI runner. The
        // one-minute schedule delay guarantees the *only* writer to the database is the drain on the graceful-shutdown
        // path of run(), which is exactly what this test exercises.
        let deadline = ContinuousClock.now + .seconds(10)
        while await processor.bufferedRecordCount < messages.count, ContinuousClock.now < deadline {
            await Task.yield()  // let run()'s consumer task drain the stream into the buffer
        }
        #expect(await processor.bufferedRecordCount == messages.count)  // all five crossed before cancellation
        let storedBeforeCancellation = try await store.fetchAllRecords()
        #expect(storedBeforeCancellation.isEmpty)  // nothing may be written before cancellation

        runner.cancel()
        do {
            try await runner.value
        } catch is CancellationError {
            // expected when run() surfaces its own cancellation
        } catch {
            Issue.record("run() failed with an unexpected error: \(error)")
        }

        // The drain on graceful shutdown was the only writer; it must have persisted every logged record.
        let records = try await store.fetchAllRecords()
        #expect(records.count == messages.count)
        #expect(records.map(\.message) == messages)
    }
}
