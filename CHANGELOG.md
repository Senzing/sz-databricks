# Changelog

All notable changes to this project will be documented in this file.

The changelog format is based on [Keep a Changelog] and [CommonMark].

Versions here are the releases of sz-databricks, `<senzing_version>-<build>` (for example
`4.4.3-1`): the Senzing version the release carries and a build counter that restarts at 1 for
each Senzing version.

## [4.4.3-3] - 2026-11-10

### Fixed

- A first install works: on an empty internal schema the App creates its tables (as setup defines
  them) and hands them to the jobs' service principal, so the Setup page opens before the first
  setup run instead of failing with `TABLE_OR_VIEW_NOT_FOUND` on `sz_app_state`. While it cannot
  create them, its pages name the cause and the grants to check.
- The install script checks the workspace before it creates anything, a dry run included
  (`scripts/preflight.sh`): it stops on a serverless-only workspace, and on your existing deployment
  of the bundle in another catalog, App or Lakebase project. Its bind step reads the deployment from
  the workspace, never a stale local cache.
- `scripts/admin.sh post` waits up to a minute for the group `admin.sh pre` just created.

### Changed

- Uninstall in the use guide: `databricks bundle destroy` with `--auto-approve`, what to do after an
  install that created no App, and the group and service principal the destroy leaves.
- The AI-assisted install checks for a serverless-only workspace in step 1 and the dry run's exit
  code in step 5.

## [4.4.3-2] - 2026-11-09


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
