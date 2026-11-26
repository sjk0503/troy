# Troy architecture

Troy is a project memory graph for AI coding agents that lives on one Mac. Agents save
tasks, decisions, notes, results and prompts through a local MCP server, link them to each
other, and read the project's state back at the start of the next session. A menu bar app
shows the same data to the person the agents work for.

Nothing leaves the machine. There is no account, no server to run and no network port.

## Parts

| Part | Target | What it does |
|---|---|---|
| Storage | `TroyCore` | One SQLite file, the schema, every read and write rule, search, link rules, advisories. No dependency beyond the system SQLite. |
| MCP server and tools | `TroyMCP` | JSON-RPC over stdio, the eight tools, and the text agents read. |
| Command line | `TroyCLI` (binary `troy`) | `troy mcp` runs the server. Other commands print the same text for hooks and scripts. |
| Graph | `TroyGraph` | Force-directed layout and the canvas that draws it. Knows nothing about records. |
| App state and design | `TroyUI` | `AppModel`, `StoreClient`, colors, symbols and small shared views. |
| Main window | `TroyMainUI` | Sidebar, record list, inspector, editor, graph screen. |
| Menu bar app | `TroyApp` | AppKit shell (status item, panel, windows, hotkey), panel and settings views. |

## Processes

There is no daemon. Every AI client starts its own `troy mcp` process over stdio, and the
menu bar app is one more process. All of them open the same file:

    ~/Library/Application Support/Troy/troy.db      (override with TROY_DB)

SQLite runs in WAL mode with a five second busy timeout. Every write is one
`BEGIN IMMEDIATE` transaction, so two processes never interleave half a change.

After a write commits, the writer posts the Darwin notification `dev.troy.store.changed`.
The app listens for it, but treats it only as a fast path: a process can die between its
commit and its post. The app therefore also compares `PRAGMA data_version` when the panel
opens, when a window becomes key, and every few seconds while a window is visible.

MCP keeps working when the app is not running, and the app works with no agent connected.

**Usage log.** `troy mcp` and the session-start hook append one row per tool call, per
handshake message (`initialize`, `server/discover`, `tools/list`) and per hook run to
`troy-usage.db` next to the database (`UsageLog`). It is a separate file, not a table in
`troy.db`, for three reasons: a write there would change `data_version` and make the app
reload; a read-only tool must not take the database's write lock; and the log's format is
expected to change, which must not touch the append-only schema. The file has its own
`application_id` ('TRYU') and `user_version` 1. A foreign or newer file is left alone and
logging stays off for that process. Rows hold sizes, timings, counts and record and project
numbers, never typed text: the fields that tools put in `UsageNote`. The agent and client
names are logged only when they look like a label (otherwise "other"), since `TROY_AGENT`
or a client's name could hold a folder path. Logging can never change a reply, and the
handshake never opens the database. A write during a tool call waits at most a few
milliseconds for the lock, and opening the file at most about a tenth of a second; only
closing (the end of a server, and the hook's one run) waits up to a second. While another
connection holds the lock, rows wait in an in-memory queue of up to 500 rows (overflow is
counted as `dropped`), and the server writes what is left when it closes. A `tools/call`
that reaches no tool (an unknown name, bad arguments) is logged as a protocol error without
the name that was sent. Rows older than 90 days are pruned when a server opens the log. `host` is the
nearest non-shell ancestor process (`pid@start`). It ties a hook run to the server of the
same client only when the client starts both directly. `troy stats` reads the log and the
database read-only and creates neither. `TROY_USAGE=off` turns the log off.

## Data model

A **project** has a unique name, a summary and any number of linked folders. A **record**
belongs to one project and has a kind, a status, a title, a Markdown body, tags and the
paths it touches. A **link** joins two records with one of six relations.

Record kinds: `task`, `decision`, `note`, `result`, `prompt`.

Record statuses: `open`, `doing`, `done`, `dropped`.

| Relation | Reads as | Direction | Meaning |
|---|---|---|---|
| `part_of` | part of / contains | directed | The source is a sub-task or component of the target. |
| `depends_on` | depends on / blocks | directed | The source cannot be finished before the target is done. |
| `derived_from` | derived from / led to | directed | The source was produced from, or justified by, the target. |
| `supersedes` | supersedes / superseded by | directed | The source replaces the target. |
| `relates_to` | relates to | symmetric | Same topic. |
| `conflicts_with` | conflicts with | symmetric | Contradicting decisions or overlapping work. |

Rules the storage layer enforces:

- A record can have any number of links of any relation, to records in any project.
- A symmetric link is stored once, with the smaller record id as its source.
- One pair of records holds at most one link per relation. Linking again returns the existing link.
- A record cannot link to itself.
- A directed relation cannot form a cycle. The write is refused and the message names the path.
- **Superseded is not a status.** A record is superseded while at least one `supersedes`
  link points at it. Creating or deleting links never changes a status, so removing the
  link restores exactly what was there before.
- Links are only ever created by an explicit call. The server suggests candidates; it never links on its own.

Relations are a fixed set because free-text labels drift into synonyms that cannot be
queried. The optional `note` on a link carries the reason in words.

### Claims

Setting a record to `doing` claims it: `assignee` becomes the caller's agent label and
`claimed_at` the current time. The claim is a conditional update. While another agent
holds it, every status change is refused with that agent's label and the time it claimed,
and the caller has to pass `takeover` to go ahead. (Refusing only a second `doing` would
leave a way round: set the record to `open`, then claim it.) Leaving `doing` clears both
fields. A status change made in the app is the person's decision and always takes over.

Claims are advisory. There are no locks, leases or expiry timers, because a dead session
holding a lock is a worse failure on a single-user machine than two sessions being told
about each other. A claim older than 24 hours is shown as stale.

### Advisories

Writes return advisories next to their result. They never block.

- **Path overlap**: another agent is `doing` a record in the same project whose `paths`
  overlap this task's. Two paths overlap when they are equal or one is a folder that
  contains the other. Only tasks get this advisory, and a task that has not started and
  already depends on the other record is told that once, as a dependency.
- **Unfinished dependency**: the record depends on a record that is not `done` or `dropped`.
- **Conflict**: a `conflicts_with` link to a record that is not finished.

### History

A trigger on `records` stores the previous values of the changed fields in
`record_versions` on every update, whoever writes. A change of holder is a change too, so
a takeover leaves the previous holder behind. The newest 50 versions per record are kept.
A write that changes nothing writes nothing.

### Schema

`Sources/TroyCore/Schema.swift` is the schema. Timestamps are integer milliseconds since
1970; `tags` and `paths` are JSON arrays. Record ids are small integers from
`AUTOINCREMENT`, so an id is never reused and costs an agent one or two tokens instead of
the twenty a UUID costs.

`Schema.migrations` is append-only once a release contains it: files made by that release
keep whatever the migration said then, so an edit in place leaves two different schemas
under one version number. A test pins the text of every migration and of the search index.

## Storage rules

These complete the doc comments in `Store.swift`.

**Opening.** Create the folder and file when missing. Set `journal_mode=WAL`,
`synchronous=NORMAL`, `foreign_keys=ON`, `busy_timeout=5000`, `temp_store=MEMORY`. A new
file gets `application_id`; an existing non-empty file with a different non-zero
`application_id` is refused. Apply pending migrations, each in one transaction. A file
with a higher `user_version` than this build knows is refused with a message that says so.
Then run `Schema.searchIndex`; if it fails, `ftsAvailable` is false and search uses LIKE.
If the index was just created and `records` is not empty, rebuild it.

Several processes may create the file at the same moment (two clients starting on a new
machine). The identity (`application_id`, `user_version`, table count) is read in one
snapshot, so a file another process is setting up is seen as empty or as finished and
never as half of each. The switch to WAL is the one step SQLite refuses at once instead
of waiting for a lock, so it is retried for as long as `busy_timeout` would have waited.

**Text input.** Titles and names are trimmed and must not be empty. No field may contain
U+0000. Lengths are counted in characters against `Limits`.

**Tags.** Trimmed, empty ones dropped, duplicates removed (first wins, compared without
case), order kept. A tag cannot contain a quote, a backslash or a control character: tags
are stored as JSON and indexed as that text, and a tag that needed escaping would be found
by one search path and missed by the other.

**Record paths.** Trimmed; leading `./` and trailing `/` removed; repeated `/` collapsed;
empty and duplicate entries dropped. From the first `*`, `?` or `[` on, a path is cut back
to its last complete folder, so `src/**/*.ts` is treated as `src`.

**Project paths.** Absolute after expanding `~`, standardized, no trailing slash. A path
belongs to at most one project, whatever its spelling.

**Canonical paths.** Folders are compared in canonical form on both sides, the folder asked
about and every stored link: `realpath` (every symlink, `/var` → `/private/var`), then the
file system's canonical path (case as stored on disk, firmlinks such as
`/System/Volumes/Data/Users` → `/Users`). For a path that does not exist, its closest existing
ancestor is canonicalized and the rest kept as typed. Stored links are not rewritten; they are
canonicalized when looked up. The same comparison keeps `troy_new_project` from linking a
second spelling of a linked folder to another project, and a project made by a first save is
created under the canonical path.

**Resolving a project.** See `Store.resolveProject`. When nothing matches, the error lists
the active projects by id and name, so the caller can choose.

**The project of a folder.** One function decides it (`ToolRuntime.folderState`), and every
caller goes through it: `troy_context` without a project, the scope of `troy_search`, the
"this folder" mark of `troy_projects`, a folder passed as `project`, the save target and the
session-start hook. Nothing re-resolves a folder by a plain ancestor lookup.

The closest link to the folder wins, then the closest link to its repository root; archived
projects take part, so an archived project linked to the repository is not passed over for an
active one linked to a folder above it (the folder then has no project, and the error names
the archived one).

A repository is a boundary. For a folder in a repository a link counts only when it lies at
or below the repository's root, or is itself the root of a repository this one is nested in
(a submodule's superproject, the repository a vendored clone or a scratch checkout sits in;
found by walking up, and never the home folder or `/`). Any other link above a
repository says where the repository happens to sit. So a project linked to a plain folder
never takes the repositories below it, whether they were there when it was linked or came
with a later `git init`, and an archived one does not block them. A folder in no repository
has no boundary of its own: every link above it counts.

On the walk up (`Repository.enclosing`) a `.git` folder is taken as it is and a `.git` file
is read first. A linked worktree counts itself, and above it the walk goes on from its main
repository, which git is asked for as above, not from the folder the worktree happens to
sit in. A `.git` file that leads nowhere readable ends the walk, so a plain folder with a
stale one owns nothing below it. A repository whose root git could not name, and that is no
linked worktree (a submodule, a separate git dir), is a boundary all the same: its own
folder and the repositories around it are the only links that count, and nothing is created
for it.

In a linked git worktree a link above the worktree does not count: it says
where the worktree happens to sit, and the worktree belongs to its main repository. A link
inside the worktree itself still wins. Whether a folder is in a linked worktree is read from
its `.git` file alone, without git: the `gitdir:` target has a `commondir` file, or the target
is missing or unreadable. No `commondir` (a submodule, the main folder of a separate git dir)
means no boundary. So git's answer can only add the main repository; a git that fails or is
slow never changes which project a folder gets, it only leaves a worktree without one.

**Repository root.** The nearest folder at or above the given one that holds `.git`:

- `.git` is a folder with a `HEAD` file: that folder is the root. A `.git` folder without
  `HEAD` (a leftover empty one) is not a git dir; the walk goes on upwards, as git's does. No subprocess runs, because this is the common
  case and the session-start hook runs it before every session.
- `.git` is a file (a linked worktree, a submodule, a separate git dir): git is asked, with
  `/usr/bin/git` first (servers started by GUI apps get a short `PATH`), no stdin, none of
  the inherited `GIT_*` variables (a session started from a git hook carries `GIT_DIR` of
  another repository) and two seconds in all. When `git rev-parse` reports the same git dir and common dir, the folder is
  not a linked worktree and its top level is the root (a submodule, the main folder of a
  separate git dir). Otherwise the root is the first entry of `git worktree list --porcelain`,
  the main worktree, when it is not `bare` and is itself a work folder.
- Git missing, failing, too slow, a bare repository, or a separate git dir seen from a linked
  worktree (git lists the metadata folder there, because nothing records where the work
  folder is): no root. A link on the worktree or inside it still claims the folder; nothing
  else does, nothing is created, `troy_context` is the not-found error and the hook prints nothing.

The main folder is not derived from `gitdir` and `commondir` by hand: with
`--separate-git-dir` the common dir's parent is the metadata folder, not the work tree. The
home folder and `/` are never a root. Git's answer is kept for 30 seconds per folder and contents
of its `.git` file, so a git that hangs costs its time limit once and a worktree replaced at
the same path is asked about again. A `gitdir` target that cannot be looked into counts as a
worktree boundary. `troy_new_project` without `path` in a worktree whose main folder is
unknown is refused instead of linking the worktree, which would split the repository.

A folder passed as `project` or `path` that exists is resolved by the file system as typed
(`realpath`), so `..` right after a symlink leaves the link's target; only a path that does
not exist is cleaned up as text.

Known limitation: a repository made with `--separate-git-dir` whose git directory is itself
named `.git` (work folder `/work/app`, git dir `/meta/app/.git`). Nothing records the real
work folder (`core.worktree` is not set), and from a linked worktree git names `/meta/app` as
the main worktree, which holds a `.git` folder and so passes the check. A linked worktree of
such a repository therefore gets a project at the metadata folder, apart from the work
folder's project. Link the worktree with `troy_new_project` and `path` to choose otherwise.

**A work folder in no repository.** A repository names its own root. A plain folder does not,
so the folder itself is taken (the working folder, or the folder passed as `project`), in its
canonical spelling, and nothing walks up. It gets a project on its first save when it exists
and lies at least two levels below the home folder (`~/dev/notes`), below an iCloud Drive or
cloud-storage folder (`~/Library/Mobile Documents/<container>/…`,
`~/Library/CloudStorage/<provider>/…`) or below another volume (`/Volumes/<disk>/…`), with
nothing hidden on the way, the drive's and the volume's own names included (`PlainFolder`).
Not taken:

- the home folder, a drive, and the folders right in them (`~/dev`, `~/Documents`,
  `~/Library`). A project claims every plain folder below its link that has no link of its
  own, so a place that holds projects must not become one;
- the rest of `~/Library`, and `~/Documents/Codex`, where Codex Desktop keeps the chats that
  have no project;
- everything else outside the home folder: system and temporary folders.

The tests are made on the resolved path, so a symlink into one of these places is left out
as well; the chats folder is also matched on the path as typed and without case, because it
may be a symlink itself or stored as `codex`. There `troy_context` is the not-found error
and the hook prints nothing, and for a folder that holds projects neither the error nor
`troy_new_project` without `path` links it (the project is created without a folder).

Depth stands in for intent, and it is all there is to go by: `~/dev/clients` qualifies as
readily as `~/dev/app`, and a save there takes the client folders below it that have no
project yet (never their repositories). Which of two nested plain folders gets a project
depends on where the first session ran: saved first in `cs/notes`, `notes` is a project and
`cs` gets its own later; saved first in `cs`, `notes` belongs to `cs`. A guard that refused a
folder holding a repository or a linked folder was dropped for that reason: it would leave a
work folder without records because of what happens to be below it, and the repository
boundary keeps repositories apart without it.

**The first save creates the project.** `troy_save` whose `project` is a folder (it starts with
`/` or `~`) that resolves to no project creates one and saves the record into it: linked to
the repository root, or to the folder itself for a work folder in no repository, in the
canonical spelling. The name
is the folder's name; when taken, `name (parent)`; then `name (parent) 2`, `3`, and so on.
Lookup, creation and insert are one `BEGIN IMMEDIATE` transaction
(`Store.saveCreatingProject`), so two sessions saving their first record at once end up in one
project. Refused: a folder in no repository that is not a work folder as above; a repository
whose root is, or contains, a folder linked to an archived project, or that is nested in a
repository an archived project is linked to (a second project would split its records; the
error names the archived one); and a plain folder with an archived project's link on it or
above it. Reads never create anything.

**Creating a record.** Validate, then in one transaction: check for the duplicate window,
insert the record, insert `parent` as a `part_of` link and every draft link (same rules as
`link`). A repeated save inside the window stores no second record, but its links are
still checked and added to the existing one. After the commit, compute similar records and
advisories.

**Updating a record.** In one transaction: read the row, check `expectedRev`, apply the
claim rule, build the new values, and stop without writing when nothing differs.
Otherwise update with `rev = rev + 1`, `updated_at` strictly greater than the old value,
and `updated_by = agent`.

**Search.** Split the text on whitespace into at most eight terms. Every term must occur,
ignoring case, in the title, the tags or the body. Terms of three or more characters go to
the trigram index as quoted phrases joined with AND; shorter terms are matched with LIKE
on the candidate rows. With no long term, or with no index, everything is matched with
LIKE. The LIKE test defines a match and the index only narrows the candidates, so both
paths match the same records. They rank differently, so a search cut off by its limit can
return different records with and without the index. Patterns are escaped scalar by
scalar, because `_` followed by a combining mark is one character that is not `_`.
Ranking: `bm25` with weights title 10, tags 5, body 1 when the index is used;
otherwise title matches first, then newest. The snippet is about 220 characters of body
around the first occurrence of the first term, or the start of the body.

**Similar records.** Lowercase the title and tags, split on anything that is not a letter
or digit, and collect the character bigrams inside each word (a one-character word counts
as itself). The score is the Dice coefficient of the two bigram sets. Compare against the
3,000 most recently updated records of the project and return those scoring 0.30 or more,
best first. Bigrams make Korean particles and partial words match where a word tokenizer
or a trigram index would not: 토큰별 and 토큰을 share 토큰.

**Overview.** One call returns what the context tool and the panel show: records being
done, open tasks that wait on nothing, tasks that wait on something, collisions, decisions
in effect, and the most recently updated records not already listed.

**Backup.** `Store.backup(to:)` (`troy backup <file>`, Back Up in Settings) writes one
complete file with `VACUUM INTO`. Until it is whole it sits in a folder of its own next
to the target, made for that one call, and only that folder is removed afterwards. A new
file gets its name with a rename that fails when the name is taken, so two backups
started for the same file cannot both succeed, and the app replaces an existing file only
when the save panel asked about it. It is safe while other processes write. Copying `troy.db`
by hand is not a backup: in WAL mode the newest writes are in `troy.db-wal` until SQLite
moves them over, and while a client or the app keeps the database open that can be
everything since the file was created. Never accepted as the target: the database itself
with the files SQLite keeps next to it, a name that has a `-wal`, `-shm` or `-journal`
file next to it, and a name that ends in one of those. SQLite pairs such files with a
database by name alone: the log of another database, open now or long gone, would be
replayed onto the backup, and a backup named like a log would be overwritten as one.

## MCP server

`troy mcp` reads one JSON-RPC message per line from stdin and writes one per line to
stdout. Logs go to stderr. It exits when stdin closes.

It answers both protocol generations: the handshake revisions up to `2025-11-25`
(`initialize`, `notifications/initialized`, `ping`) and the stateless `2026-07-28`
revision (`server/discover`, per-request `_meta`, `resultType`). It declares the `tools`
capability only.

Tool results are plain text in `content`. There is no `structuredContent` and no
`outputSchema`: the same answer twice doubled the token cost in the previous version, and
some clients drop results that carry only structured content.

### Agent label

The server labels its writes with the client's name from the handshake plus a three
character tag unique to the process, for example `claude-code/a3f`. Two sessions of the
same client therefore see each other's claims as someone else's. `TROY_AGENT` overrides
the whole label.

### Tools

| Tool | Arguments | Result |
|---|---|---|
| `troy_context` | `project?`, `max_chars?` | The project's state: in progress, ready, blocked, collisions, decisions in effect, recent. Titles only. In a folder without a project, how the first save creates it. |
| `troy_save` | `project`, `kind`, `title`, `body?`, `tags?`, `paths?`, `status?`, `parent?`, `links?` | Stores one record, links it, returns its id, similar records and advisories. A folder as `project` (a repository, or a work folder in none) creates the project on the first save. |
| `troy_update` | `id`, `title?`, `body?`, `append?`, `status?`, `kind?`, `tags?`, `paths?`, `takeover?` | Changes a record. `status: "doing"` claims it. |
| `troy_link` | `from`, `to`, `relation`, `note?`, `remove?` | Creates or removes one link. `to` may be a list. |
| `troy_search` | `query`, `project?`, `all_projects?`, `kind?`, `status?`, `tag?`, `limit?` | Matching records with a snippet each. |
| `troy_read` | `ids`, `max_chars?` | Full records with their links and advisories. |
| `troy_projects` | `include_archived?` | Projects with counts and linked folders. |
| `troy_new_project` | `name`, `summary?`, `path?` | Creates a project linked to a folder: for a custom name, or a folder Troy makes no project for on its own. |

`project` is an id, a name, or a folder (a value starting with `/` or `~`), which resolves
like the working folder (see Storage rules). `troy_context` and `troy_search` fall back to
the project of the server's working directory and always say which project they used; for them
a name may be partial when only one project matches. `troy_save` requires `project` and
takes an id, the exact name or a folder only: a server started in one repository must not
silently file another repository's decision, and neither may a half-typed name. A folder
without a project (a repository, or a work folder in none) gets one on that first save. The one way to save
without naming the project is `TROY_PROJECT` in the server's own configuration, which is
the person's explicit choice. A number is always an id: when no project has it, a project
whose name merely contains those digits is not used.

With nothing linked, `troy_context` for a folder whose first save would create a project (a
repository root that no archived project claims, or a work folder in no repository) is not
an error. The folder is the working folder when no `project` and no
`TROY_PROJECT` is given, or the folder they name: an agent told to start with `troy_context`
often passes the folder it is in. `troy_search` naming such a folder answers "No results"
with the same explanation. A name or an id that matches nothing stays an error.

    No project yet for this repository: /Users/me/dev/troy
    Record this session's work without being asked: troy_save each decision (with its reason), finding and finished piece of work as it happens. The first save with "project": "/Users/me/dev/troy" creates the project, named after the folder and linked to it.
    Other projects: #1 atlas, #2 notes.

In a work folder that is no repository the first line reads "No project yet for this folder:".
Anywhere else it stays the not-found error (for a worktree whose main folder git could not
name, and for a folder that holds projects, with a sentence saying so).

There is no delete tool. An agent marks a record `dropped`; removing data is done in the app.

### What the text looks like

A record is referred to as `#42`. Its tagline is `[kind/status]`, with the holder and the
age of the claim when it is being done: `[task/doing by codex/a1f, 2h]`. Superseded
records add `superseded`. Ages are `5m`, `2h`, `3d`, `2w`, then a date.

`troy_context`:

    Project #3 "troy" — /Users/me/dev/troy
    42 records · 7 open tasks · 2 in progress · last activity 5m ago

    IN PROGRESS
    #31 Rewrite the store — codex/a1f, 2h · part of #12
    #33 Graph view — claude-code/9f2, 20m · paths: Sources/TroyGraph

    READY
    #35 Add the export command · part of #12
    #36 Write the README

    BLOCKED
    #34 MCP smoke tests — waits on #31

    WATCH OUT
    #33 conflicts with #29: both restructure AppModel
    #31 and #40 are both in progress and touch Sources/TroyCore/Store.swift

    DECISIONS IN EFFECT
    #20 All Swift, no dependencies (2026-11-24)

    RECENT
    #41 [note/open] Trigram misses two-character Korean words · 10m
    #39 [task/done] Remove the web stack · 1h

    Keep this current without being asked: troy_save {"project":3,…} each decision, finding and finished piece of work as it happens, and claim a task with troy_update before working on it. Read bodies with troy_read {"ids":[…]}.

Empty sections are left out. The default budget is 6,000 characters; a section that does
not fit ends with a line saying how many records were left out.

`troy_read`:

    #31 [task/doing by codex/a1f, 2h] Rewrite the store
    project #3 troy · tags: core, swift · paths: Sources/TroyCore · created 2026-11-24 · updated 5m ago by codex/a1f

    <body>

    Links:
    - part of #12 [task/open] Native rewrite
    - contains #45 [task/done] SQLite wrapper
    - blocks #34 [task/open] MCP smoke tests
    - relates to #29 [note/open] Old store audit — same module
    Watch out:
    - depends on #30 [task/doing by claude-code/9f2, 1h], which is not finished

Several records are separated by a line holding `---`. A body longer than `max_chars`
(default 8,000) is cut with a line that says how long the whole body is.

`troy_save`:

    Saved #42 [task/open] "Add the export command" in project #3 troy.
    Linked: part of #12.
    Similar records already exist. Link them with troy_link, or reuse one instead of duplicating:
    - #35 [task/open] Add export command (97%, probably the same item)
    - #18 [decision/open] Export format is Markdown (41%)
    Watch out:
    - #33 [task/doing by claude-code/9f2, 20m] touches the same paths: Sources/TroyApp/Export.swift

`troy_update`:

    Updated #42 [task/doing by codex/a1f, 0m] "Add the export command": status open → doing.

A task set to `done` in a call that adds no text gets one more line asking for a one-line
outcome, because a bare `doing → done` leaves the next session nothing to read. A refused
claim is a tool error:

    #42 is in progress by codex/a1f, claimed 2h ago. Pick other work, or pass "takeover": true if that session is gone.

`troy_search`:

    3 results for "export" in project #3 troy:
    1. #35 [task/open] Add the export command · 2h
       …writes every record as Markdown, links included…

### Getting agents to use it

Nothing here captures a conversation or calls a model, so an agent records only when it is
allowed to and told to. Both failed on the first real day of use (2026-11-24: 36 server starts,
no tool call), and both were then measured with real sessions on tasks that never mention Troy:

1. **The agent has to be allowed.** Claude Code asks before each call of a tool that no rule
   allows, and a session nobody watches (`claude -p`, a delegated worker) is refused instead.
   With `"permissions": { "allow": ["mcp__troy"] }` in `~/.claude/settings.json`, 12 of 12
   sessions read the context and saved their work unasked, with the old instructions as well as
   the new ones; without the rule, the one real session that tried was refused. Permissions are
   the person's to give: `troy connect claude-code` prints the line and changes nothing.
2. **The rule has to open the instructions.** Codex lists a server as the first 250 characters
   of its `instructions` and nothing else until the agent loads the tools, so
   `AgentGuide.instructions` starts with the whole rule: use it without being asked, read the
   context when work starts, save as you go (`AgentGuide.leadLength`, pinned by a test). With a
   description of what Troy is in that place, Codex saved in 1 of 4 sessions; with the rule, in
   3 of 4. A narrowly scoped delegated prompt still makes Codex skip it, also with the section
   from `troy guide` in `AGENTS.md` (1 of 2).
3. The replies say it again where the agent is already looking: the hint for a folder
   without a project and the last line of `troy_context` both tell it to record without being
   asked. At first only a git repository got that hint and a project, and a day of real
   sessions in a work folder that was no repository left no record. With the rule for such
   folders, 4 of 4 sessions there (two Claude Code, two Codex) read the context, saved
   unasked and got their project on the first save.
4. `troy context` prints the same text as `troy_context`, so a session-start hook can put
   the project's state in front of the agent before it does anything. `troy context --quiet`
   (the hook) prints the project's state, or in a folder whose first save would create a
   project the hint above, and otherwise nothing. It never fails and never creates the database: without the
   file it prints the hint with "There are no projects yet." and opens nothing. Git is only
   run when `.git` is a file, under the same time limit. Each run is logged as one hook row in
   the usage log (state `project`, `pending` or `none`).
5. The app and `troy guide` hand out a short section for `AGENTS.md` or `CLAUDE.md`.

### Connecting clients

`MCPClients` registers the server, from the app's Settings or `troy connect <client>`, and
only when asked. Claude Code, Codex, VS Code and Gemini CLI are registered by running
their own command line tool. Claude Desktop and Cursor have none, and VS Code has one for
adding but not for removing, so there Troy edits the JSON settings file under these rules:

- Only a plain JSON object with a name-to-server table is rewritten. Comments, a list of
  servers or a file that cannot be read are refused, with the entry to paste by hand.
- Everything else in the file is kept, including what an existing `troy` entry carries.
- A link is followed, so settings kept in a dotfiles folder stay linked.
- The new file and the old one trade places in one step of the file system
  (`renamex_np` with `RENAME_SWAP`), and what came out is compared with what was read. If
  the client saved in between, its version goes back and nothing of Troy's is written.
  The file that was replaced becomes `<name>.troy-backup`.
- A client cannot be locked out of its own file, so for the instant between the exchange
  and the exchange back a reader finds Troy's version, and a client that reads it then may
  save on top of it, during the exchanges or after them. The rule that covers it: once the
  client has saved in between, a copy of every save of its that came out of an exchange
  is kept next to the file as `<name>.troy-<tag>-<n>`, and the error names them.

## Menu bar app

The app is an accessory application: no Dock icon until a window is open. An AppKit shell
owns the status item, a borderless panel and the windows; everything inside them is SwiftUI.

- **Panel** (status item click or global hotkey): project switcher, search, what is in
  progress, what is ready, collisions, recent records.
- **Main window**: projects and filters in the sidebar, a project overview (first launch;
  later opens remember the mode), records as a list or as a graph, and an inspector with
  the body, links grouped by relation, advisories and history. The project-wide graph shows
  up to 2,000 recent nodes; a selected record's local view takes its direct connections
  from the record detail, so it works even when the record is outside those 2,000.
- **Settings**: connecting AI clients, launch at login, hotkey, database location, backup, export.

All database work goes through `StoreClient`, which runs it on a background queue.
`AppModel` holds what the views show and reloads it when the data version changes.

User-facing strings are written as `L("English", ko: "한국어")` at the call site. The
package builds with `swift build` alone, and SwiftPM resource bundles do not survive being
copied into a hand-assembled `.app`, so there is no strings file.

## Building

    swift build -c release        # builds troy and TroyApp
    swift test
    make app                      # assembles and ad-hoc signs build/Troy.app
    make install                  # copies it to /Applications and links troy into ~/.local/bin

Requires macOS 14 or later and Swift 6.2 or later.
