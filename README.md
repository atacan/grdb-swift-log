# GRDBLogging

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fatacan%2Fgrdb-swift-log%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/atacan/grdb-swift-log)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fatacan%2Fgrdb-swift-log%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/atacan/grdb-swift-log)

A [swift-log](https://github.com/apple/swift-log) backend that persists your application logs as rows in a [SQLite](https://www.sqlite.org/) database through [GRDB](https://github.com/groue/GRDB.swift) — queryable forever — built on top of [SwiftLogExport](https://github.com/atacan/SwiftLogExport).

## Features

- **Queryable logs**: every record becomes exactly one row (`id`, `timestamp`, `level`, `label`, `message`, `metadata`, `source`, `file`, `function`, `line`) in a table you can `SELECT`, join, aggregate and prune with plain SQL — long after the log call happened.
- **SQLite persistence with concurrent readers**: `.file` destinations open a `DatabasePool` in write-ahead logging (WAL) mode, so readers never block the writer and vice versa — tail or inspect your logs while the app keeps logging.
- **Batched transactions**: each export batch is inserted inside one write transaction — a single durability point per batch instead of per record. An `INTEGER PRIMARY KEY AUTOINCREMENT` preserves insertion order *within* one batch, even when records share a timestamp — batches larger than `maximumExportBatchSize` are drained as concurrent chunks, so ids can invert across chunk boundaries. For chronological reads, sort with `ORDER BY timestamp DESC, id DESC` (see [Querying your logs](#querying-your-logs)).
- **Built on the SwiftLogExport pipeline**: records flow through a batching `BatchLogRecordProcessor` into a `GRDBLogRecordExporter`, so you get queueing, scheduled exports and graceful drain for free.
- **Stable, machine-readable fields**: ISO-8601 UTC timestamps *with* fractional seconds (fixed-width strings that sort chronologically as plain text), lowercase levels, metadata as a JSON object stored in a nullable column (`NULL` when empty).
- **Apple lifecycle-friendly**: `start(_:)` synchronously installs the backend and starts the async batching processor; its runtime handle provides explicit flush and terminal shutdown barriers.
- **ServiceLifecycle-friendly**: `bootstrap(_:)` remains available for applications that want to own the processor in a `ServiceGroup`.
- **Testing-friendly**: nothing forces a global bootstrap — construct exporters, processors, handlers, or a runtime around an existing processor in tests, while keeping once-per-process global state isolated.
- **Strict-concurrency clean**: the sink is an actor (no locks), every public type is `Sendable`.

## Requirements

- Swift 6.1+
- macOS 13+, iOS 16+, watchOS 9+, tvOS 16+, or visionOS 1+
- **Apple platforms only, by design.** Linux is *deliberately* unsupported: this package targets Apple's platforms exclusively (and only macOS is covered by CI, see [.github/workflows/test.yml](.github/workflows/test.yml)). Windows is not supported either.
- [apple/swift-log](https://github.com/apple/swift-log) 1.5+ and [SwiftLogExport](https://github.com/atacan/SwiftLogExport) revision `b8f0b7747fa1a50444bc86e3950cf411645ff2ce` ([groue/GRDB.swift](https://github.com/groue/GRDB.swift) 7.0+) are declared as dependencies; add GRDB yourself too if you want to query the database.

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
    .package(
        url: "https://github.com/atacan/SwiftLogExport.git",
        revision: "b8f0b7747fa1a50444bc86e3950cf411645ff2ce"
    ),
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    .package(url: "https://github.com/atacan/grdb-swift-log.git", from: "1.0.0"),
]

targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "Logging", package: "swift-log"),
            // Only needed if you query the database yourself (see below).
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "GRDBLogging", package: "grdb-swift-log"),
        ]
    )
]
```

## Usage

Call either `GRDBLogging.start(_:)` or `GRDBLogging.bootstrap(_:)` once at the very top of your entry point, **before** the first `Logger` is created. Calling either entry point more than once traps (swift-log semantics). `start(_:)` is nonthrowing; the `try` in examples applies to configuration construction, which validates the table name.

### Apple app lifecycle — `start(_:)`

Apple lifecycle callbacks do not need to be async. `GRDBLogging.start(_:)` synchronously installs the swift-log backend and starts the async batching processor for you. Only explicit lifecycle operations such as `forceFlush()` and `shutdown()` are async, so synchronous callbacks can bridge to them with `Task { ... }`.

Flush when an app may resume; shut down only for a genuinely terminal lifecycle. `forceFlush()` persists everything emitted before the call and leaves logging operational. `shutdown()` is terminal: it closes ingress, drains accepted records, and waits for the exporter to close. Records emitted afterward are not expected to persist. Never block the main thread with a semaphore while waiting for either operation; launch a task or use the platform's background-execution or deferred-termination mechanism.

#### SwiftUI

This uses the one-argument `onChange` overload supported by iOS 16 and macOS 13:

```swift
import SwiftUI
import GRDBLogging

@main
struct ExampleApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let logging: GRDBLoggingRuntime

    init() {
        let configuration = try! GRDBLoggingConfiguration(
            destination: .file(path: logDatabasePath) // its parent directory must already exist
        )
        logging = GRDBLogging.start(configuration)
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .onChange(of: scenePhase) { phase in
                guard phase == .background else { return }
                Task { await logging.forceFlush() }
            }
    }
}
```

Backgrounding flushes instead of shutting down because the same process may resume. On macOS, an application that needs a graceful termination handshake can use `@NSApplicationDelegateAdaptor` with the AppKit pattern below.

#### UIKit

```swift
import UIKit
import GRDBLogging

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var logging: GRDBLoggingRuntime!

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        do {
            let configuration = try GRDBLoggingConfiguration(
                destination: .file(path: logDatabasePath) // its parent directory must already exist
            )
            logging = GRDBLogging.start(configuration)
            return true
        } catch {
            print("Failed to configure logging: \(error)")
            return false
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Task { await logging.forceFlush() }
    }
}
```

If the flush needs extra time before suspension, use a UIKit background task:

```swift
func applicationDidEnterBackground(_ application: UIApplication) {
    let taskID = application.beginBackgroundTask(withName: "Flush logs")
    Task {
        await logging.forceFlush()
        application.endBackgroundTask(taskID)
    }
}
```

Do not rely on `applicationWillTerminate(_:)` as the primary iOS persistence mechanism.

#### AppKit

```swift
import AppKit
import GRDBLogging

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var logging: GRDBLoggingRuntime!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let configuration = try GRDBLoggingConfiguration(
                destination: .file(path: logDatabasePath) // its parent directory must already exist
            )
            logging = GRDBLogging.start(configuration)
        } catch {
            fatalError("Failed to configure logging: \(error)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await logging.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
```

AppKit can use terminal `shutdown()` here because `.terminateLater` supplies an explicit deferred-termination handshake.

### ServiceLifecycle — `bootstrap(_:)`

Running the processor inside a `ServiceGroup` means graceful shutdown drains every buffered record through the exporter and closes the store. `ServiceLifecycle` comes in transitively once any of your dependencies provides it.

```swift
import Logging
import ServiceLifecycle // available transitively; declare it yourself if nothing else pulls it in
import GRDBLogging

// 1. Install the backend BEFORE creating your first `Logger`.
var configuration = try GRDBLoggingConfiguration(
    destination: .file(path: "logs/app.sqlite") // the `logs/` directory must already exist
)
configuration.level = .debug
configuration.baseMetadata = ["host": "web-1"]
let processor = GRDBLogging.bootstrap(configuration)

// 2. Log as usual through swift-log.
let logger = Logger(label: "app")
logger.info("Application started")
logger.warning("Cache miss rate high", metadata: ["rate": "0.87"])

// 3. Run until shutdown; cancellation drains the buffer into the database, then closes the store.
let serviceGroup = ServiceGroup(services: [processor])
try await serviceGroup.run()
```

### Manual task driving — `bootstrap(_:)`

If you do not use `ServiceLifecycle`, run the processor on a task and cancel that task when your application shuts down — `run()` reacts to cancellation by exporting everything still queued and shutting the exporter down.

```swift
import Logging
import GRDBLogging

let configuration = try GRDBLoggingConfiguration(
    destination: .file(path: "logs/app.sqlite"),
    level: .info
)
let processor = GRDBLogging.bootstrap(configuration)

let processorTask = Task { try await processor.run() }

let logger = Logger(label: "app")
logger.error("Payment provider unreachable")

// On terminal shutdown: cancellation closes ingress, drains accepted records, and closes the store.
processorTask.cancel()
try? await processorTask.value
```

### Querying your logs

Because storage is a plain SQLite table, your logs stay queryable long after they were written. Recent errors, newest first:

```swift
import GRDB
import GRDBLogging

// Opening the same file again is safe: WAL mode lets this reader run next to the writer.
let database = try DatabasePool(path: "logs/app.sqlite")

let recentErrors = try await database.read { db in
    try GRDBLogRecord
        .filter(sql: "level = ?", arguments: ["error"])
        .order(sql: "timestamp DESC, id DESC")
        .limit(50)
        .fetchAll(db)
}

for record in recentErrors {
    print("[\(record.level.rawValue)] \(record.message)")
}
```

`ORDER BY timestamp DESC, id DESC` matters: timestamps have millisecond precision, so the auto-incremented `id` breaks ties back into emission order (within a single export batch; very large drains are chunked, so across batches this ordering is approximate). Aggregation works just as well:

```sql
SELECT strftime('%Y-%m-%d', timestamp) AS day, count(*) AS errors
FROM logs WHERE level = 'error' GROUP BY day ORDER BY day;
```

`GRDBLogRecord.databaseTableName` follows the default `"logs"` table. If you configured another `tableName`, address it with an explicit `SQLRequest<GRDBLogRecord>` instead of the static record API — and do **not** write through `GRDBLogRecord`'s own persistence methods (`insert`, `update`, `delete` from `PersistableRecord`): those always resolve against the statically declared `"logs"` table regardless of your configuration, so rows must go through the exporter/store path instead, which interpolates the configured name into its statements.

### Sample row

Each log call becomes exactly one row. For

```swift
logger.error("Payment provider unreachable", metadata: ["payment.provider": "stripe"])
```

the `logs` table gains:

| Column | Value |
| --- | --- |
| `id` | `42` |
| `timestamp` | `'2026-08-21T09:30:12.481Z'` |
| `level` | `'error'` |
| `label` | `'app'` |
| `message` | `'Payment provider unreachable'` |
| `metadata` | `'{"payment.provider":"stripe"}'` |
| `source` | `'Checkout'` |
| `file` | `'/Sources/App/Checkout.swift'` |
| `function` | `'submitOrder()'` |
| `line` | `42` |

Rows without metadata store `NULL` in `metadata`, which decodes back to an empty dictionary. The schema is created lazily by an initial schema migration registered per table name the first time anything is written — an exporter that never receives a record never touches disk.

### Mixing with other backends

Prefer human-readable logs on the console while also persisting every record as a row in SQLite? Build the pipeline yourself and hand both handlers to a `MultiplexLogHandler`. This bypasses `GRDBLogging.bootstrap` entirely, which is why no global bootstrap trap applies here — just make sure something drives the processor.

```swift
import Logging
import SwiftLogExport
import GRDBLogging

let exporter = GRDBLogRecordExporter(destination: .file(path: "logs/app.sqlite"))
let processor = BatchLogRecordProcessor<GRDBLogRecord, GRDBLogRecordExporter, ContinuousClock>(
    exporter: exporter,
    configuration: BatchLogRecordProcessorConfiguration(scheduleDelay: .seconds(5))
)

LoggingSystem.bootstrap { label in
    let consoleHandler = StreamLogHandler.standardOutput(label: label)
    let databaseHandler = LoggingHandler(label: label, processor: processor)
    return MultiplexLogHandler([consoleHandler, databaseHandler])
}

// Don't forget the driver here either.
Task { try await processor.run() }
```

## Advanced Configuration

Every knob lives on `GRDBLoggingConfiguration`:

| Option | Default | Effect |
| --- | --- | --- |
| `destination` | *(none — required)* | `.file(path:)` opens (or creates) the SQLite database at the given path as a WAL-mode `DatabasePool`; the parent directory must already exist and is **not** created. `.inMemory` opens a private in-memory database — ideal for tests and previews, but its contents vanish with the process. There is deliberately no default: an implicit one would either surprise you with files or silently discard your logs. |
| `level` | `.info` | Minimum level handled by every logger created during bootstrap. Per-logger levels can still be changed afterwards via `Logger.logLevel`. |
| `baseMetadata` | `[:]` | Merged into every record unless a logging call overrides a key. Nested values are flattened lossily to strings (see [Limitations](#limitations)). |
| `tableName` | `"logs"` | SQL table created by the initial schema migration and written to. Validated against `^[A-Za-z_][A-Za-z0-9_]*$` at initialization; invalid names throw, since the name ends up interpolated into DDL/DML statements (SQLite cannot bind identifiers). |
| `processorConfiguration.scheduleDelay` | `.seconds(1)` | Maximum delay between two exports — effectively your **flush latency** for quiet periods. Lower it if other processes read the database live. |
| `processorConfiguration.maximumExportBatchSize` | `512` | Maximum number of records handed to the exporter in one export call (one transaction); larger queues are drained in chunks of this size. It does **not** trigger earlier exports — timing is governed by `scheduleDelay` and the `maximumQueueSize` threshold. |
| `processorConfiguration.maximumQueueSize` | `2048` | Number of records buffered between exports; when the buffer count reaches this size an export is triggered immediately instead of waiting for `scheduleDelay`. It is not a hard cap — records are never dropped, so a sustained burst can grow the buffer further. |
| `processorConfiguration.exportTimeout` | `.seconds(30)` | How long a single export may run before it is cancelled. |

For example, a low-latency logger with a larger burst buffer and its own table:

```swift
let configuration = try GRDBLoggingConfiguration(
    destination: .file(path: "/var/log/myapp/log.sqlite"),
    level: .debug,
    baseMetadata: ["service": "api-gateway"],
    tableName: "request_logs",
    processorConfiguration: BatchLogRecordProcessorConfiguration(
        maximumQueueSize: 4096,
        scheduleDelay: .milliseconds(250),
        maximumExportBatchSize: 1024,
        exportTimeout: .seconds(10)
    )
)
GRDBLogging.bootstrap(configuration)
```

You can also flush eagerly without waiting for the schedule: `try await processor.forceFlush()` is an ingress barrier that drains every record accepted before the call through the exporter. Because each batch already commits its own transaction, records are committed and durable against process crashes the moment the call returns — WAL mode does not fsync every commit (`DatabasePool` runs with `PRAGMA synchronous = NORMAL`), so an operating-system crash or power loss may still lose the most recent commits until SQLite writes a checkpoint.

## Limitations

- **Metadata is flattened lossily.** `Logger.MetadataValue.dictionary` entries become dotted keys (`"parent.child"`), `.array` values collapse into comma-separated strings, and colliding keys overwrite each other. Structured metadata fidelity beyond strings is out of scope.
- **No retention policy yet.** The table grows forever — there is no built-in rotation, compression or pruning. Prune with your own SQL (`DELETE FROM logs WHERE timestamp < …`) or drop old database files; a retention option may arrive in a future version.
- **`.inMemory` vanishes with the process.** In-memory databases live only as long as the process holds them open and are ideal for tests and previews — never for records you want tomorrow.
- **The parent directory must exist.** `.file(path:)` creates the database file when missing, but never invents directory structures next to whatever it was pointed at.
- **Export errors are swallowed by design.** SwiftLogExport's `BatchLogRecordProcessor` discards errors thrown by exporters, so the store handles failures internally: a failed transaction drops its whole batch and emits a one-time notice to standard error; further failures stay silent. Losing logs never takes your application down.
- **Apple platforms only.** Linux support was deliberately scoped out, and Windows is unsupported.

## Acknowledgements

- Powered by [SwiftLogExport](https://github.com/atacan/SwiftLogExport) — the `LogRecord`, `LogRecordExporter` and `BatchLogRecordProcessor` pipeline this package plugs into, whose batching machinery draws inspiration from the [swift-otel](https://github.com/swift-otel/swift-otel) project.
- Built on [groue/GRDB.swift](https://github.com/groue/GRDB.swift) — the SQLite toolkit providing `DatabasePool` (WAL), migrations and `FetchableRecord`.
- And of course [apple/swift-log](https://github.com/apple/swift-log) for the `Logger` API itself.

## License

This package is available under the [MIT License](LICENSE).
