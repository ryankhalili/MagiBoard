"""Optional, disconnected Databricks chart adapter; original standard-library code.

The caller supplies an authenticated transport after workspace setup is reviewed.
Importing this module never connects, authenticates, provisions, or starts compute.
"""
from __future__ import annotations

from dataclasses import dataclass
import math
import re
from typing import Callable, Mapping


MAX_ROWS = 500
MAX_BYTES = 1024 * 1024
WAIT_SECONDS = 10


class DatabricksError(Exception):
    pass


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,127}", value):
        raise DatabricksError("Choose a configured table and columns with simple SQL identifiers.")
    return "`" + value + "`"


def number(value, name):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value):
        raise DatabricksError(name + " must be a finite number.")
    return float(value)


@dataclass(frozen=True)
class Dataset:
    """Operator-reviewed source; never populated from a model's free-form SQL."""
    title: str
    catalog: str
    schema: str
    table: str
    x_column: str
    y_column: str

    def __post_init__(self):
        for value in (self.catalog, self.schema, self.table, self.x_column, self.y_column):
            identifier(value)
        if not isinstance(self.title, str) or not 1 <= len(self.title) <= 200:
            raise DatabricksError("Dataset title must contain 1–200 characters.")


def prepare_query(dataset, warehouse_id, minimum_x=None, maximum_x=None, row_limit=MAX_ROWS):
    if not isinstance(warehouse_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", warehouse_id):
        raise DatabricksError("Invalid configured warehouse identifier.")
    if isinstance(row_limit, bool) or not isinstance(row_limit, int) or not 1 <= row_limit <= MAX_ROWS:
        raise DatabricksError("Choose a row limit from 1 to 500.")
    low = number(minimum_x, "Minimum x") if minimum_x is not None else None
    high = number(maximum_x, "Maximum x") if maximum_x is not None else None
    if low is not None and high is not None and low > high:
        raise DatabricksError("Minimum x must not exceed maximum x.")
    source = ".".join(identifier(value) for value in (dataset.catalog, dataset.schema, dataset.table))
    x, y = identifier(dataset.x_column), identifier(dataset.y_column)
    conditions = [x + " IS NOT NULL", y + " IS NOT NULL"]
    # Fetch one additional row so the API can truthfully mark truncation.
    parameters = [{"name": "fetch_rows", "value": str(row_limit + 1), "type": "INT"}]
    for value, name, operator in ((low, "minimum_x", ">="), (high, "maximum_x", "<=")):
        if value is not None:
            conditions.append(x + " " + operator + " :" + name)
            parameters.append({"name": name, "value": str(value), "type": "DOUBLE"})
    # This is the only SQL shape the adapter can send. Values use typed markers.
    statement = (f"SELECT CAST({x} AS DOUBLE) AS x, CAST({y} AS DOUBLE) AS y FROM {source} "
        + "WHERE " + " AND ".join(conditions) + f" ORDER BY {x} ASC LIMIT :fetch_rows")
    return {"warehouse_id": warehouse_id, "statement": statement, "parameters": parameters,
        "format": "JSON_ARRAY", "disposition": "INLINE", "row_limit": row_limit,
        "byte_limit": MAX_BYTES, "wait_timeout": str(WAIT_SECONDS) + "s", "on_wait_timeout": "CANCEL"}


def query_state(response):
    status = response.get("status") if isinstance(response, dict) else None
    return status.get("state") if isinstance(status, dict) else None


def normalize_result(response, dataset_id, dataset, row_limit):
    if query_state(response) != "SUCCEEDED":
        raise DatabricksError("The data query did not finish successfully. No chart was changed.")
    manifest = response.get("manifest", {})
    if not isinstance(manifest, dict) or not isinstance(manifest.get("schema"), dict):
        raise DatabricksError("The query returned an unexpected chart schema.")
    columns = manifest["schema"].get("columns", [])
    if not isinstance(columns, list):
        raise DatabricksError("The query returned an unexpected chart schema.")
    positions = {column.get("name"): column.get("position") for column in columns if isinstance(column, dict)}
    if len(columns) != 2 or set(positions) != {"x", "y"} or any(type(value) is not int for value in positions.values()) or sorted(positions.values()) != [0, 1]:
        raise DatabricksError("The query returned an unexpected chart schema.")
    result = response.get("result", {})
    if not isinstance(result, dict):
        raise DatabricksError("The query returned unreadable chart rows.")
    rows = result.get("data_array", [])
    if not isinstance(rows, list):
        raise DatabricksError("The query returned unreadable chart rows.")
    points, omitted = [], 0
    for row in rows[:row_limit]:
        if not isinstance(row, list) or len(row) != 2:
            raise DatabricksError("The query returned unreadable chart rows.")
        values = [row[positions["x"]], row[positions["y"]]]
        if any(value is None for value in values):
            omitted += 1
            continue
        try:
            if any(isinstance(value, bool) or not isinstance(value, (str, float, int)) or len(str(value)) > 128 for value in values):
                raise ValueError()
            point = [float(value) for value in values]
            if not all(math.isfinite(value) for value in point):
                raise ValueError()
        except (ValueError, OverflowError):
            raise DatabricksError("The query returned non-finite or non-numeric chart values.")
        points.append(point)
    return {"source": "Databricks", "datasetID": dataset_id, "title": dataset.title,
        "columns": [dataset.x_column, dataset.y_column], "points": points,
        "truncated": manifest.get("truncated") is True or len(rows) > row_limit or bool(result.get("next_chunk_internal_link")),
        "omittedNullRows": omitted}


class DatabricksChartAdapter:
    """No credentials or arbitrary SQL enter the canvas interface.

    transport(method, path, JSON_body_or_None) -> decoded JSON, authenticated by
    the host using the user's chosen Databricks profile. It must enforce HTTPS,
    its configured workspace origin, timeouts, and a bounded response body.
    """
    def __init__(self, transport: Callable, warehouse_id: str, datasets: Mapping[str, Dataset], *, enabled=False):
        self.transport = transport
        self.warehouse_id = warehouse_id
        self.datasets = dict(datasets)
        self.enabled = enabled
        if not callable(transport):
            raise DatabricksError("An authenticated workspace transport is required.")
        if not isinstance(warehouse_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", warehouse_id):
            raise DatabricksError("Invalid configured warehouse identifier.")

    def _request(self, method, path, payload=None):
        try:
            response = self.transport(method, path, payload)
        except Exception:
            # A transport error may contain request headers or workspace details.
            raise DatabricksError("Databricks could not complete the request. Check the configured account and connection.") from None
        if not isinstance(response, dict):
            raise DatabricksError("Databricks returned an unreadable response.")
        return response

    def read_chart(self, dataset_id, *, minimum_x=None, maximum_x=None, row_limit=MAX_ROWS):
        if not self.enabled:
            raise DatabricksError("Databricks is not enabled. Review workspace, dataset, and compute access first.")
        if not isinstance(dataset_id, str):
            raise DatabricksError("Choose an operator-configured dataset.")
        dataset = self.datasets.get(dataset_id)
        if not isinstance(dataset, Dataset):
            raise DatabricksError("Choose an operator-configured dataset.")
        query = prepare_query(dataset, self.warehouse_id, minimum_x, maximum_x, row_limit)
        warehouse = self._request("GET", "/api/2.0/sql/warehouses/" + self.warehouse_id)
        if warehouse.get("state") != "RUNNING":
            raise DatabricksError("The selected warehouse is not running. No query was submitted.")
        # This check does not lock warehouse state: a query can auto-start compute
        # if the warehouse stops immediately afterward. Setup must disclose this.
        response = self._request("POST", "/api/2.0/sql/statements", query)
        state = query_state(response)
        if state in ("PENDING", "RUNNING"):
            statement_id = response.get("statement_id", "")
            if not isinstance(statement_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", statement_id):
                raise DatabricksError("The query returned an invalid statement identifier. Its cancellation could not be confirmed.")
            self._request("POST", "/api/2.0/sql/statements/" + statement_id + "/cancel", {})
            raise DatabricksError("The data query exceeded its wait window and cancellation was requested. Try a smaller prepared dataset.")
        return normalize_result(response, dataset_id, dataset, row_limit)
