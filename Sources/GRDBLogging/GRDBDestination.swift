/// Where log records are persisted.
public enum GRDBDestination: Equatable, Sendable {
    /// Persist to the SQLite database file at the given path, opened as a `DatabasePool` in write-ahead logging (WAL)
    /// mode, so concurrent readers never block the writer and vice versa.
    ///
    /// - Parameter path: The file system path of the SQLite database file. The file is created when missing; the
    ///   parent directory must already exist and is *not* created.
    case file(path: String)

    /// Persist to a private in-memory SQLite database opened as a `DatabaseQueue`.
    ///
    /// - Note: Ideal for tests and previews. The contents exist only as long as the process holds the database open
    ///   and vanish with it; nothing is ever written to disk.
    case inMemory
}
