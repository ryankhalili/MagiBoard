# Optional Databricks data charts

Status: **experimental, disconnected, and disabled by default**. `databricks_adapter.py` contains original query preparation and result validation code with offline tests. It is not imported by `server.py`, has no HTTP endpoint or canvas UI, and includes no credentials or authenticated network transport. Nothing is provisioned or queried by installing, importing, or starting MagiBoard.

## Recommended first use

Add a Data Chart object showing measurements from a user-selected Databricks dataset. For example, a physics tutor could plot pendulum length against measured period, annotate the points with Apple Pencil, and change the x-range in the inspector. Databricks supplies the measured data; MagiBoard supplies the interactive canvas and annotations. This is a proposed product integration, not a feature already available in the app.

The first version should use a small, reviewed table or prepared view with two numeric columns. A named dataset ID maps to that configuration. The model may select the ID and numeric filters; it cannot submit arbitrary SQL, table names, or functions. Returned values should become a visible chart snapshot with source, filter range, and truncation information. Refresh should be an explicit user action. Sending dataset values to an AI provider should be a separate, visible action rather than an automatic part of fetching data.

## Setup needed before connecting it

1. Identify the workspace URL, an existing SQL warehouse, and an existing table or prepared view. Choose the numeric x/y columns and verify access. Keep real workspace details in ignored local configuration.
2. Use Databricks' supported OAuth user-to-machine login on the Mac. With its CLI installed, `databricks auth login --host <workspace-url>` opens the user's browser. A browser tab being signed in does not itself authenticate this adapter; do not copy browser cookies or tokens into notebook files. Databricks recommends OAuth and supports automated refresh through unified authentication. [Official OAuth guide](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m)
3. Review the dataset and compute choice before enabling live requests. Running a SQL query against a stopped warehouse can start it automatically. The adapter rejects a warehouse that is not currently RUNNING, but that precheck cannot lock its state or guarantee that a subsequent query incurs no compute usage. No warehouse start/create endpoint exists in this adapter. [Warehouse behavior](https://docs.databricks.com/aws/en/compute/sql-warehouse)
4. Implement a host-owned authenticated transport for one configured HTTPS workspace origin, using the selected official auth profile. Enforce request timeouts and a bounded response body; refuse redirects to other origins. Keep credentials out of iPad objects, generated HTML, logs, and the repository.
5. Review the server endpoint and native chart UI before wiring this adapter. Preserve the companion's bearer authentication and return normalized data rather than raw Databricks responses.

The official Databricks CLI was installed separately on the development Mac, with its release checksum verified, and a local OAuth sign-in was initiated. That CLI and its account configuration are external development setup; they are not bundled in this repository or iPad app. The adapter has not been connected to an authenticated transport or live-tested. No warehouse, dataset, or other Databricks resource has been created or started by this work.

## Adapter contract

`DatabricksChartAdapter(transport, warehouse_id, datasets, enabled=False)` accepts an injected function `transport(method, path, body_or_None) -> JSON_object`. The adapter uses only warehouse inspection, fixed SELECT statement execution, and cancellation of its pending statement. A configured `Dataset` supplies its title, catalog, schema, table, and numeric columns. Configuration accepts simple identifiers, not SQL fragments.

`read_chart(dataset_id, minimum_x=None, maximum_x=None, row_limit=500)` builds typed numeric parameters, permits at most 500 returned points, requests INLINE JSON_ARRAY results with a 1 MiB limit, and asks Databricks to cancel after a 10-second wait. It does not retry queries or follow result URLs. One extra SQL row permits the API to indicate truncation correctly. SELECT queries can still scan more source rows than they return; prepare small datasets for a predictable demo. The API supports the parameter markers, result limits, and timeout behavior used here. [Statement Execution API](https://docs.databricks.com/api/statement-execution/v1/execute-statement)

Successful output contains `source`, `datasetID`, `title`, `columns`, finite numeric `points`, `truncated`, and `omittedNullRows`. It contains no account token, workspace URL, or raw SQL. It is a data snapshot, not executable widget code. The eventual renderer should create chart objects from this data using original application code.

## Why not start with Genie?

Genie Agents, formerly Genie Spaces, support natural-language questions, follow-ups, SQL results, and data-aware context. That is a good second integration when a curated agent already exists. Current documentation requires at least CAN VIEW access to the agent and SELECT on its underlying Unity Catalog data; configuring an agent also needs appropriate warehouse access. A fixed data query is a smaller first integration while workspace availability is unknown. [Genie Agents API](https://docs.databricks.com/aws/en/genie-agents/conversation-api)

## Offline verification

```sh
cd bridge
python3 -m unittest test_databricks_adapter -v
```

Tests cover disabled-mode isolation, dataset allowlisting, identifier and numeric injection rejection, typed parameters, output bounds, stopped-warehouse refusal, cancellation, credential-free errors, schema/axis mapping, null rows, non-finite values, and refusing result URLs. All test data is fictional. No external application source was copied.
