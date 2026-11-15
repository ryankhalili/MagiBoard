# Databricks object catalog and optional data charts

The cloud object catalog is implemented through Databricks Unity Catalog volume files. It is available only when the Mac companion has an explicit local configuration and a working Databricks OAuth profile. A fresh checkout starts with it unconfigured. The separate SQL data-chart adapter remains experimental, disabled, and disconnected from the app. Starting MagiBoard does not provision Databricks resources or run SQL queries.

## Cloud object catalog

Save explicitly uploads one selected canvas object as an immutable JSON snapshot. Load retrieves one selected snapshot for import as a fresh local object. Widgets retain their original code and exposed parameter controls; image bytes stay inside the package. Existing notebooks and strokes are never uploaded automatically. This is a file-backed object library, not a replacement for the local notebook store or a live collaborative database.

Each snapshot has a unique version UUID, timestamp, schema version, source object, and content checksum. No overwrite or delete endpoint is exposed. Listings fetch at most 200 metadata records and mark incomplete results as `truncated`; they do not download every object's content. Loads are capped at 12 MiB and revalidate object fields, finite parameters, property controls, and image data. Native import must assign a fresh object ID. Widget code still uses the app's restricted interaction model after import.

All catalog HTTP endpoints require the same companion bearer token:

- `GET /catalog/status` returns `configured`, `connected`, `provider`, and `message`.
- `GET /catalog/objects` returns `objects` entries with `id,title,kind,createdAt,schemaVersion`, plus `truncated`.
- `POST /catalog/objects` accepts `{object: CanvasObject}` and returns `{entry}`.
- `GET /catalog/objects/{id}` returns `{entry,object}` for that version UUID.

The official Databricks CLI manages account authentication; this bridge does not export OAuth tokens or copy browser cookies. Install the CLI separately and sign in through its supported OAuth flow. [Databricks CLI authentication](https://docs.databricks.com/aws/en/dev-tools/cli/authentication)

An operator must select or explicitly create a managed volume and its `objects` directory. Configure the companion's private Application Support directory with a `databricks.json` file such as the following, substituting an authorized profile and volume:

```json
{"enabled":true,"profile":"MAGIBOARD","volume":"/Volumes/my_catalog/my_schema/my_volume"}
```

Keep that file outside the repository and restrict it to the Mac user. Disabling `enabled` and restarting the companion disables catalog access. The runtime performs only volume inspection and Files API list/read/write operations; it does not create volumes, start warehouses, or grant permissions. Files API access is subject to the user's Unity Catalog permissions and may incur data-transfer charges. [Files API](https://docs.databricks.com/api/files/v2/file), [volume privileges](https://docs.databricks.com/aws/en/volumes/privileges)

Development validation used a newly authorized dedicated managed volume and a single original synthetic triangle. Actual save/list/load preserved its geometry, and the SQL warehouse remained STOPPED. The real workspace URL, OAuth state, profile settings, and volume configuration remain outside the repository. No existing user notebooks were used in the test.

## Optional data-chart extension

Add a Data Chart object showing measurements from a user-selected Databricks dataset. For example, a physics tutor could plot pendulum length against measured period, annotate the points with Apple Pencil, and change the x-range in the inspector. Databricks supplies the measured data; MagiBoard supplies the interactive canvas and annotations. This is a proposed product integration, not a feature already available in the app.

The first version should use a small, reviewed table or prepared view with two numeric columns. A named dataset ID maps to that configuration. The model may select the ID and numeric filters; it cannot submit arbitrary SQL, table names, or functions. Returned values should become a visible chart snapshot with source, filter range, and truncation information. Refresh should be an explicit user action. Sending dataset values to an AI provider should be a separate, visible action rather than an automatic part of fetching data.

## Setup needed before connecting SQL charts

1. Identify the workspace URL, an existing SQL warehouse, and an existing table or prepared view. Choose the numeric x/y columns and verify access. Keep real workspace details in ignored local configuration.
2. Use Databricks' supported OAuth user-to-machine login on the Mac. With its CLI installed, `databricks auth login --host <workspace-url>` opens the user's browser. A browser tab being signed in does not itself authenticate this adapter; do not copy browser cookies or tokens into notebook files. Databricks recommends OAuth and supports automated refresh through unified authentication. [Official OAuth guide](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m)
3. Review the dataset and compute choice before enabling live requests. Running a SQL query against a stopped warehouse can start it automatically. The adapter rejects a warehouse that is not currently RUNNING, but that precheck cannot lock its state or guarantee that a subsequent query incurs no compute usage. No warehouse start/create endpoint exists in this adapter. [Warehouse behavior](https://docs.databricks.com/aws/en/compute/sql-warehouse)
4. Implement a host-owned authenticated transport for one configured HTTPS workspace origin, using the selected official auth profile. Enforce request timeouts and a bounded response body; refuse redirects to other origins. Keep credentials out of iPad objects, generated HTML, logs, and the repository.
5. Review the server endpoint and native chart UI before wiring this adapter. Preserve the companion's bearer authentication and return normalized data rather than raw Databricks responses.

The official CLI and local OAuth account are external setup, not bundled in this repository or iPad app. The SQL adapter has not been connected to an authenticated transport or live-tested. No SQL warehouse or dataset was created or started for this work; the cloud catalog uses the separate Files API described above.

## Adapter contract

`DatabricksChartAdapter(transport, warehouse_id, datasets, enabled=False)` accepts an injected function `transport(method, path, body_or_None) -> JSON_object`. The adapter uses only warehouse inspection, fixed SELECT statement execution, and cancellation of its pending statement. A configured `Dataset` supplies its title, catalog, schema, table, and numeric columns. Configuration accepts simple identifiers, not SQL fragments.

`read_chart(dataset_id, minimum_x=None, maximum_x=None, row_limit=500)` builds typed numeric parameters, permits at most 500 returned points, requests INLINE JSON_ARRAY results with a 1 MiB limit, and asks Databricks to cancel after a 10-second wait. It does not retry queries or follow result URLs. One extra SQL row permits the API to indicate truncation correctly. SELECT queries can still scan more source rows than they return; prepare small datasets for a predictable demo. The API supports the parameter markers, result limits, and timeout behavior used here. [Statement Execution API](https://docs.databricks.com/api/statement-execution/v1/execute-statement)

Successful output contains `source`, `datasetID`, `title`, `columns`, finite numeric `points`, `truncated`, and `omittedNullRows`. It contains no account token, workspace URL, or raw SQL. It is a data snapshot, not executable widget code. The eventual renderer should create chart objects from this data using original application code.

## Why not start with Genie?

Genie Agents, formerly Genie Spaces, support natural-language questions, follow-ups, SQL results, and data-aware context. That is a good second integration when a curated agent already exists. Current documentation requires at least CAN VIEW access to the agent and SELECT on its underlying Unity Catalog data; configuring an agent also needs appropriate warehouse access. A fixed data query is a smaller first integration while workspace availability is unknown. [Genie Agents API](https://docs.databricks.com/aws/en/genie-agents/conversation-api)

## Offline verification

```sh
cd bridge
python3 -m unittest test_databricks_adapter test_databricks_catalog -v
```

Tests cover disabled-mode isolation, dataset allowlisting, identifier and numeric injection rejection, typed parameters, output bounds, stopped-warehouse refusal, cancellation, credential-free errors, schema/axis mapping, null rows, non-finite values, and refusing result URLs. All test data is fictional. No external application source was copied.
