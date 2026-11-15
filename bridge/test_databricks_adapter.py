"""Offline tests only: no Databricks credentials, networks, or compute."""
import unittest
from unittest.mock import Mock

from databricks_adapter import Dataset, DatabricksChartAdapter, DatabricksError, prepare_query


class DatabricksAdapterTests(unittest.TestCase):
    def setUp(self):
        self.dataset = Dataset("Pendulum measurements", "science", "lab", "pendulum", "length_m", "period_s")
        self.response = {"status": {"state": "SUCCEEDED"},
            "manifest": {"schema": {"columns": [{"name": "x", "position": 0}, {"name": "y", "position": 1}]}, "truncated": False},
            "result": {"data_array": [["0.5", "1.42"], ["1.0", "2.01"]]}}
        self.transport = Mock(side_effect=[{"state": "RUNNING"}, self.response])
        self.adapter = DatabricksChartAdapter(self.transport, "warehouse-test", {"pendulum": self.dataset}, enabled=True)

    def test_disabled_adapter_never_calls_transport(self):
        self.adapter.enabled = False
        with self.assertRaises(DatabricksError):
            self.adapter.read_chart("pendulum")
        self.transport.assert_not_called()

    def test_unknown_dataset_never_calls_transport(self):
        with self.assertRaises(DatabricksError):
            self.adapter.read_chart("select * from private")
        self.transport.assert_not_called()

    def test_sql_identifier_injection_is_rejected(self):
        for malicious in ("measurements; DROP TABLE users", "x` FROM private --", "x.y", "read_files('secret')"):
            with self.subTest(malicious=malicious), self.assertRaises(DatabricksError):
                Dataset("Bad source", "science", "lab", malicious, "x", "y")

    def test_numeric_filters_use_typed_parameters(self):
        query = prepare_query(self.dataset, "warehouse-test", 0.25, 2.75, 20)
        self.assertIn("`length_m` >= :minimum_x", query["statement"])
        self.assertNotIn("0.25", query["statement"])
        parameters = {item["name"]: item for item in query["parameters"]}
        self.assertEqual(parameters["minimum_x"], {"name": "minimum_x", "value": "0.25", "type": "DOUBLE"})
        self.assertEqual(parameters["fetch_rows"]["value"], "21")
        self.assertEqual(query["row_limit"], 20)
        self.assertEqual(query["disposition"], "INLINE")
        self.assertEqual(query["on_wait_timeout"], "CANCEL")
        self.assertEqual(query["byte_limit"], 1024 * 1024)

    def test_bad_filter_or_limit_does_not_contact_workspace(self):
        for options in ({"minimum_x": "0; DROP TABLE t"}, {"maximum_x": float("nan")},
                        {"minimum_x": True}, {"minimum_x": 2, "maximum_x": 1},
                        {"row_limit": 501}, {"row_limit": 0}, {"row_limit": True}):
            with self.subTest(options=options), self.assertRaises(DatabricksError):
                self.adapter.read_chart("pendulum", **options)
        self.transport.assert_not_called()

    def test_stopped_warehouse_never_gets_query_or_start_request(self):
        self.transport.side_effect = [{"state": "STOPPED"}]
        with self.assertRaisesRegex(DatabricksError, "No query was submitted"):
            self.adapter.read_chart("pendulum")
        self.assertEqual(self.transport.call_count, 1)
        self.assertEqual(self.transport.call_args.args[:2], ("GET", "/api/2.0/sql/warehouses/warehouse-test"))

    def test_numeric_rows_become_structured_chart(self):
        chart = self.adapter.read_chart("pendulum")
        self.assertEqual(chart["points"], [[0.5, 1.42], [1.0, 2.01]])
        self.assertEqual(chart["source"], "Databricks")
        self.assertEqual(chart["columns"], ["length_m", "period_s"])
        self.assertFalse(chart["truncated"])

    def test_limited_result_is_explicit(self):
        self.response["manifest"]["truncated"] = True
        chart = self.adapter.read_chart("pendulum", row_limit=1)
        self.assertEqual(len(chart["points"]), 1)
        self.assertTrue(chart["truncated"])

    def test_null_rows_are_counted_and_omitted(self):
        self.response["result"]["data_array"].append([None, "1"])
        chart = self.adapter.read_chart("pendulum")
        self.assertEqual(chart["omittedNullRows"], 1)
        self.assertEqual(len(chart["points"]), 2)

    def test_nonfinite_result_rejected(self):
        self.response["result"]["data_array"][0][0] = "NaN"
        with self.assertRaises(DatabricksError):
            self.adapter.read_chart("pendulum")

    def test_does_not_follow_result_urls(self):
        self.response["result"]["next_chunk_internal_link"] = "https://untrusted.example/next"
        chart = self.adapter.read_chart("pendulum")
        self.assertTrue(chart["truncated"])
        self.assertEqual(self.transport.call_count, 2)

    def test_pending_statement_is_cancelled_without_retry(self):
        self.transport.side_effect = [{"state": "RUNNING"},
            {"status": {"state": "RUNNING"}, "statement_id": "statement-test"}, {}]
        with self.assertRaisesRegex(DatabricksError, "cancellation was requested"):
            self.adapter.read_chart("pendulum")
        self.assertEqual(self.transport.call_args.args[:2], ("POST", "/api/2.0/sql/statements/statement-test/cancel"))
        self.assertEqual(self.transport.call_count, 3)

    def test_transport_error_does_not_expose_credentials(self):
        self.transport.side_effect = RuntimeError("Authorization: Bearer private-example")
        with self.assertRaises(DatabricksError) as error:
            self.adapter.read_chart("pendulum")
        self.assertNotIn("private-example", str(error.exception))

    def test_bad_schema_does_not_create_mislabelled_chart(self):
        self.response["manifest"]["schema"]["columns"][0]["name"] = "wrong_axis"
        with self.assertRaises(DatabricksError):
            self.adapter.read_chart("pendulum")

    def test_column_positions_control_axis_mapping(self):
        self.response["manifest"]["schema"]["columns"] = [{"name": "x", "position": 1}, {"name": "y", "position": 0}]
        chart = self.adapter.read_chart("pendulum")
        self.assertEqual(chart["points"][0], [1.42, 0.5])

    def test_invalid_cancel_identifier_never_becomes_request_path(self):
        self.transport.side_effect = [{"state": "RUNNING"},
            {"status": {"state": "RUNNING"}, "statement_id": "../../warehouses/private/start"}]
        with self.assertRaisesRegex(DatabricksError, "invalid statement identifier"):
            self.adapter.read_chart("pendulum")
        self.assertEqual(self.transport.call_count, 2)


if __name__ == "__main__":
    unittest.main()
