-- Databases for the Trades workspace.
--
-- This file runs ONCE, on a FIRST postgres boot against an empty data directory. Editing it
-- does not touch an existing cluster — a line removed here still exists as a live database
-- until someone drops it by hand or recreates the volume.

-- ── The modular-monolith app (ADR-076) ──────────────────────────────────────
-- ONE database for the whole backend; each bundle owns a SCHEMA inside it
-- (identity.*, company.*, catalog.*, comms.*, profile.*, demand.*, chat.*, shared.*),
-- created by the app's own Phinx migrations — never here.
CREATE DATABASE trades_app;
CREATE DATABASE trades_app_test;

-- ── media-service ───────────────────────────────────────────────────────────
-- The one context that stays a separate service, permanently: different runtime (ClamAV,
-- MinIO, image processing), two tables, six routes, and its only coupling to the app is two
-- inbound HTTP calls. Since Wave 8 this database also holds its `messenger_messages` queue.
--
-- `media_test` was MISSING from this file for the whole microservices era — every other
-- service that needed one had it listed, so media-service's integration suite could not run
-- on a freshly-provisioned workspace without a manual `CREATE DATABASE`. Added at Wave 8,
-- when it was found by running that suite.
CREATE DATABASE media;
CREATE DATABASE media_test;

-- ── RETIRED AT WAVE 8 — the migration's point of no return ──────────────────
-- These nine were the microservices era:
--
--   identity  company  comms  catalog  demand
--   profile_service  profile_service_test  chat  chat_test
--
-- Every one of them is a SCHEMA inside `trades_app` now. They stayed listed here through
-- Waves 1-7 because the rollback path depended on them surviving: a wave could be undone by
-- re-pointing a service at its old database. Wave 8 is where that path is deliberately
-- closed (migration plan § 9).
--
-- REMOVING THEM HERE DROPS NOTHING. A cluster that already exists still has all nine, with
-- their data, until someone runs `DROP DATABASE` — which is an operational decision, taken
-- once the app has run long enough on `trades_app` to be trusted, and never as a side effect
-- of a config edit. What this file now guarantees is that a FRESH environment gets the
-- monolith and nothing else.
