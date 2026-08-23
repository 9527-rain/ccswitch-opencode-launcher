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
    if parsed.scheme != "https" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise RuntimeError("API base URL must use HTTPS (HTTP is allowed only for localhost)")
    return value_


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


def print_doctor() -> int:
    global DB_PATH
    cc_root = Path(os.environ.get("CCSWITCH_HOME", Path.home() / ".cc-switch"))
    DB_PATH = Path(os.environ.get("CCSWITCH_DB", cc_root / "cc-switch.db"))
    settings = read_json(cc_root / "settings.json", {})
    app_type, row = current_provider(settings, os.environ.get("CCSWITCH_APP_TYPE", ""), os.environ.get("CCSWITCH_PROVIDER_ID"))
    runtime = runtime_for(app_type, row, require_key=False)
    validate_discovery_mode(os.environ.get("CCSWITCH_MODEL_DISCOVERY", "never"))
    print(f"provider: {row['name']}")
    print(f"app type: {app_type}")
    print(f"model: {runtime['model_id']}")
    print(f"api base URL: {runtime['base_url']}")
    print(f"api key: {'configured' if runtime['api_key'] else 'missing'}")
    print(f"opencode: {'found' if shutil.which('opencode') else 'missing'}")
    print(f"model discovery: {os.environ.get('CCSWITCH_MODEL_DISCOVERY', 'never')}")
    return 0


def main(argv: list[str]) -> int:
    if argv and argv[0] in {"doctor", "--doctor"}:
        return print_doctor()
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

    options = safe_options(runtime["config"], runtime["base_url"])
    generated = {
        "$schema": "https://opencode.ai/config.json",
        "provider": {"ccswitch": {"npm": runtime["npm"], "name": f"CCSwitch: {row['name']}", "options": options, "models": runtime["models"]}},
        "model": f"ccswitch/{runtime['model_id']}",
    }
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
        return subprocess.call([executable, *forwarded_args], env=env)
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
