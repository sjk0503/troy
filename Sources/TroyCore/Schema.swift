/// The database schema. `Store.init` applies every migration whose number is above
/// `PRAGMA user_version`, each inside one transaction, then sets `user_version`.
///
/// Timestamps are INTEGER milliseconds since 1970. `tags` and `paths` are JSON arrays of strings.
public enum Schema {
    /// 'TROY' in ASCII. Written to `PRAGMA application_id` when the file is created.
    public static let applicationID: Int32 = 0x5452_4F59

    /// Applied in order. Index 0 is version 1.
    public static let migrations: [String] = [v1]

    public static var currentVersion: Int { migrations.count }

    static let v1 = """
    CREATE TABLE projects (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL COLLATE NOCASE UNIQUE,
      summary     TEXT NOT NULL DEFAULT '',
      status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
      created_at  INTEGER NOT NULL,
      updated_at  INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE project_paths (
      path        TEXT PRIMARY KEY,
      project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX project_paths_project ON project_paths(project_id);

    CREATE TABLE records (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      kind        TEXT NOT NULL CHECK (kind IN ('task','decision','note','result','prompt')),
      status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','doing','done','dropped')),
      title       TEXT NOT NULL,
      body        TEXT NOT NULL DEFAULT '',
      tags        TEXT NOT NULL DEFAULT '[]',
      paths       TEXT NOT NULL DEFAULT '[]',
      source      TEXT NOT NULL DEFAULT '',
      assignee    TEXT,
      claimed_at  INTEGER,
      rev         INTEGER NOT NULL DEFAULT 1,
      created_at  INTEGER NOT NULL,
      updated_at  INTEGER NOT NULL,
      updated_by  TEXT NOT NULL DEFAULT ''
    ) STRICT;
    CREATE INDEX records_project_updated ON records(project_id, updated_at DESC, id DESC);
    CREATE INDEX records_project_kind_status ON records(project_id, kind, status);
    CREATE INDEX records_doing ON records(project_id, claimed_at) WHERE status = 'doing';

    CREATE TABLE links (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      source_id   INTEGER NOT NULL REFERENCES records(id) ON DELETE CASCADE,
      target_id   INTEGER NOT NULL REFERENCES records(id) ON DELETE CASCADE,
      relation    TEXT NOT NULL CHECK (relation IN ('part_of','depends_on','derived_from','supersedes','relates_to','conflicts_with')),
      note        TEXT NOT NULL DEFAULT '',
      created_by  TEXT NOT NULL DEFAULT '',
      created_at  INTEGER NOT NULL,
      CHECK (source_id <> target_id),
      CHECK (relation NOT IN ('relates_to','conflicts_with') OR source_id < target_id),
      UNIQUE (source_id, target_id, relation)
    ) STRICT;
    CREATE INDEX links_target ON links(target_id, relation);

    CREATE TABLE record_versions (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      record_id   INTEGER NOT NULL REFERENCES records(id) ON DELETE CASCADE,
      rev         INTEGER NOT NULL,
      changed     TEXT NOT NULL,
      actor       TEXT NOT NULL DEFAULT '',
      created_at  INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX record_versions_record ON record_versions(record_id, id DESC);

    -- Every change to a record leaves the previous values of the changed fields behind,
    -- whoever writes it. json_patch drops the NULLs, so `changed` holds only what changed.
    -- A takeover changes nothing but the holder, and is recorded as the previous holder.
    CREATE TRIGGER records_version AFTER UPDATE OF title, body, kind, status, tags, paths, project_id, assignee ON records
    WHEN old.title IS NOT new.title OR old.body IS NOT new.body OR old.kind IS NOT new.kind
      OR old.status IS NOT new.status OR old.tags IS NOT new.tags OR old.paths IS NOT new.paths
      OR old.project_id IS NOT new.project_id OR old.assignee IS NOT new.assignee
    BEGIN
      INSERT INTO record_versions (record_id, rev, changed, actor, created_at)
      VALUES (old.id, old.rev, json_patch('{}', json_object(
        'title',     CASE WHEN old.title IS NOT new.title THEN old.title END,
        'body',      CASE WHEN old.body IS NOT new.body THEN old.body END,
        'kind',      CASE WHEN old.kind IS NOT new.kind THEN old.kind END,
        'status',    CASE WHEN old.status IS NOT new.status THEN old.status END,
        'tags',      CASE WHEN old.tags IS NOT new.tags THEN json(old.tags) END,
        'paths',     CASE WHEN old.paths IS NOT new.paths THEN json(old.paths) END,
        'projectID', CASE WHEN old.project_id IS NOT new.project_id THEN old.project_id END,
        'assignee',  CASE WHEN old.assignee IS NOT new.assignee THEN old.assignee END
      )), new.updated_by, new.updated_at);
      DELETE FROM record_versions
      WHERE record_id = old.id
        AND id NOT IN (SELECT id FROM record_versions WHERE record_id = old.id ORDER BY id DESC LIMIT \(Limits.versionKeep));
    END;
    """

    /// Full-text index over title, tags and body. Created after the migrations, and only when
    /// this SQLite build has FTS5 with the trigram tokenizer; otherwise search falls back to LIKE.
    /// Trigram matches any substring of three or more characters, which also covers Korean
    /// compounds and camelCase identifiers. Shorter terms are matched with LIKE.
    public static let searchIndex = """
    CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(
      title, tags, body, content='records', content_rowid='id', tokenize='trigram'
    );
    CREATE TRIGGER IF NOT EXISTS records_fts_insert AFTER INSERT ON records BEGIN
      INSERT INTO records_fts (rowid, title, tags, body) VALUES (new.id, new.title, new.tags, new.body);
    END;
    CREATE TRIGGER IF NOT EXISTS records_fts_delete AFTER DELETE ON records BEGIN
      INSERT INTO records_fts (records_fts, rowid, title, tags, body) VALUES ('delete', old.id, old.title, old.tags, old.body);
    END;
    CREATE TRIGGER IF NOT EXISTS records_fts_update AFTER UPDATE OF title, tags, body ON records BEGIN
      INSERT INTO records_fts (records_fts, rowid, title, tags, body) VALUES ('delete', old.id, old.title, old.tags, old.body);
      INSERT INTO records_fts (rowid, title, tags, body) VALUES (new.id, new.title, new.tags, new.body);
    END;
    """
}
