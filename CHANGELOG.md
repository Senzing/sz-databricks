# Changelog

All notable changes to this project will be documented in this file.

The changelog format is based on [Keep a Changelog] and [CommonMark].

Versions here are the releases of sz-databricks, `<senzing_version>-<build>` (for example
`4.4.3-1`): the Senzing version the release carries and a build counter that restarts at 1 for
each Senzing version.

## [Unreleased]

### Changed

- A release is 6 files and carries one signature, `SHA256SUMS.sigstore.json`: `SHA256SUMS` is
  signed and holds the SHA-256 of every file, so the per-file `.sigstore.json` files are gone.
  Verify the signature, then `sha256sum -c SHA256SUMS`; `scripts/verify-release.sh` and the
  install script do both. The App binary and the engine JAR ship only in the bundle tarball.

## [4.4.3-1] - 2026-11-09

### Added

- First release: Senzing entity resolution that runs entirely in your Databricks
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
