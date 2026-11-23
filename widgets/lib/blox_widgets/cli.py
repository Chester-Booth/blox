"""JSON command interface for the standalone Settings editor.

Run with PYTHONPATH=widgets/lib python -m blox_widgets.cli --path FILE read.
Writes require --expected-digest HASH, or --expected-digest missing after an absent-file read.
Input comes from --file FILE or stdin. Import always requires an explicit --mode replace|copy.
Export writes the raw portable document to stdout; other successes use a JSON response envelope.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from .model import ValidationError, catalogue, default_widget, parse_profile
from .store import ConflictError, MAX_PROFILE_BYTES, ProfileSnapshot, ProfileStore
from .registry import scan_registry


def _input(path: str | None) -> dict:
    if path is None:
        data = sys.stdin.buffer.read(MAX_PROFILE_BYTES + 1)
    else:
        with Path(path).open("rb") as source:
            data = source.read(MAX_PROFILE_BYTES + 1)
    if len(data) > MAX_PROFILE_BYTES:
        raise ValidationError("profile: JSON document exceeds 4 MiB")
    try:
        return parse_profile(data.decode("utf-8"))
    except UnicodeDecodeError as error:
        raise ValidationError("profile: expected UTF-8 JSON") from error


def _snapshot(snapshot: ProfileSnapshot) -> dict:
    return {"ok": True, "profile": snapshot.document, "digest": snapshot.digest}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read and edit fresh Blox widget profiles")
    parser.add_argument("--path", help="profile path; defaults to XDG_CONFIG_HOME/blox/widgets.json")
    commands = parser.add_subparsers(dest="operation", required=True)
    for name in ("read", "export", "catalogue"):
        commands.add_parser(name)
    registry = commands.add_parser("registry", help="discover explicitly installed trusted QML packages")
    registry.add_argument("--root", help="package directory; defaults to XDG_DATA_HOME/blox-user/widgets")
    default = commands.add_parser("default")
    default.add_argument("kind")
    default.add_argument("id")
    for name in ("validate", "write", "import"):
        command = commands.add_parser(name)
        command.add_argument("--file", help="input JSON file; otherwise stdin")
        if name != "validate":
            command.add_argument("--expected-digest", required=True)
        if name == "import":
            command.add_argument("--mode", choices=("replace", "copy"), required=True)
    args = parser.parse_args(argv)
    try:
        store = ProfileStore(args.path)
        if args.operation == "read":
            response = _snapshot(store.read())
        elif args.operation == "export":
            response = store.export()
        elif args.operation == "catalogue":
            response = {"ok": True, "catalogue": catalogue()}
        elif args.operation == "registry":
            response = {"ok": True, **scan_registry(args.root)}
        elif args.operation == "default":
            response = {"ok": True, "widget": default_widget(args.kind, args.id)}
        else:
            document = _input(args.file)
            if args.operation == "validate":
                response = {"ok": True, "profile": document}
            else:
                digest = None if args.expected_digest == "missing" else args.expected_digest
                snapshot = store.write(document, expected_digest=digest) if args.operation == "write" else store.import_profile(document, expected_digest=digest, mode=args.mode)
                response = _snapshot(snapshot)
        code = 0
    except (ValidationError, ConflictError, OSError) as error:
        category = "conflict" if isinstance(error, ConflictError) else "validation" if isinstance(error, ValidationError) else "io"
        response = {"ok": False, "error": {"type": category, "message": str(error)}}
        code = 3 if category == "conflict" else 2
    print(json.dumps(response, ensure_ascii=True, allow_nan=False))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
