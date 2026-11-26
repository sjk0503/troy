import Foundation
import TroyCore
import TroyMCP

enum CLI {
    static func run(_ arguments: [String]) -> Int32 {
        let console = Console()
        var context = CLIContext()
        var rest: [String] = []
        var index = 0
        // `--db` may appear anywhere before a `--` separator.
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                rest.append(argument)
                rest.append(contentsOf: arguments[index...])
                break
            }
            if argument == "--db" {
                guard index < arguments.count else {
                    console.err("troy: --db needs a file path.")
                    return 2
                }
                context.db = arguments[index]
                index += 1
            } else if argument.hasPrefix("--db=") {
                context.db = String(argument.dropFirst(5))
            } else {
                rest.append(argument)
            }
        }
        guard let first = rest.first else {
            console.err(overview())
            return 2
        }
        let commandArguments = Array(rest.dropFirst())
        switch first {
        case "help", "--help", "-h":
            if let name = commandArguments.first, let command = Commands.find(name) {
                console.out(help(for: command))
                return 0
            }
            console.out(overview())
            return 0
        case "version", "--version", "-V":
            console.out("troy \(MCPServer.version)")
            return 0
        default: break
        }
        guard let command = Commands.find(first) else {
            console.err("troy: unknown command '\(first)'.\nRun 'troy help' for the list of commands.")
            return 2
        }
        if commandArguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
            console.out(help(for: command))
            return 0
        }
        do {
            return try command.run(try command.parse(commandArguments), console, context)
        } catch let error as UsageError {
            console.err("troy: \(error.message)")
            console.err(error.usage ?? command.usage)
            return 2
        } catch let error as Failure {
            console.err("troy: \(error.message)")
            return 1
        } catch let error as ToolError {
            console.err("troy: \(error.message)")
            return 1
        } catch let error as TroyError {
            console.err("troy: \(error.message)")
            return 1
        } catch let error as MCPClients.Failure {
            console.err("troy: \(error.description)")
            return 1
        } catch {
            console.err("troy: \(error.localizedDescription)")
            return 1
        }
    }

    static func help(for command: Command) -> String {
        var text = "\(command.usage)\n\n\(command.summary)"
        let all = command.flags.map { "--\($0)" } + command.options.map { "--\($0) <value>" }
        if !all.isEmpty { text += "\n\nOptions: " + all.joined(separator: ", ") }
        text += "\nGlobal: --db <path> selects the database (default: $TROY_DB or ~/Library/Application Support/Troy/troy.db)."
        return text
    }

    static func overview() -> String {
        var text = "troy \(MCPServer.version): project memory for AI coding agents\n\nusage: troy [--db <path>] <command> [options]\n\ncommands:\n"
        let width = Commands.all.map { $0.name.count }.max() ?? 8
        for command in Commands.all {
            text += "  \(command.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(command.summary)\n"
        }
        text += "  \("help".padding(toLength: width, withPad: " ", startingAt: 0))  show this list, or 'troy help <command>'\n"
        text += "\nEvery command accepts --help."
        return text
    }
}
