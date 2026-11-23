"""Apply transaction across named owners, with an evidence-based result.

Owners keep their own action logic. An owner must capture a JSON pre-image,
restore it, and observe the result independently of its apply receipt.
"""
from __future__ import annotations

import copy
from contextlib import ExitStack
import fcntl
import json
import os
import re
import secrets
import stat
from pathlib import Path
from typing import Any, Mapping

from .composition import CompositionDocument, component_digest, mark_managed, observe_component, validate_ledger
from .core import canonical_json


JOURNAL_LIMIT = 4 * 1024 * 1024
EVIDENCE_LIMIT = 16 * 1024
JOURNAL_GROWTH_PER_OWNER = 64 * 1024


class ApplyError(RuntimeError):
    pass


class CoreApplyFailure(ApplyError):
    """A generation, Settings or activation failure requires a full restore."""


class BeforeCoreMutationFailure(ApplyError):
    """The core rejected activation before changing any owned state."""


class BeforeTargetPublicationFailure(ApplyError):
    """Target publication refused before changing its external package or selection."""


class ApplyCoordinator:
    """Serialise Apply and recovery; keep the window protected while busy."""

    def __init__(self, settings, ledger: CompositionDocument, journal_dir: Path,
                 core, owners: Mapping[str, Any]):
        self.settings = settings
        self.ledger = ledger
        self.journal_dir = Path(journal_dir)
        self.core = core
        self.owners = dict(owners)
        self.busy = False
        self.trace: list[dict[str, Any]] = []
        self.event_sink = None

    @staticmethod
    def _evidence(value: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(value, dict) or len(canonical_json(value).encode()) > EVIDENCE_LIMIT:
            raise ApplyError("owner result exceeds the evidence size limit")
        return value

    @staticmethod
    def _message(value: Any) -> str:
        return str(value).encode()[:2048].decode(errors="ignore")

    def _remember_failure(self, dfd: int, record: dict[str, Any], stage: str, error: Exception,
                          target: str | None = None) -> None:
        if 'failureCause' not in record:
            record['failureCause'] = {'stage': stage, 'target': target, 'message': self._message(error)}
            try:
                self._write(dfd, record)
            except (OSError, ApplyError):
                # A failed active-journal publication must still attempt its
                # normal restore. That restore persists the same cause first.
                pass

    def _event(self, stage: str, **details: Any) -> None:
        event = {"stage": stage, **details}
        self.trace.append(event)
        if self.event_sink is not None:
            self.event_sink(event)

    def _release_journal(self, dfd: int) -> None:
        self._write(dfd, None)
        release_history = getattr(self.core, "release_history", None)
        if release_history is not None:
            try:
                release_history()
            except Exception as error:
                # The receipt is already released. A contended publication
                # lock defers pruning rather than inventing recovery work.
                self._event("history-prune-deferred", error=self._message(error))

    def _directory(self) -> int:
        if not self.journal_dir.is_absolute() or ".." in self.journal_dir.parts:
            raise ApplyError("Apply journal path must be absolute without parent traversal")
        dfd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in self.journal_dir.parts[1:]:
                try:
                    nextfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
                except FileNotFoundError:
                    os.mkdir(part, 0o700, dir_fd=dfd)
                    nextfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
                os.close(dfd)
                dfd = nextfd
            info = os.fstat(dfd)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise ApplyError("unsafe Apply journal directory")
            return dfd
        except BaseException:
            os.close(dfd)
            raise

    @staticmethod
    def _read(dfd: int) -> dict[str, Any] | None:
        try:
            fd = os.open("apply.json", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=dfd)
        except FileNotFoundError:
            return None
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size > JOURNAL_LIMIT:
                raise ApplyError("unsafe Apply journal")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                record = json.loads(stream.read(JOURNAL_LIMIT + 1))
            if record.get("version") != 1 or record.get("phase") not in ("pending", "active", "committing", "partial", "complete", "restoring", "aborted"):
                raise ApplyError("invalid Apply journal")
            return record
        finally:
            os.close(fd)

    @staticmethod
    def _write(dfd: int, record: dict[str, Any] | None, filename: str = "apply.json") -> None:
        if record is None:
            os.unlink(filename, dir_fd=dfd)
            os.fsync(dfd)
            return
        payload = canonical_json(record).encode()
        if len(payload) > JOURNAL_LIMIT:
            raise ApplyError("Apply journal exceeds the aggregate size limit")
        if filename != "apply.json":
            try:
                existing = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
            except FileNotFoundError:
                pass
            else:
                try:
                    info = os.fstat(existing)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > JOURNAL_LIMIT:
                        raise ApplyError("unsafe superseded Apply receipt")
                    if os.read(existing, JOURNAL_LIMIT + 1) != payload:
                        raise ApplyError("superseded Apply receipt has changed")
                    return
                finally:
                    os.close(existing)
        name = f".apply-{secrets.token_hex(8)}.tmp"
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        try:
            with os.fdopen(fd, "wb", closefd=False) as stream:
                stream.write(payload)
                stream.flush()
            os.fsync(fd)
        finally:
            os.close(fd)
        try:
            if filename == "apply.json":
                os.replace(name, filename, src_dir_fd=dfd, dst_dir_fd=dfd)
            else:
                os.link(name, filename, src_dir_fd=dfd, dst_dir_fd=dfd, follow_symlinks=False)
            os.fsync(dfd)
        finally:
            try:
                os.unlink(name, dir_fd=dfd)
            except FileNotFoundError:
                pass

    def _lock(self):
        dfd = self._directory()
        try:
            fd = os.open("apply.lock", os.O_RDWR | os.O_NONBLOCK | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
        except BaseException:
            os.close(dfd)
            raise
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) & 0o077:
            os.close(fd)
            os.close(dfd)
            raise ApplyError("unsafe Apply lock")
        fcntl.flock(fd, fcntl.LOCK_EX)
        return dfd, fd

    @staticmethod
    def _unlock(dfd: int, fd: int) -> None:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
        os.close(dfd)

    def _result(self, record: dict[str, Any], code: str, error: str | None = None) -> dict[str, Any]:
        if record['phase'] in ('pending', 'active', 'committing', 'restoring'):
            parts = []
            cause = record.get('failureCause')
            if cause:
                parts.append((cause.get('target') or cause['stage']) + ': ' + cause['message'])
            if record.get('restoreErrors'):
                parts.append('restore incomplete: ' + '; '.join(record['restoreErrors']))
            elif error:
                parts.append(error)
            error = '\n'.join(parts) or error
        targets = copy.deepcopy(record["targets"])
        failed = [name for name, item in targets.items()
                  if item["state"] == "failure" and self.owners[name].can_retry(record["images"][name])]
        partial = record["phase"] == "partial" and bool(record.get("durable"))
        proved_success = any(item["state"] in ("success", "restart", "manual") for item in targets.values())
        activated = record["phase"] in ("active", "partial", "complete")
        can_restore = self.core.can_restore(record["images"]["core"]) and all(
            self.owners[name].can_restore(record["images"][name]) for name in record["selected"]
        )
        return {
            "code": code,
            "error": error,
            "failureCause": record.get('failureCause'),
            "restoreErrors": record.get('restoreErrors', []),
            "transactionId": record["id"],
            "phase": record["phase"],
            "windowProtected": False,
            "themeId": record["request"].get("themeId"),
            "recoveryAvailable": record["phase"] not in ("complete", "partial", "restored"),
            "targets": targets,
            "actions": {
                "retryFailedTargets": failed if partial else [],
                "keepSuccessfulChanges": partial and proved_success,
                "rollBack": activated and can_restore and record["phase"] in ("partial", "complete"),
                "cancel": False,
            },
            "ledgerRevision": self.ledger.read()["revision"],
        }

    def _restore(self, dfd: int, record: dict[str, Any]) -> None:
        before_revision = record["ledgerBefore"]["revision"]
        current_revision = self.ledger.read()["revision"]
        allowed = {before_revision, record.get("ledgerRevision", before_revision),
                   record.get("committingRevision", before_revision)}
        if current_revision not in allowed:
            if record['phase'] not in ('complete', 'partial'):
                record['phase'] = 'restoring'
            record['restoreErrors'] = ['composition changed since Apply; recovery needs review']
            self._write(dfd, record)
            raise ApplyError(record['restoreErrors'][0])
        record["phase"] = "restoring"
        self._write(dfd, record)
        if "settingsAfterRevision" in record:
            current = self.settings.get()
            permitted = {(record["settingsAfterRevision"], record["settingsAfterDigest"])}
            if "settingsBeforeDigest" in record:
                permitted.add((record["settingsBeforeRevision"], record["settingsBeforeDigest"]))
            if not current.ok or (current.revision, component_digest(current.data)) not in permitted:
                record["restoreErrors"] = ["Settings changed since core activation; recovery needs review"]
                self._write(dfd, record)
                raise ApplyError(record["restoreErrors"][0])
        self._event("restore-started")
        errors = []
        for name in reversed(record["selected"]):
            try:
                bind_image = getattr(self.owners[name], "bind_transaction_image", None)
                if bind_image is not None:
                    bind_image(record['images'][name], record['targets'][name])
                self.owners[name].restore(record["images"][name])
                self.owners[name].verify_restored(record["images"][name])
                self._event("owner-restored", target=name)
            except Exception as error:
                errors.append(self._message(f"{name}: {error}"))
        try:
            self.core.restore(record["images"]["core"])
            self.core.verify_restored(record["images"]["core"])
            self._event("core-restored")
        except Exception as error:
            errors.append(self._message(f"core: {error}"))
        if not errors:
            before = record["ledgerBefore"]
            if "ledgerImage" in record:
                self.ledger.restore_preimage(record["ledgerImage"], expected_revision=current_revision)
            elif current_revision != before_revision:
                self.ledger.update(lambda current: dict(before), expected_revision=current_revision)
            self._release_journal(dfd)
            self._event("restore-complete")
        else:
            record["restoreErrors"] = errors
            self._write(dfd, record)
            raise ApplyError("restore incomplete: " + "; ".join(errors))

    def _validate_request(self, request: dict[str, Any], expected_revision: int | None = None):
        if not isinstance(request, dict):
            raise ApplyError("Apply request must be an object")
        if not isinstance(request.get("themeId"), str) or not request["themeId"]:
            raise ApplyError("theme ID is required")
        if not isinstance(request.get("sourceDigest"), str) or not re.fullmatch(r"[0-9a-f]{64}", request["sourceDigest"]):
            raise ApplyError("theme source digest is invalid")
        settings = self.settings.get()
        if not settings.ok:
            raise ApplyError(f"Settings read failed: {settings.code}")
        expected = request.get("settingsRevision") if expected_revision is None else expected_revision
        if settings.revision != expected:
            raise ApplyError("Settings revision conflict")
        selected = [name for name, item in settings.data["targets"].items() if item["enabled"]]
        if request.get("scope") == "widgets":
            if "widgets" not in selected:
                raise ApplyError("saved target is disabled: widgets")
            selected = ["widgets"]
        elif "scope" in request:
            raise ApplyError("unknown Apply scope")
        if not selected:
            raise ApplyError("no targets are enabled")
        missing = set(selected) - set(self.owners)
        if missing:
            raise ApplyError("target owner unavailable: " + ", ".join(sorted(missing)))
        if set(request.get("components", {})) != set(selected):
            raise ApplyError("request components differ from saved target selection")
        if not isinstance(request.get("approvals"), dict):
            raise ApplyError("file approvals are required")
        for path, digest in request["approvals"].items():
            if not isinstance(path, str) or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ApplyError("invalid file approval")
            source = Path(path)
            info = source.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ApplyError("approved file is unsafe")
            import hashlib
            if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
                raise ApplyError("approved file changed")
        self.core.validate(request, settings.data, selected)
        for name in selected:
            self.owners[name].validate(request, settings.data)
            component = request["components"][name]
            if component != self.owners[name].component_id:
                raise ApplyError(f"component owner mismatch: {name}")
            if component not in self.ledger.read()["components"]:
                raise ApplyError(f"unknown component: {component}")
        # A dependent owner cannot safely run after a target has failed.
        selected.sort(key=lambda name: bool(self.owners[name].independent))
        return settings, selected

    def _verify_journal(self, record: dict[str, Any]) -> None:
        if not isinstance(record.get("id"), str) or not re.fullmatch(r"[0-9a-f]{24}", record["id"]):
            raise ApplyError("invalid Apply transaction identity")
        selected = record.get("selected")
        if not isinstance(selected, list) or len(selected) != len(set(selected)) or set(selected) - set(self.owners):
            raise ApplyError("Apply journal names unknown owners")
        if not isinstance(record.get("images"), dict) or set(record["images"]) != set(selected) | {"core"}:
            raise ApplyError("Apply journal has incomplete pre-images")
        if not isinstance(record.get("targets"), dict) or set(record["targets"]) != set(selected):
            raise ApplyError("Apply journal has incomplete target results")
        validate_ledger(record["ledgerBefore"])
        if "ledgerImage" in record:
            prior = self.ledger.validate_preimage(record["ledgerImage"])
            if prior is not None and prior != record["ledgerBefore"]:
                raise ApplyError("composition pre-image differs from its journal")
        self.core.validate_image(record["images"]["core"])
        for name in selected:
            self.owners[name].validate_image(record["images"][name])

    def _verify_current(self, record: dict[str, Any]) -> None:
        if self.ledger.read()["revision"] != record["ledgerRevision"]:
            raise ApplyError("composition changed since Apply")
        settings = self.settings.get()
        if not settings.ok or settings.revision != record["settingsAfterRevision"] or component_digest(settings.data) != record["settingsAfterDigest"]:
            raise ApplyError("Settings changed since Apply")
        if self.core.observe() != record["coreObservation"]:
            raise ApplyError("core changed since Apply")
        for name in record["selected"]:
            item = record["targets"][name]
            owner = self.owners[name]
            if item["state"] == "failure":
                owner.verify_restored(record["images"][name])
            else:
                observed = owner.observe()
                if observed.get("digest") != item["observedDigest"] or observed.get("revision") != item["revision"]:
                    raise ApplyError(f"{name} changed since Apply")

    def apply(self, request: dict[str, Any]) -> dict[str, Any]:
        dfd, fd = self._lock()
        self.busy = True
        self.trace = []
        settings_guard = ExitStack()
        try:
            if self._read(dfd) is not None:
                raise ApplyError("previous Apply requires recovery or a decision")
            request = copy.deepcopy(request)
            if request.get("scope") == "widgets":
                settings_guard.enter_context(self.settings._locked_dir())
            settings, selected = self._validate_request(request)
            ledger_before = self.ledger.read()
            ledger_image = self.ledger.capture_preimage()
            captured = self.ledger.validate_preimage(ledger_image)
            if captured is not None and captured != ledger_before:
                raise ApplyError("composition changed during Apply capture")
            images = {"core": self.core.capture()}
            self.core.validate_image(images["core"])
            if not self.core.can_restore(images["core"]):
                raise ApplyError("core pre-image cannot be restored")
            for name in selected:
                images[name] = self.owners[name].capture()
                self.owners[name].validate_image(images[name])
                if not self.owners[name].can_restore(images[name]):
                    raise ApplyError(f"target pre-image cannot be restored: {name}")
            record = {
                "version": 1, "id": secrets.token_hex(12), "phase": "pending",
                "selected": selected, "images": images, "ledgerBefore": ledger_before, "ledgerImage": ledger_image,
                "request": request, "durable": False,
                "settingsBeforeRevision": settings.revision,
                "settingsBeforeDigest": component_digest(settings.data),
                "targets": {name: {"state": "pending", "message": "", "component": request["components"][name],
                                   "observedDigest": None, "revision": None, "generationId": None} for name in selected},
            }
            # Reserve bounded evidence and recovery errors before any owner writes.
            reserved = JOURNAL_GROWTH_PER_OWNER * (len(selected) + 2)
            if len(canonical_json(record).encode()) + reserved > JOURNAL_LIMIT:
                raise ApplyError("Apply pre-images exceed the aggregate journal size limit")
            # This fsynced record is the boundary before any owner mutates state.
            self._write(dfd, record)
            self._event("journal-durable")
            try:
                record["coreStarted"] = True
                self._write(dfd, record)
                receipt = self._evidence(self.core.apply(request))
                if "settingsDigest" in receipt:
                    record["settingsAfterRevision"] = receipt["revision"]
                    record["settingsAfterDigest"] = receipt["settingsDigest"]
                    self._write(dfd, record)
                self.core.verify(request)
                observed = self._evidence(self.core.observe())
                if observed.get("digest") != receipt.get("digest") or observed.get("revision") != receipt.get("revision"):
                    raise ApplyError("core observation differs from apply receipt")
                record["coreObservation"] = observed
                current_settings = self.settings.get()
                if not current_settings.ok:
                    raise ApplyError("Settings observation failed after core activation")
                if "settingsAfterRevision" in record:
                    if (current_settings.revision != record["settingsAfterRevision"]
                            or component_digest(current_settings.data) != record["settingsAfterDigest"]):
                        raise ApplyError("Settings changed after core activation")
                else:
                    record["settingsAfterRevision"] = current_settings.revision
                    record["settingsAfterDigest"] = component_digest(current_settings.data)
                self._event("core-verified")
            except Exception as error:
                self._remember_failure(dfd, record, 'core', error)
                self._event("core-failed", error=str(error))
                if isinstance(error, BeforeCoreMutationFailure):
                    # Persist the no-mutation decision before release. Cold
                    # recovery must not restore captures over a competing edit.
                    record["phase"] = "aborted"
                    self._write(dfd, record)
                    self._release_journal(dfd)
                    result = self._result(record, "before-write-failure", self._message(error))
                    result.update(phase="none", journalReleased=True, recoveryAvailable=False)
                    return result
                self._restore(dfd, record)
                record["phase"] = "restored"
                for item in record["targets"].values():
                    item["state"] = "unchanged"
                    item["message"] = "Restored pre-image"
                return self._result(record, "core-failure", str(error))
            record["phase"] = "active"
            try:
                self._write(dfd, record)
                return self._apply_targets(dfd, record, selected)
            except Exception as error:
                self._remember_failure(dfd, record, 'targets', error)
                self._restore(dfd, record)
                raise
        finally:
            self.busy = False
            settings_guard.close()
            self._unlock(dfd, fd)

    def _apply_targets(self, dfd: int, record: dict[str, Any], names: list[str]) -> dict[str, Any]:
        record.pop("localImages", None)
        request = record["request"]
        publication_conflict = False
        for name in names:
            owner = self.owners[name]
            item = record["targets"][name]
            local_image = None
            try:
                bind_image = getattr(owner, "bind_transaction_image", None)
                if bind_image is not None:
                    bind_image(record["images"][name], item)
                local_image = owner.capture()
                owner.validate_image(local_image)
                if not owner.can_restore(local_image):
                    raise CoreApplyFailure(f"target pre-image cannot be restored: {name}")
                # Local rollback is immediate. Cold recovery uses the original
                # transaction image, so do not duplicate this image on disk.
                receipt = self._evidence(owner.apply(request))
                observed = self._evidence(owner.observe())
                if observed.get("digest") != receipt.get("digest") or observed.get("revision") != receipt.get("revision"):
                    raise ApplyError("owner observation differs from apply receipt")
                state = receipt.get("state")
                if state not in ("success", "unchanged", "restart", "manual"):
                    raise ApplyError("owner returned an unsupported result state")
                item.update(state=state, message=self._message(receipt.get("message", "")),
                            observedDigest=observed["digest"], revision=observed["revision"],
                            generationId=receipt.get("generationId"))
                item.pop('publicationConflict', None)
                self._event("target-result", target=name, state=state)
            except Exception as error:
                self._remember_failure(dfd, record, 'target', error, name)
                if isinstance(error, BeforeTargetPublicationFailure):
                    publication_conflict = True
                    item.update(state='failure', message=self._message(error), observedDigest=None,
                                revision=None, generationId=None, publicationConflict=True)
                    self._write(dfd, record)
                    try:
                        owner.restore_before_publication_failure(local_image)
                    except Exception as restore_error:
                        record['phase'] = 'restoring'
                        record['restoreErrors'] = [self._message(f'{name}: {restore_error}')]
                        item.update(state='failure', message=self._message(error), observedDigest=None,
                                    revision=None, generationId=None)
                        self._write(dfd, record)
                        return self._result(record, 'rollback-failure', record['restoreErrors'][0])
                elif not owner.independent or isinstance(error, CoreApplyFailure):
                    self._event("dependent-target-failed", target=name, error=str(error))
                    self._restore(dfd, record)
                    record["phase"] = "restored"
                    for prior in record["targets"].values():
                        prior["state"] = "unchanged"
                        prior["message"] = "Restored pre-image"
                    return self._result(record, "core-failure", f"{name}: {error}")
                else:
                    try:
                        if local_image is None:
                            raise ApplyError("owner pre-image capture failed")
                        owner.restore(local_image)
                        owner.verify_restored(local_image)
                    except Exception as restore_error:
                        self._restore(dfd, record)
                        record["phase"] = "restored"
                        for prior in record["targets"].values():
                            prior["state"] = "unchanged"
                            prior["message"] = "Restored pre-image"
                        return self._result(record, "core-failure", f"{name}: {error}; restore: {restore_error}")
                item.update(state="failure", message=self._message(error), observedDigest=None,
                            revision=None, generationId=None)
                self._event("target-result", target=name, state="failure")
            self._write(dfd, record)
        ledger = self.ledger.read()
        by_component: dict[str, list[tuple[str, dict[str, Any]]]] = {}
        for name, item in record["targets"].items():
            by_component.setdefault(item["component"], []).append((name, item))
        for component, members in by_component.items():
            states = {item["state"] for _, item in members}
            if "failure" in states:
                ledger = observe_component(ledger, component, digest=None)
                continue
            evidence = {name: {"digest": item["observedDigest"], "revision": item["revision"]}
                        for name, item in members}
            digest = component_digest(evidence)
            if states.issubset({"success", "unchanged"}):
                generations = {item["generationId"] for _, item in members}
                revisions = {item["revision"] for _, item in members}
                ledger = mark_managed(ledger, component, theme_id=request["themeId"],
                                      source_digest=request["sourceDigest"],
                                      generation_id=next(iter(generations)) if len(generations) == 1 else None,
                                      revision=next(iter(revisions)) if len(revisions) == 1 else None,
                                      digest=digest)
            else:
                ledger = observe_component(ledger, component, digest=digest, state="pending")
        record["phase"] = "committing"
        record["committingRevision"] = self.ledger.read()["revision"] + 1
        self._write(dfd, record)
        saved = self.ledger.update(lambda current: ledger, expected_revision=self.ledger.read()["revision"])
        record["durable"] = True
        record["phase"] = "partial" if any(item["state"] == "failure" for item in record["targets"].values()) else "complete"
        record["ledgerRevision"] = saved["revision"]
        self._write(dfd, record)
        self._event("ledger-committed", revision=saved["revision"])
        if publication_conflict:
            try:
                self._verify_current(record)
            except Exception as error:
                result = self._result(record, 'observation-conflict', self._message(error))
                result['observationConflict'] = True
                result['actions'] = {'retryFailedTargets': [], 'keepSuccessfulChanges': False,
                                     'rollBack': False, 'cancel': False, 'abandonSuperseded': True}
                return result
        return self._result(record, "partial" if record["phase"] == "partial" else "ok")

    def retry_failed_targets(self) -> dict[str, Any]:
        dfd, fd = self._lock()
        self.busy = True
        self.trace = []
        settings_guard = ExitStack()
        try:
            record = self._read(dfd)
            if record is None or record["phase"] != "partial" or not record["durable"]:
                raise ApplyError("no durable partial Apply to retry")
            if record["request"].get("scope") == "widgets":
                settings_guard.enter_context(self.settings._locked_dir())
            self._verify_journal(record)
            self._validate_request(record["request"], record["settingsAfterRevision"])
            self._verify_current(record)
            failed = [name for name in record["selected"] if record["targets"][name]["state"] == "failure"
                      and self.owners[name].can_retry(record["images"][name])]
            if not failed:
                raise ApplyError("no failed target has a safe retry")
            record.pop("localImages", None)
            if len(canonical_json(record).encode()) + JOURNAL_GROWTH_PER_OWNER * (len(failed) + 2) > JOURNAL_LIMIT:
                raise ApplyError("Apply journal exceeds the recovery size budget")
            self._event("retry-started", targets=failed)
            try:
                return self._apply_targets(dfd, record, failed)
            except Exception:
                self._restore(dfd, record)
                raise
        finally:
            self.busy = False
            settings_guard.close()
            self._unlock(dfd, fd)

    def finish(self) -> dict[str, Any]:
        """Release a valid terminal receipt without changing any current owner."""
        dfd, fd = self._lock()
        try:
            record = self._read(dfd)
            if record is None or record["phase"] not in ("complete", "restored"):
                raise ApplyError("Apply still requires recovery or a partial-commit decision")
            self._verify_journal(record)
            conflict = None
            if record["phase"] == "complete":
                try:
                    self._verify_current(record)
                except Exception as error:
                    # Acknowledgement releases only this terminal receipt. It
                    # neither restores nor adopts the state that superseded it.
                    conflict = str(error)
            result = self._result(record, "finished")
            if conflict is not None:
                result["observationConflict"] = True
                result["observationConflictMessage"] = conflict
            self._release_journal(dfd)
            result["journalReleased"] = True
            result["actions"] = {"retryFailedTargets": [], "keepSuccessfulChanges": False, "rollBack": False, "cancel": False}
            return result
        finally:
            self._unlock(dfd, fd)

    def keep_successful_changes(self) -> dict[str, Any]:
        dfd, fd = self._lock()
        self.busy = True
        try:
            record = self._read(dfd)
            if record is None or record["phase"] != "partial" or not record["durable"] or not any(
                item["state"] in ("success", "restart", "manual") for item in record["targets"].values()
            ):
                raise ApplyError("no proved partial commit to keep")
            self._verify_journal(record)
            self._verify_current(record)
            result = self._result(record, "kept")
            self._release_journal(dfd)
            result["actions"] = {"retryFailedTargets": [], "keepSuccessfulChanges": False, "rollBack": False, "cancel": False}
            return result
        finally:
            self.busy = False
            self._unlock(dfd, fd)

    def status(self) -> dict[str, Any] | None:
        """Recheck offered actions against the durable journal and observations."""
        dfd, fd = self._lock()
        try:
            record = self._read(dfd)
            if record is None:
                return None
            self._verify_journal(record)
            if record["phase"] in ("partial", "complete"):
                try:
                    self._verify_current(record)
                except Exception as error:
                    # A terminal receipt can outlive the state it describes.
                    # Report that conflict without offering restoration actions.
                    result = self._result(record, "observation-conflict", str(error))
                    result["observationConflict"] = True
                    result["actions"] = {"retryFailedTargets": [], "keepSuccessfulChanges": False,
                                         "rollBack": False, "cancel": False}
                    if record["phase"] == "partial":
                        result["actions"]["abandonSuperseded"] = True
                    return result
            code = "partial" if record["phase"] == "partial" else "ok" if record["phase"] == "complete" else "recovery-required"
            return self._result(record, code)
        finally:
            self._unlock(dfd, fd)

    def abandon_superseded_partial(self) -> dict[str, Any]:
        """Record a superseded partial outcome and release only its receipt."""
        dfd, fd = self._lock()
        try:
            record = self._read(dfd)
            if record is None or record["phase"] != "partial" or not record.get("durable"):
                raise ApplyError("no superseded partial Apply to dismiss")
            self._verify_journal(record)
            try:
                self._verify_current(record)
            except Exception as error:
                conflict = self._message(error)
            else:
                raise ApplyError("partial Apply is current; choose Retry, Keep or Roll back")
            receipt = {"version": 1, "transactionId": record["id"], "code": "superseded-partial",
                       "themeId": record["request"].get("themeId"), "error": conflict,
                       "restorationAttempted": False,
                       "targets": {name: {key: item[key] for key in ("state", "message", "component")}
                                   for name, item in record["targets"].items()}}
            # Persist its failure outcome before removing the recovery receipt.
            self._write(dfd, receipt, "superseded-" + record["id"] + ".json")
            result = self._result(record, "abandoned", conflict)
            result["journalReleased"] = True
            result["observationConflict"] = True
            result["actions"] = {"retryFailedTargets": [], "keepSuccessfulChanges": False,
                                 "rollBack": False, "cancel": False}
            self._release_journal(dfd)
            return result
        finally:
            self._unlock(dfd, fd)

    def roll_back(self) -> dict[str, Any]:
        dfd, fd = self._lock()
        self.busy = True
        try:
            record = self._read(dfd)
            if record is None or record["phase"] not in ("partial", "complete"):
                raise ApplyError("rollback requires an activated Apply")
            self._verify_journal(record)
            self._verify_current(record)
            if not self.core.can_restore(record["images"]["core"]) or any(
                not self.owners[name].can_restore(record["images"][name]) for name in record["selected"]
            ):
                raise ApplyError("rollback is no longer safe")
            self._restore(dfd, record)
            record["phase"] = "restored"
            for item in record["targets"].values():
                item["state"] = "unchanged"
                item["message"] = "Restored pre-image"
                item["observedDigest"] = None
            return self._result(record, "rolled-back")
        finally:
            self.busy = False
            self._unlock(dfd, fd)

    def recover(self) -> bool:
        """Cold-start recovery does not repeat activation or owner actions."""
        dfd, fd = self._lock()
        self.busy = True
        try:
            record = self._read(dfd)
            if record is None or record["phase"] in ("partial", "complete"):
                return False
            self._verify_journal(record)
            if record["phase"] == "aborted":
                self._release_journal(dfd)
                return True
            no_mutation = getattr(self.core, "no_mutation_since_capture", None)
            if (record["phase"] == "pending" and no_mutation is not None
                    and all(item["state"] == "pending" for item in record["targets"].values())
                    and no_mutation(record["images"]["core"])):
                record["phase"] = "aborted"
                self._write(dfd, record)
                self._release_journal(dfd)
                return True
            self.core.force_restore_reload = bool(record.get("coreStarted") or record.get("restoreErrors"))
            try:
                self._restore(dfd, record)
            finally:
                self.core.force_restore_reload = False
            return True
        finally:
            self.busy = False
            self._unlock(dfd, fd)
