# Changelog

All notable changes to this project will be documented in this file.

The changelog format is based on [Keep a Changelog] and [CommonMark].

Versions here are the releases of sz-databricks, `<senzing_version>-<build>` (for example
`4.4.3-1`): the Senzing version the release carries and a build counter that restarts at 1 for
each Senzing version.

## [Unreleased]

### Changed

- `sz.sh register --sources JSON` (a JSON array of each source's register parameters) registers
  several sources in one operations run (`op=register` `sources=`); each is registered on its own and
  the result's `sources` lists each one's outcome. Install P10 registers every `--source` in one run
  instead of one run per source.
- The CORD load creates its tables with `delta.enableChangeDataFeed` and
  `delta.deletedFileRetentionDuration` (30 days) from `package.table_properties` in
  `testdata/cord/schema.yaml`, so registering a CORD source no longer warns about file retention.
- The AI-assisted guide waits for `resolve_state` `CAUGHT_UP` (`sz.sh wait` in the background) before
  Prompt 2, so the report covers every loaded record.

### Fixed

- The install no longer stops at P3 `SERVERLESS_ONLY` "cannot read this workspace's compute" when the
  Databricks CLI prints a one-time hint on stderr (CLI 1.24, under an AI agent: `databricks aitools install`):
  the preflight parses a successful command's stdout only and passes its stderr on.
- `sz.sh` waits after starting a stopped App until `databricks apps get` reads RUNNING
  (`app_start_wait_secs`, 600), and retries a request the Apps proxy answers 502 or 503 with its own
  page every `poll_interval_secs` for at most `app_unavailable_wait_secs` (300), then `APP_NOT_RUNNING`;
  the App's own JSON errors are never retried. An uninstall no longer fails on a stopped App.
- The watcher's `watch_pending` (and its state file's `status.pending`) is counted after it adopts the
  ingest drain position, every run and while an ingest run is still active, so `sz_health` no longer
  reports sources pending that a run already read; it logs the baselines it raised and the tables still
  pending.
- The watcher's first scheduled run after the bundle deploy no longer fails before setup has created
  `sz_app_state` and `sz_sources`: with neither present it logs that setup has not finished and succeeds
  without writing; with only one present it fails.

## [4.4.3-5] - 2026-11-12

### Added

- The Databricks App `sz-databricks`, headless: a JSON API with no pages, running as its own service
  principal. `GET /api`, `GET /api/health` (the `sz_health` row) and `GET /api/grants`; with CAN
  MANAGE on the App (else `NOT_MANAGER`), `POST /api/ops/{op}` and `POST /api/setup/{action}` start a
  run of the operations or setup job and answer its run id, `PUT /api/license` stores a license and
  `POST /api/rotate-password` replaces the engine password; `GET /api/runs/{run_id}` reports a run and
  its result. The App stops its compute after 30 minutes without a request (`app_idle_minutes`, 0
  keeps it running), and the watcher stops it should it not; `app_compute_size` and `app_group` set its size and its group. The bundle
  tarball carries its binary in `app/`.
- The install script starts the App after the deploy and waits until it is RUNNING
  (`APP_NOT_RUNNING`); `admin.sh pre` creates the group `sz-databricks-app`, which has WRITE on the
  secret scope, and `admin.sh app` adds the App's service principal to it.

### Changed

- `sz.sh` calls the App: it starts a stopped App, sends the operation and follows the run it
  started; `status` and `wait` read `GET /api/health`. Its output and exit codes are unchanged; an
  operation that changes the install needs CAN MANAGE on the App, which `--operator-group` grants.
  `uninstall` runs from your shell as before and also removes the App.

### Removed

- The install's refusal of a workspace holding a Databricks App (`APP_INSTALL_PRESENT`).

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
