"""Coordinate durable Pi runs while the owning agentxd holds its root lock."""
import datetime
import hashlib
import re
import threading
import time
import uuid

from agentxd_pi import PiProcess


ACTIVE = {"running", "cancelling"}
ID = re.compile(r"[A-Za-z0-9_-]{1,100}")
APPLE_EPOCH = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc).timestamp()


def now():
    return time.time() - APPLE_EPOCH


class CommandError(Exception):
    def __init__(self, status, reason):
        super().__init__(reason)
        self.status = status
        self.reason = reason


def validate_pi_binding(config):
    required = {"instanceID", "providerID", "model", "baseURL", "systemPrompt"}
    if (not isinstance(config, dict) or set(config) != required
            or not all(isinstance(v, str) for v in config.values())
            or not ID.fullmatch(config["instanceID"])
            or not ID.fullmatch(config["providerID"])
            or len(config["systemPrompt"].encode()) > 100_000):
        raise ValueError("invalid Pi binding")


class PilotRuns:
    def __init__(self, store, bundle, factory=PiProcess):
        self.store = store
        self.config = store.config.get("pi")
        self.bundle = bundle
        self.factory = factory
        self.workers = {}
        self.closing = False
        if self.config is not None:
            validate_pi_binding(self.config)
        store.recover_audit()
        # The root lock excludes the previous service, but cannot attest to its child's exit.
        for run in store.list_runs():
            if run.get("pilotCreateKey") and run.get("status") in ACTIVE:
                self._patch(run["id"], status="failed", stopEvidence="unverified", endedAt=now(),
                            requiresProcessReview=True, failure="服务已重启，旧 Pi 进程的退出尚未确认。")

    def _patch(self, run_id, *, flush_audit=True, **changes):
        with self.store.lock:
            run = self.store.get(run_id)
            return self.store.update(run_id, run["revision"], changes, flush_audit=flush_audit)[1]

    @staticmethod
    def key_digest(key):
        if not isinstance(key, str) or not re.fullmatch(r"[a-zA-Z0-9_.:-]{1,128}", key):
            raise CommandError(400, "invalid_idempotency_key")
        return hashlib.sha256(key.encode()).hexdigest()

    def create(self, key, body):
        digest = self.key_digest(key)
        if (not isinstance(body, dict) or set(body) != {"instanceId", "prompt"}
                or not isinstance(body["instanceId"], str) or not ID.fullmatch(body["instanceId"])
                or not isinstance(body["prompt"], str) or not body["prompt"].strip()
                or len(body["prompt"].encode()) > 100_000):
            raise CommandError(400, "invalid_run")
        run_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "agentxd/" + self.store.app + "/" + digest))
        with self.store.lock:
            try:
                existing = self.store.get(run_id)
            except FileNotFoundError:
                existing = None
            if existing is not None:
                if (existing.get("pilotCreateKey") != digest or existing["prompt"] != body["prompt"]
                        or existing["instanceID"] != body["instanceId"]):
                    raise CommandError(409, "idempotency_conflict")
                return 200, existing
            config = self.config
            if self.closing or not config or not self.bundle:
                raise CommandError(503, "pi_unavailable")
            self.store.recover_audit()
            if (self.factory is PiProcess and self.store.audit is None) or any(
                    r.get("auditStatus") == "pending" for r in self.store.list_runs()):
                raise CommandError(503, "audit_unavailable")
            instance = config["instanceID"]
            if body["instanceId"] != instance:
                raise CommandError(422, "unbound_instance")
            member = self.store.directory.parent / "instances" / instance / "config/agent.yaml"
            if member.resolve() != member or not member.is_file():
                raise CommandError(422, "unbound_instance")
            runs = [r for r in self.store.list_runs() if r.get("instanceID") == instance]
            if any(r.get("status") in ACTIVE or r.get("requiresProcessReview") for r in runs):
                raise CommandError(409, "instance_busy")
            messages = [{"role": "system", "content": config["systemPrompt"]}]
            history = sorted((r for r in runs if r.get("status") == "completed" and not r.get("purpose")
                              and all(key in r for key in ("startedAt", "prompt", "response"))),
                             key=lambda r: (r["startedAt"], r["id"]))
            for turn in history[-20:]:
                messages.extend([{"role": "user", "content": turn["prompt"]},
                                 {"role": "assistant", "content": turn["response"]}])
            messages.append({"role": "user", "content": body["prompt"]})
            try:
                child = self.factory(self.bundle, config["baseURL"], config["model"], messages)
            except ValueError:
                raise CommandError(422, "invalid_pi_configuration_or_context") from None
            run = dict(id=run_id, appID=self.store.app, instanceID=instance, prompt=body["prompt"],
                       status="running", response="", isRead=False, startedAt=now(), revision=1,
                       pilotCreateKey=digest, runtimeCore="pi-agent-core",
                       actualProviderID=config["providerID"], actualModel=config["model"])
            if self.store.audit is not None:
                run["auditContext"] = dict(providerId=config["providerID"], model=config["model"],
                                           promptBytes=len(body["prompt"].encode()),
                                           requestTextBytes=sum(len(m["content"].encode()) for m in messages))
            self.store.insert(run)
            if run.get("auditStatus") == "pending":
                self._patch(run_id, status="failed", endedAt=now(),
                            failure="开始审计尚未确认，未启动 Pi。")
                raise CommandError(503, "audit_unavailable")
            thread = threading.Thread(target=self._execute, args=(run_id, child), name="agentxd-pi")
            self.workers[run_id] = (child, thread)
            try:
                thread.start()
            except RuntimeError:
                self.workers.pop(run_id)
                return 201, self._patch(run_id, status="failed", stopEvidence="unverified", endedAt=now(),
                                        failure="无法启动 Pi 执行线程。")
            return 201, run

    def _execute(self, run_id, child):
        receipt = None
        def launched(identity):
            nonlocal receipt
            self._patch(run_id, processEvidence=identity)
            receipt = identity
        try:
            result = child.run(launched)
            exit_info = result.get("processEvidence", {})
            if result.get("stopEvidence") == "confirmedExited" and not (
                    receipt and receipt.get("launchID") and receipt.get("childPID")
                    and receipt["launchID"] == exit_info.get("launchID")
                    and receipt["childPID"] == exit_info.get("childPID")
                    and exit_info.get("reaped") is True and type(exit_info.get("exitCode")) is int):
                result = dict(result, status="failed", stopEvidence="unverified",
                              failure="Pi 退出凭据与启动记录不匹配。", requiresProcessReview=True)
        except Exception:
            result = dict(status="failed", stopEvidence="unverified", failure="Pi 运行结果未能确认。",
                          requiresProcessReview=bool(receipt))
        with self.store.lock:
            try:
                self._patch(run_id, endedAt=now(), **result)
            finally:
                self.workers.pop(run_id, None)

    def stop(self, run_id, key):
        digest = self.key_digest(key)
        with self.store.lock:
            run = self.store.get(run_id)
            if not run.get("pilotCreateKey"):
                raise CommandError(409, "not_a_service_execution")
            if run["status"] not in ACTIVE:
                return 200, run
            if run["status"] == "cancelling":
                return 202, run
            owned = self.workers.get(run_id)
            if owned is None:
                raise CommandError(409, "unverified_owner")
            try:
                pending = self._patch(run_id, flush_audit=False, status="cancelling", stopEvidence="pending",
                                      stopRequestedAt=now(), pilotStopKey=digest)
            finally:
                owned[0].request_stop()
            return 202, self.store.flush_audit(pending)

    def close(self):
        with self.store.lock:
            self.closing = True
            owned = list(self.workers.items())
            for run_id, (child, _) in owned:
                try:
                    self.stop(run_id, "service-shutdown")
                except (OSError, ValueError, KeyError, CommandError):
                    child.request_stop()
        for _, (_, thread) in owned:
            thread.join()
