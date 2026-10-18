# syntax=docker/dockerfile:1
#
# Trades — PostgreSQL 18 + PostGIS: the project's OWN database image (dev and production).
#
# WHY our own: the two upstream PostGIS images stopped fitting — `postgis/postgis:18-*` is
# amd64-only (production is an arm64 Graviton host) and the multi-arch `imresamu/postgis` tags
# froze on PostgreSQL 18.1 (2026-02), five patch releases and ~28 CVEs behind. This file is
# the same recipe both of them use — the OFFICIAL `postgres` Debian image plus the PGDG
# `postgresql-18-postgis-3` packages — so nothing about the cluster changes:
#   - same distribution (Debian 13 trixie) and same glibc (2.41) as the imresamu image it
#     replaces → the libc collations keep their version (2.41): an existing data directory
#     starts as-is, no re-init, no REINDEX (verify with the query in deploy/RUNBOOK.md);
#   - same data-directory layout (/var/lib/postgresql, the PG 18 versioned layout);
#   - the same entrypoint and POSTGRES_* variables (it IS the official image).
# The extensions the schema uses: postgis (this layer), pg_trgm and pgcrypto (contrib, already
# in the base image).
#
# Multi-arch: build linux/arm64 (production, Apple Silicon) and linux/amd64 (CI) from this one
# file — the base is a multi-arch index and PGDG publishes both architectures.
#
# Bumping: re-resolve the base digest with `docker buildx imagetools inspect postgres:<x.y>-trixie`
# and list the PostGIS builds PGDG offers with
#   docker run --rm postgres:<x.y>-trixie sh -c 'apt-get update -qq && apt-cache madison postgresql-18-postgis-3'
# then update POSTGIS_DEB below AND keep three strings equal: the LABEL version at the bottom,
# the dev compose tag (docker-compose.yml) — `make postgres-image-tag` checks both. PGDG rotates
# old builds out of trixie-pgdg (3.6.1 is already gone): a build failing with "Version … was not
# found" means this pin aged out — bump it, never loosen it. After a PostGIS bump an EXISTING database still carries the old
# extension version until `ALTER EXTENSION postgis UPDATE;` runs in it (deploy/RUNBOOK.md).

# PostgreSQL 18.6 on Debian trixie — the multi-arch index digest (BR-2: a tag is not a pin).
FROM postgres:18.6-trixie@sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336

# PostGIS 3.6.4 from the PGDG repository the base image already trusts (signed-by keyring in
# /etc/apt/sources.list.d/pgdg.list). Exact package version — an apt pin, not a range.
ARG POSTGIS_DEB=3.6.4+dfsg-2.pgdg13+1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "postgresql-${PG_MAJOR}-postgis-3=${POSTGIS_DEB}" \
        "postgresql-${PG_MAJOR}-postgis-3-scripts=${POSTGIS_DEB}"; \
    rm -rf /var/lib/apt/lists/*

LABEL org.opencontainers.image.title="trades-postgres" \
      org.opencontainers.image.description="PostgreSQL 18.6 + PostGIS 3.6.4 (official postgres:18.6-trixie + PGDG packages)" \
      org.opencontainers.image.version="18.6-postgis-3.6.4"
