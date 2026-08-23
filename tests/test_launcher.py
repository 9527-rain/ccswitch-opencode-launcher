import unittest
import importlib.util
import json
import os
import sqlite3
import tempfile
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "opencode-ccswitch.py"
SPEC = importlib.util.spec_from_file_location("opencode_ccswitch", MODULE_PATH)
opencode_ccswitch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(opencode_ccswitch)


class LauncherTests(unittest.TestCase):
    def test_codex_provider_is_translated_to_openai_compatible_runtime(self):
        row = {
            "id": "provider-1",
            "name": "Example",
            "website_url": "https://example.test",
            "meta": "{}",
            "settings_config": '{"auth":{"OPENAI_API_KEY":"test-key"},"config":"model = \\\"demo-model\\\"\\nbase_url = \\\"https://example.test/v1\\\"\\nmodel_reasoning_effort = \\\"high\\\""}',
        }
        runtime = opencode_ccswitch.runtime_for("codex", row)
        self.assertEqual(runtime["base_url"], "https://example.test/v1")
        self.assertEqual(runtime["model_id"], "demo-model")
        self.assertEqual(runtime["effort"], "high")
        self.assertEqual(runtime["api_key"], "test-key")

    def test_missing_base_url_is_rejected_instead_of_using_website(self):
        row = {
            "id": "provider-1",
            "name": "Example",
            "website_url": "https://example.test",
            "meta": "{}",
            "settings_config": '{"auth":{"OPENAI_API_KEY":"test-key"},"config":"model = \\\"demo-model\\\""}',
        }
        with self.assertRaisesRegex(RuntimeError, "no explicit API base URL"):
            opencode_ccswitch.runtime_for("codex", row)

    def test_safe_options_drops_credentials_and_unknown_fields(self):
        config = {
            "options": {
                "apiKey": "real-key",
                "token": "real-token",
                "organization": "org",
                "unknown": "drop-me",
            }
        }
        options = opencode_ccswitch.safe_options(config, "https://api.example.test/v1")
        self.assertEqual(options["baseURL"], "https://api.example.test/v1")
        self.assertEqual(options["organization"], "org")
        self.assertNotIn("token", options)
        self.assertNotIn("unknown", options)
        self.assertNotIn("real-key", repr(options))

    def test_nested_model_metadata_is_sanitized(self):
        model = {
            "name": "Demo",
            "options": {"apiKey": "secret-key", "headers": {"Authorization": "Bearer secret", "X-Mode": "test"}},
            "credentials": [{"token": "secret-token"}],
        }
        sanitized = opencode_ccswitch.sanitize(model)
        self.assertEqual(sanitized["name"], "Demo")
        self.assertEqual(sanitized["options"]["headers"], {"X-Mode": "test"})
        self.assertNotIn("secret-key", repr(sanitized))
        self.assertNotIn("secret-token", repr(sanitized))

    def test_http_is_allowed_only_for_localhost(self):
        self.assertEqual(opencode_ccswitch.validate_base_url("http://localhost:8080/v1", "Local"), "http://localhost:8080/v1")
        with self.assertRaisesRegex(RuntimeError, "HTTPS"):
            opencode_ccswitch.validate_base_url("http://api.example.test/v1", "Remote")

    def test_discovery_mode_must_be_explicit(self):
        opencode_ccswitch.validate_discovery_mode("never")
        with self.assertRaisesRegex(RuntimeError, "MODEL_DISCOVERY"):
            opencode_ccswitch.validate_discovery_mode("sometimes")

    def test_environment_key_reference_is_resolved(self):
        config = {"options": {"apiKey": "{env:CCSWITCH_TEST_KEY}"}}
        old = opencode_ccswitch.os.environ.get("CCSWITCH_TEST_KEY")
        opencode_ccswitch.os.environ["CCSWITCH_TEST_KEY"] = "from-env"
        try:
            self.assertEqual(opencode_ccswitch.resolve_key(config), "from-env")
        finally:
            if old is None:
                opencode_ccswitch.os.environ.pop("CCSWITCH_TEST_KEY", None)
            else:
                opencode_ccswitch.os.environ["CCSWITCH_TEST_KEY"] = old

    def test_dry_run_needs_no_key_or_opencode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            db_path = root / "cc-switch.db"
            connection = sqlite3.connect(db_path)
            try:
                connection.execute("CREATE TABLE providers (id TEXT, name TEXT, settings_config TEXT, meta TEXT, website_url TEXT, app_type TEXT, is_current INTEGER)")
                connection.execute(
                    "INSERT INTO providers VALUES (?, ?, ?, ?, ?, ?, ?)",
                    ("p1", "Preview", json.dumps({"options": {"baseURL": "https://api.example.test/v1"}, "models": {"demo": {"apiKey": "hidden"}}}), "{}", "https://example.test", "opencode", 1),
                )
                connection.commit()
            finally:
                connection.close()
            old_home = os.environ.get("CCSWITCH_HOME")
            old_db = os.environ.get("CCSWITCH_DB")
            os.environ["CCSWITCH_HOME"] = str(root)
            os.environ["CCSWITCH_DB"] = str(db_path)
            output = StringIO()
            try:
                with redirect_stdout(output):
                    result = opencode_ccswitch.main(["--dry-run"])
            finally:
                if old_home is None:
                    os.environ.pop("CCSWITCH_HOME", None)
                else:
                    os.environ["CCSWITCH_HOME"] = old_home
                if old_db is None:
                    os.environ.pop("CCSWITCH_DB", None)
                else:
                    os.environ["CCSWITCH_DB"] = old_db
            self.assertEqual(result, 0)
            self.assertIn('"model": "ccswitch/demo"', output.getvalue())
            self.assertNotIn("hidden", output.getvalue())


if __name__ == "__main__":
    unittest.main()
