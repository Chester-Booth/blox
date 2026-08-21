#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import subprocess
import sys
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parent
DEFAULT_CONTRACT = SCRIPT_ROOT / "contracts" / "status.json"
TYPE_CHECKS = {
    "array": lambda value: isinstance(value, list),
    "boolean": lambda value: isinstance(value, bool),
    "null": lambda value: value is None,
    "number": lambda value: isinstance(value, (int, float)) and not isinstance(value, bool),
    "object": lambda value: isinstance(value, dict),
    "string": lambda value: isinstance(value, str),
}


def type_matches(value, expected):
    if isinstance(expected, list):
        return any(type_matches(value, item) for item in expected)
    return TYPE_CHECKS[expected](value)


def type_name(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def expected_name(expected):
    if isinstance(expected, list):
        return "|".join(expected)
    return expected


def validate_fields(label, data, fields, errors):
    for field, expected in fields.items():
        if field not in data:
            errors.append(f"{label}: missing field {field}")
            continue
        if not type_matches(data[field], expected):
            errors.append(f"{label}.{field}: expected {expected_name(expected)}, got {type_name(data[field])}")


def validate_optional(label, data, fields, errors):
    for field, expected in fields.items():
        if field in data and not type_matches(data[field], expected):
            errors.append(f"{label}.{field}: expected {expected_name(expected)}, got {type_name(data[field])}")


def validate_items(label, data, item_specs, errors):
    for field, spec in item_specs.items():
        value = data.get(field)
        if not isinstance(value, list):
            continue

        if isinstance(spec, str):
            for index, item in enumerate(value):
                if not type_matches(item, spec):
                    errors.append(f"{label}.{field}[{index}]: expected {spec}, got {type_name(item)}")
            continue

        for index, item in enumerate(value):
            if not isinstance(item, dict):
                errors.append(f"{label}.{field}[{index}]: expected object, got {type_name(item)}")
                continue
            validate_fields(f"{label}.{field}[{index}]", item, spec, errors)


def validate_children(label, data, child_specs, errors):
    for field, spec in child_specs.items():
        value = data.get(field)
        if not isinstance(value, dict):
            continue
        if "required" in spec:
            validate_fields(f"{label}.{field}", value, spec["required"], errors)
            validate_enum(f"{label}.{field}", value, spec.get("enum", {}), errors)
        else:
            validate_fields(f"{label}.{field}", value, spec, errors)


def validate_enum(label, data, enum_specs, errors):
    for field, allowed in enum_specs.items():
        if field in data and data[field] not in allowed:
            values = ", ".join(allowed)
            errors.append(f"{label}.{field}: expected one of [{values}], got {data[field]!r}")


def command_for(spec):
    today = dt.date.today().isoformat()
    return [str(SCRIPT_ROOT / part) if index == 0 else today if part == "$TODAY" else part
            for index, part in enumerate(spec["command"])]


def run_contract(name, spec, timeout):
    command = command_for(spec)
    result = subprocess.run(command, cwd=SCRIPT_ROOT, text=True, capture_output=True, timeout=timeout)
    if result.returncode != 0:
        stderr = result.stderr.strip()
        return [f"{name}: command exited {result.returncode}" + (f": {stderr}" if stderr else "")]

    output = result.stdout.strip()
    try:
        data = json.loads(output)
    except json.JSONDecodeError as error:
        preview = output[:120].replace("\n", "\\n")
        return [f"{name}: invalid JSON at byte {error.pos}: {preview}"]

    if not isinstance(data, dict):
        return [f"{name}: expected top-level object, got {type_name(data)}"]

    errors = []
    validate_fields(name, data, spec.get("required", {}), errors)
    validate_optional(name, data, spec.get("optional", {}), errors)
    validate_items(name, data, spec.get("items", {}), errors)
    validate_children(name, data, spec.get("children", {}), errors)
    validate_enum(name, data, spec.get("enum", {}), errors)
    return errors


def main():
    parser = argparse.ArgumentParser(description="Validate Quickshell script JSON contracts.")
    parser.add_argument("names", nargs="*", help="Optional contract names to validate.")
    parser.add_argument("--contract", default=DEFAULT_CONTRACT, type=Path)
    parser.add_argument("--timeout", default=20, type=float)
    args = parser.parse_args()

    contracts = json.loads(args.contract.read_text())
    selected = args.names or sorted(contracts)
    unknown = [name for name in selected if name not in contracts]
    if unknown:
        print(f"unknown contracts: {', '.join(unknown)}", file=sys.stderr)
        return 2

    failed = False
    for name in selected:
        try:
            errors = run_contract(name, contracts[name], args.timeout)
        except subprocess.TimeoutExpired:
            errors = [f"{name}: command timed out after {args.timeout:g}s"]

        if errors:
            failed = True
            print(f"fail {name}")
            for error in errors:
                print(f"  {error}")
        else:
            print(f"ok {name}")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
