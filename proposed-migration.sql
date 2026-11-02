-- =============================================================================
-- proposed-migration.sql
-- v2 bucket/KG/access additive migration
--
-- PURPOSE
--   Adds all tables and columns required by the v2 bucket/KG/access design.
--   Does NOT drop any existing table. Does NOT alter existing columns.
--   Only ADDs new tables and new columns to existing tables.
--
-- REQUIREMENTS
--   PostgreSQL 15+  (UNIQUE NULLS NOT DISTINCT used in widget_access)
--   pgvector        (vector type, HNSW indexes)
--   pg_trgm         (GIN trigram index on questions.text)
--
-- SAFE TO RUN AFTER schema.sql
--   All statements use IF NOT EXISTS / IF NOT EXISTS guards.
--   Re-running is idempotent.
--
-- USAGE
--   psql $DATABASE_URL -f docs/architecture/proposed-migration.sql
-- =============================================================================

-- Ensure required extensions are present
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;


-- =============================================================================
-- SECTION 1: Global canonical tables
-- =============================================================================

-- Global deduplicated responsibility library.
-- Each user_responsibilities row links back here after the dedup pass.
CREATE TABLE IF NOT EXISTS responsibilities (
    id              SERIAL PRIMARY KEY,
    canonical_text  TEXT        NOT NULL,
    embedding       vector(3072),
    source          TEXT        NOT NULL DEFAULT 'extracted',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 2: Tenant extraction tables
-- =============================================================================

-- Raw responsibility strings extracted from JDs/ERP for each employee.
-- responsibility_id is set after global dedup; nullable until then.
CREATE TABLE IF NOT EXISTS user_responsibilities (
    id                 BIGSERIAL PRIMARY KEY,
    tenant_id          UUID        NOT NULL REFERENCES tenants(id),
    user_id            UUID        NOT NULL REFERENCES tenant_users(id),
    text               TEXT        NOT NULL,
    embedding          vector(3072),
    responsibility_id  INT         REFERENCES responsibilities(id),
    chunk_index        INT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 3: Bucket model
-- =============================================================================

-- Role-like groupings replacing fixed job titles.
-- profile_embedding is the centroid of member responsibility embeddings.
CREATE TABLE IF NOT EXISTS buckets (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID        NOT NULL REFERENCES tenants(id),
    name             TEXT        NOT NULL,
    profile_embedding vector(3072),
    bucket_version   INT         NOT NULL DEFAULT 1,
    status           TEXT        NOT NULL DEFAULT 'draft'
                         CHECK (status IN ('draft', 'active', 'deprecated')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

-- Many-to-many: users assigned to buckets with role, score, and provenance.
CREATE TABLE IF NOT EXISTS user_bucket_map (
    id         BIGSERIAL PRIMARY KEY,
    tenant_id  UUID        NOT NULL REFERENCES tenants(id),
    user_id    UUID        NOT NULL REFERENCES tenant_users(id),
    bucket_id  UUID        NOT NULL REFERENCES buckets(id),
    role       TEXT        NOT NULL CHECK (role IN ('primary', 'secondary')),
    score      FLOAT,
    method     TEXT        CHECK (method IN ('auto', 'provisional', 'admin', 'inferred')),
    status     TEXT        NOT NULL DEFAULT 'active'
                   CHECK (status IN ('active', 'pending_review', 'expired')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, user_id, bucket_id)
);


-- =============================================================================
-- SECTION 4: Knowledge graph
-- =============================================================================

-- Vertices. tenant_id IS NULL → global node.
-- external_id is the PK of the referenced entity in its own table.
CREATE TABLE IF NOT EXISTS kg_nodes (
    id          BIGSERIAL PRIMARY KEY,
    tenant_id   UUID REFERENCES tenants(id),
    node_type   TEXT        NOT NULL
                    CHECK (node_type IN ('Bucket', 'Responsibility', 'Widget',
                                         'Question', 'DataSource', 'Employee')),
    external_id TEXT        NOT NULL,
    props       JSONB       NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, node_type, external_id)
);

-- Directed edges of the knowledge graph.
-- Edge types: HAS_RESPONSIBILITY, SERVED_BY, CONTAINS, ANSWERS,
--             FOLLOWED_BY, NEEDS, PERFORMS, IN
CREATE TABLE IF NOT EXISTS kg_edges (
    id          BIGSERIAL PRIMARY KEY,
    tenant_id   UUID REFERENCES tenants(id),
    from_node   BIGINT      NOT NULL REFERENCES kg_nodes(id),
    to_node     BIGINT      NOT NULL REFERENCES kg_nodes(id),
    edge_type   TEXT        NOT NULL,
    weight      FLOAT       NOT NULL DEFAULT 1.0,
    props       JSONB       NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, from_node, to_node, edge_type)
);


-- =============================================================================
-- SECTION 5: Coverage gap detection and generation queue
-- =============================================================================

-- Records where a bucket has no widget covering a given responsibility.
-- Drives the generation queue. tenant_id nullable = cross-tenant gap.
CREATE TABLE IF NOT EXISTS bucket_coverage_gaps (
    id                 BIGSERIAL PRIMARY KEY,
    bucket_id          UUID        NOT NULL REFERENCES buckets(id),
    responsibility_id  INT         NOT NULL REFERENCES responsibilities(id),
    tenant_id          UUID        REFERENCES tenants(id),
    member_count       INT         NOT NULL DEFAULT 1,
    status             TEXT        NOT NULL DEFAULT 'open'
                           CHECK (status IN ('open', 'accumulating', 'ready',
                                             'generating', 'in_review', 'closed')),
    resolved_by        TEXT        CHECK (resolved_by IN ('link', 'fork', 'generate')),
    detected_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (bucket_id, responsibility_id)
);

-- Priority work queue for the widget generation pipeline.
-- Supports coalescing duplicate gap requests before a run starts.
CREATE TABLE IF NOT EXISTS generation_queue (
    id             BIGSERIAL PRIMARY KEY,
    gap_id         BIGINT      NOT NULL REFERENCES bucket_coverage_gaps(id),
    priority       FLOAT       NOT NULL DEFAULT 0.0,
    state          TEXT        NOT NULL DEFAULT 'waiting'
                       CHECK (state IN ('waiting', 'coalescing', 'running', 'done', 'failed')),
    coalesce_until TIMESTAMPTZ,
    tenant_id      UUID        REFERENCES tenants(id),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Audit log of every LLM generation attempt.
-- gap_id is nullable for manual triggers.
CREATE TABLE IF NOT EXISTS generation_runs (
    id                 BIGSERIAL PRIMARY KEY,
    responsibility_id  INT         NOT NULL REFERENCES responsibilities(id),
    gap_id             BIGINT      REFERENCES bucket_coverage_gaps(id),
    intents            JSONB       NOT NULL DEFAULT '[]',
    output             JSONB       NOT NULL DEFAULT '[]',
    tokens_used        INT,
    status             TEXT        NOT NULL DEFAULT 'running'
                           CHECK (status IN ('running', 'completed', 'failed')),
    started_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at       TIMESTAMPTZ
);


-- =============================================================================
-- SECTION 6: Question library
-- =============================================================================

-- Global canonical question bank. Replaces cross_questions.
-- aliases[] holds alternative phrasings for fuzzy matching.
CREATE TABLE IF NOT EXISTS questions (
    id         SERIAL PRIMARY KEY,
    text       TEXT        NOT NULL,
    intent     TEXT,
    embedding  vector(3072),
    source     TEXT        NOT NULL DEFAULT 'seed'
                   CHECK (source IN ('seed', 'promoted', 'admin')),
    aliases    TEXT[]      NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (text)
);

-- Many-to-many: widgets tagged with the questions they answer.
-- Replaces widget_task_tags.
CREATE TABLE IF NOT EXISTS widget_questions (
    widget_id    INT     NOT NULL REFERENCES widgets(id),
    question_id  INT     NOT NULL REFERENCES questions(id),
    score        FLOAT   NOT NULL DEFAULT 1.0,
    PRIMARY KEY (widget_id, question_id)
);

-- Markov-style transition counts between questions within a bucket.
-- probability is normalised; recomputed on update by the learner.
CREATE TABLE IF NOT EXISTS question_transitions (
    id                BIGSERIAL PRIMARY KEY,
    from_question_id  INT         NOT NULL REFERENCES questions(id),
    to_question_id    INT         NOT NULL REFERENCES questions(id),
    bucket_id         UUID        NOT NULL REFERENCES buckets(id),
    count             INT         NOT NULL DEFAULT 1,
    probability       FLOAT       NOT NULL DEFAULT 0.0,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (from_question_id, to_question_id, bucket_id)
);


-- =============================================================================
-- SECTION 7: Interaction events (replaces widget_render_events)
-- =============================================================================

-- Granular per-user widget interaction events.
-- event values: opened, dwell, thumbs_up, thumbs_down, hide, pin, follow_up
CREATE TABLE IF NOT EXISTS widget_events (
    id          BIGSERIAL PRIMARY KEY,
    tenant_id   UUID        NOT NULL REFERENCES tenants(id),
    user_id     UUID        NOT NULL REFERENCES tenant_users(id),
    widget_id   INT         NOT NULL REFERENCES widgets(id),
    event       TEXT        NOT NULL,
    value       FLOAT,
    session_id  TEXT,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 8: Access control
-- =============================================================================

-- Inferred access profile per user. Rebuilt on ERP sync.
-- (tenant_id, user_id) is unique — one profile per user per tenant.
CREATE TABLE IF NOT EXISTS user_access_profile (
    id            BIGSERIAL PRIMARY KEY,
    tenant_id     UUID        NOT NULL REFERENCES tenants(id),
    user_id       UUID        NOT NULL REFERENCES tenant_users(id),
    level         TEXT        NOT NULL,
    department    TEXT,
    region        TEXT,
    team_ids      TEXT[]      NOT NULL DEFAULT '{}',
    manager_chain TEXT[]      NOT NULL DEFAULT '{}',
    overrides     JSONB       NOT NULL DEFAULT '{}',
    inferred_at   TIMESTAMPTZ,
    confirmed_at  TIMESTAMPTZ,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, user_id)
);

-- Access policy per widget. tenant_id IS NULL = global default policy row.
-- Requires PG 15+ UNIQUE NULLS NOT DISTINCT to allow one global + one per tenant.
CREATE TABLE IF NOT EXISTS widget_access (
    id                  SERIAL PRIMARY KEY,
    widget_id           INT         NOT NULL REFERENCES widgets(id),
    tenant_id           UUID        REFERENCES tenants(id),
    min_level           TEXT,
    allowed_roles       TEXT[]      NOT NULL DEFAULT '{}',
    allowed_departments TEXT[]      NOT NULL DEFAULT '{}',
    data_scope          TEXT        NOT NULL DEFAULT 'company'
                            CHECK (data_scope IN ('self', 'team', 'department', 'company')),
    sensitivity         TEXT        NOT NULL DEFAULT 'internal'
                            CHECK (sensitivity IN ('public', 'internal', 'confidential', 'restricted')),
    tenant_overrides    JSONB       NOT NULL DEFAULT '{}',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (widget_id, tenant_id)
);

-- Immutable audit log of every access decision.
CREATE TABLE IF NOT EXISTS access_decisions (
    id          BIGSERIAL PRIMARY KEY,
    tenant_id   UUID        NOT NULL REFERENCES tenants(id),
    user_id     UUID        NOT NULL REFERENCES tenant_users(id),
    widget_id   INT         NOT NULL REFERENCES widgets(id),
    decision    TEXT        NOT NULL CHECK (decision IN ('allow', 'scoped', 'deny')),
    reason      TEXT,
    ts          TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 9: Bucket learner signals
-- =============================================================================

-- Aggregated behavioural affinity per (user, bucket).
-- Feeds bucket re-assignment when affinity with a non-primary bucket grows.
CREATE TABLE IF NOT EXISTS user_bucket_affinity (
    id                  BIGSERIAL PRIMARY KEY,
    tenant_id           UUID        NOT NULL REFERENCES tenants(id),
    user_id             UUID        NOT NULL REFERENCES tenant_users(id),
    bucket_id           UUID        NOT NULL REFERENCES buckets(id),
    score               FLOAT       NOT NULL DEFAULT 0.0,
    distinct_questions  INT         NOT NULL DEFAULT 0,
    distinct_days       INT         NOT NULL DEFAULT 0,
    last_seen           TIMESTAMPTZ,
    status              TEXT        NOT NULL DEFAULT 'candidate'
                            CHECK (status IN ('candidate', 'inferred_secondary', 'confirmed', 'expired')),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, user_id, bucket_id)
);

-- Audit trail of every bucket add/remove/confirm/expire action.
CREATE TABLE IF NOT EXISTS bucket_assignment_decisions (
    id                    BIGSERIAL PRIMARY KEY,
    tenant_id             UUID        NOT NULL REFERENCES tenants(id),
    user_id               UUID        NOT NULL REFERENCES tenant_users(id),
    bucket_id             UUID        NOT NULL REFERENCES buckets(id),
    action                TEXT        NOT NULL CHECK (action IN ('add', 'remove', 'confirm', 'expire')),
    evidence_question_ids INT[]       NOT NULL DEFAULT '{}',
    score                 FLOAT,
    decided_by            TEXT        NOT NULL CHECK (decided_by IN ('system', 'admin', 'user')),
    ts                    TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =============================================================================
-- SECTION 10: Additive column migrations on existing tables
-- =============================================================================

-- tenant_users: add manager hierarchy and JD change detection
ALTER TABLE tenant_users
    ADD COLUMN IF NOT EXISTS manager_id TEXT;

ALTER TABLE tenant_users
    ADD COLUMN IF NOT EXISTS jd_hash TEXT;

-- widgets: add v2 form, fork, spec override, status, and version fields
-- status and version have NOT NULL defaults — safe for all existing rows.
ALTER TABLE widgets
    ADD COLUMN IF NOT EXISTS form TEXT
        CHECK (form IN ('kpi', 'trend', 'comparison', 'breakdown', 'alert', 'forecast', 'action'));

ALTER TABLE widgets
    ADD COLUMN IF NOT EXISTS parent_widget_id INT REFERENCES widgets(id);

ALTER TABLE widgets
    ADD COLUMN IF NOT EXISTS spec_overrides JSONB;

ALTER TABLE widgets
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('draft', 'active', 'deprecated'));

ALTER TABLE widgets
    ADD COLUMN IF NOT EXISTS version INT NOT NULL DEFAULT 1;

-- user_widget_bundle: add explanation path for v2 bundle builder
ALTER TABLE user_widget_bundle
    ADD COLUMN IF NOT EXISTS path JSONB;

-- rag_answers: add data_version for cache invalidation (replaces v1 role_id semantics)
-- role_id is NOT dropped — retained for v1 RAG path until retired.
ALTER TABLE rag_answers
    ADD COLUMN IF NOT EXISTS data_version TEXT;


-- =============================================================================
-- SECTION 11: Indexes
-- =============================================================================

-- ── pgvector HNSW indexes (cosine distance) ──────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_responsibilities_embedding_hnsw
    ON responsibilities USING hnsw (embedding vector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_user_responsibilities_embedding_hnsw
    ON user_responsibilities USING hnsw (embedding vector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_buckets_profile_embedding_hnsw
    ON buckets USING hnsw (profile_embedding vector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_questions_embedding_hnsw
    ON questions USING hnsw (embedding vector_cosine_ops);

-- ── GIN trigram full-text index ───────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_questions_text_trgm
    ON questions USING gin (text gin_trgm_ops);

-- ── Tenant-scoped B-tree indexes ──────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_user_responsibilities_tenant
    ON user_responsibilities (tenant_id);

CREATE INDEX IF NOT EXISTS idx_buckets_tenant
    ON buckets (tenant_id);

CREATE INDEX IF NOT EXISTS idx_user_bucket_map_tenant
    ON user_bucket_map (tenant_id);

CREATE INDEX IF NOT EXISTS idx_bucket_coverage_gaps_tenant
    ON bucket_coverage_gaps (tenant_id);

CREATE INDEX IF NOT EXISTS idx_generation_queue_tenant
    ON generation_queue (tenant_id);

CREATE INDEX IF NOT EXISTS idx_widget_events_tenant
    ON widget_events (tenant_id);

CREATE INDEX IF NOT EXISTS idx_user_access_profile_tenant
    ON user_access_profile (tenant_id);

CREATE INDEX IF NOT EXISTS idx_access_decisions_tenant
    ON access_decisions (tenant_id);

CREATE INDEX IF NOT EXISTS idx_user_bucket_affinity_tenant
    ON user_bucket_affinity (tenant_id);

CREATE INDEX IF NOT EXISTS idx_bucket_assignment_decisions_tenant
    ON bucket_assignment_decisions (tenant_id);

-- ── Knowledge graph traversal indexes ────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_kg_edges_from_type
    ON kg_edges (from_node, edge_type);

CREATE INDEX IF NOT EXISTS idx_kg_edges_to_type
    ON kg_edges (to_node, edge_type);

-- ── Coverage gap lookup ───────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_bucket_coverage_gaps_bucket_status
    ON bucket_coverage_gaps (bucket_id, status);

-- ── Generation queue dequeue order ───────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_generation_queue_state_priority
    ON generation_queue (state, priority DESC);

-- ── User affinity lookups ─────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_user_bucket_affinity_tenant_user
    ON user_bucket_affinity (tenant_id, user_id);

-- ── Access decision audit ─────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_access_decisions_tenant_user_ts
    ON access_decisions (tenant_id, user_id, ts);

-- ── Widget event analytics ────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_widget_events_tenant_ts
    ON widget_events (tenant_id, ts);

CREATE INDEX IF NOT EXISTS idx_widget_events_user_ts
    ON widget_events (user_id, ts);


-- =============================================================================
-- END OF MIGRATION
-- Run: psql $DATABASE_URL -f docs/architecture/proposed-migration.sql
-- =============================================================================
