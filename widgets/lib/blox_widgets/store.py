"""Atomic profile storage with explicit optimistic concurrency."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from .model import ValidationError, default_profile, parse_profile, validate_profile


MAX_PROFILE_BYTES = 4 * 1024 * 1024


class ConflictError(RuntimeError):
    """The profile changed after the caller read it."""


@dataclass(frozen=True)
class ProfileSnapshot:
    document: dict
    digest: str | None


def profile_path() -> Path:
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "blox" / "widgets.json"


def _encode(document: dict) -> bytes:
    document = validate_profile(document)
    encoded = (json.dumps(document, ensure_ascii=True, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("utf-8")
    if len(encoded) > MAX_PROFILE_BYTES:
        raise ValidationError("profile: JSON document exceeds 4 MiB")
    return encoded


def _check_digest(digest: str | None) -> None:
    if digest is not None and (not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None):
        raise ValidationError("expected digest must be SHA-256 or null for a missing profile")


class ProfileStore:
    def __init__(self, path: str | Path | None = None):
        self.path = Path(path) if path is not None else profile_path()

    def _read_unlocked(self) -> ProfileSnapshot:
        try:
            with self.path.open("rb") as source:
                data = source.read(MAX_PROFILE_BYTES + 1)
        except FileNotFoundError:
            return ProfileSnapshot(default_profile(), None)
        if len(data) > MAX_PROFILE_BYTES:
            raise ValidationError("profile: JSON document exceeds 4 MiB")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValidationError("profile: expected UTF-8 JSON") from error
        return ProfileSnapshot(parse_profile(text), hashlib.sha256(data).hexdigest())

    def read(self) -> ProfileSnapshot:
        """Read an atomic snapshot. A missing file stays missing."""
        return self._read_unlocked()

    @contextmanager
    def _locked(self):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock_path = self.path.with_name(self.path.name + ".lock")
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def _commit(self, encoded: bytes) -> ProfileSnapshot:
        temporary_path = None
        try:
            with tempfile.NamedTemporaryFile(prefix=f".{self.path.name}.", dir=self.path.parent, delete=False) as target:
                temporary_path = Path(target.name)
                target.write(encoded)
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary_path, self.path)
            temporary_path = None
            directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
        return ProfileSnapshot(parse_profile(encoded.decode("utf-8")), hashlib.sha256(encoded).hexdigest())

    def write(self, document: dict, *, expected_digest: str | None) -> ProfileSnapshot:
        """Commit only if the exact bytes previously read are still current."""
        encoded = _encode(document)
        _check_digest(expected_digest)
        with self._locked():
            current = self._read_unlocked()
            if current.digest != expected_digest:
                raise ConflictError("profile changed since it was read; reload before saving")
            return self._commit(encoded)

    def export(self) -> dict:
        """Return the same validated document used for storage and Settings drafts."""
        return self.read().document

    def import_profile(self, document: dict, *, expected_digest: str | None, mode: str) -> ProfileSnapshot:
        """Replace the profile, or append a copy with deterministic collision renaming."""
        imported = validate_profile(document)
        _encode(imported)
        _check_digest(expected_digest)
        if mode not in {"replace", "copy"}:
            raise ValidationError("import mode must be 'replace' or 'copy'")
        with self._locked():
            current = self._read_unlocked()
            if current.digest != expected_digest:
                raise ConflictError("profile changed since it was read; reload before importing")
            if mode == "replace":
                result = imported
            else:
                result = current.document
                used = {item["id"] for item in result["widgets"]}
                # Reserve all incoming ids so a generated name cannot steal a later item's id.
                reserved = used | {item["id"] for item in imported["widgets"]}
                for widget in imported["widgets"]:
                    original = widget["id"]
                    if original in used:
                        number = 1
                        while True:
                            suffix = "-copy" if number == 1 else f"-copy-{number}"
                            candidate = original[:64 - len(suffix)].rstrip("-") + suffix
                            if candidate not in reserved:
                                break
                            number += 1
                        widget["id"] = candidate
                        reserved.add(candidate)
                    used.add(widget["id"])
                    result["widgets"].append(widget)
            return self._commit(_encode(result))
