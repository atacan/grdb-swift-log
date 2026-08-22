import Foundation
import GRDBLogging
import Logging
import SwiftLogExport
import Testing

/// Tests for ``GRDBLoggingConfiguration``: defaults, validation of the interpolated table name and memberwise wiring.
@Suite struct GRDBLoggingConfigurationTests {
    // MARK: - Defaults

    @Test func configurationDefaultsMatchTheDocumentedValues() throws {
        let configuration = try GRDBLoggingConfiguration(destination: .inMemory)
        #expect(configuration.destination == .inMemory)  // the destination is required, so it round-trips unchanged
        #expect(configuration.level == .info)
        #expect(configuration.baseMetadata.isEmpty)
        #expect(configuration.tableName == "logs")
        #expect(configuration.tableName == GRDBLoggingConfiguration.defaultTableName)
        #expect(configuration.processorConfiguration.maximumQueueSize == 2048)
        #expect(configuration.processorConfiguration.scheduleDelay == .seconds(1))
        #expect(configuration.processorConfiguration.maximumExportBatchSize == 512)
        #expect(configuration.processorConfiguration.exportTimeout == .seconds(30))
    }

    @Test func configurationKeepsExplicitlyProvidedValues() throws {
        let configuration = try GRDBLoggingConfiguration(
            destination: .file(path: "/tmp/app.sqlite"),
            level: .debug,
            baseMetadata: ["service": "tests"],
            tableName: "app_events"
        )
        #expect(configuration.destination == .file(path: "/tmp/app.sqlite"))
        #expect(configuration.level == .debug)
        #expect(configuration.baseMetadata == ["service": "tests"])
        #expect(configuration.tableName == "app_events")
    }

    // MARK: - Table name validation

    @Test func configurationRejectsInvalidTableNames() {
        let rejectedNames = [
            "",  // empty
            "1logs",  // must not start with a digit
            "has space",
            "has-dash",
            "has.dot",
            "logs; DROP TABLE users",  // the injection shape the validation exists to close
            "café",  // non-ASCII letters are excluded as well
        ]
        for name in rejectedNames {
            #expect(throws: GRDBLoggingConfiguration.ValidationError.invalidTableName(name)) {
                _ = try GRDBLoggingConfiguration(destination: .inMemory, tableName: name)
            }
        }
    }

    @Test func configurationAcceptsValidTableNames() throws {
        let acceptedNames = ["logs", "_private", "a", "Log_2", "z9_", "LOGS", "select"]
        for name in acceptedNames {
            let configuration = try GRDBLoggingConfiguration(destination: .inMemory, tableName: name)
            #expect(configuration.tableName == name)
        }
        // "select" above is deliberately accepted: SQL keywords are safe because the store quotes every identifier.
    }
}
