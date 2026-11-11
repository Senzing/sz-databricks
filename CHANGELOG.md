# Changelog

All notable changes to this project will be documented in this file.

The changelog format is based on [Keep a Changelog] and [CommonMark].

Versions here are the releases of sz-databricks, `<senzing_version>-<build>` (for example
`4.4.3-1`): the Senzing version the release carries and a build counter that restarts at 1 for
each Senzing version.

## [4.4.3-4] - 2026-11-11

### Added

- `sz-databricks-cord-data.tar.gz`, a file of every release: the official Senzing CORD data, Las
  Vegas collection (about 200,000 records over six source systems), reshaped into normalized source
  tables, one directory of CSV files per source system, with `load.sql` to load them into Delta tables
  (change data feed on) and a `README.md`. For evaluation only, not for operational use.
- The install script is a release file of its own, `sz-databricks-install-<release>.sh`: one run
  verifies the release, checks the workspace (every problem listed at once as `problem=<CODE>: …`
  before anything changes), installs, accepts the EULA (`--accept-eula`), stores the license
  (`--license-file`), grants (`--operator-group`, `--consumer-group`), registers sources (`--source`)
  and waits until they resolve; `--dry-run`, `--check-only`, `--upgrade`, `--alert-email`,
  `--lakebase-vcpu` and `--set <name>=<value>` for any other bundle variable.
- `scripts/sz.sh` operates the install from the command line: `status`, `wait`, `register` (tables
  through a mapping view, or a Volume folder), `unregister`, `enable`, `disable`, `purge-source`,
  `reload`, `validate`, `confirm-removal`, `requeue-rejected`, `grants`, `run`, `pause`, `resume`,
  `stop`, `flush`, `accept-eula`, `license`, `rotate-password`, `setup`, `check`, `upgrade`, `prune`,
  `logs` and `uninstall`. Each prints one JSON result; each is also a run of the operations job
  `sz-databricks-ops` in the Jobs UI.
- The `sz_health` view in the mart schema: `overall` (`OK`, `WARN`, `FAIL`), `fail_codes`, `warn_codes`
  and one column per check. Every code and its fix is in the troubleshooting guide.
- The `sz-databricks status` dashboard, the hourly `sz-databricks health` alert (mails `--alert-email`)
  and the read-only SQL notebook `sz_quickstart`.

### Changed

- Upgrading is explicit: the new release's install script with `--upgrade`, or `sz.sh upgrade`. The
  watcher reports `UPGRADE_PENDING` and never upgrades by itself.
- Uninstall is `sz.sh uninstall --confirm "delete data"` (it removes everything, purges the Lakebase
  project and checks that nothing remains) or `--confirm uninstall --keep-data`.
- The guides describe one command-line path, install to results to health; the AI-assisted guide runs
  it with no browser step and adds a local Streamlit report.

### Removed

- The Databricks App, its group `sz-databricks-app` and its pages: every task is `sz.sh` or the install
  script. An install with the App is refused (`APP_INSTALL_PRESENT`): uninstall it first.

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
