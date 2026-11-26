import AppKit
import TroyCore
import TroyUI

/// What the command line asked for. Everything except `--render`, `--db` and `--show` is for render mode.
struct LaunchOptions {
    /// `--show main|overview|graph|local-graph|panel|settings|new-record|new-project`: open that window at launch, for a development run.
    /// `local-graph` with `--select <id>` opens that record's live local graph; without `--select` it is the ordinary graph.
    var show: String?
    /// `--select <id>`: the record `--show main`, `graph` and `local-graph` open on.
    var select: Int64?
    var render: String?
    var out: String?
    var db: String?
    var demo: DemoData.Language?
    var dark = false
    var language: AppLanguage?
    var size: CGSize?
    var query: String?
    var emptyProject = false

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--render": render = iterator.next()
            case "--show": show = iterator.next()
            case "--select": select = iterator.next().flatMap { Int64($0) }
            case "--out": out = iterator.next()
            case "--db": db = iterator.next().map { ($0 as NSString).expandingTildeInPath }
            case "--demo":
                demo = iterator.next() == "ko" ? .korean : .english
            case "--dark": dark = true
            case "--lang":
                let value = iterator.next()
                language = value == "ko" ? .korean : (value == "en" ? .english : nil)
            case "--size":
                let parts = (iterator.next() ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
            case "--query": query = iterator.next()
            case "--empty-project": emptyProject = true
            default: break
            }
        }
    }
}

/// Another copy is already running: bring it forward through its URL scheme and report true.
func activateRunningInstance() -> Bool {
    let me = ProcessInfo.processInfo.processIdentifier
    let identifier = Bundle.main.bundleIdentifier ?? "dev.troy.app"
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { $0.processIdentifier != me }
    guard let other = others.first else { return false }
    if let url = URL(string: "troy://open") { NSWorkspace.shared.open(url) }
    other.activate()
    return true
}

let options = LaunchOptions(CommandLine.arguments)

if options.render != nil {
    exit(RenderMode.run(options))
}

// A copy started with an explicit database is a development run and may live next to the real app.
if options.db == nil, activateRunningInstance() { exit(0) }
// `--lang` on a development run picks the interface language for it.
if options.show != nil, let language = options.language { Localization.language = language }

let application = NSApplication.shared
let delegate = AppDelegate(databasePath: options.db ?? Store.defaultPath(), show: options.show, select: options.select)
application.delegate = delegate
application.run()
