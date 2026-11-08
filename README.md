# Senzing entity resolution for Databricks (sz-databricks)

> **Release candidate.** This guide is for the first public release candidate, published as a
> prerelease. Some steps have not yet been run end to end on every workspace configuration: if
> anything differs from what is described here, open an issue in this repository.

## 1. What it is

Senzing entity resolution that runs entirely in your Databricks workspace. Nothing is hosted by
Senzing and nothing is sent to Senzing.

- **A Databricks App** is the control plane: setup, the EULA and license, source registration, and
  starting, pausing and monitoring the jobs.
- **Two jobs on classic job clusters** (sized by you):
  - **setup** stages the engine payload into your Volume and installs the Lakebase side;
  - **ingest** reads your Unity Catalog tables through a mapping view you write (incremental input
    from Delta Change Data Feed), resolves entities with the Senzing engine, runs redo and keeps
    an entity mart in its own schema current; it keeps polling for new commits and stops after 10
    idle minutes, like a warehouse that suspends.
    A source can instead be a **folder of files** in a UC Volume (`jsonl`, one Senzing JSON record
    per line): each new or changed file is loaded, and only its changed records reach Senzing (section 9).
- **The Senzing repository** is a Lakebase Autoscaling (PostgreSQL) database that scales to zero.

One Databricks Asset Bundle creates all of it: the App, both jobs, two schemas (the entity mart's, and an
internal one with the Volume), the secret scope and the Lakebase project.

## Quickstart: a sample file to a query

1. **Install** (sections 2-5), naming the group that will query the results:
   `scripts/install.sh --target prod --release-dir <download-dir> --var catalog=<catalog> --var consumer_group=<group>`.
   Without `consumer_group`, nobody but the installer and the service principals can read the results:
   run the two GRANT lines `install.sh` prints (`GRANT USE CATALOG ON CATALOG <catalog> TO <group>` and
   `GRANT USE SCHEMA, SELECT ON SCHEMA <catalog>.senzing TO <group>`).
2. **Set up** (section 6): accept the EULA, paste a license (an evaluation license: section 6), enter the
   Lakebase vCPU, click **Install**.
3. **Get sample data.** Senzing's CORD sample data is Senzing-ready JSONL (real historical records, for
   evaluation only). This file holds one data source, `PPP_LOANS` (3,488 records):

   ```sh
   curl -fsSL 'https://mcp.senzing.com/download/las-vegas?source=ppp_loans&limit=250000' -o ppp_loans.jsonl
   ```

4. **Put it in a Volume** your catalog holds, readable by both principals that read sources (`<principal>`:
   the App's service principal and the jobs' one; the **Grants** page names them and prints these statements):

   ```sql
   CREATE VOLUME IF NOT EXISTS <catalog>.<your_schema>.landing;
   GRANT USE SCHEMA ON SCHEMA <catalog>.<your_schema> TO `<principal>`;
   GRANT READ VOLUME ON VOLUME <catalog>.<your_schema>.landing TO `<principal>`;
   ```

   ```sh
   databricks fs cp ppp_loans.jsonl dbfs:/Volumes/<catalog>/<your_schema>/landing/cord/ppp_loans.jsonl
   ```

5. **Register it** on **Sources**: Add source `/Volumes/<catalog>/<your_schema>/landing/cord`, source name
   `ppp_loans`, data source `PPP_LOANS`, format `jsonl`. It shows *checking*, then *ready*, and its first
   load starts by itself (one cluster start).
6. **Query** as the run loads (the mart fills as each batch commits; section 12 has more):

   ```sql
   SELECT entity_id, record_count FROM <catalog>.senzing.entity
   WHERE record_count > 1 ORDER BY record_count DESC LIMIT 20;
   ```

## 2. Requirements

- An **AWS** Databricks workspace with:
  - Unity Catalog;
  - **classic compute** for jobs (job clusters; Graviton/arm64 by default);
  - **Databricks Apps**;
  - **Lakebase Autoscaling** (AWS only today);
  - a **SQL warehouse** (serverless is fine).
- **Outbound access from the job clusters** to these hosts, for the payload download only:
  - `github.com`
  - `release-assets.githubusercontent.com`
  - `objects.githubusercontent.com`

  If your workspace restricts egress, allow these hosts, or use the restricted-network option in
  step 4.
- Databricks CLI **1.23.0**.

## 3. Verify the release (recommended)

Every release file is signed keyless with Sigstore by the signing workflow (`sign-release.yaml`) of
`Senzing/sz-databricks` on the tag `v<release>`, and `SHA256SUMS` lists them all. Download the
release files into a directory and, with [cosign](https://docs.sigstore.dev), run in it:

```sh
release=<release>   # the tag without its v
for f in $(awk '{print $2}' SHA256SUMS) SHA256SUMS; do
  cosign verify-blob --bundle "$f.sigstore.json" \
    --certificate-identity "https://github.com/Senzing/sz-databricks/.github/workflows/sign-release.yaml@refs/tags/v$release" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com "$f"
done
sha256sum -c SHA256SUMS   # macOS: shasum -a 256 -c SHA256SUMS
```

The signatures (`<file>.sigstore.json`) are attached to the release a few minutes after it is published;
`SHA256SUMS.sigstore.json` is attached last, so the release is complete once it is there.
Every file must print `Verified OK`, then `OK`. (`scripts/verify-release.sh <dir> <release>` in the bundle
directory does the same, and `scripts/install.sh` runs it first: step 5.)

The setup job trusts the payload archives through the engine JAR: it refuses any archive whose
SHA-256 differs from the digests compiled into the JAR that ships in the bundle. So the bundle is
what to verify. Without this step the trust rests on HTTPS from GitHub alone.

## 4. Choose the payload source

- **Default (`payload_source=github-release`):** the setup job downloads the payload for its release
  from the public GitHub release (needs the egress hosts above).
- **Restricted network (`payload_source=volume:<dir>`):**
  1. download the release files on a machine that can reach GitHub, and verify them (step 3);
  2. copy the three payload archives into a directory of a Volume that the jobs' service principal
     (step 5) can read, for example the bundle's own Volume:

     ```sh
     dest=dbfs:/Volumes/<catalog>/<schema>/<volume>/drop/<release>
     databricks fs mkdir "$dest"
     for f in sz-databricks-engine-shared-<release>.tar.gz \
              sz-databricks-engine-native-<release>-linux-aarch64.tar.gz \
              sz-databricks-engine-native-<release>-linux-x86_64.tar.gz; do
       databricks fs cp --overwrite "$f" "$dest/$f"
     done
     ```

  3. deploy with `--var payload_source=volume:/Volumes/<catalog>/<schema>/<volume>/drop/<release>`.

  The setup job checks these files against the same compiled digests.

## 5. Install

A workspace admin with MANAGE on the catalog installs in one command, from the unpacked bundle tarball
(`sz-databricks-bundle-<release>.tar.gz`, beside the other release files in `<download-dir>`). It needs the
Databricks CLI, `jq` and cosign:

```sh
tar -xzf sz-databricks-bundle-<release>.tar.gz && cd bundle
scripts/install.sh --target prod --release-dir <download-dir> --var catalog=<catalog>
```

| Step | What it does |
|---|---|
| 1 verify | `scripts/verify-release.sh <download-dir> <release>` (section 3): nothing runs from an unverified release |
| 2 pre | `scripts/admin.sh pre`: creates the two schemas (`senzing_internal`, `senzing`) and the Volume, the `sz-databricks-app` group and the jobs' service principal (below); `DEPLOYER=<user>` when someone else will deploy |
| 3 bind | binds those schemas and the Volume to the bundle (`databricks bundle deployment bind`), so one deploy is enough |
| 4 deploy | `databricks bundle deploy -t prod`: the App, the jobs, the Lakebase project, the secret scope, the warehouse and the grants; the jobs' JAR goes to the Volume |
| 5 post | `scripts/admin.sh post`: the App's service principal joins the `sz-databricks-app` group and gets USE CATALOG |
| 6 grant | only with `--var consumer_group=<group>`: `admin.sh consumer`, USE CATALOG and USE SCHEMA, SELECT on the results schema (section 12) |
| 7 start | `databricks bundle run sz_app -t prod`: starts the App |

Every step is idempotent: a re-run skips what exists, and a failed step prints the command that resumes
there (`--from <step>`). `--dry-run` prints the steps and changes nothing. Pass any bundle variable as
`--var <name>=<value>` (the sizing below, `--var mart_schema=`, `--var schema=`), and
`--var job_run_as=<jobs-sp-application-id>` to run the jobs as a service principal you already have. Without
`--var warehouse_id=<warehouse-id>` the App uses a 2X-Small serverless SQL warehouse the bundle creates (it
stops after 5 idle minutes; with a given id it is still created and stays stopped). Without
`--var lakebase_project=<project-id>` the Lakebase project is named after the App (`sz-databricks`). Use
**dedicated schemas**: the App and the jobs create and modify tables there. It ends by printing the grants
that let a group read the results (section 12).

**The jobs' service principal.** `scripts/admin.sh pre` creates a **dedicated service principal for the jobs**
(`sz-databricks-jobs`, not the App's) unless it exists, and gives it the `workspace-access` entitlement and
USE CATALOG on `<catalog>`; it gives you (the deploying user) the **Service principal: User** role on it,
which the deploy needs to set the jobs' `run_as` (the **manager** role the creator gets is not enough: "must
have 'servicePrincipal.user' role on the service principal"). The principal needs no `allow-cluster-create`:
the bundle's cluster policy (`<app_name>-jobs`, CAN_USE for it) lets it create the jobs' clusters and fixes
their node type, runtime and access mode. The deploying user needs no cluster rights.

The jobs run as that principal, and the App can manage the ingest job (it runs it, and removes a
trigger an earlier release set). So the App can reach only that principal's rights, never yours. Give it nothing beyond what these steps list.

**Without install.sh**, run the steps by hand: `scripts/admin.sh pre <catalog>` (it prints
`job_run_as=<jobs-sp-application-id>`), then deploy **twice**, since the Volume the jobs' JAR goes to must
exist before a deploy can name it:

```sh
vars=(--var catalog=<catalog> --var job_run_as=<jobs-sp-application-id>)
databricks bundle deploy -t prod "${vars[@]}" --var 'artifact_path=${workspace.root_path}/artifacts'
databricks bundle deploy -t prod "${vars[@]}"
```

then `scripts/admin.sh post <catalog> <app_name>` (default App name: `sz-databricks`) and
`databricks bundle run sz_app -t prod`.

**Cluster sizing** (bundle variables; the defaults are the smallest):

| Variable | Default | Meaning |
|---|---|---|
| `node_type_id` | `r6g.large` | Graviton (arm64), 2 cores, 16 GB; any node type works (both arm64 and x86_64 natives ship). Size memory for Senzing: ~4 GB per engine process plus 0.5-1 GB per engine thread, native (outside the JVM heap), growing with the repository; prefer memory-optimized types and fewer, larger workers |
| `autoscale_min`, `autoscale_max` | `1`, `2` | ingest job cluster workers (equal for a fixed size) |
| `ebs_volume_size` | `100` | GiB of the one EBS volume per node: types without local disks (the default `r6g.large`) need one |
| `on_demand_nodes` | `1` | job cluster nodes on demand, the driver first; the rest are spot with fallback. A reclaimed driver loses the run; set it above the worker count when a spot reclaim must not slow a run |
| `worker_task_slots` | `12` | engine threads (Spark task slots) per worker: the node type's cores × 6. Senzing runs 4-8 threads per core against a cloud database, since its threads wait on database round trips |
| `cluster_slots` | empty | the most engine partitions the ingest job runs at once. Empty: the engine computes `autoscale_max` × `worker_task_slots`, so you size the cluster in one place. Set it only to override that (too low throttles; too high only queues tasks) |
| `executor_memory` | `4g` | JVM heap of each ingest executor; keep it small, the rest of the node is the engine's native memory |
| `spark_version` | `17.3.x-scala2.13` | Databricks Runtime 17.3 LTS (Spark 4.0, Scala 2.13) |
| `data_security_mode` | `SINGLE_USER` | dedicated to the jobs' service principal (`USER_ISOLATION` also needs the Volume's `lib/` on the metastore allowlist) |
| `setup_timeout_seconds`, `ingest_timeout_seconds` | `3600`, `28800` | the longest a run may take before it is stopped (and stops billing); the ingest bound sits above the engine loop's 6-hour `loop.max_run_secs`, so it stops only a hung run |
| `pg_sslmode`, `pg_sslrootcert` | `verify-full`, `/etc/ssl/certs/ca-certificates.crt` | the engine's Lakebase TLS (below) |

The setup job runs on a single-node cluster of the same node type. Job clusters exist only while a
run lasts. The engine's concurrency is bounded by the database size you enter on the Setup page and
by `cluster_slots`. The setup job needs a Graviton (or the chosen) node type with capacity in your
region.

**The App's group.** `admin.sh post` adds the App's service principal to the `sz-databricks-app` group (`admin.sh pre`
created it; the bundle gives it WRITE on the secret scope, so the grant survives every redeploy) and gives it USE CATALOG.

Setup logs in to Lakebase as the jobs' service principal to create the Senzing database and role; it needs
no permission on the Lakebase project itself. The deploy creates that login, a Lakebase OAuth role for the jobs' service principal with CREATEDB and CREATEROLE
(no superuser). Without it, setup fails with `password authentication failed for user '<jobs-sp-application-id>'`;
an install deployed before this role existed adds it with
`databricks postgres create-role projects/<project-id>/branches/production --role-id sz-jobs --json '{"spec":{"identity_type":"SERVICE_PRINCIPAL","postgres_role":"<jobs-sp-application-id>","auth_method":"LAKEBASE_OAUTH_V1","attributes":{"createdb":true,"createrole":true}}}'`.
The engine logs in with its own native password role (`sz_engine`), so the bundle's Lakebase project also turns
on native Postgres login (`enable_pg_native_login`, Beta). Without it, setup fails with `native postgres login is
disabled for this endpoint`; an older install turns it on with
`databricks postgres update-project projects/<project-id> spec.enable_pg_native_login --json '{"spec":{"enable_pg_native_login":true}}'`. If you
cannot, create them by hand from `scripts/lakebase-setup.sql` in the bundle directory
and run setup with `admin=skip`.

The bundle already grants:
- the App USE SCHEMA, SELECT, MODIFY and CREATE TABLE on the internal schema, USE SCHEMA and SELECT on
  the mart schema, and READ VOLUME on the Volume;
- the jobs' principal USE SCHEMA, SELECT, MODIFY and CREATE TABLE on both schemas, READ and WRITE VOLUME,
  and READ on the secret scope;
- the `sz-databricks-app` group (`--var app_group=`) WRITE on the secret scope.

It cannot grant on the catalog or name the App in a scope ACL (the CLI does not pass the App's identity into a
scope ACL): the catalog grants and the group membership are `admin.sh`'s. The ingest job has no trigger: the App
starts it (section 10), so a redeploy changes nothing there.

**Upgrade to a new release:** run the new release's `scripts/install.sh` with the same `--var`s. The new App sees
that setup installed an older release: Setup and Status show "Upgrade required", and it starts no run. It then
upgrades by itself, once per release: it pauses ingest (section 10), waits until no run is active, runs
**Setup → Upgrade** (stages the new payload, updates the tables), and resumes if it paused. If that Upgrade fails it
is not retried and ingest stays paused: fix the cause and click **Setup → Upgrade** (the pause then clears). An App older than the installed release refuses Install
and Upgrade and never downgrades: deploy that release or newer. Older releases' payloads stay under
`engine/<release>/` on the Volume; delete them by hand once you will not roll back (about 1.3 GB each, its
payload.jar included).

## 6. Set up Senzing

Open the App:
1. **Setup**: accept the Senzing EULA and store your Senzing license (base64). **No license yet?** Open Ask
   Senzing, the assistant pop-up on https://docs.senzing.com, and ask it for a free evaluation license.
2. Enter the Lakebase size (vCPU), which sets the engine concurrency.
3. Click **Install**. The setup job stages the payload into the Volume (a no-op once this release's
   payload is installed), then creates the `senzing` database and the `sz_engine` role in Lakebase,
   the Senzing schema and default config, and the App's tables in your schema.

To keep Lakebase reads and lock contention low, Install (and Upgrade) turns on Senzing's per-entity
Feature Store (`RES_ENT.FEATURES`), and the engine uses advisory entity locks
(`ER.ENTITY_LOCK_MODE` `ADVISORY`). Every engine on one Senzing repository must use the same lock mode.

**The engine's database connection is TLS with the server certificate verified** by default on
classic clusters: the job clusters set `PGSSLMODE=verify-full` and `PGSSLROOTCERT=/etc/ssl/certs/ca-certificates.crt` (the node's CA bundle), and
Lakebase presents a public Let's Encrypt certificate that the node's CA bundle holds.

## 7. Prepare each source table

For each base table a source reads, and for its mapping view. `<principal>` is each of: the App's
service principal (registration checks with a real `SELECT … LIMIT 0` as it), and the jobs' service
principal (`job_run_as`, step 5):

```sql
ALTER TABLE <catalog>.<schema>.<table> SET TBLPROPERTIES (
  delta.enableChangeDataFeed = true,
  delta.deletedFileRetentionDuration = 'interval 30 days'   -- recommended (default 7 days)
);
GRANT USE CATALOG ON CATALOG <catalog> TO `<principal>`;
GRANT USE SCHEMA ON SCHEMA <catalog>.<schema> TO `<principal>`;
GRANT SELECT ON TABLE <catalog>.<schema>.<table> TO `<principal>`;
GRANT SELECT ON VIEW <catalog>.<schema>.<mapping_view> TO `<principal>`;
```

The ingest job reads the sources as the jobs' principal; the App checks them as its own.

**The Grants page** lists, per registered source and per principal (the App's service principal, and the
principal the ingest job runs as, read from the job), each privilege needed: USE CATALOG, USE SCHEMA, then
SELECT on each base table and the view, or READ VOLUME for a files source. It shows whether Unity Catalog
effective permissions hold it (a group's grant counts), and the GRANT statement to run. An answer it cannot
read shows "cannot verify", never granted; answers are cached 5 minutes (`grants.cache_secs`), and **Check
again** re-reads. A source the jobs' principal cannot read would never update, so its registration is refused
with the statements. When `job_run_as` is the App's own service principal there is one set of grants. The App
never runs a GRANT.

## 8. Write a mapping view

One row per Senzing record, with exactly these columns:
- `DATA_SOURCE`: a constant per source, such as `'CUSTOMERS'`.
- `RECORD_ID`: the record key, trimmed exactly so: `trim(BOTH ' \t\r\n' FROM <key>)`. The ingest
  matches changed rows to the view with the same expression.
- `RECORD_JSON`: the Senzing JSON of the record. Child rows (addresses, phones) are aggregated
  in through a `LEFT JOIN`, so the view returns one row per key.

Get the attribute mapping from the Senzing MCP server's `mapping_workflow` rather than writing it
by hand. A view that returns two rows for one `RECORD_ID` fails that source with a named error;
other sources continue.

## 9. Register a source

On **Sources**, **Add source** takes one box: a mapping view or table (`<catalog>.<schema>.<name>`), or a
folder (`/Volumes/…`, a files source, below). Give the source name and its Senzing data source; for a mapping
view, its base tables with their key columns. A table that itself holds `DATA_SOURCE`, `RECORD_ID` and
`RECORD_JSON`, given no base tables, is its own base table, keyed by `RECORD_ID`.

Registration answers at once: the source shows *checking* while the App checks, in the background, CDF, the
grants (section 7) and the view's columns on a sample of 1000 rows (`registration.sample_rows`). A base table
with no Delta version in Unity Catalog (a streaming table or materialized view) is refused: register the Delta
table it reads. A passed check shows *ready* (with retention advice), enables the source and starts its first
load: the run adds the data source to the Senzing config itself, so the first load costs one cluster start. A
source registered while a run is active loads in the next run. There is no limit on how many tables are watched.

### A files source

A source can be a folder in a UC Volume instead of tables: give the folder
(`/Volumes/<catalog>/<schema>/<volume>/<folder>`) and the format (`jsonl`: one Senzing JSON record per
line, with `RECORD_ID`; a line without `DATA_SOURCE` gets the registered one; blank lines are skipped). No
mapping view is needed. Grant both principals `READ VOLUME` on the volume (plus `USE CATALOG` and `USE SCHEMA`);
registration checks the folder exists, the App can list it and the format.

**How files load.** The folder is walked recursively. A file version is its path, size and modification time.
A new or changed file (overwritten, appended to) is re-read whole, and only the records that changed reach
Senzing; a record the new version no longer holds is deleted, under either `on_remove` mode (a large drop is
held, below). A record in a later file
replaces an earlier one with the same `RECORD_ID`. The file states (Files tab, below) use Databricks Auto
Loader's vocabulary, but the mechanism is sz-databricks' own ledger, the staging table `_files_<source>`:
there is no Auto Loader checkpoint to look for.

- **Latency.** A file is taken once two listings in a row see the same version, plus `file_sources.settle_secs`
  (default 0). While a run is active the engine lists every loop poll (`loop.poll_secs`, 15 s), so a dropped
  file reaches the mart within one or two polls plus the settle and the load itself. With no run active, the App's
  change poll (`watch.poll_secs`, 60 s) starts one first: add the cluster start.
- **Modification times have 1-second precision** (the Files API). A file rewritten at the same size within the
  same second as the version already listed looks unchanged and is not re-read: write it under a new name, or
  wait a second.
- **Skipped names.** Any path segment starting with `.` or `_` (`file_sources.skip_prefixes`), and names ending in
  `.tmp`, `.part` or `.crc` (`skip_suffixes`). Drop each file whole: write it elsewhere and move it in, or give it
  a skipped name until it is complete. A link or a path leaving the folder is refused.

**When a file is removed** (chosen at registration, shown on **Sources**):
- `mirror` (the default): the folder is the source of truth. Removing a file deletes the records
  only it supplied (a record another file still holds stays). **Do not move or archive files out of
  the folder**: moving one into a `_`-prefixed subfolder such as `_done/` removes it too. Moving a
  file to another path in the folder deletes nothing.
- `keep`: removing a file deletes nothing. Choose it if your process archives files after loading.

A removal counts once two listings in a row miss the file; a missing or unreadable folder never
counts (it fails the source instead). Deletes run through the Senzing engine like adds, at about ingest speed:
removing a file takes about as long as loading it did. If a removal (with any rewrites that drop records)
would delete more than half the folder's files (with at least 3 held) or records, or every file, it is
**held** (`file_sources.mass_remove_*`): new files and changes that drop nothing still load, **Sources** shows
how many files and records it would delete, and putting the files back releases it. A manager (CAN MANAGE)
confirms that exact set with **Confirm removal**.

The App starts a run when a folder's listing differs from what the last run loaded.

**Files** shows each file of a files source: PENDING (seen, not loaded yet), INGESTED, FAILED (with
why), REMOVED or HELD, with its size and time, and the count per state. It lists at most 1000 files
(those not INGESTED first); for every loaded file query `<schema>._files_<source>_ledger_v` (file, version,
record count, last load). `<schema>._file_events` records each time a file failed, was held or was removed.
Viewing **Files** reads the Volume only, so it never starts the SQL warehouse.

## 10. Run, pause and resume

The ingest job runs when a registered table changes, or when you click **Start** on **Status**.
Each run is one engine loop: it ingests every new commit, processes redo and refreshes the mart
for the entities that changed, all at once, then polls the tables again every 15 s
(`loop.poll_secs`). After 10 minutes with no new commit and no redo (`loop.idle_shutdown_secs`)
it ends and the cluster stops; a busy run ends after 6 hours (`loop.max_run_secs`) and the next
change starts a fresh one. Commits that land while a run is active are ingested by that run and
start no second run. One run at a time.

The App watches for changes itself; the job has no table update trigger (it watches at most 10
tables, 25 with file events). Every minute (`watch.poll_secs`) the App reads each registered base
table's latest Delta commit version from Unity Catalog's table metadata. That read starts no
warehouse or cluster. When a version moved, the App starts the job once the tables have been quiet
for `watch.wait_after_last_change_seconds` (0 s: at once). It never starts a run while one is running or
queued. Any commit counts, even one that changes no rows.

**Pause** sets a flag: the App starts no run, and a run in progress stops cleanly. The engine reads the flag at
its next poll (within `loop.poll_secs`), takes no new work, lets the chunks in flight commit, writes a stop
marker and ends `paused`. **Status** shows "pausing… (≤30 s; run N stops at its next clean point)", then
`paused`. The App cancels the run only as a fallback: a queued run at once, a run still active 30 s
(`pause.grace_secs`) after the App first saw its stop marker, or a run that wrote no marker within its loop
poll plus 30 s (`pause.marker_slack_secs`). A run that stops within the grace is never cancelled.

**Replay bound after a cancel:** every position is durable when its step commits, so the next run resumes
from them. At most one chunk per engine slot in use (`loop.records_per_batch`, 500 records) is applied again,
each a replace, so nothing is doubled. Redo records the engine had fetched but not yet staged may be lost to
that run (at most one chunk per redo slot). Changes made while paused wait in the Change Data Feed (or the
folder). **Resume** clears the flag and starts a run. Between runs no compute is left running, and Lakebase
scales to zero.

**Bottlenecks (last hour)** on **Status** charts what the engine loop samples about every 15 s while a
run works (the internal table `_loop_health`): the latest run's last hour (`telemetry.chart_minutes`), raw
signals only. Each chart's legend shows the newest value; hover a sample for all of its values. `n/a`
means the engine could not read that signal, never zero; a break in a line is a gap between samples
(over `telemetry.gap_secs`, 60 s) or an unknown value. Before the engine has the table (a release
before telemetry; setup Upgrade creates it) the panel says telemetry is not available.

- **Cluster.** Engine slots in use, stacked by kind (ingest, redo, mart), against the dashed total;
  records per second; the backlog (rows staged and not yet ingested, entity ids waiting for the mart,
  the redo queue); the latest active and pending tasks and executors.
- **Lakebase.** The engine role's sessions (active, idle); connections used against the dashed limit;
  waiting sessions stacked by `wait_event_type:wait_event` (the five with the most sessions over the
  window, the rest as `other`); and the latest sample's top statements by total time since the
  sample before (`pg_stat_statements`, when the extension is present).

Reading the waits: the name is PostgreSQL's `pg_stat_activity` wait type and event. `Lock:tuple` is
sessions queued for a row another session is updating (for example many engine threads updating the
same `RES_ENT` rows); `Lock:transactionid` waits for another transaction to end; `LWLock:*` is
contention on shared memory (`BufferContent`, `WALWrite`); `IO:*` is waiting on storage (`DataFileRead`,
`WALSync`); `Client:ClientRead` is a session waiting for the engine to send its next statement (the
database is idle there, the engine is the slower side). Few waits with slots full point at the
cluster; many `Lock` or `LWLock` waits with slots full point at Lakebase.

## 11. Retention warnings and reload

Each source's position is a Delta version. If it falls behind the table's retained change data,
the App warns before the gap. If the gap is reached, the source stops with a named error and
**Reload source** rebuilds it:
1. a full re-read of the view;
2. then a reconcile that deletes the Senzing records no longer in it.

Change data is never skipped silently.

## 12. Using the results

The results are the entity mart, in the mart schema (`mart_schema`, default `senzing`). Setup creates its
tables with their comments; the ingest run refreshes them while it works (only the changed entities, as
each batch commits; under a large load the mart trails ingest by minutes, and the run ends only once it
has caught up).

**How far behind the mart is.** Each committed batch appends its affected entity ids to the internal table
`_affected`; each mart refresh takes everything there, refreshes those entities and removes exactly what it
took. So the rows in `_affected` are the mart's backlog, and the run log's `MART_REFRESH` lines show where a
refresh spends its time (`read_ms`, `get_ms` for the Senzing reads, `merge_ms` for the mart writes,
`delete_ms`). Every 15 seconds the run also records one row in the internal table `_loop_health` (kept 7
days): slots in use, records per second, the three backlogs (`backlog_staged`: ingest chunks not committed
x `records_per_batch`, so high by under one chunk per source; `backlog_affected`; `backlog_redo`) and the Lakebase sessions, waits and connections. A column is NULL when that signal could
not be read. The upgrade from a release with a Volume feed (`feed/incoming`) moves it into `_affected` on the
first run.

The mart is an entity map: which entity each source record resolves
to and why, and which entities relate. It does not copy your data: everything else about a record is in
your source table, joined on `(data_source, record_id)`.

| Table | One row per | Columns |
|---|---|---|
| `entity` | resolved entity | `entity_id`, `record_count` (its `entity_record` rows), `updated_at` |
| `entity_record` | source record | `data_source`, `record_id` (the mapping view's `RECORD_ID`), `entity_id` it resolves to, `match_key` (the features that resolved it, e.g. `+NAME+DOB`; null when Senzing reports none), `updated_at` |
| `relationship` | related pair of entities | `entity_id_lo` < `entity_id_hi`, `match_level_code` (e.g. `POSSIBLY_SAME`), `match_level`, `match_key`, `updated_at` |

`updated_at` is when the mart last changed the row (a refresh that changes nothing leaves it). **The
joins**: `entity_record.entity_id` and both `relationship` ids are `entity.entity_id`;
`(entity_record.data_source, entity_record.record_id)` is your source row whose mapping view gave that
`RECORD_ID` (the key trimmed of surrounding whitespace), so joining the mapping view on `RECORD_ID` is the
exact match.

**Who can read it.** Pass `--var consumer_group=<group>` to `scripts/install.sh` and it grants that group
USE CATALOG on the catalog and USE SCHEMA and SELECT on the mart schema (on every run; there is no grant by
default, and never to `account users` unless you name it). Or run the GRANT lines `install.sh` prints. The
mart's bookkeeping, `_sync_state` and `_quarantine` (entities the mart could not read, with the error), is in
the internal schema, so the grant does not reach it. Records the engine rejected are in
`_ingest_quarantine`, also internal.

Duplicates found, largest first:

```sql
SELECT entity_id, record_count
FROM <catalog>.senzing.entity
WHERE record_count > 1
ORDER BY record_count DESC
LIMIT 100;
```

Your records with the entity each resolves to (here `customers` stands in for your source table or its
mapping view, registered with data source `CUSTOMERS`):

```sql
WITH customers AS (SELECT 'C1' AS RECORD_ID, 'Ann Lee' AS name)
SELECT c.*, r.entity_id, r.match_key, e.record_count
FROM customers c
JOIN <catalog>.senzing.entity_record r ON r.data_source = 'CUSTOMERS' AND r.record_id = c.RECORD_ID
JOIN <catalog>.senzing.entity e ON e.entity_id = r.entity_id;
```

Entities that span sources (for example a customer on a watch list):

```sql
SELECT entity_id, collect_set(data_source) AS data_sources, count(*) AS records
FROM <catalog>.senzing.entity_record
GROUP BY entity_id
HAVING count(DISTINCT data_source) > 1;
```

Possible matches to review, with each side's records:

```sql
SELECT rel.entity_id_lo, rel.entity_id_hi, rel.match_key,
       lo.data_source AS lo_source, lo.record_id AS lo_record, hi.data_source AS hi_source, hi.record_id AS hi_record
FROM <catalog>.senzing.relationship rel
JOIN <catalog>.senzing.entity_record lo ON lo.entity_id = rel.entity_id_lo
JOIN <catalog>.senzing.entity_record hi ON hi.entity_id = rel.entity_id_hi
WHERE rel.match_level_code = 'POSSIBLY_SAME';
```

Records whose entity changed in the last day (for an incremental sync of your own):

```sql
SELECT data_source, record_id, entity_id
FROM <catalog>.senzing.entity_record
WHERE updated_at > current_timestamp() - INTERVAL 1 DAY;
```

## 13. Uninstall

On **Setup → Uninstall** (needs CAN MANAGE on the App), type `uninstall` to confirm. The App
pauses ingest and cancels the jobs' active runs.

Your data is kept unless you also tick **Also delete data** and type `delete data`. Data means:
- the App's tables in both schemas (registry, status, quarantine and the entity mart) and the
  Volume's working data (checkpoints, feed, staging): a setup run (`action=purge`) deletes them as
  the jobs' service principal, which owns them. Its result is in the setup job's runs;
- the license and engine password secrets, which the App deletes.

The staged payload and the jobs' JAR stay until `bundle destroy`.

The CAN MANAGE check reads the App's permissions as the App's service principal. If it may not
read them, Uninstall is refused with that reason. Group grants count for groups the user is a
direct member of.

`databricks bundle destroy` then removes everything the bundle created: the App, both jobs, the
schema and Volume (with the staged payload), the secret scope and the Lakebase project (with the
Senzing repository).

## 14. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Setup run fails: "… does not match the digest compiled into this release: refused" | The payload archive is not this release's: re-download it, or stage it from the matching release. |
| Setup run fails: "download of …: HTTP …" | The job cluster cannot reach GitHub: allow the egress hosts, or use `payload_source=volume:` (step 4). |
| Setup run fails: "download of … did not finish within download_timeout_seconds" | The transfer from GitHub stalled or is too slow: retry, or use `payload_source=volume:` (step 4). |
| An ingest run fails: "engine payload not installed" | A new release was deployed but its payload is not staged: run **Setup → Upgrade** (step 5, Upgrade). |
| After an upgrade the run ends `mart_failed`: "The entity mart has an earlier release's tables" | The mart is now an entity map without `entity_doc`; nothing was dropped. Pause ingest, run the statements the error prints (they queue every entity the old mart held, then drop its tables), resume: the next refresh rebuilds the mart. |
| One source fails, others continue | Isolated: its position does not advance and the App shows the error. Fix the view or the grant, then the next run retries. |
| Registering a files source: "folder … cannot be listed: no such directory", or it shows `GRANT … READ VOLUME` statements | Create the folder, or run the grants shown (for the jobs' principal too). |
| A record the engine rejects | It goes to `_ingest_quarantine` with its error; the run continues. |
| Retention gap warning or "retention lost" | Raise `delta.deletedFileRetentionDuration`, or use **Reload source** (step 11). |
| First connection to Lakebase slow | It is waking from scale-to-zero; connections retry with bounded back-off. |
| A failed task | The ingest task retries once and runs are replay-safe. |
| The mart trails ingest more and more | Look at the run's latest `_loop_health` rows: a growing `backlog_affected` with high `get_ms` / `merge_ms` in `MART_REFRESH` means the cluster (slots) or Lakebase is too small for the load; the mart takes every free slot, chunk by chunk (`loop.mart_ids_per_chunk`); `pg_waits` and `pg_connections_used` near `pg_connections_limit` point at Lakebase. |
| `LOOP_HEALTH_ERROR` in the run log | One signal could not be read (its `part`); that column is NULL and the run is unaffected. |
| `_affected` or `_loop_health` keeps many small files | The run compacts and vacuums them daily (`mart.feed_maintenance: loop`); with `predictive`, enable predictive optimization on the internal schema. |
| License missing or expired | The App refuses to start the job and names the fix (Setup → License). |
| "needs CAN MANAGE on the App" | Ask a user with CAN MANAGE on the App (Compute > Apps > Permissions), or a workspace admin. |
| "the App's service principal may not read the App's permissions (HTTP 403)" | Give the App's service principal CAN MANAGE on the App (`scripts/admin.sh post` does this), or remove the installation with `databricks bundle destroy`. |
