[sz-databricks](../README.md) / Install and report with an AI assistant

# Install and report with an AI assistant

An AI coding assistant with a shell and a Databricks CLI profile (Claude Code or similar) can run
the whole [path](../README.md#the-path) for you from the command line: verify the release, install,
register your sources, watch them resolve and build a report on the results. Nothing happens in a
browser. You watch and answer its questions; it asks for your approval before it creates, grants or
changes anything, and it never accepts the Senzing End User License Agreement (EULA) on your behalf.

The assistant uses the Databricks CLI profile you name, so you do not log in separately.

## Before you start

**Connect the SENZING® Model Context Protocol (MCP) server.** Add `https://mcp.senzing.com/mcp`
(HTTP, no authentication) to your assistant's MCP servers. It answers Senzing questions (attribute
mappings, match keys, match levels, error codes) from the Senzing documentation, so the assistant
does not guess. Do not send it personal data or credentials.

Have ready:

| | |
|---|---|
| The [prerequisites](../README.md#prerequisites) | a workspace admin with MANAGE on the catalog, Databricks CLI 1.23.0 or later with a profile for the workspace, `jq`, `cosign`, `openssl`, a bash or zsh shell |
| The GitHub CLI (optional) | `gh`, logged in (`gh auth status`), to download the release; without it you download the files yourself |
| A release | its tag, for example `4.4.3-1`, from this repository's [releases](https://github.com/Senzing/sz-databricks/releases) |
| A directory | an absolute path to a new empty directory for the release files, for example `/home/me/sz-databricks-4.4.3-1` |
| A catalog | the Unity Catalog catalog to install into |
| Your sources | per data source: a code (`CUSTOMERS`), its base tables with Change Data Feed on and a mapping view (`DATA_SOURCE`, `RECORD_ID`, `RECORD_JSON` = the Senzing JSON), or the tables alone: the assistant maps them with you |
| No data of your own? | the assistant can load and map the [Collections Of Relatable Data (CORD)](#no-data-of-your-own) instead |
| A license (optional) | a base64 file; without one the engine runs in evaluation mode and takes 500 records. No license yet? Open Ask Senzing, the assistant on [docs.senzing.com](https://docs.senzing.com), and ask it for a free evaluation license |

The prompts cite these pages by URL, since the release does not contain them:

- install: https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/install.md
- use: https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/use.md
- troubleshooting: https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/troubleshooting.md

## Prompt 1: install and resolve

Fill in the placeholders and paste:

> Install sz-databricks release `<release>` (the release tag, for example `4.4.3-1`) into my
> Databricks workspace, using my Databricks CLI profile `<profile>`, catalog `<catalog>` and the new
> empty directory `<dir>` (an absolute path).
>
> Rules for every step:
>
> - Use bash or zsh. Your shell may not keep variables between commands, so start every shell
>   command with `export DATABRICKS_CONFIG_PROFILE=<profile>`.
> - A shell call times out after about 2 minutes. Run anything longer in the background with
>   `nohup` as the steps show, and check it with one shell call that loops at most 110 seconds,
>   checking every 15 seconds; run it again until it reports the end. Tell me each new line in one
>   line of your own, at least every 15 seconds while something runs.
> - Use the Senzing MCP tools for any Senzing question; do not answer Senzing questions from memory.
> - Only SELECT, SHOW and DESCRIBE statements and read-only CLI calls (`get`, `list`, `sz.sh status`)
>   run without my approval. Never run a GRANT, ALTER, CREATE or DROP statement, or a command that
>   changes my workspace, that I have not seen and approved. Never run REVOKE, DELETE, TRUNCATE,
>   INSERT, UPDATE, MERGE, `databricks bundle destroy`, `databricks fs rm` or `sz.sh uninstall`
>   unless I ask.
> - Never accept the Senzing EULA for me, and never ask me to paste a license, password or token into
>   this chat.
> - When a step fails, fetch the troubleshooting page
>   https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/troubleshooting.md, find the
>   code or message there and show me the error and the fix; act only after I confirm. If it is not
>   on that page, show it to me and stop: propose no fix. Never retry blindly.
> - If you cannot fetch a page these steps name by URL, ask me to paste its content.
>
> 1. **Check the tools and my rights.** Run `databricks --version`, `jq --version`, `cosign version`,
>    `openssl version` and `databricks current-user me -o json | jq -r '.userName, (.groups[]?.display)'`.
>    If the CLI is older than 1.23.0, stop and tell me. If the groups do not include `admins`, stop:
>    the install needs a workspace admin. Ask me to confirm the workspace runs on AWS and that I have
>    MANAGE on `<catalog>` (or own it), and wait for my answer.
> 2. **Download.** Create `<dir>` and download the release's install script, bundle and signature:
>    `gh release download <release> --repo Senzing/sz-databricks --dir <dir> --pattern 'sz-databricks-install-*' --pattern 'sz-databricks-bundle-*' --pattern 'SHA256SUMS*'`.
>    If `gh` is missing or `gh auth status` fails, ask me to download those files from
>    https://github.com/Senzing/sz-databricks/releases into `<dir>` and wait until I say it is done.
>    If `SHA256SUMS.sigstore.json` is missing, the release is still being signed: wait 5 minutes and
>    download again with `--skip-existing` added; stop after 3 tries.
> 3. **Verify.** Run this; it stops when the signature or a file fails:
>
>    ```sh
>    (
>      cd <dir> || exit 1
>      cosign verify-blob --bundle SHA256SUMS.sigstore.json \
>        --certificate-identity "https://github.com/Senzing/sz-databricks/.github/workflows/sign-release.yaml@refs/tags/<release>" \
>        --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS \
>        || { echo "FAIL SHA256SUMS"; exit 1; }
>      if command -v sha256sum >/dev/null; then sha256sum --ignore-missing -c SHA256SUMS; else shasum -a 256 --ignore-missing -c SHA256SUMS; fi
>    )
>    ```
>
>    `cosign` must print `Verified OK`, then every downloaded file `OK`; the command must exit 0. If
>    it prints `FAIL` or `FAILED` or exits non-zero, stop, show me the output and install nothing.
>    Then show me the install script's header (`sed -n 1,80p <dir>/sz-databricks-install-<release>.sh`)
>    in a few lines: what it does and what it creates.
> 4. **Ask me, don't assume.** Ask me, and wait for every answer:
>    a. which data sources to resolve: for each, its code and its mapping view and base tables, or
>       only its tables (then map them with me as "Map a source" below), or no data of my own (then
>       follow the "No data of your own" instructions below, before step 6);
>    b. a group that should operate the install (`--operator-group`) and a group that should read the
>       results (`--consumer-group`), if any;
>    c. an email address for the health alert and failed runs (`--alert-email`), if any;
>    d. whether the workspace's job clusters can reach `github.com`,
>       `release-assets.githubusercontent.com` and `objects.githubusercontent.com`. Unless I answer
>       yes, treat the network as restricted: add
>       `--set payload_source=volume:/Volumes/<catalog>/senzing_internal/files/drop/<release>` to the
>       install commands and do step 8;
>    e. the path of my license file, if I have one (you pass the path; never read or print the file).
>
>    **Map a source** (tables without a mapping view): ask me for the parent table (one row per
>    person or organization) and its key column, and each child table (addresses, phones and the
>    like) with the column holding the parent's key. Ask me first, then export a sample of each table
>    to a CSV file on this machine (never paste rows into the chat) through the Statement Execution
>    API on a SQL warehouse I name from `databricks warehouses list`. Run ONE Senzing MCP
>    `mapping_workflow` over those files together (never hand-write the mapping): its profiler and
>    mapper run here, and the server receives the column names and the mapping, never the rows. Write
>    the view `<catalog>.<schema>.<code>_mapped` as the use page's "Write a mapping view" says, with
>    exactly `DATA_SOURCE`, `RECORD_ID` (`trim(BOTH ' \t\r\n' FROM <key>)`) and `RECORD_JSON` (child
>    rows aggregated through a `LEFT JOIN`, one row per key). Show me the view and every
>    `ALTER TABLE … SET TBLPROPERTIES (delta.enableChangeDataFeed = true, delta.deletedFileRetentionDuration = 'interval 30 days')`
>    it needs (the table then keeps 30 days of changed files, which uses more storage; an
>    `ALTER TABLE` needs the table owner); run them after I approve. Verify with counts only:
>    `SELECT count(*), count(DISTINCT RECORD_ID) FROM <view>` returns two equal numbers.
> 5. **The EULA.** Give me https://senzing.com/end-user-license-agreement/ to read and ask whether I
>    accept it. Add `--accept-eula` to the commands below only if I say yes; if I do not, stop.
> 6. **Dry run.** In `<dir>` run, as one command on its own with `; echo "EXIT $?"` added:
>
>    ```sh
>    cd <dir> && chmod +x sz-databricks-install-<release>.sh && ./sz-databricks-install-<release>.sh <release> \
>      --catalog <catalog> --dir <dir>/bundle [--accept-eula] [--license-file <path>] \
>      [--source <CODE>=<view>:<table>[=<column>][,<table>[=<column>]...][:<record id column>] ...] \
>      [--operator-group <group>] [--consumer-group <group>] [--alert-email <address>] [--set ...] --dry-run
>    ```
>
>    with one `--source` per data source, listing every base table the view reads that holds the
>    record id (a child table with `=<its foreign key>`). If the last line is not `EXIT 0`, or the
>    line before it is not `done: dry run of release <release> in catalog <catalog> (target prod); nothing was changed.`,
>    show me every `problem=<CODE>: …` line with its fix from the troubleshooting page, and stop.
>    Otherwise show me, from its output:
>    - the billable resources: the jobs `sz-databricks-setup` and `sz-databricks-ingest` (their
>      clusters bill only while a run lasts), the serverless jobs `sz-databricks-watch` (every 5
>      minutes) and `sz-databricks-ops` (each operation), the SQL warehouse `sz-databricks-warehouse`
>      (2X-Small, stops after 5 idle minutes) and the Lakebase project `sz-databricks` (4 compute
>      units, about 8 GB, scales to zero after 30 idle minutes);
>    - what it creates: the schemas `<catalog>.senzing_internal` and `<catalog>.senzing`, the Volume
>      `<catalog>.senzing_internal.files`, the secret scope, the cluster policy, the dashboard, the
>      alert, the notebook and the service principal `sz-databricks-jobs`;
>    - every grant it prints (the "What the install grants" section of the install page lists them).
>
>    Ask me to approve the resources, their cost and these grants. My approval covers exactly these;
>    nothing else.
> 7. **Install.** Run the same command without `--dry-run` in the background:
>
>    ```sh
>    cd <dir> && nohup bash -c './sz-databricks-install-<release>.sh <release> <the same options, without --dry-run>; echo "EXIT $?"' > <dir>/install.log 2>&1 &
>    ```
>
>    Then check it with this, and tell me each new line:
>
>    ```sh
>    for i in 1 2 3 4 5 6 7; do grep -q '^EXIT ' <dir>/install.log && break; sleep 15; done
>    grep -E '^(==>|done:|EXIT|sz-databricks-install|install)|^ *(problem=|[0-9]{2}:[0-9]{2}:[0-9]{2} resolve_state|resolve wait:)' <dir>/install.log | tail -n 20
>    ```
>
>    Run it again until a line `EXIT <code>` appears. Setup (step P9) takes 5 to 15 minutes; resolving
>    the sources (P10) depends on their size. Success is the `done: sz-databricks <release> installed …`
>    line, then `EXIT 0`. Otherwise show me `tail -n 40 <dir>/install.log` and the fix from the
>    troubleshooting page. When a registration stops with `SOURCE_NO_ACCESS` or `SOURCE_CDF_OFF` (the
>    jobs' principal is new, so it cannot yet read my tables), show me the statements it printed with
>    the names filled in, say what they mean (the jobs' principal can then read every column of those
>    tables, personal data included), run them after I approve (an `ALTER TABLE` needs the table
>    owner) and run the same install command again: every step skips what exists.
> 8. **Restricted network only.** The first run stops at setup, naming a missing archive. Download
>    the three engine archives (`--pattern 'sz-databricks-engine-*'`), verify them as in step 3, copy
>    them as the install page's "Restricted network" section shows, then run the same install
>    command again.
> 9. **Check it.** Run `<dir>/bundle/scripts/sz.sh status`: it must print `"overall": "OK"`. If it
>    lists codes, show me each with its `fix`. Show me the counts:
>    `<dir>/bundle/scripts/sz.sh status | jq '{resolve_state, entity_count, source_count}'`.
>    Tell me in one line each: the install is done; the jobs' clusters bill only during a run and the
>    watcher starts one when my tables change; `sz.sh` operates it (the use page); `sz.sh uninstall`
>    removes it.
> 10. **Budget alerts.** Tell me to set two budgets with email alerts, and give me both links: a
>     Databricks budget, set by an account admin, for the DBU spend
>     (https://docs.databricks.com/aws/en/admin/account-settings/budgets), and an AWS budget for the
>     job clusters' EC2 instances and EBS volumes
>     (https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html). Do
>     not create them yourself: they need account-level access and alert addresses only I can choose.
>
> Every step can be run again.

Never paste a license, password or token into the prompt: give the assistant the license file's
path, and the install script stores it without printing it.

### No data of your own

Use the CORD data for Senzing on Databricks: the official Senzing
[CORD](https://senzing.com/senzing-ready-data-collections-cord/) data, from its Las Vegas collection,
reshaped into normalized source tables for six source systems. Add this to Prompt 1 and leave the
`--source` values to the assistant:

> I have no data of my own; use the CORD data, before the dry run.
>
> 1. Download `sz-databricks-cord-data.tar.gz` from the same release
>    (`--pattern 'sz-databricks-cord-data.tar.gz'`) and verify it exactly like the other files
>    (step 3). Stop if a check fails. Extract it in `<dir>` (`tar -xzf`) and show me its `README.md`
>    and `load.sql` in a few lines.
> 2. `load.sql` uses the catalog `sz_cord_data`, which must exist: check with
>    `databricks catalogs get sz_cord_data`. If it does not exist, ask me whether to create it or to
>    use another catalog (then replace `sz_cord_data` throughout the file).
> 3. Ask me for a SQL warehouse from `databricks warehouses list`. Write `<dir>/sql.sh`, which runs
>    one statement through the Statement Execution API and prints its rows:
>
>    ```sh
>    export DATABRICKS_CONFIG_PROFILE=<profile>
>    WAREHOUSE_ID=<warehouse id>
>    sql() {
>      local body r id st
>      body="$(jq -n --arg s "$1" --arg w "$WAREHOUSE_ID" '{statement: $s, warehouse_id: $w, wait_timeout: "50s", on_wait_timeout: "CONTINUE"}')"
>      r="$(databricks api post /api/2.0/sql/statements --json "$body")"; id="$(jq -r .statement_id <<<"$r")"
>      while st="$(jq -r .status.state <<<"$r")"; [ "$st" = PENDING ] || [ "$st" = RUNNING ]; do
>        sleep 3; r="$(databricks api get "/api/2.0/sql/statements/$id")"
>      done
>      [ "$st" = SUCCEEDED ] || { jq -r '.status.error.message // .status' <<<"$r" >&2; return 1; }
>      jq -c '.result.data_array[]?' <<<"$r"
>    }
>    ```
>
>    Each statement in `load.sql` ends with `;` at the end of a line. After I approve, run part 1
>    one statement at a time with `source <dir>/sql.sh && sql "<statement>"`, upload each source
>    directory as the install page's CORD section shows, then run part 2. Its last statements compare
>    every table's loaded and expected row counts: they must be equal.
> 4. Map each of the six source systems as "Map a source" says (its tables are already in Databricks
>    with Change Data Feed on): one mapping view per source system in its schema, showing me each view
>    before you create it. Then pass one `--source` per source system to the install script, listing
>    every table its view reads that holds the record id.
>    When a view only looks up a table that holds no record id (a contacts view reading each
>    contact's account from `crm.accounts`), add one `--source-via` for that table as the install
>    page's "Sources at install" shows.

## Prompt 2: a report on your data

When `sz.sh status` reads `"overall": "OK"`, paste:

> Build a Streamlit app that runs locally on this machine and reports on my source data joined with
> the Senzing results. This is a report on the data, not on the install. Use a Python 3.12 virtual
> environment with `streamlit`, `databricks-sql-connector` and `databricks-sdk`, start it with
> `streamlit run`, open http://localhost:8501 and confirm every section renders with no errors in
> the terminal. Read only: run only SELECT statements; create, grant and change nothing.
>
> Connect with my Databricks CLI profile `<profile>` on the SQL warehouse `sz-databricks-warehouse`
> (its id from `databricks warehouses list`):
>
> ```python
> from databricks import sql
> from databricks.sdk.core import Config
> cfg = Config(profile="<profile>")
> conn = sql.connect(server_hostname=cfg.host.removeprefix("https://"),
>                    http_path=f"/sql/1.0/warehouses/{warehouse_id}",
>                    credentials_provider=lambda: cfg.authenticate)
> ```
>
> Results, schema `<catalog>.senzing`: `entity_record` (data_source, record_id, entity_id,
> match_key, null when the engine reports none), `entity` (entity_id, record_count),
> `relationship` (entity_id_lo, entity_id_hi, match_level_code, match_key). For readable fields join
> each record to its source's mapping view on `DATA_SOURCE` and `RECORD_ID` and read the features
> with `explode(from_json(RECORD_JSON, 'struct<FEATURES: array<map<string,string>>>').FEATURES)`;
> join name parts with `concat_ws(' ', …)`, which skips NULLs. Show readable fields such as name,
> date of birth, address, phone and email. Bind user input as named parameters (`:name` with a
> dict); never build SQL from it.
>
> Sections:
>
> 1. Metrics: source records, entities, percentage of duplicates removed, entities that span more
>    than one data source, relationships.
> 2. Bar chart: entities by data source combination (for example "CUSTOMERS + WATCHLIST").
> 3. Bar chart: records per entity.
> 4. Bar chart: why records matched (count by non-null `match_key`, top 12).
> 5. Bar chart: relationships by `match_level_code`.
> 6. Table: entities that hold records from both `<CODE A>` and `<CODE B>`, with every record's
>    readable fields and `match_key`.
> 7. Entity explorer: search a name, pick an entity, show its records and why each matched, then the
>    related (not merged) entities' records with `match_level_code` and `match_key`.

The report creates nothing in Databricks; stop the local process to remove it. The demo notebook
`sz_quickstart` and the `sz-databricks status` dashboard show the same results inside the workspace
([use](use.md#use-the-results)).

| Known issue | Fix |
|---|---|
| The first query takes a minute | the SQL warehouse is starting after its 5 idle minutes; later queries are fast |
| `databricks-sql-connector` will not install | it has no build for the newest Python; use Python 3.12 |
| Streamlit warns about `use_container_width` | use `width="stretch"` |
| The assistant polls slowly or stops checking | say "check every 15 seconds"; setup alone can take 15 minutes |
| A shell call times out | each wait is one call of at most about 110 seconds; say "run the check again" |
