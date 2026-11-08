[sz-databricks](../README.md) / Install and query with an AI assistant

# Install and query with an AI assistant

An AI coding assistant with a shell and a Databricks CLI profile (Claude Code or similar) can run
most of the [path](../README.md#the-path) for you: verify the release, run the install script, put
data in place and query the SENZING® entity resolution results. Some steps stay yours, in the App in
your browser: accepting the Senzing EULA, storing your license, clicking **Install** and registering
a source. The assistant stops and waits for you at each of them; it never accepts the EULA on your
behalf. It also asks for your approval before it creates, grants or changes anything.

The assistant uses the Databricks CLI profile you name, so you do not log in separately.

## Before you start

**Connect the Senzing MCP server.** Add `https://mcp.senzing.com/mcp` (HTTP, no authentication) to
your assistant's MCP servers. It answers Senzing questions (attribute mappings, match keys, error
codes) from the Senzing documentation, so the assistant does not guess. Do not send it personal data
or credentials.

Have ready:

| | |
|---|---|
| The [prerequisites](../README.md#prerequisites) | a workspace admin with MANAGE on the catalog, Databricks CLI 1.23.0 or later with a profile for the workspace, `jq`, `cosign`, a bash or zsh shell |
| The GitHub CLI (optional) | `gh`, logged in (`gh auth status`), to download the release; without it you download the files yourself |
| A release | its number, the tag without its `v`, for example `0.1.0-rc.1`, from this repository's [releases](https://github.com/Senzing/sz-databricks/releases) |
| A directory | an absolute path to a new empty directory for the release files, for example `/home/me/sz-databricks-0.1.0-rc.1` |
| A catalog | the Unity Catalog catalog to install into |
| A group (optional) | the group that will query the results |
| A license | base64; you paste it into the App yourself. No license yet? Open Ask Senzing, the assistant on [docs.senzing.com](https://docs.senzing.com), and ask it for a free evaluation license |
| Your data | tables you want resolved, or none: the assistant can load the [CORD sample](#no-data-of-your-own) instead |

**Cost.** The install creates billable resources in your workspace: the App (it bills all the time
it runs, also between ingest runs), job clusters while a run is active, a SQL warehouse (it stops
after 5 idle minutes) and a Lakebase database (it scales to zero after 30 idle minutes). When you
are done evaluating, remove them as [Uninstall](use.md#uninstall) describes.

The prompts cite these pages by URL, since the release does not contain them:

- install: https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/install.md
- use: https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/use.md
- troubleshooting: https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/troubleshooting.md

## Prompt 1: install

Fill in the placeholders and paste:

> Install sz-databricks release `<release>` (the tag without its `v`, for example `0.1.0-rc.1`) into
> my Databricks workspace, using my Databricks CLI profile `<profile>`, catalog `<catalog>` and the
> new empty directory `<dir>` (an absolute path).
>
> Rules for every step:
>
> - Use bash or zsh. Your shell may not keep variables or functions between commands, so start
>   every shell command with `export DATABRICKS_CONFIG_PROFILE=<profile>` and, once step 8 has
>   written it, `source <dir>/sql.sh`. One shell call may do both and run the command, for example
>   `source <dir>/sql.sh && sql "SHOW TABLES IN <catalog>.senzing"`.
> - A shell call times out after about 2 minutes. Run anything longer in the background as the
>   steps show, and wait with the given check: one shell call with a loop of at most 110 seconds,
>   run again until it reports the end. If `sleep` is refused, run the check without it, once per
>   call. After 10 checks, wait about 5 minutes between checks: run `sleep 110` as its own call
>   twice, then the check.
> - Use the Senzing MCP tools for any Senzing question; do not answer Senzing questions from memory.
> - Only SELECT, SHOW and DESCRIBE statements run without my approval. Never run a GRANT, ALTER,
>   CREATE or DROP statement I have not seen and approved. Never run REVOKE, DELETE, TRUNCATE,
>   INSERT, UPDATE, MERGE, `databricks bundle destroy`, `databricks apps delete` or
>   `databricks fs rm` unless I ask.
> - Never accept the Senzing EULA for me, never open the App's own URL (its web pages or API;
>   `databricks apps get` is allowed) and never ask me to paste a license, password or token into
>   this chat.
> - When a step fails, fetch the troubleshooting page
>   https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/troubleshooting.md, find the
>   error there and show me the error and the fix; act only after I confirm. If the error is not on
>   that page, show it to me and stop: propose no fix. Never retry blindly.
> - If you cannot fetch a page these steps name by URL, ask me to paste its content.
>
> 1. **Check the tools and my rights.** Run `databricks --version`, `jq --version`, `cosign version`
>    and `databricks current-user me -o json | jq -r '.userName, (.groups[]?.display)'`. If the CLI
>    is older than 1.23.0, the version the bundle is validated with, stop and tell me. Ask me to
>    confirm the workspace runs on AWS (the bundle's default node type, `r6g.large`, is an AWS
>    type); if it does not, stop. If the groups do not include `admins`, stop: the install needs a
>    workspace admin. Ask me to confirm that I have MANAGE on `<catalog>` (or own it), and wait for
>    my answer. If any command fails, stop and show me the error.
> 2. **Download.** Create `<dir>` and download every file of the release into it:
>    `gh release download v<release> --repo Senzing/sz-databricks --dir <dir>`. If `gh` is missing
>    or `gh auth status` fails, ask me to download every file of the release from
>    https://github.com/Senzing/sz-databricks/releases into `<dir>` and wait until I say it is done.
>    Verify: `<dir>` holds `SHA256SUMS`, `SHA256SUMS.sigstore.json` and one `.sigstore.json` per
>    file `SHA256SUMS` lists. If `SHA256SUMS.sigstore.json` is missing, the release is still being
>    signed: wait 5 minutes and download again with `--skip-existing` added; stop after 3 tries.
> 3. **Verify.** Run this; it stops at the first file that fails:
>
>    ```sh
>    (
>      cd <dir> || exit 1
>      for f in $(awk '{print $2}' SHA256SUMS) SHA256SUMS; do
>        cosign verify-blob --bundle "$f.sigstore.json" \
>          --certificate-identity "https://github.com/Senzing/sz-databricks/.github/workflows/sign-release.yaml@refs/tags/v<release>" \
>          --certificate-oidc-issuer https://token.actions.githubusercontent.com "$f" \
>          || { echo "FAIL $f"; exit 1; }
>      done
>      if command -v sha256sum >/dev/null; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi
>    )
>    ```
>
>    Every file must print `Verified OK`, then `OK`; the command must exit 0. If it prints
>    `FAIL` or `FAILED` or exits non-zero, stop, show me the output and install nothing.
>
>    On success: unpack the bundle with `cd <dir> && tar -xzf sz-databricks-bundle-<release>.tar.gz`.
> 4. **Ask me, don't assume.** Ask me: (a) which group should read the results, if any; (b) whether
>    the workspace's job clusters can reach `github.com`, `release-assets.githubusercontent.com` and
>    `objects.githubusercontent.com`. Unless I answer yes, treat the network as restricted (that
>    path works on any network): add
>    `--var payload_source=volume:/Volumes/<catalog>/senzing_internal/files/drop/<release>` to the
>    install commands in steps 5 and 6, and do step 7.
> 5. **Dry run.** In `<dir>/bundle` run
>    `scripts/install.sh --target prod --release-dir <dir> --var catalog=<catalog> --var consumer_group=<group> --dry-run`
>    (leave out `--var consumer_group=<group>` if I named no group). Show me the steps it prints,
>    together with what they create and grant:
>    - billable resources: the App `sz-databricks` (it bills all the time it runs, also between
>      ingest runs), the jobs `sz-databricks-setup` and `sz-databricks-ingest` (their clusters bill
>      while a run is active), the SQL warehouse `sz-databricks-warehouse` (2X-Small, stops after 5
>      idle minutes) and the Lakebase project `sz-databricks` (4 compute units, about 8 GB, scales to
>      zero after 30 idle minutes);
>    - the schemas `<catalog>.senzing_internal` and `<catalog>.senzing`, the Volume
>      `<catalog>.senzing_internal.files`, the secret scope `sz_databricks`, the cluster policy
>      `sz-databricks-jobs`, the group `sz-databricks-app` and the service principal
>      `sz-databricks-jobs` with the `workspace-access` entitlement;
>    - USE CATALOG on `<catalog>` to that service principal and to the App's service principal;
>    - the **Service principal: User** role on `sz-databricks-jobs` to me;
>    - the deploy's grants: to the App, USE SCHEMA, SELECT, MODIFY and CREATE TABLE on
>      `senzing_internal`, USE SCHEMA and SELECT on `senzing` and READ VOLUME on the Volume; to
>      `sz-databricks-jobs`, USE SCHEMA, SELECT, MODIFY and CREATE TABLE on both schemas, READ and
>      WRITE VOLUME and READ on the secret scope, plus a Lakebase role with CREATEDB and CREATEROLE;
>      to `sz-databricks-app`, WRITE on the secret scope;
>    - CAN MANAGE on the App to the App's service principal;
>    - with a group: USE CATALOG on `<catalog>` and USE SCHEMA and SELECT on `<catalog>.senzing` to it.
>
>    Ask me to approve the resources, their cost and these grants. My approval covers exactly
>    these; nothing else.
> 6. **Install.** In `<dir>/bundle`, run the same command without `--dry-run` in the background, so
>    that it outlives your shell call and records its exit code:
>
>    ```sh
>    cd <dir>/bundle && nohup bash -c 'scripts/install.sh --target prod --release-dir <dir> --var catalog=<catalog> <the other --var options of step 5>; echo "EXIT $?"' > <dir>/install.log 2>&1 &
>    ```
>
>    Then check it with this, and tell me each new line it shows:
>
>    ```sh
>    for i in 1 2 3 4 5 6 7 8 9 10 11; do grep -q '^EXIT ' <dir>/install.log && break; sleep 10; done
>    grep -E '^(STEP|SKIP|EXIT|install\.sh:|Installed|  GRANT)' <dir>/install.log
>    ```
>
>    Run it again until a line `EXIT <code>` appears. The lines the script prints are listed under
>    "What it prints" in https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/install.md.
>    Success is `Installed (target prod).`, then two GRANT statements (show them to me; don't run
>    them), then `EXIT 0`. Any other code is a failure: show me `tail -n 40 <dir>/install.log`, which
>    ends with `install.sh: step <name> failed; after fixing it, resume with: …`. Find the error in
>    the "Install" table of the troubleshooting page, tell me the fix and run the printed resume
>    command (the same way, with `nohup`) only after I confirm.
> 7. **Restricted network only: stage the payload.** The install created the Volume
>    `<catalog>.senzing_internal.files`. Copy the three payload archives (about 600 MB) into it in the
>    background:
>
>    ```sh
>    cd <dir> && nohup bash -c 'run() {
>      dest=dbfs:/Volumes/<catalog>/senzing_internal/files/drop/<release>
>      databricks fs mkdir "$dest" || return 1
>      for f in sz-databricks-engine-shared-<release>.tar.gz sz-databricks-engine-native-<release>-linux-aarch64.tar.gz sz-databricks-engine-native-<release>-linux-x86_64.tar.gz; do
>        echo "COPY $f"; databricks fs cp --overwrite "$f" "$dest/$f" || return 1
>      done
>    }; run; echo "EXIT $?"' > <dir>/payload.log 2>&1 &
>    ```
>
>    Check it like step 6, with `<dir>/payload.log` and `grep -E '^(COPY|EXIT)'`, until `EXIT <code>`
>    appears. On `EXIT 0`, verify:
>    `databricks fs ls dbfs:/Volumes/<catalog>/senzing_internal/files/drop/<release>` lists all three
>    archives. On any other code, show me `tail -n 20 <dir>/payload.log` and stop.
> 8. **Write the helper.** Write `<dir>/sql.sh` with this content (fill in `<profile>`); it needs
>    bash or zsh. It looks up the App's SQL warehouse (the App resource the bundle's
>    `resources/app.yml` names `sql-warehouse`), the App's service principal and the jobs'
>    service principal, and defines `sql`, which runs one statement on that warehouse and prints the
>    result rows:
>
>    ```sh
>    export DATABRICKS_CONFIG_PROFILE=<profile>
>    WAREHOUSE_ID="$(databricks apps get sz-databricks -o json | jq -r '.resources[]? | select(.name == "sql-warehouse") | .sql_warehouse.id // empty')"
>    APP_SP="$(databricks apps get sz-databricks -o json | jq -r '.service_principal_client_id // empty')"
>    JOB_RUN_AS="$(databricks service-principals list -o json --filter 'displayName eq "sz-databricks-jobs"' | jq -r '.[0].applicationId // empty')"
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
>    Verify: `source <dir>/sql.sh && echo "[$WAREHOUSE_ID] [$APP_SP] [$JOB_RUN_AS]"` prints three
>    non-empty values. If one is empty, stop and tell me which.
> 9. **Hand over the Setup page to me.** Get the App's URL with
>    `databricks apps get sz-databricks -o json | jq -r .url` and give it to me with these steps,
>    written to me as "you":
>    - "Read the Senzing EULA at https://senzing.com/end-user-license-agreement/. If you accept it,
>      click **I accept the EULA** yourself."
>    - "Paste your license into **Base64 license text** and click **Store license**."
>    - "Leave the Lakebase size at its default, 2 vCPU for the bundle's 4 compute units (8 GB); it is
>      stored when a run starts. Change it and click **Save** only if Lakebase was sized differently
>      at install."
>    - "Click **Install** and wait until the Setup section reads `Status: ok`. The first run starts a
>      cluster and stages the engine payload."
>
>    Then **stop and wait**. `Status: ok` alone does not show that the EULA is accepted and the
>    license stored, so ask me to confirm all three: the EULA accepted, the license stored (the page
>    shows its expiry) and `Status: ok`. If I report an error instead, find it in the "Setup" table
>    of the troubleshooting page and tell me the fix.
> 10. **Check it yourself.** Run `source <dir>/sql.sh && sql "SHOW TABLES IN <catalog>.senzing"`: it
>     must list `entity`, `entity_record` and `relationship`. If it fails, show me the error. Tell me
>     in one line that the install is done, and in one more that the App bills while it runs and
>     https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/use.md (section "Uninstall")
>     removes everything when I am done.
>
> Every step can be run again.

Never paste a license, password or token into the prompt: you store the license in the App
yourself.

## Prompt 2: load data and query the results

When the install is done, paste one of the two data blocks below, then the query block. Each block
works in a new assistant session: it needs only `<dir>/sql.sh` from Prompt 1. Fill in the same
`<dir>` and `<catalog>` as in Prompt 1.

### No data of your own

> Load the CORD sample into my workspace, catalog `<catalog>`. CORD is real historical data
> published for evaluating entity resolution, already in Senzing JSON.
>
> Rules:
>
> - Use bash or zsh and start every shell command with `source <dir>/sql.sh`, which sets my
>   Databricks CLI profile and defines `sql`, `APP_SP` and `JOB_RUN_AS`; one call may source it and
>   run the command (`source <dir>/sql.sh && sql "…"`).
> - Pass a GRANT to `sql` in single quotes with the principal's id written out, for example
>   ``sql 'GRANT USE SCHEMA ON SCHEMA <catalog>.<your_schema> TO `<the id>`'``: inside double quotes
>   the shell runs the backticks as a command. Pass other statements in double quotes.
> - Only SELECT, SHOW and DESCRIBE statements run without my approval. Never run a GRANT, ALTER,
>   CREATE or DROP statement I have not seen and approved. Never run REVOKE, DELETE, TRUNCATE,
>   INSERT, UPDATE, MERGE, `databricks bundle destroy`, `databricks apps delete` or
>   `databricks fs rm` unless I ask.
> - Never open the App's own URL (its web pages or API; `databricks apps get` is allowed).
> - When a step fails, show me the error, find it in
>   https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/troubleshooting.md and tell me
>   the fix; act only after I confirm. If the error is not on that page, show it to me and stop:
>   propose no fix. If you cannot fetch that page, ask me to paste its content.
>
> 1. Download it: `cd <dir> && curl -fsSL 'https://mcp.senzing.com/download/las-vegas?source=ppp_loans&limit=250000' -o ppp_loans.jsonl`.
>    Verify: `wc -l < <dir>/ppp_loans.jsonl` prints 3488.
> 2. Ask me for a schema `<your_schema>` in `<catalog>` to hold a landing Volume; it must not be
>    `senzing` or `senzing_internal`. Verify it exists with
>    `databricks schemas get <catalog>.<your_schema>`. If it does not exist or I cannot use it, ask
>    me for another, or offer to run `CREATE SCHEMA <catalog>.<your_schema>` with `sql` after I
>    approve. The install already granted USE CATALOG on `<catalog>` to both service principals, so
>    only these are needed. Print `$APP_SP` and `$JOB_RUN_AS`, show me these statements with the
>    names and both ids filled in (one GRANT pair per id) and run each with `sql` after I approve:
>    `CREATE VOLUME IF NOT EXISTS <catalog>.<your_schema>.landing`,
>    ``GRANT USE SCHEMA ON SCHEMA <catalog>.<your_schema> TO `<id>` ``,
>    ``GRANT READ VOLUME ON VOLUME <catalog>.<your_schema>.landing TO `<id>` ``.
> 3. Upload:
>
>    ```sh
>    databricks fs mkdir dbfs:/Volumes/<catalog>/<your_schema>/landing/cord
>    databricks fs cp <dir>/ppp_loans.jsonl dbfs:/Volumes/<catalog>/<your_schema>/landing/cord/ppp_loans.jsonl
>    ```
>
>    Verify: `databricks fs ls dbfs:/Volumes/<catalog>/<your_schema>/landing/cord` lists it.
> 4. **Hand over the Sources page to me** and stop. Tell me, as "you": "On **Sources**, under
>    **Register a source**, fill in the **Add source** box with `/Volumes/<catalog>/<your_schema>/landing/cord`,
>    source name `ppp_loans`, Senzing data source code `PPP_LOANS` and format `jsonl`, then click
>    **Register**. Refresh the page until the source shows *enabled* and no longer *checking*, and
>    tell me." If I report an error or *registration failed: …*, find it in the "Sources and
>    results" table of the troubleshooting page and tell me the fix.
>
> When the source shows *enabled*, tell me the values for the query block: `<DATA_SOURCE>` is
> `PPP_LOANS`, `<expected_count>` is 3488 and `<your_schema>` is the schema I gave.

### Your own tables

> Prepare my tables in catalog `<catalog>` as one sz-databricks source with data source code
> `<CODE>`.
>
> Rules:
>
> - Use bash or zsh and start every shell command with `source <dir>/sql.sh`, which sets my
>   Databricks CLI profile and defines `sql`, `APP_SP` and `JOB_RUN_AS`; one call may source it and
>   run the command (`source <dir>/sql.sh && sql "…"`).
> - Pass a GRANT to `sql` in single quotes with the principal's id written out, for example
>   ``sql 'GRANT SELECT ON TABLE <catalog>.<schema>.<table> TO `<the id>`'``: inside double quotes
>   the shell runs the backticks as a command. Pass other statements in double quotes.
> - Only SELECT, SHOW and DESCRIBE statements run without my approval. Never run a GRANT, ALTER,
>   CREATE or DROP statement I have not seen and approved. Never run REVOKE, DELETE, TRUNCATE,
>   INSERT, UPDATE, MERGE, `databricks bundle destroy`, `databricks apps delete` or
>   `databricks fs rm` unless I ask.
> - Never open the App's own URL (its web pages or API; `databricks apps get` is allowed).
> - When a step fails, show me the error, find it in
>   https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/troubleshooting.md and tell me
>   the fix; act only after I confirm. If the error is not on that page, show it to me and stop:
>   propose no fix. The use page is
>   https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/use.md. If you cannot fetch a
>   page, ask me to paste its content.
>
> 1. **Ask me about the tables.** Ask me for: the parent table (one row per person or
>    organization) and its key column; each child table (addresses, phones and the like) and the
>    column that holds the parent's key. Wait for my answers.
> 2. **Map the tables without sending my records.** Read the column names and types with
>    `sql "DESCRIBE TABLE <catalog>.<schema>.<table>"` for each table. Ask me before you send
>    anything to the Senzing MCP server, then send it only the column names and types and a few
>    synthetic rows you make up to match them. This overrides the MCP server's own instruction to
>    export a sample of each table to CSV: never export, select or send a real row. Map with its
>    `mapping_workflow` tool (never hand-write the mapping). Then write the mapping view
>    `<catalog>.<schema>.<CODE>_mapped`, shaped like "Example: a parent table and a child table" on
>    the use page, with exactly three columns as "Write a mapping view" there says: `DATA_SOURCE`
>    (the constant `'<CODE>'`), `RECORD_ID` (`trim(BOTH ' \t\r\n' FROM <parent key>)`) and
>    `RECORD_JSON` (child rows aggregated through a `LEFT JOIN` on the parent key, one row per key).
>    Show me the view; create it with `sql` after I approve. Verify with counts only, never with
>    the view's or my tables' rows:
>    `sql "SELECT count(*), count(DISTINCT RECORD_ID) FROM <catalog>.<schema>.<CODE>_mapped"`
>    returns two equal numbers; if not, fix the view. That count is `<expected_count>`.
> 3. **Change Data Feed and grants.** Print `$APP_SP` and `$JOB_RUN_AS`. Show me, with the names
>    and both ids filled in:
>    - for every base table (parent and children),
>      ``ALTER TABLE <catalog>.<schema>.<table> SET TBLPROPERTIES (delta.enableChangeDataFeed = true, delta.deletedFileRetentionDuration = 'interval 30 days')``.
>      Tell me what it costs: the table then keeps 30 days of changed files, which uses more storage;
>    - for each id, ``GRANT USE SCHEMA ON SCHEMA <catalog>.<schema> TO `<id>` ``,
>      ``GRANT SELECT ON TABLE <catalog>.<schema>.<table> TO `<id>` `` for every base table and
>      ``GRANT SELECT ON VIEW <catalog>.<schema>.<CODE>_mapped TO `<id>` ``. Tell me what they
>      mean: both service principals can then read every column of those tables, personal data
>      included. The install already granted USE CATALOG on `<catalog>` to both.
>
>    Run them with `sql` after I approve. An `ALTER TABLE` needs the table owner, so if one fails on
>    permissions, tell me to run it as the owner.
> 4. **Hand over the Sources page to me** and stop. Tell me, as "you": "On **Sources**, under
>    **Register a source**, fill in the **Add source** box with `<catalog>.<schema>.<CODE>_mapped`,
>    source name `<code in lower case>`, Senzing data source code `<CODE>` and the base tables, one
>    per line: the parent as `<catalog>.<schema>.<parent> <parent key column>` and each child as
>    `<catalog>.<schema>.<child> <column holding the parent's key>`. Click **Register**, refresh
>    until the source shows *enabled* and no longer *checking*, and tell me." If I report an error,
>    find it in the "Sources and results" table of the troubleshooting page and tell me the fix.
>
> When the source shows *enabled*, tell me the values for the query block: `<DATA_SOURCE>` is
> `<CODE>`, `<expected_count>` is the count from step 2 and `<your_view>` is the mapping view.

### Query block

Paste this after the source shows *enabled*, with these filled in:

- `<dir>` and `<catalog>` are the same as in Prompt 1.
- `<DATA_SOURCE>` is the data source code the data block's last message gave.
- `<expected_count>` is the record count that message gave.
- `<your_view>` is your mapping view; only your own tables have one.
- `<your_schema>` is the schema of the landing Volume; only the CORD sample has one.

> The source with data source code `<DATA_SOURCE>` in catalog `<catalog>` shows *enabled*, so its
> first load has started; it holds `<expected_count>` records. Use bash or zsh and start every shell
> command with `source <dir>/sql.sh`. Never open the App's own URL (its web pages or API).
> Read only: run only SELECT, SHOW and DESCRIBE; create, grant and change nothing. A shell call
> times out after about 2 minutes. If you cannot fetch a page named by URL, ask me to paste it.
>
> 1. **Wait for the load.** Check with this one call (three readings, 30 seconds apart) and tell me
>    the last reading's two numbers in one line:
>
>    ```sh
>    source <dir>/sql.sh && for i in 1 2 3; do sql "SELECT
>      (SELECT count(*) FROM <catalog>.senzing.entity_record WHERE data_source = '<DATA_SOURCE>') AS resolved,
>      (SELECT count(DISTINCT q.record_id) FROM <catalog>.senzing_internal._ingest_quarantine q
>        WHERE q.data_source = '<DATA_SOURCE>' AND NOT EXISTS (SELECT 1 FROM <catalog>.senzing.entity_record r
>          WHERE r.data_source = q.data_source AND r.record_id = q.record_id)) AS rejected"; [ $i = 3 ] || sleep 30; done
>    ```
>
>    Run it again until `resolved + rejected` equals `<expected_count>`. If `sleep` is refused, run
>    the query once per call. After 10 checks, wait about 5 minutes between checks: run `sleep 110`
>    as its own call twice, then the check. If neither number has changed for 15 minutes, stop and
>    ask me what the **Status** page shows for the ingest job; find any error in
>    https://raw.githubusercontent.com/Senzing/sz-databricks/main/docs/troubleshooting.md, and if it
>    is not there, show it to me and stop. If `rejected` is above 0, show me
>    `SELECT error_code, message, count(*) FROM <catalog>.senzing_internal._ingest_quarantine WHERE data_source = '<DATA_SOURCE>' GROUP BY 1, 2`
>    (the use page's "Who can read the results" lists that table's columns).
> 2. **Report on my data, not on the install,** as a short Markdown summary. Every figure is for
>    `<DATA_SOURCE>` only:
>    - source records and entities:
>      `SELECT count(*), count(DISTINCT entity_id) FROM <catalog>.senzing.entity_record WHERE data_source = '<DATA_SOURCE>'`;
>      records merged into another record's entity are records minus entities;
>    - the 10 largest entities:
>      `SELECT entity_id, count(*) AS records FROM <catalog>.senzing.entity_record WHERE data_source = '<DATA_SOURCE>' GROUP BY entity_id ORDER BY records DESC LIMIT 10`;
>    - `POSSIBLY_SAME` relationships between its entities:
>      `SELECT count(*) FROM <catalog>.senzing.relationship rel WHERE rel.match_level_code = 'POSSIBLY_SAME' AND EXISTS (SELECT 1 FROM <catalog>.senzing.entity_record r WHERE r.data_source = '<DATA_SOURCE>' AND r.entity_id IN (rel.entity_id_lo, rel.entity_id_hi))`;
>    - for the 3 largest entities, the match keys that joined their records:
>      `SELECT entity_id, match_key, count(*) FROM <catalog>.senzing.entity_record WHERE data_source = '<DATA_SOURCE>' AND entity_id IN (<the 3 entity ids>) GROUP BY 1, 2 ORDER BY 1, 2`.
>
>    Show record keys (`record_id`) only if I ask, except for the CORD sample (`PPP_LOANS`). Do not
>    show names, addresses or other contents of my records unless I ask. If I ask, read them from
>    the mapping view (`SELECT RECORD_ID, RECORD_JSON FROM <your_view> WHERE RECORD_ID IN (…)`), or
>    for the CORD sample from the uploaded file:
>
>    ```sh
>    source <dir>/sql.sh && sql "SELECT r.entity_id, r.match_key, f.value AS record
>      FROM <catalog>.senzing.entity_record r
>      JOIN read_files('/Volumes/<catalog>/<your_schema>/landing/cord', format => 'text') f
>        ON r.record_id = trim(BOTH ' \t\r\n' FROM get_json_object(f.value, '\$.RECORD_ID'))
>      WHERE r.data_source = 'PPP_LOANS' AND r.entity_id IN (<the 3 entity ids>)
>      ORDER BY r.entity_id"
>    ```

| Known issue | Fix |
|---|---|
| The first `sql` call takes a minute | the SQL warehouse is starting after its 5 idle minutes; later calls are fast |
| The count stays 0 for several minutes after the source shows *enabled* | the first load starts a job cluster; the query block waits 15 minutes without change before it asks you what **Status** shows |
| The assistant stops checking | say "run the check again and tell me the numbers" |
| A shell call times out | each wait is one call of at most about 110 seconds; say "run the check again" |
| A new assistant session has no `sql` | it sources `<dir>/sql.sh`; if that file is missing, run step 8 of Prompt 1 again |
