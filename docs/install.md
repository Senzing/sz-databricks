[sz-databricks](../README.md) / Install

# Install

**From a signed release to resolved records, in your own Databricks workspace, with one script.**
A workspace admin with MANAGE on the catalog does this once per workspace, and again with
`--upgrade` for each new release. Nothing happens in a browser. Start with the
[README](../README.md): the prerequisites and how to verify the release files.

Download one release's files into a directory and run the steps from there. Replace `<release>`
with the release, for example `4.4.3-1`, and `<catalog>` with the Unity Catalog catalog (it must
exist) that will hold the SENZING® entity resolution schemas. Every command uses your Databricks CLI
profile: `--profile <name>`, else `DATABRICKS_CONFIG_PROFILE`, else the CLI's default profile.

## 1. Dry run

`sz-databricks-install-<release>.sh` does everything from the downloaded files. Read it first, then
run it with `--dry-run`: it verifies and unpacks the release, reads the workspace, and prints every
step, command and grant; it changes nothing.

```sh
chmod +x sz-databricks-install-<release>.sh
./sz-databricks-install-<release>.sh <release> --catalog <catalog> --dry-run
```

Before any step changes anything, the script checks every prerequisite (the tools, the release
files, the license file, the workspace) and lists every problem at once, each as
`problem=<CODE>: <what and how to fix it>`, then exits 1. The codes are in
[troubleshooting](troubleshooting.md#sz_health-and-script-codes). A dry run ends with
`done: dry run of release <release> in catalog <catalog> (target prod); nothing was changed.`

## 2. Install

```sh
./sz-databricks-install-<release>.sh <release> --catalog <catalog> --accept-eula \
  [--license-file <path>] [--source <CODE>=<view>:<table>[=<column>][,<table>[=<column>]...][:<record id column>] ...] \
  [--operator-group <group>] [--consumer-group <group>] [--alert-email <address> ...] [--set <name>=<value> ...]
```

| Option | Meaning |
|---|---|
| `--catalog <catalog>` | required: the catalog the two schemas go in |
| `--accept-eula` | you accept the Senzing EULA ([below](#the-senzing-eula)); pass it only after you read it |
| `--license-file <path>` | your Senzing license ([below](#the-license)) |
| `--source …` | a data source to register and resolve, repeatable ([below](#sources-at-install)) |
| `--operator-group <group>` | a group that runs `sz.sh` ([below](#what-the-install-grants)) |
| `--consumer-group <group>` | a group that reads the results ([below](#what-the-install-grants)) |
| `--alert-email <address>` | mailed when a job run fails and when the hourly health alert finds `sz_health` not `OK`; repeatable |
| `--lakebase-vcpu <n>` | the Lakebase vCPU the engine's concurrency assumes ([Sizing](use.md#sizing)) |
| `--set <name>=<value>` | any other bundle variable, repeatable ([Settings](#settings)) |
| `--assets <dir>` | where the downloaded release files are (default: the current directory) |
| `--dir <dir>` | where the bundle is unpacked and kept (default `./sz-databricks-<release>`) |
| `--profile <name>` | the Databricks CLI profile |
| `--job-run-as <application id>` | a service principal you already have for the jobs, instead of `sz-databricks-jobs` |
| `--resolve-wait <seconds>` | how long to wait for the sources to resolve (default 1800) |
| `--upgrade` | upgrade an installed release ([upgrade](use.md#upgrade)) |
| `--force-setup` | run setup on a re-run even when it succeeded for this release |
| `--check-only` | verify and unpack the release, then stop: nothing in the workspace is read or changed |
| `--dry-run` | print every step; change nothing |

Keep `--dir`: it holds the install record (`sz-install.yaml`) and the deployment's local state, and
`<dir>/scripts/sz.sh` operates the install ([use](use.md)).

It runs these steps, each printed as `==> P<n> …` before it runs:

| Step | What it does |
|---|---|
| P0 local checks | the tools (`databricks`, `jq`, `tar`, `openssl`, `cosign`, `sha256sum` or `shasum`), the release files and the license file (not empty, base64, a multiple of 4 characters, at most 64 KB) |
| P1 verify and unpack | the signature of `SHA256SUMS` against the exact identity in the [README](../README.md#verify), the SHA-256 of each file it uses (which must be listed), then unpacks the bundle into `--dir` |
| P2 check | `scripts/preflight.sh`: stops before anything is created on a serverless-only workspace, on your existing deployment of this bundle in another catalog or Lakebase project (one deployment per user and target; [uninstall](use.md#uninstall)), on a soft-deleted Lakebase project holding the project id and, on a new install, on a EULA you have not accepted |
| P3 size | `scripts/node-sizing.sh`: stops when one worker of the node type cannot hold the engine threads at 1 GB each ([Sizing](use.md#sizing)), and when Lakebase is set below 4 compute units |
| P4 pre | `scripts/admin.sh pre`: creates the two schemas (`senzing_internal`, `senzing`) and the Volume `files`, the jobs' service principal `sz-databricks-jobs` (unless it exists) with the `workspace-access` entitlement and USE CATALOG, and gives you the **Service principal: User** role on it, which the deploy needs; creates the App's group `sz-databricks-app` (unless it exists) |
| P5 bind | binds those schemas and the Volume to the bundle, so one deploy is enough; also binds a Lakebase project an `uninstall --keep-data` kept, with its Senzing repository |
| P6 deploy | `databricks bundle deploy -t prod`: the Databricks App `sz-databricks`, the jobs, the Lakebase project, the secret scope, the SQL warehouse, the dashboard, the alert and the notebook; writes the install record; then starts the App and waits until it is RUNNING (`APP_NOT_RUNNING` otherwise). A dry run prints the bundle's grants here |
| P7 secrets | generates the engine's Lakebase password and stores it and the license in the secret scope (on stdin, never printed) |
| P8 grants | `scripts/admin.sh post` and `app`, and `operator` and `consumer` for the groups you named |
| P9 EULA and setup | runs the setup job: it stages the engine payload into the Volume (the first run downloads about 600 MB), creates the `senzing` database and the `sz_engine` role in Lakebase, the Senzing schema and default configuration, the install's tables, the entity mart and `sz_health`, and records your EULA acceptance. A re-run skips it when `sz_health` shows setup succeeded for this release, unless you pass `--license-file` or `--force-setup` or P7 generated a new engine password. On a re-install over kept data it then resumes ingest, which the uninstall paused |
| P10 sources | `sz.sh register --sources`: every `--source` in one operations run (a dry run prints the `GRANT` statements every source needs, all sources together; a source refused for access or change data feed lets the others register, then the install stops with every statement they need), then `sz.sh wait` until `sz_health.resolve_state` reads `CAUGHT_UP`, for at most `--resolve-wait` seconds (default 1800). A wait that ends while the install is healthy and its records still rise is not a failure: it prints `still resolving … check with sz.sh status` and the install goes on to P11 |
| P11 health | `sz.sh status`: `sz_health.overall` must read `OK` |

Every step is idempotent: run the same command again after fixing a failure and it skips what
exists. Success ends with
`done: sz-databricks <release> installed in catalog <catalog> (target prod; operate it with <dir>/scripts/sz.sh); sz_health.overall reads OK.`
The exit status is 0 only then; 1 means a step failed or `sz_health` is not `OK` (its codes and
fixes are printed); 2 means bad usage.

Verify: `<dir>/scripts/sz.sh status` prints `"overall": "OK"`.

## The Senzing EULA

Read the [Senzing End User License Agreement](https://senzing.com/end-user-license-agreement/), then
pass `--accept-eula`. Without it a new install stops at P2 with `EULA_NOT_ACCEPTED`, before anything
is changed, and an upgrade to a release that carries a new EULA version stops at P9, before setup.
Setup records the EULA version, the time and who accepted; `sz_health` shows them
(`eula_version`, `eula_accepted_at`, `eula_accepted_by`). Once setup has run, `sz.sh accept-eula --yes`
accepts it too. No setup or ingest run starts until it is accepted.

## The license

`--license-file <path>` takes the license as Senzing, Inc. sends it: a file of base64 text. The
script checks it at P0 and stores it in the secret scope without printing it; setup has the engine
read it and `sz_health` shows its expiry, record limit and records used. Without a license the
engine runs in evaluation mode, which takes 500 records: the install completes, then exits 1 with
`LICENSE_EVALUATION` until you store one with `sz.sh license --file <path>`. To renew, check the new
file first (`sz.sh license --file <path> --check` stores nothing), then store it. No license yet?
Open Ask Senzing, the assistant on [docs.senzing.com](https://docs.senzing.com), and ask it for a
free evaluation license.

## Sources at install

`--source <CODE>=<view>:<table>[=<column>][,<table>[=<column>]...][:<record id column>]` names a
data source code, its mapping view and the base tables the view reads (each `catalog.schema.name`).
The record id column of the tables defaults to `RECORD_ID`; `<table>=<column>` gives one table its
own (a child table's foreign key). For example:

```sh
--source CUSTOMERS=main.crm.customer_mapped:main.crm.customer=customer_id,main.crm.customer_phone=customer_id
```

After setup the script registers them all in one operations run (`sz.sh register --sources`,
[use](use.md#several-sources-in-one-run)) and waits until they are resolved, so one run ends with
results. Prepare each source first ([use](use.md#prepare-a-source)): Change Data Feed on and a
mapping view. On a new install the jobs' service principal does not exist before P4, so a source it
cannot read is refused with `SOURCE_NO_ACCESS` and the GRANT statements to run (the others
register): run them, then run the same command again; it keeps the sources an earlier run
registered (to change one, `sz.sh unregister` it first). A folder of files is registered after the
install with `sz.sh register <CODE> --path …` ([use](use.md#a-files-source)).

`--source-via <CODE>=<table>.<key column>:<base table>.<via key column>.<record id column>` names a
table the mapping view of `--source <CODE>` only looks up, one that holds no record id (repeatable).
A changed row of it, before and after the change, re-resolves the records of `<base table>` (one of
that source's tables) whose `<via key column>` equals its `<key column>`; `<record id column>` is
`<base table>`'s. For example, a contacts view that reads each contact's account:

```sh
--source-via CONTACTS=main.crm.accounts.account_id:main.crm.contacts.account_id.contact_id
```

The script exits 2 if `<CODE>` names no `--source`. After the install, `sz.sh register --via` does
the same ([use](use.md#tables-shared-across-sources)).

## What the install grants

Nothing beyond this list; a dry run prints each grant.

| To | What |
|---|---|
| the jobs' service principal (`sz-databricks-jobs`) | the `workspace-access` entitlement, USE CATALOG on `<catalog>`; USE SCHEMA, SELECT, MODIFY and CREATE TABLE on both schemas; READ and WRITE VOLUME on the Volume; READ on the secret scope; CAN USE on the cluster policy; CAN MANAGE RUN on the setup, ingest and watcher jobs; a Lakebase OAuth role with CREATEDB and CREATEROLE (no superuser) |
| you, the installer | the **Service principal: User** role on the jobs' principal; USE SCHEMA and SELECT on both schemas (the jobs' principal creates and owns every table and view in them, `sz_health` among them, so owning the catalog does not let you read them); you own the deployment and MANAGE the secret scope |
| the App's service principal | membership of the group `sz-databricks-app`, which has WRITE on the secret scope (the App stores the license and the engine password); CAN MANAGE on the App (it reads the App's permissions to check a caller's); USE CATALOG on `<catalog>` and SELECT on both schemas; CAN MANAGE RUN on the setup, ingest, watcher and operations jobs, CAN USE on the warehouse, READ and WRITE VOLUME on the Volume (run results and its activity record) and access to the Lakebase database, bound to the App |
| the jobs' service principal, on the App | CAN MANAGE: the watcher stops the App when it has been idle for `app_idle_minutes`, should the App not stop itself |
| `--operator-group` | CAN MANAGE on the App (every `sz.sh` operation but `uninstall`), CAN MANAGE RUN on the setup, operations and ingest jobs, READ VOLUME on the Volume (the operations' results), SELECT on `sz_health`, CAN USE on the warehouse and the USE CATALOG and USE SCHEMA those need |
| `--consumer-group` | USE CATALOG on `<catalog>`, USE SCHEMA and SELECT on the mart schema `senzing` (the entity tables and `sz_health`), CAN USE on the warehouse and CAN READ on the dashboard |

The jobs run as that principal, so they reach only its rights, never yours. Give it nothing beyond
what these pages list, plus SELECT on your sources ([use](use.md#change-data-feed-and-grants)). An
operator runs the operations job, so an operator can register any table the jobs' principal reads.
Without a group, nobody but you and the jobs' principal can operate the install or read the results.
The principal needs no cluster-create entitlement: the cluster policy lets it create the jobs'
clusters and fixes their node type, runtime and access mode.

## Settings

`--set <name>=<value>` sets any bundle variable that has no flag of its own; a name the bundle does
not have is refused. The most used:

| Variable | Default | Meaning |
|---|---|---|
| `schema` | `senzing_internal` | the internal schema (registry, status, bookkeeping) and the Volume's home |
| `mart_schema` | `senzing` | the schema of the entity mart and `sz_health`, the one you grant to readers |
| `volume` | `files` | the Volume in the internal schema |
| `app_name` | `sz-databricks` | the name of the Databricks App, and the name the jobs, the warehouse, the cluster policy, the dashboard and the alert are named after |
| `app_idle_minutes` | `30` | minutes without a request after which the App stops its compute (`sz.sh` starts it again); `0` keeps it running |
| `app_compute_size` | `MEDIUM` | the App's compute size (`MEDIUM`, `LARGE` or `XLARGE`) |
| `app_group` | `sz-databricks-app` | the group that holds the App's service principal and has WRITE on the secret scope |
| `lakebase_project` | `sz-databricks` | the Lakebase project id (unique in the workspace) |
| `warehouse_id` | the warehouse the bundle creates | a SQL warehouse you already have (the bundle's is still created, and stays stopped) |
| `payload_source` | `github-release` | where the setup job reads the engine payload ([below](#restricted-network-stage-the-payload)) |
| `watch_cron` | `0 0/5 * * * ?` | the watcher's schedule (Quartz) |
| `alert_cron` | `0 0 * * * ?` | the health alert's schedule (Quartz), hourly |

The cluster and Lakebase sizes are bundle variables too ([Sizing](use.md#sizing)). Use dedicated
schemas: the jobs create and modify tables there. A later run of the install script, an upgrade
included, must name the same `--catalog` and the same `--set` values; the install record keeps them.

## Restricted network: stage the payload

The engine payload is the Senzing runtime and native libraries the jobs run: the shared archive and
the two native archives of the release. By default (`payload_source=github-release`) the setup job
downloads them from this repository's release, which needs the job clusters to reach `github.com`,
`release-assets.githubusercontent.com` and `objects.githubusercontent.com`. On a network that
restricts egress, read them from the Volume instead:

1. Install with
   `--set payload_source=volume:/Volumes/<catalog>/senzing_internal/files/drop/<release>`. The
   install creates the Volume at P4; setup at P9 then fails, naming the missing archive.
2. Copy the three archives there from the download directory:

   ```sh
   dest=dbfs:/Volumes/<catalog>/senzing_internal/files/drop/<release>
   databricks fs mkdir "$dest"
   for f in sz-databricks-engine-shared-<release>.tar.gz \
            sz-databricks-engine-native-<release>-linux-arm64.tar.gz \
            sz-databricks-engine-native-<release>-linux-amd64.tar.gz; do
     databricks fs cp "$f" "$dest/$f"
   done
   ```

3. Run the same install command again.

Setup checks every archive against the digests compiled into the engine JAR whichever source you
choose, so an archive from another release is refused.

## No data of your own? Load the CORD data

`sz-databricks-cord-data.tar.gz` is the official Senzing
[Collections Of Relatable Data (CORD)](https://senzing.com/senzing-ready-data-collections-cord/) for
Senzing on Databricks, from its Las Vegas collection, reshaped into normalized source tables for six
source systems (about 200,000 records): `crm`, `provider_registry`, `vendor_master`,
`risk_watchlist`, `loan_portfolio` and `entity_reference`. The original JSON Lines data is on the
[CORD page](https://senzing.com/senzing-ready-data-collections-cord/). Download it with the release
and verify it like the other files ([README](../README.md#verify)), then:

```sh
tar -xzf sz-databricks-cord-data.tar.gz
cd sz-databricks-cord-data
cat README.md   # what it holds: 26 tables in six source systems
```

`load.sh` loads it into a catalog you name, which must exist: use the catalog you install
sz-databricks into. It runs `load.sql` one statement at a time through the Statement Execution API
on a SQL warehouse you can use (`databricks warehouses list`), with your catalog in place of the
`sz_cord_data` the file names. Part 1 creates the schema `cord_stage` with the Volume `files`, then
one schema per source system with its tables, every table with Change Data Feed on and 30 days of
deleted files kept (the retention registration recommends). The script then
uploads each source directory to the Volume and runs part 2: `COPY INTO` loads every table. Last it
prints every table's loaded and expected row counts and exits 0 only when they are equal. It needs
`jq`; `--dry-run` prints every statement and upload and runs nothing.

```sh
./load.sh <catalog> <warehouse id> [--profile <name>]
```

Re-running is safe: objects are created only if missing and `COPY INTO` skips files it already
loaded. The tables are ordinary business tables, not Senzing records: map them to the
Senzing entity specification with mapping views before you register them
([use](use.md#write-a-mapping-view)), then pass one `--source` per mapping view. A source system
can hold more than one kind of record: `crm` holds organizations (`accounts`) and people
(`contacts`), so it maps to two views, each its own data source.

A view that only looks up another table, such as a view over `crm.contacts` that reads each
contact's account from `crm.accounts`, also needs one `--source-via` for that table
([sources at install](#sources-at-install)):
`--source-via <CODE>=<catalog>.crm.accounts.account_id:<catalog>.crm.contacts.account_id.contact_id`.

Next: [watch it resolve](use.md#watch-it-resolve). If a step fails:
[troubleshooting](troubleshooting.md).

## Reference

### Engine settings

Setup turns on the per-entity feature store of the Senzing repository (`RES_ENT.FEATURES`) and the
engine uses advisory entity locks (`ER.ENTITY_LOCK_MODE` `ADVISORY`), to keep Lakebase reads and
lock contention low. Every engine on one Senzing repository must use the same lock mode.

The engine's database connection is TLS with the server certificate verified: the job clusters set
`PGSSLMODE=verify-full` and `PGSSLROOTCERT=/etc/ssl/certs/ca-certificates.crt`, the node's CA
bundle, which holds the Let's Encrypt roots Lakebase's certificate chains to.
