[sz-databricks](../README.md) / Use

# Use

Day-to-day operation of an installed App: bringing data in, watching SENZING® entity resolution
run and using the results. The App has five pages: **Setup**, **Sources**, **Files**, **Grants** and **Status**. Every
action on them needs CAN MANAGE on the App (set on the App page with **Share**).

`<catalog>` below is the catalog you installed into. `senzing` is the mart schema: it holds the
entity mart, the resolved entities as tables you query. `senzing_internal` is the internal schema.
Both are the defaults; use your names if you changed them at install.

## Prepare a source

A source is either a set of Unity Catalog tables read through a mapping view, or a folder of files
in a Volume ([a files source](#a-files-source), which needs no mapping view and no Change Data
Feed).

### Change Data Feed and grants

The ingest job reads each base table's changes through Delta Change Data Feed. `<principal>` below
is each of the App's service principal (registration checks the source as it) and the jobs' service
principal (`sz-databricks-jobs` unless you gave `job_run_as`), which loads it. Who can run each
statement:

- **The table owner**, for each base table a source reads:

  ```sql
  ALTER TABLE <catalog>.<schema>.<table> SET TBLPROPERTIES (
    delta.enableChangeDataFeed = true,
    delta.deletedFileRetentionDuration = 'interval 30 days'   -- recommended (default 7 days)
  );
  ```

- **The catalog owner, or a user with MANAGE on the catalog**, only when the tables are in a catalog
  other than the one you installed into (the install already granted USE CATALOG on that one to
  both principals):

  ```sql
  GRANT USE CATALOG ON CATALOG <catalog> TO `<principal>`;
  ```

- **The owner of the schema, table and view, or a user with MANAGE on them:**

  ```sql
  GRANT USE SCHEMA ON SCHEMA <catalog>.<schema> TO `<principal>`;
  GRANT SELECT ON TABLE <catalog>.<schema>.<table> TO `<principal>`;
  GRANT SELECT ON VIEW <catalog>.<schema>.<mapping_view> TO `<principal>`;
  ```

A longer retention keeps more history, and so more storage, and gives you more time to recover from
a stopped source before its changes expire ([retention warnings](#retention-warnings-and-reload)).


### Write a mapping view

One row per Senzing record, with exactly these columns:

- `DATA_SOURCE`: a constant per source, such as `'CUSTOMERS'`.
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

On **Sources**, under **Register a source**, the **Add source** box takes a mapping view or table
(`<catalog>.<schema>.<name>`), or a folder (`/Volumes/…`, a files source). Give the source name and
its Senzing data source code (the `DATA_SOURCE` value of the view); for a mapping view, its base tables with their key columns. A table that
itself holds `DATA_SOURCE`, `RECORD_ID` and `RECORD_JSON`, given no base tables, is its own base
table, keyed by `RECORD_ID`.

Registration answers at once. The source shows *checking* while the App checks, in the background,
Change Data Feed, the grants and the view's columns on a sample of 1,000 rows. A passed check enables
the source (it shows *enabled*, with any retention advice under *Recommended*) and
starts its first load: the run adds the data source to the Senzing configuration itself, so the first load costs one cluster start. A source
registered while a run is active loads in the next run. There is no limit on how many tables are
watched.

A base table with no Delta version in Unity Catalog (a streaming table or materialized view) is
refused: register the Delta table it reads. A source the jobs' principal cannot read would never
update, so its registration is refused with the GRANT statements to run.

### A files source

A source can be a folder in a Volume instead of tables: give the folder
(`/Volumes/<catalog>/<schema>/<volume>/<folder>`) and the format `jsonl`, one Senzing JSON record per
line with `RECORD_ID`. A line without `DATA_SOURCE` gets the registered one; blank lines are
skipped. Grant both principals READ VOLUME on the volume, plus USE CATALOG and USE SCHEMA.
Registration checks that the folder exists, that the App can list it and the format.

**How files load.** The folder is walked recursively. A file's version is its path, size and
modification time. A new or changed file (overwritten, appended to) is read again whole, and only the
records that changed reach the engine; a record the new version no longer holds is deleted. A record
in a later file replaces an earlier one with the same `RECORD_ID`.

- **Latency.** A file is taken once two listings in a row see the same version. While a run is
  active the engine lists the folder every 15 seconds, so a dropped file reaches the mart within one
  or two polls plus the load itself. With no run active, the App checks every 60 seconds and starts
  one: add the cluster start.
- **Modification times have 1-second precision.** A file rewritten at the same size within the same
  second as the version already listed looks unchanged and is not read again: write it under a new
  name, or wait a second.
- **Skipped names.** Any path segment starting with `.` or `_`, and names ending in `.tmp`, `.part`
  or `.crc`. Drop each file whole: write it elsewhere and move it in, or give it a skipped name until
  it is complete. A link or a path leaving the folder is refused.

**When a file is removed** (chosen at registration, shown on **Sources**):

- `mirror` (the default): the folder is the source of truth. Removing a file deletes the records only
  it supplied (a record another file still holds stays). **Do not move or archive files out of the
  folder**: moving one into a `_`-prefixed subfolder such as `_done/` removes it too. Moving a file to
  another path in the folder deletes nothing.
- `keep`: removing a file deletes nothing. Choose it if your process archives files after loading.

A removal counts once two listings in a row miss the file; a missing or unreadable folder never
counts (it fails the source instead). Deletes run through the engine like adds: removing a file takes
about as long as loading it did. If a removal would delete more than half the folder's files (with at
least 3 held) or records, or every file, it is **held**: new files and changes that drop nothing
still load, **Sources** shows how many files and records it would delete, and putting the files back
releases it. A user with CAN MANAGE confirms that exact set with **Confirm removal**.

**Files** shows each file of a files source: PENDING (seen, not loaded yet), INGESTED, FAILED (with
why), REMOVED or HELD, with its size and time. It also counts the files in each state. It lists at most 1,000 files,
those not INGESTED first. For every loaded file query `<catalog>.senzing_internal._files_<source>_ledger_v`
(file, version, record count, last load); `<catalog>.senzing_internal._file_events` records each time
a file failed, was held or was removed. Viewing **Files** reads the Volume only, so it never starts
the SQL warehouse.

### The Grants page

**Grants** lists, per registered source and per principal (the App's service principal and the
principal the ingest job runs as), each privilege needed: USE CATALOG, USE SCHEMA, then SELECT on each
base table and the view, or READ VOLUME for a files source. It shows whether Unity Catalog effective
permissions hold it (a group's grant counts) and the GRANT statement to run. An answer it cannot read
shows "cannot verify", never granted. Answers are cached for 5 minutes; **Check again** reads them
again. The App never runs a GRANT itself.

## Run, pause and resume

The ingest job runs when a registered table or folder changes, or when you click **Start a run** on
**Status**. Each run is one engine loop: it ingests every new commit, processes
redo (work the engine queues when a change to one entity means related entities must be evaluated
again) and refreshes the mart for the entities that changed, then polls the sources again every 15 seconds. After 10
minutes with no new commit and no redo it ends and the cluster stops; a busy run ends after 6 hours
and the next change starts a fresh one. Commits that land while a run is active are ingested by that
run. One run at a time.

The App watches for changes itself. Every minute it reads each registered base table's latest Delta
commit version from Unity Catalog's table metadata, which starts no warehouse or cluster. When a
version moved, it starts the job, unless a run is running or queued. Any commit counts, even one that
changes no rows.

**Pause** stops new work: the App starts no run, and a run in progress stops cleanly. The engine
reads the pause at its next poll, takes no new work, lets the chunks in flight commit and ends
`paused`. **Status** shows "pausing…", then `paused`. The App cancels the run only as a fallback, when
it has not stopped within about 30 seconds. Every position is durable when its step commits, so the next
run resumes from them; at most one chunk per engine slot (500 records) is applied again, each as a
replace, so nothing is doubled. Changes made while paused wait in the Change Data Feed (or the
folder). **Resume** clears the pause and starts a run.

Between runs no compute is left running but the App: the job cluster stops, Lakebase scales to zero
after 30 idle minutes and the SQL warehouse after 5.

### Bottlenecks on the Status page

**Bottlenecks (last hour)** charts what the engine samples about every 15 seconds while a run works,
over the latest run's last hour. Each chart's legend shows the newest value; hover over a sample for
all of its values. `n/a` means the engine could not read that signal, never zero; a break in a line
is a gap between samples or an unknown value.

- **Cluster.** Engine slots in use, stacked by kind (ingest, redo, mart), against the dashed total;
  records per second; the backlog (rows staged and not yet ingested, entity ids waiting for the
  mart, the redo queue); the latest active and pending tasks and executors.
- **Lakebase.** The engine role's sessions (active, idle); connections used against the dashed
  limit; waiting sessions by wait event (the five with the most sessions, the rest as `other`); and
  the latest sample's top statements by total time.

How to read the waits is in [troubleshooting](troubleshooting.md#reading-the-lakebase-waits).

## Retention warnings and reload

Each source's position is a Delta version. If it falls behind the table's retained change data, the
App warns before the gap. If the gap is reached, the source stops with a named error and **Reload
source** on **Sources** rebuilds it:

1. a full read of the view;
2. then a reconcile that deletes the Senzing records no longer in it.

Change data is never skipped silently.

## Use the results

The results are the entity mart, in `<catalog>.senzing`. Setup creates its tables with their
comments; each ingest run refreshes them while it works, only for the entities that changed, as each
batch commits. Under a large load the mart trails ingest by minutes, and the run ends only once it
has caught up.

The mart is an entity map: which entity each source record resolves to and why, and which entities
relate. It does not copy your data: everything else about a record is in your source table, joined on
`(data_source, record_id)`.

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

### Who can read the results

Install with `--var consumer_group=<group>` and the install script grants that group USE CATALOG on
the catalog and USE SCHEMA and SELECT on the mart schema, on every run. There is no grant by default,
and never to `account users` unless you name it. Or run the two statements the install script prints:

```sql
GRANT USE CATALOG ON CATALOG <catalog> TO `<group>`;
GRANT USE SCHEMA, SELECT ON SCHEMA <catalog>.senzing TO `<group>`;
```

The mart's bookkeeping is in the internal schema, so that grant does not reach it: `_sync_state`,
`_quarantine` (entities the mart could not read, with the error) and `_ingest_quarantine`, the records
the engine rejected, one row each:

| Column | Holds |
|---|---|
| `run_id`, `source`, `data_source`, `record_id` | the run, the registered source, the data source code and the record's key |
| `category`, `error_code`, `message` | why: the error's category, the engine's error code (empty when the job, not the engine, refused the record) and the message |
| `payload` | the record as the job had it, or empty: it can hold the record's contents, so treat it like the source |
| `quarantined_at` | when |

## Sizing

Sizes are bundle variables. To change one, run the install script again with the new value and every
`--var` you installed with, for example `--var autoscale_max=4`; it redeploys and changes only what
differs. The defaults:

| Variable | Default | Meaning |
|---|---|---|
| `node_type_id` | `r6g.large` | Graviton (arm64), 2 cores, 16 GB. Any node type works (both arm64 and x86_64 libraries ship). Size memory for the engine: about 4 GB per engine process plus 0.5-1 GB per engine thread, outside the JVM heap, growing with the repository; prefer memory-optimized types and fewer, larger workers |
| `autoscale_min`, `autoscale_max` | `1`, `2` | ingest job cluster workers (equal for a fixed size) |
| `worker_task_slots` | `12` | engine threads (Spark task slots) per worker: the node type's cores x 6. The engine runs 4-8 threads per core against a cloud database, since its threads wait on database round trips |
| `cluster_slots` | empty | the most engine partitions (Spark tasks, each running one engine thread) a run uses at once. Empty: `autoscale_max` x `worker_task_slots`, so you size the cluster in one place. Set it only to override that (too low throttles; too high only queues tasks) |
| `executor_memory` | `4g` | JVM heap of each ingest executor; keep it small, the rest of the node is the engine's native memory |
| `ebs_volume_size` | `100` | GiB of the one EBS volume per node: node types without local disks (the default `r6g.large`) need one |
| `on_demand_nodes` | `1` | job cluster nodes on demand, the driver first; the rest are spot with fallback. A reclaimed driver loses the run; set it above the worker count when a spot reclaim must not slow a run |
| `spark_version` | `17.3.x-scala2.13` | Databricks Runtime 17.3 LTS (Spark 4.0, Scala 2.13) |
| `data_security_mode` | `SINGLE_USER` | the access mode the UI calls **Dedicated**, here to the jobs' service principal (`USER_ISOLATION`, the UI's **Standard**, also needs the Volume's `lib/` on the metastore allowlist) |
| `setup_timeout_seconds`, `ingest_timeout_seconds` | `3600`, `28800` | the longest a run may take before it is stopped (and stops billing); the ingest bound sits above a run's 6-hour limit, so it stops only a hung run |
| `lakebase_min_cu`, `lakebase_max_cu` | `4`, `4` | the Lakebase endpoint's autoscaling range, in compute units (about 2 GB each, so 8 GB by default) |
| `lakebase_vcpu` | `2` | the Lakebase size in vCPU the engine's concurrency is computed from (12 engine threads per vCPU); the Setup page starts with it |
| `lakebase_suspend` | `1800s` | idle time before Lakebase scales to zero (60 seconds to 7 days; 30 minutes by default) |
| `warehouse_size`, `warehouse_auto_stop_mins` | `2X-Small`, `5` | the SQL warehouse the bundle creates for the App |
| `pg_sslmode`, `pg_sslrootcert` | `verify-full`, `/etc/ssl/certs/ca-certificates.crt` | the engine's Lakebase TLS |

The setup job runs on a single-node cluster of the same node type, which needs capacity in your
region. The engine's concurrency is bounded by the Lakebase vCPU and by `cluster_slots`. To size Lakebase
up, raise `lakebase_min_cu`, `lakebase_max_cu` and `lakebase_vcpu` together, in the default's
proportion (2 vCPU per 4 compute units). You can also correct the vCPU on the Setup page and click
**Save**. The
Setup page shows the resulting limit and whether threads or connections set it.

## Upgrade

Download and verify the new release, then run its install script with the same `--var`s. The new App
sees that setup installed an older release: Setup and Status show "Upgrade required", and it starts
no run. It then upgrades by itself, once per release: it pauses ingest, waits until no run is active,
runs setup Upgrade (stages the new release's engine payload, the Senzing runtime the jobs run, and
updates the tables) and resumes if it paused.

If that Upgrade fails it is not tried again and ingest stays paused: fix the cause and click
**Upgrade** on the Setup page (the pause then clears). An App older than the installed release refuses
Install and Upgrade and never downgrades: deploy that release or newer. Older releases' payloads stay
under `engine/<release>/` in the Volume (about 1.3 GB each); delete them by hand once you will not
roll back.

## Uninstall

On **Setup**, in **Uninstall**, type `uninstall` to confirm. The App pauses ingest and cancels the
jobs' active runs.

Your data is kept unless you also tick **Also delete data** and type `delete data`. Data means:

- the App's tables in both schemas (registry, status, quarantine and the entity mart) and the
  Volume's working data (checkpoints, feed, staging): a setup run deletes them as the jobs' service
  principal (which owns them); its result is in the setup job's runs;
- the license and engine password secrets, which the App deletes.

The staged payload and the jobs' JAR stay until you destroy the bundle. From the bundle directory:

```sh
databricks bundle destroy -t prod --var catalog=<catalog> --var job_run_as=<jobs-sp-application-id>
```

Add any other `--var` you installed with. It removes everything the bundle created, the
App, both jobs, the schemas and Volume (with the staged payload), the secret scope and the Lakebase
project (with the Senzing repository).

## Reference

### How far behind the mart is

Each committed batch adds its affected entity ids to `<catalog>.senzing_internal._affected`; each mart
refresh takes everything there, refreshes those entities and removes exactly what it took. So the
rows in `_affected` are the mart's backlog. Every 15 seconds a run also records one row in
`<catalog>.senzing_internal._loop_health` (kept 7 days): slots in use, records per second, the
backlogs (`backlog_staged`, `backlog_affected`, `backlog_redo`) and the Lakebase sessions, waits and
connections. A column is NULL when that signal could not be read.
