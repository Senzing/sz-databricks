[sz-databricks](../README.md) / Install

# Install

**From a signed release to a running App, in your own Databricks workspace.** A workspace admin
does this once per workspace, and again for each new release. Start with the
[README](../README.md): the prerequisites and how to verify the release files.

Download one release's files into a directory and verify them. `<download-dir>` below is that
directory's absolute path: the install script runs from the bundle directory inside it. Replace
`<release>` with the release, for example `0.1.0-rc.1`, and `<catalog>` with the Unity Catalog
catalog that will hold the SENZING® entity resolution schemas. Every command uses your Databricks
CLI profile (`DATABRICKS_CONFIG_PROFILE`, or the default profile).

## 1. Choose the payload source

The engine payload is the Senzing runtime and native libraries the jobs run: the shared archive and
the two native archives of the release. The setup job stages it into the bundle's Volume when you
click **Install** in step 3. It reads it from one of two places, set with the bundle variable
`payload_source`:

| Source | When | What you do |
|---|---|---|
| `github-release` (the default) | the job clusters can reach `github.com`, `release-assets.githubusercontent.com` and `objects.githubusercontent.com` | nothing: the setup job downloads its release's payload |
| `volume:<dir>` | the workspace restricts egress, or you are not sure | pass `--var payload_source=volume:/Volumes/<catalog>/senzing_internal/files/drop/<release>` in step 2, then copy the three payload archives there ([restricted network](#restricted-network-copy-the-payload)) before step 3 |

The Volume path works on any network. The setup job checks the archives against the digests compiled
into the engine JAR whichever source you choose, so a copy from another release is refused.

## 2. Install the bundle

A workspace admin with MANAGE on the catalog installs in one command, from the unpacked bundle:

```sh
cd <download-dir>
tar -xzf sz-databricks-bundle-<release>.tar.gz && cd bundle
scripts/install.sh --target prod --release-dir <download-dir> --var catalog=<catalog> --var consumer_group=<group>
```

`consumer_group` names the group that will query the results; leave it out and nobody but you and
the service principals can read them ([who can read the results](use.md#who-can-read-the-results)).
Read the script first: `--dry-run` prints every step and changes nothing.

It runs these steps, each printed before it runs:

| Step | What it does |
|---|---|
| 1 verify | `scripts/verify-release.sh <download-dir> <release>`: nothing runs from an unverified release |
| 2 pre | `scripts/admin.sh pre`: creates the two schemas (`senzing_internal`, `senzing`) and the Volume, the `sz-databricks-app` group and the jobs' service principal (below) |
| 3 bind | binds those schemas and the Volume to the bundle (`databricks bundle deployment bind`), so one deploy is enough |
| 4 deploy | `databricks bundle deploy -t prod`: the App, the jobs, the Lakebase project, the secret scope, the SQL warehouse and the grants; the jobs' JAR goes to the Volume |
| 5 post | `scripts/admin.sh post`: the App's service principal joins the `sz-databricks-app` group and gets CAN MANAGE on the App and USE CATALOG |
| 6 grant | only with `--var consumer_group=<group>`: `scripts/admin.sh consumer` gives that group USE CATALOG, and USE SCHEMA and SELECT on the results schema |
| 7 start | `databricks bundle run sz_app -t prod`: starts the App |

Every step is idempotent: a re-run skips what exists, and a failed step prints the command that
resumes there (`--from <step>`).

**What it prints.** Each line starts the same way, so you can follow a run in its log:

| Line | Meaning |
|---|---|
| `STEP <n> <name>: <command>` | step `<n>` starts and runs `<command>` |
| `SKIP bind: <key> <id> already bound` | step 3 finds that schema or Volume bound already |
| `job_run_as=<application-id>` | step 2 printed the jobs' service principal |
| `install.sh: step <name> failed; after fixing it, resume with: <command>` | the run stopped; fix the cause, then run `<command>` |
| `Dry run: nothing changed.` | the `--dry-run` finished |
| `Installed (target <target>).` | every step succeeded |

After the last line it prints the two GRANT statements that let another group read the results.

**Options.** Pass any bundle variable as `--var <name>=<value>`:

| Variable | Default | Meaning |
|---|---|---|
| `schema` | `senzing_internal` | the internal schema (registry, status, bookkeeping) and the Volume's home |
| `mart_schema` | `senzing` | the schema of the entity mart (the resolved entities as tables you query), the one you grant to readers |
| `volume` | `files` | the Volume in the internal schema |
| `app_name` | `sz-databricks` | the App's name; the jobs, the warehouse and the cluster policy are named after it |
| `lakebase_project` | the App's name | the Lakebase project id (unique in the workspace) |
| `warehouse_id` | the warehouse the bundle creates | a SQL warehouse you already have for the App (the bundle's is still created, and stays stopped) |
| `job_run_as` | created by step 2 | the application id of a service principal you already have for the jobs |
| `payload_source` | `github-release` | where the setup job reads the engine payload ([step 1](#1-choose-the-payload-source)) |

The cluster and Lakebase sizes are bundle variables too ([Sizing](use.md#sizing)). Use dedicated
schemas: the App and the jobs create and modify tables there.

**The jobs' service principal.** `scripts/admin.sh pre` creates a dedicated service principal for
the jobs (`sz-databricks-jobs`, not the App's) unless it exists. It gives it the `workspace-access`
entitlement and USE CATALOG on the catalog, and gives you, the deploying user, the **Service
principal: User** role on it, which the deploy needs to set the jobs' `run_as` (the manager role the
creator gets is not enough). When someone else will deploy, set `DEPLOYER=<user>`. The principal
needs no cluster-create entitlement: the bundle's cluster policy (`sz-databricks-jobs`) lets it
create the jobs' clusters and fixes their node type, runtime and access mode.

The jobs run as that principal, and the App can run the ingest job, so the App can reach only that
principal's rights, never yours. Give it nothing beyond what these pages list.

**What the bundle grants.** The deploy grants:

- the App USE SCHEMA, SELECT, MODIFY and CREATE TABLE on the internal schema, USE SCHEMA and
  SELECT on the mart schema and READ VOLUME on the Volume;
- the jobs' principal USE SCHEMA, SELECT, MODIFY and CREATE TABLE on both schemas, READ and WRITE
  VOLUME and READ on the secret scope;
- the `sz-databricks-app` group WRITE on the secret scope;
- the jobs' principal a Lakebase OAuth role with CREATEDB and CREATEROLE (no superuser), which
  setup logs in with.

A bundle cannot grant on the catalog or name the App in a secret scope's permissions, so the
catalog grants and the group membership are `scripts/admin.sh`'s. The ingest job has no trigger:
the App starts it, so a redeploy changes nothing there.

### Without install.sh

Run the steps by hand. `scripts/admin.sh pre <catalog>` prints `job_run_as=<jobs-sp-application-id>`.
Then deploy twice, since the Volume the jobs' JAR goes to must exist before a deploy can name it:

```sh
vars=(--var catalog=<catalog> --var job_run_as=<jobs-sp-application-id>)
databricks bundle deploy -t prod "${vars[@]}" --var 'artifact_path=${workspace.root_path}/artifacts'
databricks bundle deploy -t prod "${vars[@]}"
```

Then `scripts/admin.sh post <catalog> <app_name>` (default App name `sz-databricks`) and
`databricks bundle run sz_app -t prod`.

Verify: `databricks apps get sz-databricks -o json` shows the App, and its `url` opens the Setup
page.

### Restricted network: copy the payload

With `payload_source=volume:…`, copy the three payload archives into the Volume after step 2 has
created it and before you click **Install** in step 3. From `<download-dir>`:

```sh
dest=dbfs:/Volumes/<catalog>/senzing_internal/files/drop/<release>
databricks fs mkdir "$dest"
for f in sz-databricks-engine-shared-<release>.tar.gz \
         sz-databricks-engine-native-<release>-linux-aarch64.tar.gz \
         sz-databricks-engine-native-<release>-linux-x86_64.tar.gz; do
  databricks fs cp "$f" "$dest/$f"
done
```

## 3. Set up the App

Open the App (`sz-databricks` in your workspace Apps list). You need CAN MANAGE on the App for every step
below; the installer has it.

1. **Senzing EULA.** Read the
   [Senzing End User License Agreement](https://senzing.com/end-user-license-agreement/), then click
   **I accept the EULA**. The page records who accepted and when. No ingest run starts until it is
   accepted.
2. **License.** Paste your Senzing license into **Base64 license text** and click **Store
   license**. The field takes the license as Senzing, Inc. sends it, base64 text; paste it as it is,
   without decoding it (spaces and line breaks in it are ignored). It goes to the secret scope; the page then shows its expiry and record limit. No license yet? Open Ask
   Senzing, the assistant on [docs.senzing.com](https://docs.senzing.com), and ask it for a free
   evaluation license.
3. **Database size and concurrency.** The Lakebase size field starts at 2 vCPU, the bundle's
   `lakebase_vcpu`, for the default 4 compute unit (8 GB) endpoint; it is stored when a run starts, without you
   entering anything. Change it only if you sized Lakebase differently ([Sizing](use.md#sizing)), then click
   **Save**. The page shows the most engine partitions a run
   may use and which bound sets it. An engine partition is one Spark task running one engine
   thread, so this caps the work a run does at once.
4. **Install.** Click **Install**. The setup job stages the payload into the Volume (a no-op once
   this release's payload is there), then creates the `senzing` database and the `sz_engine` role
   in Lakebase, the Senzing schema and default configuration and the App's tables, the entity
   mart's included. The first run takes longer: the cluster starts and the payload downloads.

Verify: the Setup section reads `Status: ok`, and the Lakebase section shows the PostgreSQL version
and `max_connections`. **Check** runs setup's checks again without changing anything.

## No data of your own? Load the CORD sample

CORD (Collections Of Relatable Data) is real historical data published for evaluating entity
resolution, already in Senzing JSON (evaluation only); the
[CORD page](https://senzing.com/senzing-ready-data-collections-cord/) describes the collections.
This file holds one data source, `PPP_LOANS` (3,488 records):

```sh
curl -fsSL 'https://mcp.senzing.com/download/las-vegas?source=ppp_loans&limit=250000' -o ppp_loans.jsonl
```

Put it in a Volume folder that both principals that read sources can read. `<your_schema>` is a
schema of yours in `<catalog>` other than `senzing` and `senzing_internal`, which the App manages:
an existing one, or a new one such as `CREATE SCHEMA <catalog>.sz_landing`. Already have a Volume
there? Use a folder in it and skip `CREATE VOLUME`. The install already granted USE CATALOG on
`<catalog>` to both principals. `<principal>` is each of the App's service principal and the jobs'
one. Once a source is registered, the App's **Grants** page names both and prints these statements;
before that, look them up:


```sh
databricks apps get sz-databricks -o json | jq -r '.service_principal_client_id // empty'
databricks service-principals list -o json --filter 'displayName eq "sz-databricks-jobs"' | jq -r '.[0].applicationId // empty'
```

In SQL:

```sql
CREATE VOLUME IF NOT EXISTS <catalog>.<your_schema>.landing;
GRANT USE SCHEMA ON SCHEMA <catalog>.<your_schema> TO `<principal>`;
GRANT READ VOLUME ON VOLUME <catalog>.<your_schema>.landing TO `<principal>`;
```

```sh
databricks fs mkdir dbfs:/Volumes/<catalog>/<your_schema>/landing/cord
databricks fs cp ppp_loans.jsonl dbfs:/Volumes/<catalog>/<your_schema>/landing/cord/ppp_loans.jsonl
```

Then register the folder `/Volumes/<catalog>/<your_schema>/landing/cord` on the **Sources** page,
with source name `ppp_loans`, data source `PPP_LOANS` and format `jsonl`
([register a source](use.md#register-a-source)). Its first load starts by itself.

Next: [prepare and register a source](use.md#prepare-a-source). If a step fails:
[troubleshooting](troubleshooting.md).

## Reference

### Engine settings

Install turns on the per-entity feature store of the Senzing repository (`RES_ENT.FEATURES`) and
the engine uses advisory entity locks (`ER.ENTITY_LOCK_MODE` `ADVISORY`), to keep Lakebase reads and
lock contention low. Every engine on one Senzing repository must use the same lock mode.

The engine's database connection is TLS with the server certificate verified: the job clusters set
`PGSSLMODE=verify-full` and `PGSSLROOTCERT=/etc/ssl/certs/ca-certificates.crt`, the node's CA
bundle, which holds the Let's Encrypt roots Lakebase's certificate chains to.
