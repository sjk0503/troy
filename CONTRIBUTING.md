# Contributing to Troy

Troy is a native macOS menu bar app and a command line tool (`troy`) that is also the MCP
server AI coding agents talk to. Read `docs/ARCHITECTURE.md` first; it explains the data
model and the rules the code enforces.

## Requirements

- macOS 14 or later
- Swift 6.2 or later (Xcode 26 or later, or a matching toolchain)

## Build, test, run

    swift build                # debug build of everything
    swift test                 # all test targets
    make app                   # release build, assembles and ad-hoc signs build/Troy.app
    make run                   # builds the app and opens it
    make install               # copies to /Applications, links troy into ~/.local/bin
    make uninstall             # removes exactly what install created (never your data)
    make icon                  # regenerates Resources/Troy.icns from Scripts/make-icon.swift

`make install` accepts `PREFIX_APP=` and `PREFIX_BIN=` so you can try it in a scratch folder.
Set `TROY_DB=/path/to/test.db` to keep experiments away from your real database.

## Looking at a screen

You can check a change to a screen without clicking through the app:

    # Draw one scene off screen and write a PNG. Shows no window, needs no permission.
    .build/debug/TroyApp --render main --out /tmp/main.png --demo en
    .build/debug/TroyApp --render panel --out /tmp/panel.png --demo ko --lang ko --dark

    # Start the real app on a scratch database with one window already open.
    .build/debug/troy --db /tmp/scratch.db demo
    .build/debug/TroyApp --db /tmp/scratch.db --show graph --select 6

Run `TroyApp --render` with no scene to list the scenes. `--show` takes `main`, `graph`,
`panel`, `settings`, `new-record` and `new-project`. An off-screen render has no window
behind it, so translucent materials and the sidebar's selection come out flat; the look of
those is only right in the real window. `python3 Scripts/screenshots.py` regenerates the
images in `docs/images` from real windows.

For design reviews, you can install Impeccable in this checkout for Claude Code and Codex.

    npx --yes impeccable@4.9.2 install --scope=project --providers=claude,codex --no-hooks -y

In Claude Code, use `/impeccable critique` with a screenshot and the SwiftUI view you
want to review. In Codex, use `$impeccable critique`. Use the native renders above to
check the result in both appearances and languages.

A development run started with `--db` never opens your own database and may run next to
the installed app. To see what an AI client sends the MCP server, set `TROY_TRACE=/tmp/troy-trace.log`
in that client's server configuration.

## Module map

| Target | What it holds |
|---|---|
| `TroyCore` | SQLite storage, schema, read and write rules, search, links, advisories. |
| `TroyMCP` | JSON-RPC over stdio, the eight tools, the text agents read. |
| `TroyCLI` (binary `troy`) | `troy mcp` and the other commands. |
| `TroyGraph` | Force-directed layout and the canvas. Knows nothing about records. |
| `TroyUI` | `AppModel`, `StoreClient`, design tokens, shared views. |
| `TroyMainUI` | Main window: sidebar, record list, inspector, editor, graph screen. |
| `TroyApp` | AppKit shell (status item, panel, windows, hotkey), panel and settings. |

## Rules

- **`swift build` alone must keep working.** No `.xcodeproj`, no code generation step, no
  SwiftPM resources (they do not survive a hand-assembled `.app`).
- **No third-party dependencies.** Only the system frameworks and the system SQLite.
- Tests live in `Tests/` and run with `swift test`. Add one for any storage or protocol rule you change.
- **A released migration is never edited.** Change the schema by appending to
  `Schema.migrations`; `releasedSchemaTextIsNotEdited` fails when an existing one changes.
- `python3 Scripts/smoke-mcp.py` drives the built `troy mcp` over real pipes in both protocol
  generations. Run it after touching the server.

## User-facing strings

Strings are written at the call site with both languages:

    L("Open project", ko: "프로젝트 열기")

There is no strings file. Anything a person reads in the app needs English and Korean.
MCP tool text is English only.

## Pull requests

Keep them small and say what changed and why. CI runs `swift build`, `swift test` and
builds the app bundle; all three must pass.
