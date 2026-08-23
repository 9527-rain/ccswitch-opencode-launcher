#!/usr/bin/env python3
"""Sync the active CCSwitch provider and launch OpenCode."""

from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from urllib.parse import urlparse
import urllib.request
from pathlib import Path
from typing import Any

__version__ = "0.4.0"
DOCTOR_SCHEMA_VERSION = 1
REQUIRED_PROVIDER_COLUMNS = {"id", "name", "settings_config", "meta", "app_type", "is_current"}


def value(obj: Any, name: str, default: Any = None) -> Any:
    return obj.get(name, default) if isinstance(obj, dict) else default


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def db_rows(path: Path, query: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    if not path.exists():
        raise RuntimeError(f"CCSwitch database not found: {path}")
    uri = f"file:{path.as_posix()}?mode=ro"
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=5)
        try:
            connection.row_factory = sqlite3.Row
            cursor = connection.execute(query, params)
            try:
                return [dict(row) for row in cursor]
            finally:
                cursor.close()
        finally:
            connection.close()
    except sqlite3.Error as exc:
        raise RuntimeError(f"Could not read CCSwitch database: {exc}") from exc


def db_schema_info(path: Path) -> dict[str, Any]:
    """Inspect only stable SQLite metadata before querying CCSwitch rows."""
    if not path.exists():
        return {"status": "missing", "user_version": None, "columns": [], "missing_columns": sorted(REQUIRED_PROVIDER_COLUMNS)}
    try:
        connection = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True, timeout=5)
        try:
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            columns = {str(row[1]) for row in connection.execute("PRAGMA table_info(providers)")}
        finally:
            connection.close()
    except sqlite3.Error as exc:
        raise RuntimeError(f"Could not inspect CCSwitch database: {exc}") from exc
    missing = sorted(REQUIRED_PROVIDER_COLUMNS - columns)
    return {
        "status": "supported" if not missing else "unsupported",
        "user_version": version,
        "columns": sorted(columns),
        "missing_columns": missing,
    }


def require_supported_schema(path: Path) -> dict[str, Any]:
    info = db_schema_info(path)
    if info["status"] == "missing":
        raise RuntimeError(f"CCSwitch database not found: {path}")
    if info["status"] != "supported":
        missing = ", ".join(info["missing_columns"])
        raise RuntimeError(f"Unsupported CCSwitch database schema; missing providers columns: {missing}")
    return info


def resolve_key(config: dict[str, Any]) -> str | None:
    options = value(config, "options", {})
    auth = value(config, "auth", {})
    candidates = ["apiKey", "api_key", "token", "accessToken", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
    for source in (options, auth):
        for key in candidates:
            candidate = value(source, key)
            if candidate:
                match = re.fullmatch(r"\{env:([^}]+)\}", str(candidate))
                return os.environ.get(match.group(1), "") if match else str(candidate)
        if isinstance(source, dict):
            for key, candidate in source.items():
                if re.search(r"api.?key|token|secret", key, re.I) and candidate:
                    return str(candidate)
    return None


def parse_toml_string(text: str, key: str) -> str | None:
    match = re.search(rf'^\s*{re.escape(key)}\s*=\s*"([^"]+)"', text, re.M)
    return match.group(1) if match else None


def validate_base_url(base_url: Any, provider_name: str) -> str:
    value_ = str(base_url or "").strip().rstrip("/")
    if not value_:
        raise RuntimeError(f"Provider {provider_name} has no explicit API base URL")
    parsed = urlparse(value_)
    if parsed.scheme not in {"https", "http"} or not parsed.netloc:
        raise RuntimeError(f"Provider {provider_name} has an invalid API base URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise RuntimeError("API base URL must not include credentials, query parameters, or fragments")
    if parsed.scheme != "https" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise RuntimeError("API base URL must use HTTPS (HTTP is allowed only for localhost)")
    return value_


def display_base_url(base_url: str) -> str:
    parsed = urlparse(base_url)
    host = parsed.hostname or ""
    port = f":{parsed.port}" if parsed.port else ""
    return f"{parsed.scheme}://{host}{port}{parsed.path}".rstrip("/")


def safe_options(config: dict[str, Any], base_url: str) -> dict[str, Any]:
    options = value(config, "options", {})
    if not isinstance(options, dict):
        return {"baseURL": base_url, "apiKey": "{env:CCSWITCH_OPENCODE_API_KEY}"}
    allowed = {"organization", "project", "compatibility", "fetch", "timeout"}
    result: dict[str, Any] = {"baseURL": base_url, "apiKey": "{env:CCSWITCH_OPENCODE_API_KEY}"}
    for key, item in options.items():
        if key in {"baseURL", "apiKey"} or str(key) not in allowed:
            continue
        result[str(key)] = sanitize(item)
    return result


SENSITIVE_KEY = re.compile(r"(?:api.?key|token|secret|password|credential|authorization|cookie)", re.I)


def sanitize(item: Any) -> Any:
    """Recursively remove credential-like keys from provider metadata."""
    if isinstance(item, dict):
        return {str(key): sanitize(value_) for key, value_ in item.items() if not SENSITIVE_KEY.search(str(key))}
    if isinstance(item, list):
        return [sanitize(value_) for value_ in item]
    return item


def current_provider(settings: dict[str, Any], app_type: str, provider_id: str | None) -> tuple[str, str]:
    require_supported_schema(DB_PATH)
    if app_type:
        selected_type = app_type
    else:
        open_code_id = value(settings, "currentProviderOpenCode")
        open_code_rows = db_rows(DB_PATH, "SELECT count(*) AS count FROM providers WHERE app_type='opencode' AND is_current=1")
        selected_type = "opencode" if open_code_id or (open_code_rows and open_code_rows[0]["count"] > 0) else "codex"
    selected_id = provider_id or value(settings, {
        "opencode": "currentProviderOpenCode",
        "codex": "currentProviderCodex",
    }.get(selected_type, ""))
    if selected_id:
        rows = db_rows(
            DB_PATH,
            "SELECT id,name,settings_config,meta,website_url FROM providers WHERE app_type=? AND id=? LIMIT 1",
            (selected_type, selected_id),
        )
    else:
        rows = db_rows(
            DB_PATH,
            "SELECT id,name,settings_config,meta,website_url FROM providers WHERE app_type=? AND is_current=1 LIMIT 1",
            (selected_type,),
        )
    if not rows and not app_type and selected_type == "opencode":
        return current_provider(settings, "codex", provider_id)
    if not rows:
        raise RuntimeError(f"No active CCSwitch {selected_type} provider was found")
    return selected_type, rows[0]


def runtime_for(app_type: str, row: dict[str, Any], require_key: bool = True) -> dict[str, Any]:
    try:
        config = json.loads(row["settings_config"])
    except (TypeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Invalid provider settings for {row.get('name', row.get('id'))}") from exc

    native = app_type == "opencode" or bool(value(config, "npm"))
    npm = str(value(config, "npm", "@ai-sdk/openai-compatible")) if native else "@ai-sdk/openai-compatible"
    npm = os.environ.get("CCSWITCH_OPENCODE_NPM", npm)
    models: dict[str, Any] = {}
    model_id: str | None = None
    effort: str | None = None

    if native:
        options = value(config, "options", {})
        base_url = value(options, "baseURL")
        if isinstance(value(config, "models"), dict):
            models = sanitize(json.loads(json.dumps(value(config, "models"))))
        meta = read_json_from_text(row.get("meta"))
        model_id = value(meta, "model") or value(meta, "defaultModel") or value(config, "model")
        if not model_id and models:
            model_id = next(iter(models))
    else:
        text = str(value(config, "config", ""))
        base_url = parse_toml_string(text, "base_url")
        model_id = parse_toml_string(text, "model")
        effort = parse_toml_string(text, "model_reasoning_effort")
        catalog = value(value(config, "modelCatalog", {}), "models", [])
        for entry in catalog if isinstance(catalog, list) else []:
            model = value(entry, "model") or value(entry, "id") or value(entry, "slug")
            if model:
                models[str(model)] = {"name": value(entry, "displayName") or value(entry, "name") or str(model)}

    provider_name = row.get("name", row.get("id"))
    base_url = validate_base_url(base_url, str(provider_name))
    api_key = resolve_key(config)
    if require_key and not api_key:
        raise RuntimeError(f"Provider {row.get('name', row.get('id'))} has no API key")
    return {"config": config, "npm": npm, "base_url": base_url, "model_id": model_id or "default", "effort": effort, "models": models, "api_key": api_key}


def read_json_from_text(text: Any) -> dict[str, Any]:
    if not text:
        return {}
    try:
        value_ = json.loads(str(text))
        return value_ if isinstance(value_, dict) else {}
    except json.JSONDecodeError:
        return {}


def discover_models(runtime: dict[str, Any]) -> None:
    mode = os.environ.get("CCSWITCH_MODEL_DISCOVERY", "never")
    validate_discovery_mode(mode)
    if mode != "never":
        request = urllib.request.Request(
            f"{runtime['base_url']}/models",
            headers={"Authorization": f"Bearer {runtime['api_key']}", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                catalog = json.load(response)
            entries = catalog.get("data", catalog) if isinstance(catalog, dict) else catalog
            for entry in entries if isinstance(entries, list) else []:
                model = value(entry, "id")
                if model and model not in runtime["models"]:
                    runtime["models"][str(model)] = {"name": str(model)}
        except Exception as exc:  # noqa: BLE001 - discovery is intentionally best-effort
            if mode == "required":
                raise RuntimeError(f"Model discovery failed: {exc}") from exc
    model_id = runtime["model_id"]
    runtime["models"].setdefault(model_id, {"name": model_id})
    if runtime["effort"]:
        runtime["models"].setdefault(model_id, {})["options"] = {"reasoningEffort": runtime["effort"]}


def validate_discovery_mode(mode: str) -> None:
    if mode not in {"never", "best-effort", "required"}:
        raise RuntimeError("CCSWITCH_MODEL_DISCOVERY must be never, best-effort, or required")


def generated_config(runtime: dict[str, Any], provider_name: str) -> dict[str, Any]:
    """Build only the layer owned by this launcher.

    OpenCode merges OPENCODE_CONFIG with its normal global and project config.
    Keeping this document to provider/model keys avoids copying user MCP, plugin,
    permission, or agent settings into a temporary file.
    """
    options = safe_options(runtime["config"], runtime["base_url"])
    return {
        "$schema": "https://opencode.ai/config.json",
        "provider": {"ccswitch": {"npm": runtime["npm"], "name": f"CCSwitch: {provider_name}", "options": options, "models": runtime["models"]}},
        "model": f"ccswitch/{runtime['model_id']}",
    }


def doctor_data() -> dict[str, Any]:
    global DB_PATH
    cc_root = Path(os.environ.get("CCSWITCH_HOME", Path.home() / ".cc-switch"))
    DB_PATH = Path(os.environ.get("CCSWITCH_DB", cc_root / "cc-switch.db"))
    settings = read_json(cc_root / "settings.json", {})
    issues: list[dict[str, str]] = []
    schema = db_schema_info(DB_PATH)
    provider: dict[str, Any] = {"name": None, "app_type": None, "model": None, "api_base_url": None, "api_key": "unknown"}
    if schema["status"] == "missing":
        issues.append({"code": "database_missing", "message": f"CCSwitch database not found: {DB_PATH}"})
    elif schema["status"] != "supported":
        missing = ", ".join(schema["missing_columns"])
        issues.append({"code": "schema_unsupported", "message": f"Missing providers columns: {missing}"})
    else:
        try:
            app_type, row = current_provider(settings, os.environ.get("CCSWITCH_APP_TYPE", ""), os.environ.get("CCSWITCH_PROVIDER_ID"))
            runtime = runtime_for(app_type, row, require_key=False)
            provider = {
                "name": row["name"],
                "app_type": app_type,
                "model": runtime["model_id"],
                "api_base_url": display_base_url(runtime["base_url"]),
                "api_key": "configured" if runtime["api_key"] else "missing",
            }
            if not runtime["api_key"]:
                issues.append({"code": "api_key_missing", "message": "The active provider has no API key"})
        except RuntimeError as exc:
            issues.append({"code": "provider_invalid", "message": str(exc)})
    discovery = os.environ.get("CCSWITCH_MODEL_DISCOVERY", "never")
    try:
        validate_discovery_mode(discovery)
    except RuntimeError as exc:
        issues.append({"code": "discovery_mode_invalid", "message": str(exc)})
    executable = shutil.which("opencode")
    if not executable:
        issues.append({"code": "opencode_missing", "message": "OpenCode was not found on PATH"})
    return {
        "doctor_schema": DOCTOR_SCHEMA_VERSION,
        "launcher_version": __version__,
        "platform": sys.platform,
        "python": {"version": sys.version.split()[0], "supported": sys.version_info >= (3, 9)},
        "status": "ok" if not issues else "warning",
        "issues": issues,
        "ccswitch": {"home": str(cc_root), "database": str(DB_PATH), "schema": schema},
        "provider": provider,
        "opencode": {"status": "found" if executable else "missing", "path": executable},
        "model_discovery": discovery,
    }


def print_doctor(json_output: bool = False, strict: bool = False) -> int:
    details = doctor_data()
    if json_output:
        print(json.dumps(details, ensure_ascii=False, indent=2))
        return 1 if strict and details["issues"] else 0
    provider = details["provider"]
    print(f"launcher version: {details['launcher_version']}")
    print(f"provider: {provider['name']}")
    print(f"app type: {provider['app_type']}")
    print(f"model: {provider['model']}")
    print(f"api base URL: {provider['api_base_url']}")
    print(f"api key: {provider['api_key']}")
    print(f"python: {details['python']['version']} ({'supported' if details['python']['supported'] else 'unsupported'})")
    print(f"opencode: {details['opencode']['status']}")
    print(f"model discovery: {details['model_discovery']}")
    if details["issues"]:
        print("status: warning")
        for issue in details["issues"]:
            print(f"warning [{issue['code']}]: {issue['message']}")
    else:
        print("status: ok")
    return 1 if strict and details["issues"] else 0


def run_maintenance(action: str, version: str | None = None) -> int:
    installer = Path(__file__).with_name("install.sh")
    if not installer.exists():
        raise RuntimeError("Maintenance requires install.sh beside the launcher. Reinstall from a GitHub Release.")
    environment = os.environ.copy()
    environment["OPENCODE_CCSWITCH_INSTALL_DIR"] = str(installer.parent)
    arguments = ["sh", str(installer)]
    if action == "update":
        arguments.extend(["--version", version] if version else ["--latest"])
    else:
        arguments.append("--uninstall")
    return subprocess.call(arguments, env=environment)


def main(argv: list[str]) -> int:
    if sys.version_info < (3, 9):
        raise RuntimeError("Python 3.9 or later is required")
    if argv == ["--version"]:
        print(f"CCSwitch OpenCode Launcher v{__version__}")
        return 0
    if argv and argv[0] in {"update", "uninstall"}:
        action = argv[0]
        if action == "uninstall" and argv[1:]:
            raise RuntimeError("uninstall accepts no options")
        if action == "update":
            version = None
            if len(argv) == 3 and argv[1] in {"--version", "-v"}:
                version = argv[2]
            elif len(argv) != 1:
                raise RuntimeError("update usage: update [--version vX.Y.Z]")
            if version and not re.fullmatch(r"v\d+\.\d+\.\d+", version):
                raise RuntimeError("update version must look like vX.Y.Z")
            return run_maintenance(action, version)
        return run_maintenance(action)
    if argv and argv[0] in {"doctor", "--doctor"}:
        invalid_options = set(argv[1:]) - {"--json", "--strict"}
        if invalid_options:
            raise RuntimeError("doctor accepts only --json and --strict")
        return print_doctor(json_output="--json" in argv[1:], strict="--strict" in argv[1:])
    dry_run = "--dry-run" in argv
    forwarded_args = [arg for arg in argv if arg != "--dry-run"]
    global DB_PATH
    cc_root = Path(os.environ.get("CCSWITCH_HOME", Path.home() / ".cc-switch"))
    DB_PATH = Path(os.environ.get("CCSWITCH_DB", cc_root / "cc-switch.db"))
    settings = read_json(cc_root / "settings.json", {})
    app_type, row = current_provider(settings, os.environ.get("CCSWITCH_APP_TYPE", ""), os.environ.get("CCSWITCH_PROVIDER_ID"))
    runtime = runtime_for(app_type, row, require_key=not dry_run)
    if dry_run:
        runtime["models"].setdefault(runtime["model_id"], {"name": runtime["model_id"]})
        if runtime["effort"]:
            runtime["models"][runtime["model_id"]]["options"] = {"reasoningEffort": runtime["effort"]}
    else:
        discover_models(runtime)

    generated = generated_config(runtime, str(row["name"]))
    if dry_run:
        print(json.dumps(generated, ensure_ascii=False, indent=2))
        return 0

    custom_config = os.environ.get("OPENCODE_GENERATED_CONFIG")
    temporary = not custom_config
    if custom_config:
        config_path = Path(custom_config)
    else:
        descriptor, temporary_path = tempfile.mkstemp(prefix="ccswitch-opencode-", suffix=".json")
        os.close(descriptor)
        config_path = Path(temporary_path)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        config_path.write_text(json.dumps(generated, ensure_ascii=False, indent=2), encoding="utf-8")
        executable = shutil.which("opencode")
        if not executable:
            raise RuntimeError("OpenCode was not found on PATH")
        env = os.environ.copy()
        env["CCSWITCH_OPENCODE_API_KEY"] = runtime["api_key"]
        env["OPENCODE_CONFIG"] = str(config_path)
        print(f"CCSwitch [{app_type}] provider: {row['name']} | model: {runtime['model_id']}", flush=True)
        command = [executable]
        if not any(arg == "--model" or arg.startswith("--model=") for arg in forwarded_args):
            command.extend(["--model", f"ccswitch/{runtime['model_id']}"])
        command.extend(forwarded_args)
        return subprocess.call(command, env=env)
    finally:
        if temporary:
            try:
                config_path.unlink()
            except (FileNotFoundError, PermissionError):
                pass


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except RuntimeError as exc:
        print(f"ccswitch-opencode: {exc}", file=sys.stderr)
        raise SystemExit(1)
