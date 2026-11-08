# Changelog

All notable changes to this project will be documented in this file.

The changelog format is based on [Keep a Changelog] and [CommonMark].

Versions here are the releases of sz-databricks, tagged `v<major>.<minor>.<patch>`; a release
candidate is `v<major>.<minor>.<patch>-rc.<n>` and is published as a prerelease.

## [0.1.0-rc.1] - Unreleased

### Added

- First release candidate: Senzing entity resolution that runs entirely in your Databricks
  workspace. A Databricks App (setup, EULA and license, sources, start, pause and status), a setup
  job and an ingest job on classic job clusters, and the Senzing repository in Lakebase
  Autoscaling, all created by one Databricks Asset Bundle (`scripts/install.sh`).
- Sources: Unity Catalog tables through a mapping view (incremental input from Delta Change Data
  Feed), or a folder of JSON lines files in a Unity Catalog Volume.
- An entity mart in its own schema, kept current by the ingest run.
- Every release file is signed keyless with Sigstore; `scripts/verify-release.sh` checks the
  signatures and `SHA256SUMS` before install.

[Keep a Changelog]: https://keepachangelog.com/en/1.0.0/
[CommonMark]: https://commonmark.org/
