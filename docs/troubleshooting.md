[sz-databricks](../README.md) / Troubleshooting

# Troubleshooting

Start with the App's **Status** page: the ingest job's state, its recent runs, the sources' errors
and the backlog. The **Setup** page shows the latest setup run and its error, and whether Lakebase is
reachable. Every message the App shows for a failure names the fix; the tables below explain them.
These pages assume SENZING® entity resolution installed with the default names (`sz-databricks`,
`senzing_internal`, `senzing`).

## Where to look

| Failure | Read |
|---|---|
| the install | the install script's output: each step is printed before it runs, and a failed step prints the command that resumes there |
| a setup run | **Setup** (status and error), then the `sz-databricks-setup` job's runs and their driver log |
| an ingest run | **Status** (recent runs), then the `sz-databricks-ingest` job's runs and their driver log: `MART_REFRESH` lines show where a mart refresh spends its time (`read_ms`, `get_ms`, `merge_ms`, `delete_ms`) |
| the App itself (its page does not load or shows an error) | the App page's **Logs** tab, or `databricks apps logs sz-databricks`. A stopped App (it stops itself after 30 idle minutes) answers nothing: click **Start** on it in the workspace's **Apps** page |
| the watcher (a change starts no run, a pause or upgrade does not finish) | **Status** (the watcher's last run and its error), then the `sz-databricks-watch` job's runs and their driver log |
| a source | **Sources** (its state, error and a hint), then **Grants** |
| a file of a files source | **Files** (FAILED with why), and `<catalog>.senzing_internal._file_events` |
| records the engine rejected | `<catalog>.senzing_internal._ingest_quarantine`, with each record's error |
| entities the mart could not read | `<catalog>.senzing_internal._quarantine`, with the error |
| a slow or lagging run | **Status** > **Bottlenecks (last hour)**, and `<catalog>.senzing_internal._loop_health` ([use](use.md#how-far-behind-the-mart-is)) |

## Install

| Symptom | Cause and fix |
|---|---|
| `install.sh: step <name> failed; after fixing it, resume with: …` | Fix what the step printed above it, then run the printed command: it resumes at that step. |
| `verify-release.sh` prints `FAIL <file>: no <file>.sigstore.json` | The signature files are missing: download every `.sigstore.json` file of the release. They are attached a few minutes after a release is published, `SHA256SUMS.sigstore.json` last. |
| `verify-release.sh` prints `FAIL <file>: …` with a cosign reason, or `sha256sum` reports `FAILED` | The file is not the one this release signed (another release's, or damaged): download it again from the same release, and pass that release (the tag without its `v`). Install nothing from it until every file passes. |
| `verify-release.sh: cosign is not installed` | Install [cosign](https://docs.sigstore.dev), then run the install again. |
| `install.sh: release directory <dir> not found` | `--release-dir` must name the directory that holds the downloaded release files. |
| `node-sizing.sh: worker_task_slots <n> is above the <m> engine threads one <node type> worker holds: …` | One worker of that node type cannot give each engine thread 1 GB beside the heap, the engine and the Databricks reserve; the message shows the numbers. Pass `--var worker_task_slots=<m>` or less, a smaller `executor_memory`, or a `node_type_id` with more memory, then resume with the command it prints ([Sizing](use.md#sizing)). |
| `node-sizing.sh: node type <node type> is not in this workspace's node types` | `node_type_id` names a type this workspace does not offer: pick one from `databricks clusters list-node-types`. |
| `databricks bundle run sz_app` by hand fails: "app crashed unexpectedly", the App's log names a missing variable | The App was stopped, so the run first restarted its last deployment: the new release's code with the earlier release's settings. Run `databricks bundle run sz_app -t prod` again: the App is now running, so it deploys the new settings. The install script's step 8 does this itself. |
| `install.sh: no job_run_as: pass --var job_run_as=<application-id> when resuming after pre` | You resumed after step 3: add `--var job_run_as=<application-id>`, the id step 3 printed as `job_run_as=…`. |
| Deploy fails: "must have 'servicePrincipal.user' role on the service principal" | The deploying user lacks the **Service principal: User** role on the jobs' principal. Step 3 gives it to the user running the install; when someone else deploys, run step 3 with `DEPLOYER=<user>`. |

## Setup

| Symptom | Cause and fix |
|---|---|
| Setup fails: "… does not match the digest compiled into this release: refused" | The engine payload (the Senzing runtime archives the jobs run) is not this release's: download it again, or stage it from the matching release. |
| Setup fails: "download of …: HTTP …" | The job cluster cannot reach GitHub: allow the egress hosts, or stage the payload in a Volume ([install](install.md#1-choose-the-payload-source)). |
| Setup fails: "download of …: HTTP 403" or "HTTP 429" | GitHub refused or rate-limited the download: retry later, or stage the payload in a Volume ([install](install.md#1-choose-the-payload-source)). |
| Setup fails: "download of … did not finish within download_timeout_seconds" | The transfer from GitHub stalled or is too slow: retry, or stage the payload in a Volume. |
| Setup fails: `password authentication failed for user '<jobs-sp-application-id>'` | The jobs' principal has no Lakebase role. An install deployed before the bundle created that role adds it with `databricks postgres create-role projects/<project-id>/branches/production --role-id sz-jobs --json '{"spec":{"identity_type":"SERVICE_PRINCIPAL","postgres_role":"<jobs-sp-application-id>","auth_method":"LAKEBASE_OAUTH_V1","attributes":{"createdb":true,"createrole":true}}}'`. |
| Setup fails: `native postgres login is disabled for this endpoint` | The engine's password role cannot log in. An older install turns native login on with `databricks postgres update-project projects/<project-id> spec.enable_pg_native_login --json '{"spec":{"enable_pg_native_login":true}}'`. |
| You cannot create either of those | Create the database and roles by hand from `scripts/lakebase-setup.sql` in the bundle directory, then run setup without its Lakebase admin step: open the `sz-databricks-setup` job, choose **Run now with different parameters** and set `action` to `install` and `admin` to `skip`. |
| An ingest run fails: "engine payload not installed" | A new release was deployed but its payload is not staged: click **Upgrade** on the Setup page. |
| After an upgrade the run ends `mart_failed`: "The entity mart has an earlier release's tables" | The mart is now an entity map without `entity_doc`; nothing was dropped. Pause ingest, run the statements the error prints (they queue every entity the old mart held, then drop its tables) and resume: the next refresh rebuilds the mart. |
| Setup and Status show "Upgrade required" and no run starts | The App is a newer release than setup installed. It upgrades by itself; if that Upgrade failed, fix the cause it shows and click **Upgrade** ([use](use.md#upgrade)). |
| Install and Upgrade are refused as a downgrade | Setup installed a newer release than this App. Deploy that release or a newer one. |

## A run does not start

The watcher starts a run for a change only when ingest is not paused, the installed release is current
and no ingest or setup run is active; it runs every 5 minutes and waits a few minutes for its serverless
compute, so allow about 10 minutes. When a change still starts nothing, read the watcher's error on
**Status** or its job run's driver log:

| Watcher error | Fix |
|---|---|
| "the engine password … is missing from secret scope …" | The automatic upgrade needs it: click **Upgrade** on the Setup page, which creates it. |
| "App … not found" | The upgrade runs setup with the App's service principal. Deploy the bundle again so the App exists. |
| "PERMISSION_DENIED" on the App or a job | The watcher runs as the jobs' principal, which needs CAN MANAGE on the App and CAN MANAGE RUN on the setup and ingest jobs: run `scripts/admin.sh post` again. |
**Start a run** refuses with the first condition that fails:

| Message | Fix |
|---|---|
| "Accept the Senzing EULA on the Setup page." | Read the agreement and click **I accept the EULA** on **Setup** (CAN MANAGE on the App). |
| "Upload the Senzing license in the License section of the Setup page." | Paste the base64 license and click **Store license**. |
| "The Senzing license expired on …: upload a new one in the License section of the Setup page." | Store a new license; the next run uses it. |
| "Run setup on the Setup page until it reports ok." | Click **Install** and read the error if it fails (above). |
| "A setup run is active: ingest starts once it ends …" | Wait: both change the Senzing configuration, so they never run together. |
| "The database size is not a number of vCPU: set it on the Setup page." | The size saved on **Setup** is not a number. Enter one and click **Save**; the default, 2 vCPU for the bundle's 4 compute units, is stored by itself when a run starts. |
| "Lakebase is unreachable: …" | The reason follows the colon; the Setup page's Lakebase section shows it too. A first connection after Lakebase scaled to zero (30 idle minutes by default) waits while it wakes and retries with back-off. |
| "…: the database cannot hold one engine partition; raise its size (or correct the vCPU entered) on the Setup page." | An engine partition is one Spark task running one engine thread; Lakebase this size has no room for one. Raise `lakebase_min_cu`, `lakebase_max_cu` and `lakebase_vcpu` together ([Sizing](use.md#sizing)), or correct the vCPU on the Setup page. |
| "needs CAN MANAGE on the App" | Ask a user with CAN MANAGE on the App (the App page > **Share**), or a workspace admin. |
| "the App's service principal may not read the App's permissions (HTTP 403)" | Give the App's service principal CAN MANAGE on the App (`scripts/admin.sh post` does this), or remove the installation with `databricks bundle destroy`. |

## Sources and results

| Symptom | Cause and fix |
|---|---|
| One source fails, others continue | It is isolated: its position does not advance and **Sources** shows the error with a hint. Fix the view or the grant; the next run tries again. |
| Registering: `Change Data Feed is off; run: …` | A base table has Change Data Feed off. Run the printed `ALTER TABLE` as the table owner ([use](use.md#change-data-feed-and-grants)), then register again. |
| Registering: `the mapping view <view> breaks the contract: …` | The check counted rows that break the [mapping view rules](use.md#write-a-mapping-view), each named with its count: `RECORD_ID NULL or blank`, `untrimmed RECORD_ID`, `duplicate RECORD_ID`, `DATA_SOURCE other than the registered code` or a missing column. Fix the view, then register again. |
| A run fails a source: `duplicate RECORD_ID in <view>` | The view returned one `RECORD_ID` twice; other sources continue. Make the view return one row per key (aggregate child rows), and the next run tries again. |
| The source's hint names a missing grant | **Grants** lists what to grant, to which principal, with the statement. |
| **Grants** shows "cannot verify" | The App could not read Unity Catalog's effective permissions for that principal; the reason follows `cannot verify:`. It never takes that as granted. Run the GRANT statement it shows (granting a privilege already held changes nothing), then click **Check again**. |
| The source's hint says a table or view is gone or renamed | Restore it, or register the source again. |
| Registering a files source: "folder … cannot be listed: no such directory", or it shows `GRANT … READ VOLUME` statements | Create the folder, or run the grants shown, for the jobs' principal too. |
| A record the engine rejects | It goes to `_ingest_quarantine` with its error; the run continues. Fix the record at the source. |
| Retention gap warning or "retention lost" | Raise `delta.deletedFileRetentionDuration`, or use **Reload source** ([use](use.md#retention-warnings-and-reload)). |
| A failed task | The ingest task retries once, and runs are safe to replay. |
| A files source holds a removal (HELD) | More than half the folder's files or records would be deleted. Put the files back, or confirm with **Confirm removal** ([use](use.md#a-files-source)). |
| A rewritten file is not read again | It kept its size within the same second: write it under a new name, or wait a second. |
| The mart trails ingest more and more | Look at the latest `_loop_health` rows: a growing `backlog_affected` with high `get_ms` or `merge_ms` in `MART_REFRESH` means the cluster (slots) or Lakebase is too small for the load. `pg_waits`, and `pg_connections_used` near `pg_connections_limit`, point at Lakebase. |
| `LOOP_HEALTH_ERROR` in the run log | One signal could not be read (its `part`); that column is NULL and the run is unaffected. |
| `_affected` or `_loop_health` keeps many small files | The run compacts and vacuums them daily. |

## Costs

| Symptom | Cause and fix |
|---|---|
| The App's page does not load after a quiet spell | The App stopped itself after 30 idle minutes. Click **Start** on it in the workspace's **Apps** page; ingest went on without it. To keep it up, turn on **Keep running** on **Status**. |
| A budget alert fired | Look on **Status** for a run that does not end (a busy run ends after 6 hours) and for **Keep running** left on. The job clusters bill only while a run lasts; the watcher's runs are short. Pause ingest to stop new runs. |
| No budget alert ever arrives | Budgets are set outside the App: a Databricks budget (account admin) and an AWS budget. See [What it costs to run](../README.md#what-it-costs-to-run). |

## Reading the Lakebase waits

The waits chart on **Status** names PostgreSQL's `pg_stat_activity` wait type and event:

| Wait | Means |
|---|---|
| `Lock:tuple` | sessions queued for a row another session is updating, for example many engine threads updating the same `RES_ENT` rows |
| `Lock:transactionid` | waiting for another transaction to end |
| `LWLock:*` | contention on shared memory (`BufferContent`, `WALWrite`) |
| `IO:*` | waiting on storage (`DataFileRead`, `WALSync`) |
| `Client:ClientRead` | a session waiting for the engine to send its next statement: the database is idle there, the engine is the slower side |

Few waits with the slots full point at the cluster: add workers or slots. Many `Lock` or `LWLock`
waits with the slots full point at Lakebase: raise its size ([Sizing](use.md#sizing)).
