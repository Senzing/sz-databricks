[sz-databricks](../README.md) / Troubleshooting

# Troubleshooting

Start with the one view that summarizes everything, or `sz.sh status`, which prints the same row and
each code's fix:

```sql
SELECT overall, fail_codes, warn_codes, warnings FROM <catalog>.senzing.sz_health;
```

`overall` is `OK`, `WARN` or `FAIL`; `warnings` lists every failing or warning check by the
[codes below](#sz_health-and-script-codes), the failing ones first. `fail_codes` lists only the codes
that make `overall` read `FAIL`, `warn_codes` the rest. `UPGRADE_PENDING` is a `FAIL`: no ingest run
starts until `sz.sh upgrade` runs (the install script's `--upgrade` runs it). These pages assume
SENZING® entity resolution installed with the default names (`sz-databricks`, `senzing_internal`,
`senzing`); `sz.sh` is `<dir>/scripts/sz.sh` in the bundle directory the install script unpacked.

## Where to look

| Failure | Read |
|---|---|
| the install | the install script's output: each step (`==> P<n> …`) is printed before it runs, and a failed step says what to fix; run the script again with the same options once it is fixed |
| an `sz.sh` operation | its JSON: `code`, `message`, `fix` and `run_url`; `sz.sh logs <run id>` shows the run's state, tasks and result |
| a setup run | `sz_health.setup_status`, `setup_error` and `last_setup_warnings`, then the `sz-databricks-setup` job's runs and their driver log |
| an ingest run | `sz_health.last_run_state` and `last_run_error`, then the `sz-databricks-ingest` job's runs and their driver log: `MART_REFRESH` lines show where a mart refresh spends its time (`read_ms`, `get_ms`, `merge_ms`, `delete_ms`) |
| the watcher (a change starts no run, a pause does not finish) | `sz_health.watch_error` and `watch_pending`, then the `sz-databricks-watch` job's runs and their output |
| a source | `sz_health.source_errors` (each failed source, its error and the fix); `sz.sh grants <CODE>` for the grants it needs; `sz.sh validate <CODE>` |
| a file of a files source | `<catalog>.senzing_internal._file_events` (each failed, held or removed file, and why) and `_files_<source>_ledger_v` |
| records the engine rejected | `<catalog>.senzing_internal._ingest_quarantine`, with each record's error |
| entities the mart could not read | `<catalog>.senzing_internal._quarantine`, with the error |
| a slow or lagging run | the `sz-databricks status` dashboard, and `<catalog>.senzing_internal._loop_health` ([use](use.md#how-far-behind-the-mart-is)) |

## Symptoms

| Symptom | Cause and fix |
|---|---|
| `sz-databricks-install-<release>.sh: the local check found <n> problem(s); nothing has been changed:` then `problem=<CODE>: …` lines | Each line names a code and what to fix: a missing tool, a release file not downloaded, a license file that is not base64. Fix them all, then run the script again. |
| `sz-databricks-install-<release>.sh: the signature of SHA256SUMS does not verify: …` | `SHA256SUMS` or `SHA256SUMS.sigstore.json` is not the one this release signed (another release's, or damaged): download both again from the same release and pass that release (the tag without its `v`). Install nothing until it passes. |
| `sz-databricks-install-<release>.sh: a release file does not match SHA256SUMS` (the failing file printed above) | A file is damaged, from another release or not completely downloaded: download it again from the same release. |
| `sz-databricks-install-<release>.sh: SHA256SUMS does not list sz-databricks-bundle-<release>.tar.gz` | The bundle is not this release's: download the release's files together. |
| `sz-databricks-install-<release>.sh: the check found <n> problem(s)` | The codes it prints are in the [table below](#sz_health-and-script-codes): `SERVERLESS_ONLY`, `DEPLOYMENT_DIFFERS`, `APP_INSTALL_PRESENT`, `PROJECT_SOFT_DELETED`, `NOT_INSTALLED`, `EULA_NOT_ACCEPTED` (a new install without `--accept-eula`), `NODE_SIZING`, `PG_TOO_SMALL`, `LICENSE_INVALID`. Nothing was changed. |
| `node-sizing.sh: worker_task_slots <n> is above the <m> engine threads one <node type> worker holds: …` | One worker of that node type cannot give each engine thread 1 GB beside the heap, the engine and the Databricks reserve; the message shows the numbers. Pass `--set worker_task_slots=<m>` or less, a smaller `--set executor_memory=…`, or a `--set node_type_id=…` with more memory ([Sizing](use.md#sizing)). |
| `node-sizing.sh: node type <node type> is not in this workspace's node types` | `node_type_id` names a type this workspace does not offer: pick one from `databricks clusters list-node-types`. |
| Deploy fails: "must have 'servicePrincipal.user' role on the service principal" | The deploying user lacks the **Service principal: User** role on the jobs' principal. The install gives it to the user running the install script; run the install as that user. |
| `sz-databricks-install-<release>.sh: EULA_NOT_ACCEPTED: setup did not run` | Read the agreement at the URL it printed; to accept it, run the script again with `--accept-eula`. |
| `sz-databricks-install-<release>.sh: setup failed (above): fix what it says, then re-run this script` | The setup error above it carries a code; its fix is in the [table below](#sz_health-and-script-codes). The rows that follow cover the common setup errors. |
| Setup fails: "… does not match the digest compiled into this release: refused" | The engine payload (the Senzing runtime archives the jobs run) is not this release's: run `sz.sh setup` again to download it again, or stage it from the matching release ([install](install.md#restricted-network-stage-the-payload)). |
| Setup fails: "download of …: HTTP …" | The job cluster cannot reach GitHub: allow the egress hosts, or stage the payload in the Volume ([install](install.md#restricted-network-stage-the-payload)). |
| Setup fails: "download of …: HTTP 403" or "HTTP 429" | GitHub refused or rate-limited the download: retry later, or stage the payload in the Volume. |
| Setup fails: "download of … did not finish within download_timeout_seconds" | The transfer from GitHub stalled or is too slow: retry, or stage the payload in the Volume. |
| Setup: `password authentication failed for user '<id>'` | The jobs' principal (`<id>`) has no Lakebase role: `databricks postgres create-role projects/<project-id>/branches/production --role-id sz-jobs --json '{"spec":{"identity_type":"SERVICE_PRINCIPAL","postgres_role":"<id>","auth_method":"LAKEBASE_OAUTH_V1","attributes":{"createdb":true,"createrole":true}}}'`; `sz.sh setup`. |
| Setup fails: `native postgres login is disabled for this endpoint` | The engine's password role cannot log in. Turn native login on with `databricks postgres update-project projects/<project-id> spec.enable_pg_native_login --json '{"spec":{"enable_pg_native_login":true}}'`, then `sz.sh setup`. |
| You cannot create either of those | Create the database and roles by hand from `scripts/lakebase-setup.sql` in the bundle directory, then run setup without its Lakebase admin step: on the `sz-databricks-setup` job, choose **Run now with different parameters** and set `action` to `install` and `admin` to `skip`. |
| After an upgrade the run ends `mart_failed`: "The entity mart has an earlier release's tables" | The mart is now an entity map without `entity_doc`; nothing was dropped. `sz.sh pause`, run the statements the error prints (they queue every entity the old mart held, then drop its tables) and `sz.sh resume`: the next refresh rebuilds the mart. |
| A change starts no run | The watcher runs every 5 minutes and waits a few minutes for its serverless compute: allow about 10 minutes. It starts nothing while ingest is paused (`PAUSED`), a run or setup is active or an upgrade is pending (`UPGRADE_PENDING`). Otherwise read `sz_health.watch_error`. |
| `sz.sh` exits 2: `CONFIRM_REQUIRED` | A destructive operation repeats its target as the confirm word: `--confirm <CODE>` for `purge-source` and `reload`, `--confirm "delete data"` or `--confirm uninstall --keep-data` for `uninstall`. |
| One source fails, others continue | It is isolated: its position does not advance and `source_errors` shows the error with the fix. Fix the view or the grant; the next run tries again. |
| Registering: `SOURCE_VIEW_CONTRACT` | The check counted rows that break the [mapping view rules](use.md#write-a-mapping-view), each named with its count: `RECORD_ID NULL or blank`, `untrimmed RECORD_ID`, `duplicate RECORD_ID`, `DATA_SOURCE other than the registered code` or a missing column. Fix the view, then register again. |
| A run fails a source: `duplicate RECORD_ID in <view>` | The view returned one `RECORD_ID` twice; other sources continue. Make the view return one row per key (aggregate child rows), and the next run tries again. |
| The source's error says a table or view is gone or renamed | Restore it, or register the source again. |
| A rewritten file is not read again | It kept its size within the same second: write it under a new name, or wait a second. |
| A failed task | The ingest task retries once, and runs are safe to replay. |
| The mart trails ingest more and more | Look at the latest `_loop_health` rows: a growing `backlog_affected` with high `get_ms` or `merge_ms` in `MART_REFRESH` means the cluster (slots) or Lakebase is too small for the load. `pg_waits`, and `pg_connections_used` near `pg_connections_limit`, point at Lakebase. |
| `LOOP_HEALTH_ERROR` in the run log | One signal could not be read (its `part`); that column is NULL and the run is unaffected. |
| `_affected` or `_loop_health` keeps many small files | The run compacts and vacuums them daily. |
| A budget alert fired | Look for a run that does not end (`sz_health.loop_running`; a busy run ends after 6 hours). The job clusters bill only while a run lasts; the watcher's runs are short. `sz.sh pause` stops new runs. |
| No budget alert ever arrives | Budgets are set outside sz-databricks: a Databricks budget (account admin) and an AWS budget. See [What it costs to run](../README.md#what-it-costs-to-run). |

## `sz_health` and script codes

`sz_health` reports these codes, and `sz.sh` and the install script print them in `code` (or as
`problem=<CODE>: …`). **FAIL** codes make `overall` read `FAIL`; **WARN** codes `WARN`; the rest
only come from a script.

| Code | Means | Fix |
|---|---|---|
| `USAGE` | bad arguments, or a tool or release file missing | `sz.sh --help`, or the install script's `--help`; install the tool or download the file it names |
| `NOT_INSTALLED` | no install record, or the jobs are not found | run the install script ([install](install.md)) |
| `APP_INSTALL_PRESENT` | your deployment is an install with the Databricks App, which this release no longer has | uninstall it with the release you installed it from, then install this release |
| `PROJECT_SOFT_DELETED` | the Lakebase project is soft-deleted (Databricks keeps it 7 days), so its id is taken | `databricks postgres delete-project projects/<id> --purge`, then install again |
| `SERVERLESS_ONLY` | the workspace has no classic compute, which the setup and ingest jobs run on | install in a workspace with classic compute for jobs |
| `DEPLOYMENT_DIFFERS` | you already have a deployment of this bundle with another catalog or Lakebase project (one user has one per target) | to upgrade it, run the install script again with the catalog and project it names; to install elsewhere, uninstall it first ([uninstall](use.md#uninstall)) |
| `NODE_SIZING` | the node type cannot hold the engine threads | pick a node type, `executor_memory` or `worker_task_slots` from the printed numbers ([Sizing](use.md#sizing)) |
| `EULA_NOT_ACCEPTED` (FAIL) | the Senzing EULA (this version) is not accepted | read the EULA, then the install script's `--accept-eula` or `sz.sh accept-eula --yes` |
| `EULA_VALUE` | the EULA acceptance phrase is wrong | pass `--accept-eula` (or `accept-eula --yes`) |
| `LICENSE_INVALID` | the license is not base64, empty or too large | use the license file Senzing, Inc. sent |
| `LICENSE_REJECTED` | the Senzing engine refused the license | ask Senzing, Inc. for a valid license |
| `LICENSE_EXPIRED` (FAIL) | the license expired | `sz.sh license --file <license file>` with a new one |
| `LICENSE_EXPIRING` (WARN) | the license expires within 30 days | ask Senzing, Inc. for a renewal, then `sz.sh license --file <license file>` |
| `LICENSE_NEAR_LIMIT` (WARN) | the records are at 90% of the license's record limit or more | ask Senzing, Inc. for a larger license |
| `LICENSE_EVALUATION` (WARN) | no license is installed (evaluation mode) or an evaluation one; the engine takes few records | `sz.sh license --file <license file>` (ask Senzing, Inc. for one) |
| `PASSWORD_MISSING` | no `pg_engine_password` secret | `sz.sh rotate-password` |
| `SETUP_NOT_RUN` (FAIL) | setup has never completed | `sz.sh setup` |
| `SETUP_FAILED` (FAIL) | setup failed, or has run longer than it may | fix the cause in `setup_error` ([Symptoms](#symptoms)), then `sz.sh setup` |
| `SETUP_RUNNING` (WARN) | setup is running; ingest starts once it ends | wait for it; `sz.sh status` |
| `UPGRADE_PENDING` (FAIL) | the deployed release is newer than the one setup installed; no ingest run starts | `sz.sh upgrade` ([use](use.md#upgrade)) |
| `DOWNGRADE` (FAIL) | the deployed release is older than the one setup installed | install that release or a newer one |
| `PG_UNREACHABLE` (FAIL) | cannot connect to the Lakebase (Postgres) endpoint | check the Lakebase project and endpoint; `sz.sh check`. A first connection after Lakebase scaled to zero waits while it wakes |
| `LAKEBASE_LOGIN` | the Lakebase admin login failed | the installer needs CAN_MANAGE on the Lakebase project |
| `PG_TOO_SMALL` | the Lakebase database is smaller than the engine needs | raise `lakebase_min_cu` and `lakebase_max_cu` ([Sizing](use.md#sizing)), then `sz.sh check` |
| `CONNECTION_BUDGET` (WARN) | the engine needs more Lakebase connections than the database allows | the install script's `--lakebase-vcpu <n>` matching the Lakebase size, or fewer workers ([Sizing](use.md#sizing)) |
| `SOURCE_INVALID` | the register arguments are inconsistent | give one of `--view`, `--table` or `--path` |
| `SOURCE_EXISTS` | the source is already registered | unregister it first, or use another code |
| `DATA_SOURCE_TAKEN` | the `DATA_SOURCE` is used by another source | pick a unique code |
| `SOURCE_NOT_FOUND` | no such source | `sz.sh status` lists the sources |
| `SOURCE_NO_ACCESS` | the jobs' principal cannot read the source table, view or folder | run the printed GRANT statements ([use](use.md#change-data-feed-and-grants)), then register again |
| `SOURCE_CDF_OFF` | Change Data Feed is off on a source table | run the printed `ALTER TABLE … SET TBLPROPERTIES` as the table owner, then register again |
| `SOURCE_VIEW_CONTRACT` | the view breaks the `DATA_SOURCE`, `RECORD_ID`, `RECORD_JSON` contract | the printed rows show what to fix ([Symptoms](#symptoms)) |
| `SOURCE_FOLDER` | the path is not a readable Volume folder | use `/Volumes/<catalog>/<schema>/<volume>/<folder>` and grant READ VOLUME |
| `SOURCE_ENABLED` | the operation needs the source disabled | `sz.sh disable <CODE>` |
| `SOURCES_FAILED` (FAIL) | an enabled source failed (an error, or its change data retention lost) | `source_errors` shows the source's error; fix it, or `sz.sh reload <CODE> --confirm <CODE>` ([use](use.md#retention-warnings-and-reload)) |
| `HOLD_CHANGED` | the held file set changed | read the digest again, then confirm again |
| `FILES_HELD` (WARN) | a files source holds a mass removal | check the folder, then `sz.sh confirm-removal <CODE> --digest <digest>` ([use](use.md#a-files-source)) |
| `CONFIRM_REQUIRED` | a destructive operation needs `--confirm` | repeat it with the confirm word |
| `RUN_FAILED` (FAIL) | the latest ingest run failed | `sz.sh logs <run id>`; `last_run_error` says why |
| `RUN_SKIPPED` | another run is active | wait; `sz.sh status` |
| `PAUSED` (WARN) | ingest is paused | `sz.sh resume` |
| `WAIT_TIMEOUT` | not caught up within the timeout | `sz.sh status`; raise `--timeout` |
| `REJECTED_KEYS` (WARN) | the engine rejected records | fix the records shown in `_ingest_quarantine`, then `sz.sh requeue-rejected` |
| `MART_QUARANTINE` (WARN) | entities could not be written to the mart | the mart's `_quarantine` rows show why; they are retried by the next refresh |
| `WATCH_ERRORS` (WARN) | the watcher's last run failed | `sz.sh status` shows its error (`watch_error`) |
| `PURGE_RUNNING` (WARN) | a source purge is in progress | wait for it; `sz.sh status` |
| `PURGE_FAILED` (WARN) | a source purge failed | `sz.sh status` shows its error; fix it, then purge the source again |
| `EXISTING_RECORDS` (WARN) | the last install found records of data sources not registered (an earlier install's) | keep them (they resolve with the new ones), purge their source, or uninstall and install anew |

## Reading the Lakebase waits

The dashboard's waits chart and `_loop_health` name PostgreSQL's `pg_stat_activity` wait type and
event:

| Wait | Means |
|---|---|
| `Lock:tuple` | sessions queued for a row another session is updating, for example many engine threads updating the same `RES_ENT` rows |
| `Lock:transactionid` | waiting for another transaction to end |
| `LWLock:*` | contention on shared memory (`BufferContent`, `WALWrite`) |
| `IO:*` | waiting on storage (`DataFileRead`, `WALSync`) |
| `Client:ClientRead` | a session waiting for the engine to send its next statement: the database is idle there, the engine is the slower side |

Few waits with the slots full point at the cluster: add workers or slots. Many `Lock` or `LWLock`
waits with the slots full point at Lakebase: raise its size ([Sizing](use.md#sizing)).
