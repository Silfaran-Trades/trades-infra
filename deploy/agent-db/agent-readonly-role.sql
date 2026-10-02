-- AI-agent masked read-only role — one-time setup of the trades_app database (IA-010;
-- production-infrastructure-first-deploy BR-27, AC-14, TM-3).
--
-- Derived from: ai-standards/templates/deploy/agent-readonly-role.sql.template
-- Authoritative rules: ai-standards/standards/infrastructure.md § "AI-agent access to
--   production"; invariants.md § "Agent production access".
-- Adaptations (spec § Data Model Changes; shaped after KHA's adaptation of the same template):
--   (a) SCHEMA-PER-BUNDLE. The template REVOKEs on `public` only. trades_app carries one
--       schema per bundle PLUS `shared` and `audit`, and bundles arrive over time — so the
--       REVOKE block is a LOOP over every non-system schema the database holds
--       (information_schema.schemata minus pg_*, information_schema and mask), never a list
--       that a new bundle silently falls outside of.
--   (b) IDEMPOTENT + rotation-friendly: re-running re-asserts the role's attributes and sets a
--       new password (the Postgres volume does not survive a rebuild — see WARNING).
--   (c) SELF-VERIFYING: the final DO block ABORTS the transaction if the role can still SELECT
--       any base relation outside `mask` — including through a grant made to PUBLIC, which a
--       per-role REVOKE cannot remove; so leg 2b withdraws every grant to PUBLIC on a base
--       relation first (the PostGIS reference relations are the live case).
--   (d) `CONNECT` on the `media` database is REVOKED FROM PUBLIC and never granted to the role:
--       the agent cannot reach the media database at all in stage 1 (fail-closed — it has no
--       manifest). `CONNECT` on trades_app is granted explicitly.
--
-- ============================ HOW TO RUN (OPERATOR ONLY) =====================
-- IA-004: an agent NEVER runs this. deploy/agent-db/provision-agent-role.sh is the lane
-- (host, after the first app promotion and after every later migration or inventory change):
-- it reads the password from /srv/trades/secrets/ai-readonly.env and pipes this file into
-- the postgres container's psql with -v ai_readonly_password=… (the :'var' syntax below does
-- the SQL-literal quoting). Then it runs generate-masked-views.sh — the `mask` schema starts
-- EMPTY, and an empty mask schema is fail-closed: the role can read nothing until then.
--
-- ORDER MATTERS: run AFTER the app's Phinx migrations have created the schemas. The loop
-- revokes whatever exists at run time, so a schema created LATER needs a re-run — which is
-- exactly why the lane is repeated after every migration.
--
-- CAVEAT (accepted): `ALTER ROLE … PASSWORD` sends the password in the statement text; the
-- production container ships log_statement = none for the superuser session, so it is not
-- logged. Do not raise the cluster's log_statement while running this file.
--
-- WARNING — WHERE THIS LIVES: the `ai_readonly` role and the `mask` schema live in the
-- DATABASE VOLUME, not in postgres-init/ (whose scripts fire only on an EMPTY volume).
-- Recreating `postgres-data` SILENTLY LOSES both: re-run the lane afterwards.
--
-- Design (all four legs required):
--   1. mask schema of views = the ergonomic front door (SELECT * and joins work)
--   2. ABSENCE of grants on the base schemas = the actual security boundary
--   3. fail-closed = a table without a generated view is invisible, not exposed
--   4. role-scoped audit = every agent query logged, no cluster-wide noise
-- NEVER grant this role superuser or pg_read_all_data: both bypass the mask.
-- ==============================================================================

\set ON_ERROR_STOP on

\if :{?ai_readonly_password}
\else
DO $guard$
BEGIN
    RAISE EXCEPTION 'ai_readonly_password is not set — re-run psql with -v ai_readonly_password=<generated>';
END
$guard$;
\endif

BEGIN;

CREATE SCHEMA IF NOT EXISTS mask;

-- The role. Created once; the ALTER is what makes a re-run (or a rotation) safe.
DO $create_role$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ai_readonly') THEN
        CREATE ROLE ai_readonly LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
            CONNECTION LIMIT 3;
    END IF;
END
$create_role$;

ALTER ROLE ai_readonly WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
    CONNECTION LIMIT 3
    PASSWORD :'ai_readonly_password';

-- Adaptation (d): this database only. CONNECT on media is withdrawn from PUBLIC (the
-- media-service connects as the cluster's owner role, which is unaffected).
GRANT CONNECT ON DATABASE trades_app TO ai_readonly;
REVOKE CONNECT ON DATABASE media FROM PUBLIC;
REVOKE CONNECT ON DATABASE media FROM ai_readonly;

-- ---------------------------------------------------------------------------
-- Leg 2 — the actual boundary: no grant on ANY base schema. Adaptation (a): a
-- loop over every non-system schema present NOW (identity, profile, company,
-- catalog, demand, chat, comms, telemetry, audit, shared, public, the dormant
-- modules' schemas, and whatever a later bundle adds). The REVOKEs are
-- belt-and-suspenders (a fresh role holds no grants); the rule they encode is
-- "never GRANT ai_readonly — or PUBLIC — anything on a base schema". The
-- self-verification block at the bottom is what proves it held.
-- ---------------------------------------------------------------------------
DO $revoke$
DECLARE
    s text;
BEGIN
    FOR s IN
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT IN ('mask', 'information_schema')
          AND schema_name NOT LIKE 'pg\_%'
        ORDER BY schema_name
    LOOP
        EXECUTE format('REVOKE ALL ON SCHEMA %I FROM ai_readonly', s);
        EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM ai_readonly', s);
        EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM ai_readonly', s);
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I REVOKE ALL ON TABLES FROM ai_readonly', s);
        RAISE NOTICE 'revoked ai_readonly on schema %', s;
    END LOOP;
END
$revoke$;

-- ---------------------------------------------------------------------------
-- Leg 2b — grants made to PUBLIC, which the per-role REVOKEs above cannot
-- remove (every role is a member of PUBLIC). The live case: the PostGIS
-- extension grants SELECT on its three `public` relations — spatial_ref_sys,
-- geometry_columns, geography_columns — to PUBLIC at CREATE EXTENSION time, so
-- ai_readonly could read them and the self-verification below (rightly)
-- refused the whole file on the first rehearsal. The data is reference data,
-- not personal data, but the boundary claim "no base relation readable" must be
-- true as stated. So: every SELECT (and any other privilege) granted to PUBLIC
-- on any base relation of a non-system schema is withdrawn — generically, not
-- by name, so a later extension or migration that grants PUBLIC is caught too.
-- SAFE FOR THE APPLICATION: it connects as the cluster's bootstrap superuser
-- (POSTGRES_USER, the role every env file names), and ACLs never bind a
-- superuser; a future NON-superuser application role would need its own
-- explicit GRANTs on these relations — state that in its migration.
-- ---------------------------------------------------------------------------
DO $revoke_public$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT n.nspname, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL aclexplode(c.relacl) a
        WHERE a.grantee = 0                              -- PUBLIC
          AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
          AND n.nspname NOT IN ('mask', 'pg_catalog', 'information_schema')
          AND n.nspname NOT LIKE 'pg\_%'
        ORDER BY n.nspname, c.relname
    LOOP
        EXECUTE format('REVOKE ALL ON %I.%I FROM PUBLIC', r.nspname, r.relname);
        RAISE NOTICE 'revoked PUBLIC on %.% (a grant to PUBLIC would reach ai_readonly)', r.nspname, r.relname;
    END LOOP;
END
$revoke_public$;

-- ---------------------------------------------------------------------------
-- Leg 1 — the front door. The views are generated from the mask manifest by
-- generate-masked-views.sh (run after EVERY schema or inventory change). Until
-- it runs, `mask` is empty and the role can read nothing.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA mask TO ai_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA mask TO ai_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA mask GRANT SELECT ON TABLES TO ai_readonly;

-- Session posture: read-only, bounded, pinned to the mask schema (spec § Data Model Changes).
ALTER ROLE ai_readonly SET search_path = mask;
ALTER ROLE ai_readonly SET default_transaction_read_only = on;
ALTER ROLE ai_readonly SET statement_timeout = '30s';
ALTER ROLE ai_readonly SET idle_in_transaction_session_timeout = '15s';

-- Leg 4 — audit trail: every statement this role runs, only this role.
ALTER ROLE ai_readonly SET log_statement = 'all';

-- ---------------------------------------------------------------------------
-- Self-verification (adaptation c) — the boundary, asserted, not assumed.
-- has_table_privilege() accounts for grants made to PUBLIC, which a per-role
-- REVOKE cannot remove. Catalog schemas are world-readable by Postgres design
-- and carry no row data; they are excluded deliberately.
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
    leaked text;
BEGIN
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY n.nspname, c.relname)
    INTO leaked
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
      AND n.nspname NOT IN ('mask', 'pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg\_%'
      AND has_table_privilege('ai_readonly', c.oid, 'SELECT');

    IF leaked IS NOT NULL THEN
        RAISE EXCEPTION 'IA-010 BOUNDARY BROKEN: ai_readonly can still SELECT base relations: % — check for grants made to PUBLIC', leaked;
    END IF;
END
$verify$;

COMMIT;

-- ============================ POST-RUN VERIFICATION ==========================
-- Operator-run, after generate-masked-views.sh (AC-14, TM-3):
--   SET ROLE ai_readonly;
--   SELECT * FROM identity.users;                 -- must FAIL (permission denied)
--   SELECT * FROM mask.identity__users;           -- OK — no inventoried column present
--   SELECT * FROM shared.messenger_messages;      -- must FAIL — un-inventoried table: no view
--   SELECT * FROM public.spatial_ref_sys;         -- must FAIL — PostGIS's grant to PUBLIC withdrawn
--   INSERT INTO mask.identity__users DEFAULT VALUES;   -- must FAIL (read-only)
--   RESET ROLE;
--   \c media ai_readonly                          -- must FAIL (no CONNECT)
-- The agent-facing DSN is its own secret under /trades/production/agent/database-url
-- (OUTSIDE /trades/production/env/*) with its own row in trades-docs/secrets-manifest.md —
-- never the application's DATABASE_URL. Backups still contain raw data: the mask protects
-- the query path only.
