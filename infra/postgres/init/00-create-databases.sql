-- Per-service databases. One DB per service (ai-standards backend.md).
-- Add a new line here when scaffolding a new service that needs Postgres.

CREATE DATABASE identity;
CREATE DATABASE company;
CREATE DATABASE comms;
CREATE DATABASE catalog;
CREATE DATABASE media;
CREATE DATABASE profile_service;
CREATE DATABASE profile_service_test;
CREATE DATABASE demand;
CREATE DATABASE chat;
CREATE DATABASE chat_test;

-- Modular-monolith app database (ADR-076). ONE database for the whole backend;
-- each bundle owns a SCHEMA inside it (identity.*, company.*, ...), created by the
-- app's own Phinx migrations — never here.
--
-- The per-service databases above are the microservices era and stay until
-- migration Wave 8 retires them (the rollback path depends on them surviving).
CREATE DATABASE trades_app;
CREATE DATABASE trades_app_test;
