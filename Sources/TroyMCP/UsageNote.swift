/// What one tool call reports about itself for the usage log: the project it worked in, counts
/// and record numbers. Never titles, bodies, search words or folder paths.
///
/// The server hands a fresh note to each call and writes it to the log afterwards, also when the
/// call fails. On the command line the note is filled and dropped.
public final class UsageNote: @unchecked Sendable {
    public var projectID: Int64?
    public private(set) var fields: [String: JSON] = [:]

    public init() {}

    public func set(_ key: String, _ value: JSON) { fields[key] = value }

    /// The fields as the text of a JSON object.
    public var detail: String { JSON.object(fields).text }
}
