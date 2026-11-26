import Foundation
import TroyCore

/// A working folder that is in no git repository, for the rule that its first save creates its
/// project too.
///
/// A repository names its own root. A plain folder does not, so the folder a session runs in is
/// taken as it is, and the rule only says where Troy does not do that. A project claims every
/// plain folder below its link that has no link of its own, so a folder that holds projects must
/// not become one: the home folder, a drive, and the folders right in them (`~/dev`, `~/Documents`).
/// The rest of the rule leaves out places nobody keeps work in. Depth is a stand-in for intent:
/// `~/dev/clients` qualifies as readily as `~/dev/app`, and a save there takes the client folders
/// below it that have no project yet. Repositories are never taken that way (`Store.matchFolders`).
enum PlainFolder {
    /// Why Troy makes no project for a folder on its own.
    enum Refusal: Equatable {
        /// The home folder, a drive, or a folder right in one: a place that holds projects.
        case holdsProjects
        /// Not a place work is kept in: missing, hidden, a system, temporary or application folder,
        /// or a client's folder for chats without a project.
        case notForWork
    }

    /// Why `folder` gets no project on its first save, or nil when it does.
    ///
    /// Every test is made on the path the file system resolves the folder to, so a symlink into an
    /// excluded place is excluded as well. At least two levels below the home folder, the drive or
    /// the volume, and nothing hidden on the way, the drive's and the volume's own names included.
    static func refusal(for folder: String, home: String = NSHomeDirectory()) -> Refusal? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notForWork
        }
        let asked = Store.canonicalFolder(folder)
        if asked == "/" { return .holdsProjects }
        guard let below = components(of: asked, below: Store.canonicalFolder(home)) else {
            // Outside the home folder only another volume counts: /Volumes/<disk>/<a>/<b>.
            guard let onVolume = components(of: asked, below: "/Volumes"), !onVolume.isEmpty else { return .notForWork }
            if hidden(onVolume) { return .notForWork }
            return onVolume.count < 3 ? .holdsProjects : nil
        }
        if hidden(below) { return .notForWork }
        // The home folder and the folders right in it, `~/Library` among them.
        if below.count < 2 { return .holdsProjects }
        if below[0] == "Library" {
            // Application data, apart from the two places cloud drives are kept in:
            // Mobile Documents/<container>/<a>/<b> (iCloud Drive) and CloudStorage/<provider>/<a>/<b>.
            guard below.count >= 3, below[1] == "Mobile Documents" || below[1] == "CloudStorage" else { return .notForWork }
            return below.count < 5 ? .holdsProjects : nil
        }
        // Under either spelling: the folder may be reached through a symlink, or be one itself.
        if isClientChats(below) { return .notForWork }
        if let typed = components(of: ToolRuntime.normalized(folder), below: ToolRuntime.normalized(home)), isClientChats(typed) {
            return .notForWork
        }
        return nil
    }

    private static func hidden(_ components: [String]) -> Bool {
        components.contains { $0.hasPrefix(".") }
    }

    /// Codex Desktop keeps the chats that have no project in `~/Documents/Codex/<date>/<name>`.
    /// Compared without case: on a case-insensitive volume the folder may be stored as `codex`.
    private static func isClientChats(_ below: [String]) -> Bool {
        below.count >= 2 && below[0].lowercased() == "documents" && below[1].lowercased() == "codex"
    }

    /// The path components of `path` below `base`; empty for `base` itself, nil when it is not inside.
    private static func components(of path: String, below base: String) -> [String]? {
        if path == base { return [] }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    /// What `holdsProjects` means, for the replies that refuse on it.
    static let holdsProjectsReason =
        "the home folder, a drive and the folders right in them hold projects, and Troy does not take them for one"

    /// The reply of `troy_save` for a folder that gets no project on its own.
    static func saveRefusal(_ folder: String, _ refusal: Refusal) -> String {
        switch refusal {
        case .holdsProjects:
            return "Troy does not create a project for \(folder) on its own: \(holdsProjectsReason). Pass an existing project's id or name, or the folder of the project itself."
        case .notForWork:
            return "Troy does not create a project for \(folder) on its own: it is not in a git repository, and outside one Troy only takes an existing, visible folder at least two levels below the home folder, an iCloud Drive or cloud-storage folder, or another volume. Pass an existing project's id or name, or create one with troy_new_project and \"path\"."
        }
    }
}
