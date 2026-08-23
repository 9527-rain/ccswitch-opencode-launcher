import unittest
import importlib.util
import json
import os
import stat
import sqlite3
import sys
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
        with self.assertRaisesRegex(RuntimeError, "query"):
            opencode_ccswitch.validate_base_url("https://api.example.test/v1?token=secret", "Query")

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

    def test_generated_config_only_contains_launcher_owned_layer(self):
        runtime = {
            "config": {"options": {"baseURL": "https://api.example.test/v1", "organization": "demo"}},
            "npm": "@ai-sdk/openai-compatible",
            "base_url": "https://api.example.test/v1",
            "model_id": "demo-model",
            "models": {"demo-model": {"name": "Demo"}},
        }
        generated = opencode_ccswitch.generated_config(runtime, "Provider")
        self.assertEqual(generated["model"], "ccswitch/demo-model")
        self.assertIn("provider", generated)
        self.assertNotIn("mcp", generated)
        self.assertNotIn("permission", generated)
        self.assertNotIn("plugin", generated)

    def test_doctor_json_is_redacted_and_versioned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            db_path = root / "cc-switch.db"
            connection = sqlite3.connect(db_path)
            try:
                connection.execute("CREATE TABLE providers (id TEXT, name TEXT, settings_config TEXT, meta TEXT, website_url TEXT, app_type TEXT, is_current INTEGER)")
                connection.execute(
                    "INSERT INTO providers VALUES (?, ?, ?, ?, ?, ?, ?)",
                    ("p1", "Doctor", json.dumps({"auth": {"OPENAI_API_KEY": "secret"}, "options": {"baseURL": "https://api.example.test/v1"}, "model": "demo"}), "{}", "https://example.test", "opencode", 1),
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
                    result = opencode_ccswitch.print_doctor(json_output=True)
            finally:
                if old_home is None:
                    os.environ.pop("CCSWITCH_HOME", None)
                else:
                    os.environ["CCSWITCH_HOME"] = old_home
                if old_db is None:
                    os.environ.pop("CCSWITCH_DB", None)
                else:
                    os.environ["CCSWITCH_DB"] = old_db
            details = json.loads(output.getvalue())
            self.assertEqual(result, 0)
            self.assertEqual(details["launcher_version"], opencode_ccswitch.__version__)
            self.assertEqual(details["provider"]["api_key"], "configured")
            self.assertNotIn("secret", output.getvalue())

    def test_version_command(self):
        output = StringIO()
        with redirect_stdout(output):
            result = opencode_ccswitch.main(["--version"])
        self.assertEqual(result, 0)
        self.assertIn(opencode_ccswitch.__version__, output.getvalue())

    def test_schema_info_detects_missing_columns(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cc-switch.db"
            connection = sqlite3.connect(path)
            try:
                connection.execute("CREATE TABLE providers (id TEXT, name TEXT)")
                connection.commit()
            finally:
                connection.close()
            info = opencode_ccswitch.db_schema_info(path)
            self.assertEqual(info["status"], "unsupported")
            self.assertIn("settings_config", info["missing_columns"])

    def test_doctor_strict_returns_failure_for_missing_database(self):
        with tempfile.TemporaryDirectory() as directory:
            old_db_env = os.environ.get("CCSWITCH_DB")
            os.environ["CCSWITCH_DB"] = str(Path(directory) / "missing.db")
            output = StringIO()
            try:
                with redirect_stdout(output):
                    result = opencode_ccswitch.print_doctor(json_output=True, strict=True)
            finally:
                if old_db_env is None:
                    os.environ.pop("CCSWITCH_DB", None)
                else:
                    os.environ["CCSWITCH_DB"] = old_db_env
            details = json.loads(output.getvalue())
            self.assertEqual(result, 1)
            self.assertEqual(details["issues"][0]["code"], "database_missing")

    def test_launch_injects_model_and_child_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            db_path = root / "cc-switch.db"
            connection = sqlite3.connect(db_path)
            try:
                connection.execute("CREATE TABLE providers (id TEXT, name TEXT, settings_config TEXT, meta TEXT, website_url TEXT, app_type TEXT, is_current INTEGER)")
                connection.execute(
                    "INSERT INTO providers VALUES (?, ?, ?, ?, ?, ?, ?)",
                    ("p1", "Launch", json.dumps({"auth": {"OPENAI_API_KEY": "launch-key"}, "options": {"baseURL": "https://api.example.test/v1"}, "model": "demo"}), "{}", "https://example.test", "opencode", 1),
                )
                connection.commit()
            finally:
                connection.close()
            fake_python = root / "fake_opencode.py"
            fake_python.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "json.dump({'args': sys.argv[1:], 'key': os.environ.get('CCSWITCH_OPENCODE_API_KEY'), 'config': os.environ.get('OPENCODE_CONFIG'), 'config_exists': os.path.exists(os.environ.get('OPENCODE_CONFIG', ''))}, open(os.environ['FAKE_OUTPUT'], 'w'))\n",
                encoding="utf-8",
            )
            if sys.platform == "win32":
                fake = root / "opencode.cmd"
                fake.write_text(f'@echo off\r\n"{sys.executable}" "%~dp0fake_opencode.py" %*\r\n', encoding="utf-8")
            else:
                fake = root / "opencode"
                fake.write_text("#!/bin/sh\nexec \"" + sys.executable + "\" \"$(dirname \"$0\")/fake_opencode.py\" \"$@\"\n", encoding="utf-8")
                fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
            output_path = root / "child.json"
            old_env = {name: os.environ.get(name) for name in ("CCSWITCH_HOME", "CCSWITCH_DB", "FAKE_OUTPUT", "PATH", "OPENCODE_CONFIG")}
            os.environ["CCSWITCH_HOME"] = str(root)
            os.environ["CCSWITCH_DB"] = str(db_path)
            os.environ["FAKE_OUTPUT"] = str(output_path)
            os.environ["PATH"] = f"{root}{os.pathsep}{old_env['PATH'] or ''}"
            os.environ.pop("OPENCODE_CONFIG", None)
            try:
                result = opencode_ccswitch.main([])
            finally:
                for name, previous in old_env.items():
                    if previous is None:
                        os.environ.pop(name, None)
                    else:
                        os.environ[name] = previous
            child = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(result, 0)
            self.assertEqual(child["args"][:2], ["--model", "ccswitch/demo"])
            self.assertEqual(child["key"], "launch-key")
            self.assertTrue(child["config_exists"])
            self.assertFalse(Path(child["config"]).exists())


if __name__ == "__main__":
    unittest.main()
