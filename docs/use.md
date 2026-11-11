[sz-databricks](../README.md) / Use

# Use

Day-to-day operation of an installed sz-databricks: bringing data in, watching SENZING® entity
resolution run and using the results. You operate it from the command line with one script,
`sz.sh`, in the bundle directory the install script unpacked (`<dir>`, by default
`./sz-databricks-<release>`). Below, `sz.sh` stands for `<dir>/scripts/sz.sh`.

`<catalog>` is the catalog you installed into. `senzing` is the mart schema: it holds the entity
mart, the resolved entities as tables you query, and the `sz_health` view. `senzing_internal` is the
internal schema. Both are the defaults; use your names if you changed them at install.

## sz.sh

| Operation | Does |
|---|---|
| `status` | the `sz_health` row and each code's fix; exit 0 only when `overall` is `OK` |
| `wait [--timeout S]` | reads `sz_health` every 15 seconds until `resolve_state` reads `CAUGHT_UP` |
| `register CODE …` | registers a source: a mapping view and its tables, or a Volume folder ([below](#register-a-source)) |
| `unregister CODE`, `enable CODE`, `disable CODE` | removes a source's registration (its records stay), or turns its loading on or off |
| `purge-source CODE --confirm CODE` | deletes a disabled source's records from Senzing and the mart, then its registration |
| `reload CODE --confirm CODE` | reads the source again from the start |
| `validate CODE [--sample N] [--repair]` | checks the view contract on a sample and compares the view's records with the mart's; `--repair` reloads when they differ |
| `confirm-removal CODE --digest D` | releases a held mass removal of a files source |
| `requeue-rejected [CODE]` | puts the records the engine rejected back for the next run |
| `grants [CODE]` | the GRANT statements that let the jobs' principal read each source |
| `run`, `pause`, `resume`, `stop` | starts an ingest run; pauses or resumes ingest; `stop` pauses and cancels the active runs |
| `flush [--wait S]` | starts an ingest run now, then waits for `CAUGHT_UP` |
| `accept-eula --yes` | accepts the Senzing EULA for this release |
| `license --file F [--check]` | stores a new license (`--check` only checks it) |
| `rotate-password` | a new engine Lakebase password |
| `setup`, `check`, `upgrade` | the setup job's install, check and upgrade |
| `prune` | deletes run bookkeeping and result files past their retention |
| `logs RUN_ID` | a job run's state, its tasks and its result |
| `uninstall …` | removes the install ([below](#uninstall)) |

Each operation runs as a job of the install (the operations job `sz-databricks-ops`, about a minute
on serverless compute, or the setup job) or reads `sz_health`, and prints one JSON object:
`status`, `code`, `message`, `fix`, `next` (what to run next), `run_id`, `run_url`, `details`,
`warnings` and `statements` (SQL for you to run, such as GRANTs). The exit status is 0 when it
succeeded, 1 when it failed (its code and fix printed) and 2 for bad usage or an operation refused
before anything ran (a missing `--confirm` or `--yes`). `--dry-run` before the operation prints each
command, job parameter and statement and runs nothing. A user of the `--operator-group` can run every
operation but `license`, `rotate-password` and `uninstall`, which need the installer's rights.

**In the Jobs UI instead.** Every operation is a run of `sz-databricks-ops` with job parameters (`op`
and its own, such as `code` and `view`): **Run now with different parameters** on that job does the
same, and `sz.sh --dry-run <operation>` prints the exact parameters. The result is the run's output.

## Prepare a source

A source is either a set of Unity Catalog tables read through a mapping view, or a folder of files
in a Volume ([a files source](#a-files-source), which needs no mapping view and no Change Data
Feed).

### Change Data Feed and grants

The ingest job reads each base table's changes through Delta Change Data Feed, as the jobs' service
principal (`sz-databricks-jobs` unless you gave `--job-run-as`). Who can run each statement:

- **The table owner**, for each base table a source reads:

  ```sql
  ALTER TABLE <catalog>.<schema>.<table> SET TBLPROPERTIES (
    delta.enableChangeDataFeed = true,
    delta.deletedFileRetentionDuration = 'interval 30 days'   -- recommended (default 7 days)
  );
  ```

- **The catalog owner, or a user with MANAGE on the catalog**, only when the tables are in a catalog
  other than the one you installed into (the install already granted USE CATALOG on that one):

  ```sql
  GRANT USE CATALOG ON CATALOG <catalog> TO `<jobs principal application id>`;
  ```

- **The owner of the schema, table and view, or a user with MANAGE on them:**

  ```sql
  GRANT USE SCHEMA ON SCHEMA <catalog>.<schema> TO `<jobs principal application id>`;
  GRANT SELECT ON TABLE <catalog>.<schema>.<table> TO `<jobs principal application id>`;
  GRANT SELECT ON VIEW <catalog>.<schema>.<mapping_view> TO `<jobs principal application id>`;
  ```

`sz.sh register` checks each and prints the exact statements it is missing, with the principal's
application id filled in. A longer retention keeps more history, and so more storage, and gives you
more time to recover from a stopped source before its changes expire
([retention warnings](#retention-warnings-and-reload)).

### Write a mapping view

One row per Senzing record, with exactly these columns:

- `DATA_SOURCE`: a constant per source, the source's code, such as `'CUSTOMERS'`.
- `RECORD_ID`: the record key, trimmed exactly so: `trim(BOTH ' \t\r\n' FROM <key>)`. The ingest
  job matches changed rows to the view with the same expression.
- `RECORD_JSON`: the Senzing JSON of the record, its attributes as the
  [Senzing entity specification](https://senzing.com/docs/entity_specification) names them. Child
  rows (addresses, phones) are aggregated in through a `LEFT JOIN`, so the view returns one row per
  key.

Get the attribute mapping from the `mapping_workflow` tool of the
[Senzing MCP server](https://mcp.senzing.com/mcp) rather than writing it by hand. A view that
returns two rows for one `RECORD_ID` fails that source with a named error; other sources continue.

#### Example: a parent table and a child table

A customer table (`customer`, key `customer_id`, column `full_name`) with zero or more phones in a
child table (`customer_phone`, foreign key `customer_id`, row key `phone_id`, columns `phone_type`
and `phone_number`). The view aggregates the phones per customer with `collect_list`, attaches them
with a `LEFT JOIN` (an inner join would drop customers with no phone), drops empty values and builds
`RECORD_JSON` with `to_json`:

```sql
CREATE OR REPLACE VIEW <catalog>.<schema>.customer_mapped AS
WITH c AS (
  SELECT trim(BOTH ' \t\r\n' FROM customer_id) AS RECORD_ID,
         nullif(trim(full_name), '') AS full_name
  FROM <catalog>.<schema>.customer
),
phone AS (
  SELECT RECORD_ID,
         transform(
           array_sort(collect_list(struct(phone_id, phone_type, phone_number))),
           x -> map_filter(map('PHONE_TYPE', x.phone_type, 'PHONE_NUMBER', x.phone_number),
                           (k, v) -> v IS NOT NULL)) AS features
  FROM (
    SELECT trim(BOTH ' \t\r\n' FROM customer_id) AS RECORD_ID, phone_id,
           upper(nullif(trim(phone_type), '')) AS phone_type,
           nullif(trim(phone_number), '') AS phone_number
    FROM <catalog>.<schema>.customer_phone
  )
  WHERE phone_number IS NOT NULL
  GROUP BY RECORD_ID
)
SELECT
  'CUSTOMERS' AS DATA_SOURCE,
  c.RECORD_ID,
  to_json(named_struct(
    'DATA_SOURCE', 'CUSTOMERS',
    'RECORD_ID', c.RECORD_ID,
    'FEATURES', filter(
      concat(
        array(
          map('RECORD_TYPE', 'PERSON'),
          CASE WHEN c.full_name IS NOT NULL THEN map('NAME_FULL', c.full_name) END),
        coalesce(p.features, array())),
      f -> f IS NOT NULL))) AS RECORD_JSON
FROM c
LEFT JOIN phone AS p ON p.RECORD_ID = c.RECORD_ID;
```

The child's foreign key is trimmed exactly like the parent's key, so the join matches. Sorting by
the child's row key (`phone_id`, first in the struct) keeps `RECORD_JSON` the same from run to
run. Every feature is a `map` of strings, so one array holds them all. Register it with base tables
`customer` keyed by `customer_id` and `customer_phone` keyed by `customer_id`.

Before you register it, check the view returns one row per key, with counts only:

```sql
SELECT count(*) AS rows, count(DISTINCT RECORD_ID) AS keys FROM <catalog>.<schema>.customer_mapped;
```

The two numbers must be equal.

## Register a source

```sh
sz.sh register CUSTOMERS --view <catalog>.<schema>.customer_mapped \
  --table <catalog>.<schema>.customer=customer_id --table <catalog>.<schema>.customer_phone=customer_id
```

`CODE` is the Senzing data source code, the view's `DATA_SOURCE`; the source's name is the code in
lower case with `-` as `_`. Name every base table the view reads that holds the record id: `--table
T=COL` gives one table its own record id column (a child table's foreign key), and `--key COL` the
others' (default `RECORD_ID`). A table that itself holds `DATA_SOURCE`, `RECORD_ID` and
`RECORD_JSON` can be registered alone with `--table`, as its own view. The install script's
`--source` runs the same registration ([install](install.md#sources-at-install)).

Registration checks, as the jobs' principal, that it can read each table and the view, that Change
Data Feed is on and that 1,000 sample rows of the view keep the contract above. It refuses with the
code and the statements to run (`SOURCE_NO_ACCESS`, `SOURCE_CDF_OFF`, `SOURCE_VIEW_CONTRACT`), and
advises a 30-day retention in `warnings`. A registered source is enabled and its first load starts:
the run adds the data source to the Senzing configuration itself. A source registered while a run
is active loads in the next run. There is no limit on how many tables are watched.

A base table with no Delta version in Unity Catalog (a streaming table or materialized view) is
refused: register the Delta table it reads.

### Tables shared across sources

Name with `--table` every table whose change should re-resolve the source's records. A table the
view only looks up, one that holds no record id (another system's accounts table that a contacts
view reads), is named with `--via L.KEY:T.VKEY.RID` instead (repeatable): a changed row of `L`,
before and after the change, re-resolves the records of base table `T` (one of the `--table`
tables) whose `VKEY` equals its `KEY`; `RID` is `T`'s record id column.

```sh
sz.sh register CONTACTS --view <catalog>.<schema>.contact_mapped \
  --table <catalog>.<schema>.contacts=contact_id \
  --via <catalog>.<schema>.accounts.account_id:<catalog>.<schema>.contacts.account_id.contact_id
```

The install script's `--source-via` runs the same ([install](install.md#sources-at-install)).

### A files source

A source can be a folder in a Volume instead of tables:

```sh
sz.sh register PPP_LOANS --path /Volumes/<catalog>/<schema>/<volume>/<folder> [--format jsonl] [--on-remove mirror|keep]
```

The format `jsonl` is one Senzing JSON record per line with `RECORD_ID`. A line without
`DATA_SOURCE` gets the registered code; blank lines are skipped. Grant the jobs' principal READ
VOLUME on the volume, plus USE CATALOG and USE SCHEMA. Registration checks that the folder exists,
that the jobs' principal can list it and the format.

**How files load.** The folder is walked recursively. A file's version is its path, size and
modification time. A new or changed file (overwritten, appended to) is read again whole, and only
the records that changed reach the engine; a record the new version no longer holds is deleted. A
record in a later file replaces an earlier one with the same `RECORD_ID`.

- **Latency.** A file is taken once two listings in a row see the same version. While a run is
  active the engine lists the folder every 15 seconds, so a dropped file reaches the mart within one
  or two polls plus the load itself. With no run active, the watcher lists it every 5 minutes and
  starts one: add the cluster start.
- **Modification times have 1-second precision.** A file rewritten at the same size within the same
  second as the version already listed looks unchanged and is not read again: write it under a new
  name, or wait a second.
- **Skipped names.** Any path segment starting with `.` or `_`, and names ending in `.tmp`, `.part`
  or `.crc`. Drop each file whole: write it elsewhere and move it in, or give it a skipped name until
  it is complete. A link or a path leaving the folder is refused.

**When a file is removed** (`--on-remove`):

- `mirror` (the default): the folder is the source of truth. Removing a file deletes the records only
  it supplied (a record another file still holds stays). **Do not move or archive files out of the
  folder**: moving one into a `_`-prefixed subfolder such as `_done/` removes it too. Moving a file to
  another path in the folder deletes nothing.
- `keep`: removing a file deletes nothing. Choose it if your process archives files after loading.

A removal counts once two listings in a row miss the file; a missing or unreadable folder never
counts (it fails the source instead). Deletes run through the engine like adds: removing a file takes
about as long as loading it did. If a removal would delete more than half the folder's files (with
at least 3 held) or records, or every file, it is **held**: new files and changes that drop nothing
still load, `sz_health` reports `FILES_HELD`, and putting the files back releases it. To confirm
that exact set, read the hold's digest and pass it:

```sql
SELECT value FROM <catalog>.senzing_internal.sz_app_state WHERE key = 'files.hold.<source>';
```

```sh
sz.sh confirm-removal <CODE> --digest <digest>
```

If the set changed meanwhile, it refuses with `HOLD_CHANGED`: read the digest again.

For every loaded file query `<catalog>.senzing_internal._files_<source>_ledger_v` (file, version,
record count, last load); `<catalog>.senzing_internal._file_events` records each time a file failed,
was held or was removed.

### Change or remove a source

- `sz.sh disable <CODE>` stops loading it; `enable` starts again from where it stopped.
- `sz.sh unregister <CODE>` removes the registration; its records stay in Senzing and the mart.
- `sz.sh purge-source <CODE> --confirm <CODE>` (the source disabled first) deletes its records from
  Senzing and the mart, then its registration. `sz_health` shows `purges_running` meanwhile.
- `sz.sh validate <CODE>` checks the view contract on a sample and compares the view's record count
  with the mart's; `--repair` reloads the source when they differ.

## Watch it resolve

```sh
sz.sh wait --timeout 1800
```

`wait` reads `sz_health` every 15 seconds, prints `resolve_state` and ends with one line:
`resolve wait: <outcome> after <n> s; <records> records, <entities> entities; sz_health.overall = <overall>; exit <code>`.
It exits 0 at `CAUGHT_UP`, 1 at `SOURCES_FAILED` or when the timeout passes (`WAIT_TIMEOUT`).

| `resolve_state` | Means |
|---|---|
| `NO_SOURCES` | nothing registered yet |
| `SOURCES_FAILED` | a source failed: `source_errors` says why and how to fix it |
| `WAITING_FOR_CAPTURE` | a source has changes not yet read, a reload is pending or the watcher has a run to start |
| `RESOLVING` | a run is loading records, or the mart is catching up |
| `CAUGHT_UP` | every change is resolved and in the mart |

### sz_health

`sz.sh status` prints the one row of `<catalog>.senzing.sz_health` and each code's fix:

```sql
SELECT overall, resolve_state, fail_codes, warn_codes FROM <catalog>.senzing.sz_health;
```

`overall` is `OK`, `WARN` or `FAIL`; `fail_codes` lists the codes that make it `FAIL`, `warn_codes`
the rest, and `warnings` both. Each code's meaning and fix is in
[troubleshooting](troubleshooting.md#sz_health-and-script-codes). The other columns:

| Columns | Hold |
|---|---|
| `setup_status`, `setup_phase`, `setup_running_secs`, `setup_error`, `last_setup_warnings` | the latest setup run |
| `setup_release`, `bundle_release`, `senzing_version` | the release setup installed, the release deployed and its Senzing SDK version |
| `eula_version`, `eula_accepted_at`, `eula_accepted_by` | the EULA acceptance |
| `license_expires`, `license_days_left`, `license_record_limit`, `license_records_used` | the running license; it warns 30 days before it expires and at 90% of its record limit |
| `entity_count`, `source_count`, `sources_enabled`, `sources_failed`, `source_errors` | the mart and the sources |
| `last_run_id`, `last_run_state`, `last_run_ended_at`, `last_run_error`, `loop_running`, `affected_pending`, `paused` | ingest |
| `rejected_keys`, `mart_quarantine`, `files_held`, `purges_running`, `purges_failed`, `purges` | work that needs a look |
| `watch_error`, `watch_pending`, `checked_at` | the watcher's last error, the runs it has pending, and when the row was read |

### The dashboard

The `sz-databricks status` AI/BI dashboard (workspace **Dashboards**) shows `sz_health`, the ingest
runs, the engine loop's health over the last 24 hours, quarantined records, each source's position
and the entity mart's counts. It runs on the bundle's SQL warehouse and reads with each viewer's own
access: you need SELECT on both schemas; the consumer group sees the mart's parts. Its `mart_schema`
parameter names the mart schema (default `senzing`).

### The health alert

The SQL alert `sz-databricks health` reads `sz_health` hourly (`--set alert_cron=…`, Quartz) and
triggers when `overall` is not `OK`; it notifies again when it is back to `OK`. It mails the
addresses you gave the install with `--alert-email`, which also get each failed job run. Without one
it mails nobody and shows its state in the workspace's **Alerts**. To change the addresses, run the
install script again with the new `--alert-email` options.

## Run, pause and resume

The ingest job runs when a registered table or folder changes, or when you run `sz.sh run` (start a
run) or `sz.sh flush` (start one and wait for `CAUGHT_UP`). Each run is one engine loop: it ingests
every new commit, processes redo (work the engine queues when a change to one entity means related
entities must be evaluated again) and refreshes the mart for the entities that changed, then polls
the sources again every 15 seconds. After 10 minutes with no new commit and no redo it ends and the
cluster stops; a busy run ends after 6 hours and the next change starts a fresh one. Commits that
land while a run is active are ingested by that run. One run at a time.

The watcher job (`sz-databricks-watch`, serverless) watches for changes. Every 5 minutes (the bundle
variable `watch_cron`) it reads each registered base table's latest Delta commit version from Unity
Catalog's table metadata and lists each files source's folder, which starts no warehouse or cluster.
When a version or a folder moved, it starts the job, unless ingest is paused, a run is running or
queued, a setup run is active or the deployed release still needs `sz.sh upgrade`. Any commit counts,
even one that changes no rows. A watcher run waits a few minutes for its serverless compute before it
reads anything, so a change starts a run up to about 10 minutes after it lands.

`sz.sh pause` stops new work: no run starts, and a run in progress stops cleanly. The engine reads
the pause at its next poll, takes no new work, lets the chunks in flight commit and ends `paused`.
The watcher cancels the run only as a fallback, when it has not stopped 30 seconds after the engine
saw the pause. Every position is durable when its step commits, so the next run resumes from them;
at most one chunk per engine slot (500 records) is applied again, each as a replace, so nothing is
doubled. Changes made while paused wait in the Change Data Feed (or the folder). `sz.sh resume`
clears the pause and starts a run. `sz.sh stop` pauses and cancels the active runs at once.

Between runs nothing is left running but the watcher's short scheduled runs: the job cluster stops,
Lakebase scales to zero after 30 idle minutes and the SQL warehouse after 5.

## Use the results

The results are the entity mart, in `<catalog>.senzing`. Setup creates its tables with their
comments; each ingest run refreshes them while it works, only for the entities that changed, as each
batch commits. Under a large load the mart trails ingest by minutes, and the run ends only once it
has caught up.

The mart is an entity map: which entity each source record resolves to and why, and which entities
relate. It does not copy your data: everything else about a record is in your source table, joined
on `(data_source, record_id)`.

| Table | One row per | Columns |
|---|---|---|
| `entity` | resolved entity | `entity_id`, `record_count` (its `entity_record` rows), `updated_at` |
| `entity_record` | source record | `data_source`, `record_id` (the mapping view's `RECORD_ID`), `entity_id` it resolves to, `match_key` (the features that resolved it, such as `+NAME+DOB`; null when the engine reports none), `updated_at` |
| `relationship` | related pair of entities | `entity_id_lo` < `entity_id_hi`, `match_level_code` (such as `POSSIBLY_SAME`), `match_level`, `match_key`, `updated_at` |

`updated_at` is when the mart last changed the row. `entity_record.entity_id` and both
`relationship` ids are `entity.entity_id`; `(entity_record.data_source, entity_record.record_id)` is
your source row whose mapping view gave that `RECORD_ID`, so joining the mapping view on `RECORD_ID`
is the exact match.

Duplicates found, largest first:

```sql
SELECT entity_id, record_count
FROM <catalog>.senzing.entity
WHERE record_count > 1
ORDER BY record_count DESC
LIMIT 100;
```

Your records with the entity each resolves to (here `customers` stands in for your source table or
its mapping view, registered with data source `CUSTOMERS`):

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

### The demo notebook

The deploy puts a SQL notebook, `sz_quickstart`, in your workspace at
`/Workspace/Users/<you>/.bundle/sz-databricks/prod/files/notebooks/sz_quickstart`. It tours the
results: `sz_health`, entities and records per data source, the largest entities, cross-source
entities and relationships. Attach it to the `sz-databricks-warehouse` SQL warehouse and fill in its
two widgets, `catalog` and `mart_schema` (`senzing` unless you changed it). It changes nothing.

### Who can read the results

Install with `--consumer-group <group>` and the install grants that group USE CATALOG on the catalog,
USE SCHEMA and SELECT on the mart schema, CAN USE on the warehouse and CAN READ on the dashboard.
There is no grant by default, and never to `account users` unless you name it. To grant another
group by hand:

```sql
GRANT USE CATALOG ON CATALOG <catalog> TO `<group>`;
GRANT USE SCHEMA, SELECT ON SCHEMA <catalog>.senzing TO `<group>`;
```

The mart's bookkeeping is in the internal schema, so that grant does not reach it: `_sync_state`,
`_quarantine` (entities the mart could not read, with the error) and `_ingest_quarantine`, the
records the engine rejected, one row each:

| Column | Holds |
|---|---|
| `run_id`, `source`, `data_source`, `record_id` | the run, the registered source, the data source code and the record's key |
| `category`, `error_code`, `message` | why: the error's category, the engine's error code (empty when the job, not the engine, refused the record) and the message |
| `payload` | the record as the job had it, or empty: it can hold the record's contents, so treat it like the source |
| `quarantined_at` | when |

A rejected record does not stop the run; `sz_health` reports `REJECTED_KEYS`. Fix the records at the
source, then `sz.sh requeue-rejected [CODE]` puts them back for the next run.

## Retention warnings and reload

Each source's position is a Delta version. If it falls behind the table's retained change data, the
source fails with a named error (`SOURCES_FAILED`, `source_errors` says why) and
`sz.sh reload <CODE> --confirm <CODE>` rebuilds it:

1. a full read of the view;
2. then a reconcile that deletes the Senzing records no longer in it.

Change data is never skipped silently.

## Sizing

Sizes are bundle variables. To change one, run the install script again with the new value and every
option you installed with, for example `--set autoscale_max=4`; it redeploys and changes only what
differs. The defaults:

| Variable | Default | Meaning |
|---|---|---|
| `node_type_id` | `r6g.xlarge` | Graviton (arm64), 4 cores, 32 GB. Any node type works (both arm64 and x86_64 libraries ship); prefer memory-optimized types and fewer, larger workers, since each worker's engine needs 4 GB before its threads. Change `worker_task_slots` with it (below) |
| `autoscale_min`, `autoscale_max` | `1`, `2` | ingest job cluster workers (equal for a fixed size) |
| `worker_task_slots` | `18` | engine threads (Spark task slots) per worker, at most the smaller of the node type's cores x 6 (the engine runs 4-8 threads per core against a cloud database, since its threads wait on database round trips) and the threads its memory holds at 1 GB each (below) |
| `cluster_slots` | empty | the most engine partitions (Spark tasks, each running one engine thread) a run uses at once. Empty: `autoscale_max` x `worker_task_slots`, so you size the cluster in one place. Set it only to override that (too low throttles; too high only queues tasks) |
| `executor_memory` | `4g` | JVM heap of each ingest executor; keep it small, the rest of the node is the engine's native memory, and a larger heap leaves room for fewer engine threads |
| `ebs_volume_size` | `100` | GiB of the one EBS volume per node: node types without local disks (the default `r6g.xlarge`) need one |
| `on_demand_nodes` | `1` | job cluster nodes on demand, the driver first; the rest are spot with fallback. A reclaimed driver loses the run; set it above the worker count when a spot reclaim must not slow a run |
| `spark_version` | `17.3.x-scala2.13` | Databricks Runtime 17.3 LTS (Spark 4.0, Scala 2.13) |
| `data_security_mode` | `SINGLE_USER` | the access mode the UI calls **Dedicated**, here to the jobs' service principal (`USER_ISOLATION`, the UI's **Standard**, also needs the Volume's `lib/` on the metastore allowlist) |
| `setup_timeout_seconds`, `ingest_timeout_seconds` | `3600`, `28800` | the longest a run may take before it is stopped (and stops billing); the ingest bound sits above a run's 6-hour limit, so it stops only a hung run |
| `lakebase_min_cu`, `lakebase_max_cu` | `4`, `4` | the Lakebase endpoint's autoscaling range, in compute units (about 2 GB each, so 8 GB by default); the install refuses less than 4 |
| `lakebase_vcpu` (`--lakebase-vcpu`) | `2` | the Lakebase size in vCPU the engine's concurrency is computed from (12 engine threads per vCPU) |
| `lakebase_suspend` | `1800s` | idle time before Lakebase scales to zero (60 seconds to 7 days; 30 minutes by default) |
| `warehouse_size`, `warehouse_auto_stop_mins` | `2X-Small`, `5` | the SQL warehouse the bundle creates |
| `pg_sslmode`, `pg_sslrootcert` | `verify-full`, `/etc/ssl/certs/ca-certificates.crt` | the engine's Lakebase TLS |

**Engine threads per worker.** Each ingest worker runs one engine, whose memory is outside the JVM
heap: 4 GB for the engine plus 1 GB per engine thread. A worker holds at most

```text
min(cores x 6, floor((node memory - executor_memory - 4 GB - Databricks reserve) / 1 GB))
```

engine threads, where the Databricks reserve, the memory Databricks keeps for the node's own
services, is 3% of the node plus 4800 MB. The default `r6g.xlarge` (32 GB) beside the `4g` heap holds
18 (its 4 cores would allow 24); an `r6g.2xlarge` (64 GB) holds 48 beside `4g` and 45 beside `8g`; an
`r6g.large` (16 GB) holds 2. The rule's numbers are in `scripts/node-sizing.yaml` in the bundle. Step
P3 of the install script, `scripts/node-sizing.sh <node_type_id> <executor_memory> <worker_task_slots>`,
reads the node type's cores and memory from `databricks clusters list-node-types` and stops the
install before anything changes when `worker_task_slots` is above that count, printing the numbers
(`NODE_SIZING`); it never lowers the value for you.

The setup job runs on a single-node cluster of the same node type, which needs capacity in your
region. The engine's concurrency is bounded by the Lakebase vCPU and by `cluster_slots`; a run that
needs more Lakebase connections than the database allows warns `CONNECTION_BUDGET`. To size Lakebase
up, raise `lakebase_min_cu`, `lakebase_max_cu` and `--lakebase-vcpu` together, in the default's
proportion (2 vCPU per 4 compute units).

## License and password

- `sz.sh license --file <path>` checks a license file (not empty, base64, a multiple of 4 characters,
  at most 64 KB; its value is never printed), stores it in the secret scope and has the engine read
  it: its expiry and record limit go to `sz_health`. `--check` has the engine read it from a scratch
  key, deleted after, and stores nothing. `sz_health` warns 30 days before a license expires
  (`LICENSE_EXPIRING`) and at 90% of its record limit (`LICENSE_NEAR_LIMIT`).
- `sz.sh rotate-password` generates a new password for the engine's Lakebase role, stores it and runs
  setup, which sets it. Run it when no ingest run is active.

## Upgrade

Download and verify the new release ([README](../README.md#verify)), then run its install script
with `--upgrade` and the same `--catalog` and options you installed with:

```sh
./sz-databricks-install-<new release>.sh <new release> --catalog <catalog> --upgrade [--accept-eula] [your other options]
```

It verifies and unpacks the new release into its own `--dir`, deploys it (the jobs, the watcher and
the dashboard), then runs setup's upgrade: it stages the new release's engine payload and updates
the tables. A release that carries a new EULA version needs `--accept-eula` again. Until the upgrade
runs, `sz_health` reports `UPGRADE_PENDING` and no ingest run starts; the watcher never upgrades by
itself. `sz.sh upgrade` runs setup's upgrade alone, for a deploy whose upgrade failed. An install
never downgrades: setup refuses a release older than the one it installed (`DOWNGRADE`). Operate
the install with the new release's `sz.sh` from then on.

Older releases' payloads stay under `engine/<release>/` in the Volume (about 1.3 GB each); delete them
by hand once you will not roll back.

## Uninstall

```sh
sz.sh uninstall --confirm "delete data"           # everything goes
sz.sh uninstall --confirm uninstall --keep-data   # the tables and the Volume stay
```

It prints each step as `==> U<n> …`:

| Step | What it does |
|---|---|
| U1 | stops ingest: pauses it and cancels the active runs |
| U2 | with `delete data`, runs setup's purge: every table and view in both schemas, `sz_health` included, and the Volume's working data. With `--keep-data`, unbinds the two schemas, the Volume and the Lakebase project with its endpoint so the destroy leaves them |
| U3 | `databricks bundle destroy`: the jobs, the warehouse, the dashboard, the alert, the notebook, the secret scope with the license and the password, the cluster policy and, with `delete data`, the Lakebase project, the schemas and the Volume |
| U4 | with `delete data`, purges the Lakebase project, which Databricks otherwise keeps soft-deleted for 7 days (its id stays taken meanwhile) |
| U5 | with `delete data`, checks that nothing remains: the two schemas, the four jobs, the warehouse, the dashboard (one the destroy moved to the trash does not count), the secret scope and the Lakebase project. Each one left is printed as `remains: …` and the exit status is 1 |

It ends with `uninstalled: nothing remains` (with `--keep-data`, `uninstalled; the data was kept`)
and removes the install record. Two things it never removes, because the install did not create
them for this install alone, are printed as `kept: …`:

- the jobs' service principal `sz-databricks-jobs`. It belongs to your Databricks account, not only
  this workspace: leave it (a later install uses it again), or remove its access to this workspace in
  the workspace's admin settings (**Identity and access**, **Service principals**). Deleting it in
  the account removes it from every workspace;
- the operator and consumer groups, which were only granted.

With `--keep-data` the Lakebase project and its Senzing repository stay with the schemas, so the
kept mart keeps its engine: a later install into the same catalog binds that project again. To remove a kept project by hand:
`databricks postgres delete-project projects/sz-databricks --purge`.

Verify that nothing remains, by hand:

```sh
databricks schemas get <catalog>.senzing_internal                     # does not exist
databricks schemas get <catalog>.senzing                              # does not exist
databricks jobs list -o json | jq -r '.[].settings.name' | grep '^sz-databricks-'   # prints nothing
databricks postgres list-projects --show-deleted -o json | jq -r '.[].name' | grep sz-databricks   # prints nothing
```

Each user has one deployment of the bundle per target. To install in another catalog or with
another Lakebase project, uninstall this one first: the install script stops on the existing
deployment, naming it, before it creates anything (`DEPLOYMENT_DIFFERS`).

## Reference

### How far behind the mart is

Each committed batch adds its affected entity ids to `<catalog>.senzing_internal._affected`; each
mart refresh takes everything there, refreshes those entities and removes exactly what it took. So
the rows in `_affected` are the mart's backlog (`sz_health.affected_pending`). Every 15 seconds a run
also records one row in `<catalog>.senzing_internal._loop_health` (kept 7 days): slots in use,
records per second, the backlogs (`backlog_staged`, `backlog_affected`, `backlog_redo`) and the
Lakebase sessions, waits and connections. A column is NULL when that signal could not be read.
