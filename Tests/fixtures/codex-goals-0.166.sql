-- Actual owned Codex 0.166.0 schema and migration metadata; no user data.
CREATE TABLE _sqlx_migrations (
    version BIGINT PRIMARY KEY,
    description TEXT NOT NULL,
    installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    success BOOLEAN NOT NULL,
    checksum BLOB NOT NULL,
    execution_time BIGINT NOT NULL
);
CREATE TABLE thread_goals (
    thread_id TEXT PRIMARY KEY NOT NULL,
    goal_id TEXT NOT NULL,
    objective TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN (
        'active',
        'paused',
        'blocked',
        'usage_limited',
        'budget_limited',
        'complete'
    )),
    token_budget INTEGER,
    tokens_used INTEGER NOT NULL DEFAULT 0,
    time_used_seconds INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
);
CREATE TABLE thread_goal_continuation_deferrals (
    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES thread_goals(thread_id) ON DELETE CASCADE
);
INSERT INTO _sqlx_migrations(version,description,success,checksum,execution_time) VALUES (1,'thread goals',1,X'8CE6280244A0B4B39C7C37C7F67AFF1670EC963D2401CDF2ABCFEA9904102DB6CD99B7BEDF366267791A45EB12F17713',0);
INSERT INTO _sqlx_migrations(version,description,success,checksum,execution_time) VALUES (2,'thread goal continuation deferrals',1,X'F3FF7DE2FD89914820BEF371081E885FD17DF18A6FBDC432399A83255A8A01AA32FB7EEA5E4DE21A17BDA3DA16C49584',0);
