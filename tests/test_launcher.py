import unittest
import importlib.util
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

    def test_http_is_allowed_only_for_localhost(self):
        self.assertEqual(opencode_ccswitch.validate_base_url("http://localhost:8080/v1", "Local"), "http://localhost:8080/v1")
        with self.assertRaisesRegex(RuntimeError, "HTTPS"):
            opencode_ccswitch.validate_base_url("http://api.example.test/v1", "Remote")

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


if __name__ == "__main__":
    unittest.main()
