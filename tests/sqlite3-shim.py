#!/usr/bin/env python3
"""Minimal sqlite3 CLI shim for Windows CI.

It implements the read-only JSON subset used by the PowerShell launcher and
supports `.read <file>` for the integration fixture.
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    args = [arg for arg in argv if arg not in {"-readonly", "-json", "-noheader"}]
    if len(args) < 2:
        print("sqlite3 shim: expected DATABASE QUERY", file=sys.stderr)
        return 2
    database, query = args[0], args[1]
    connection = sqlite3.connect(database)
    try:
        if query.startswith(".read "):
            script_path = Path(query[6:].strip().strip('"'))
            connection.executescript(script_path.read_text(encoding="utf-8-sig"))
            connection.commit()
            return 0
        cursor = connection.execute(query)
        if cursor.description:
            columns = [column[0] for column in cursor.description]
            print(json.dumps([dict(zip(columns, row)) for row in cursor.fetchall()]))
        return 0
    finally:
        connection.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
