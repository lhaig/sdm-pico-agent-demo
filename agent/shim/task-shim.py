#!/usr/bin/env python3
"""
task-shim.py — the missing "send the agent a task" endpoint.

WHY THIS EXISTS
---------------
`picoclaw gateway` serves /health, /ready, /reload and channel webhooks. There
is no REST API for submitting a task (build plan section 4.3, item 3). The
supported ways to hand PicoClaw work are:

  * `picoclaw agent -m "..."`     shell, immediate
  * HEARTBEAT.md                  minimum 5-minute interval — far too slow for
                                  a live demo
  * `picoclaw cron`               scheduled, same problem

So this is a ~200-line stdlib HTTP listener that accepts an incident payload and
shells out to `picoclaw agent -m`. It is the target of both trigger paths:

  scripts/break-it.sh      -> Grafana alert -> webhook -> here   (realistic)
  scripts/trigger-agent.sh -> straight here                      (stage path)

From the audience's seat the two are indistinguishable, which is the point:
you never stand in front of a customer waiting on the metric pipeline.

SECURITY
--------
Binds 127.0.0.1 by default. If you need to accept the real Grafana Alerting
webhook you must bind 0.0.0.0 and restrict the security group to Grafana Cloud's
published alerting egress ranges — set NIGHTSHIFT_SHIM_HOST=0.0.0.0 deliberately,
it is not the default. This endpoint shells out to `picoclaw agent -m`, so an
open bind is remote code execution with a bearer token in front of it.

Every request needs `Authorization: Bearer <NIGHTSHIFT_SHIM_TOKEN>`, compared in
constant time. The process refuses to start without a token set. Bodies are
capped, JSON only, and the incident fields are passed to PicoClaw as an argument
vector — never through a shell — so nothing in a webhook payload can become a
command.

ENDPOINTS
---------
  GET  /health          no auth. liveness.
  POST /incident        auth. body: JSON incident payload. -> 202 {"job_id": ...}
  GET  /jobs/<job_id>   auth. status, exit code, and captured output.
  GET  /jobs            auth. recent jobs, newest first.

CONFIG (environment)
--------------------
  NIGHTSHIFT_SHIM_TOKEN     required. bearer token.
  NIGHTSHIFT_SHIM_HOST      default 127.0.0.1
  NIGHTSHIFT_SHIM_PORT      default 18791
  NIGHTSHIFT_SESSION        default "oncall". PicoClaw session name.
  PICOCLAW_BIN              default "picoclaw"
  NIGHTSHIFT_LOG_DIR        default /var/log/nightshift
  NIGHTSHIFT_JOB_TIMEOUT    default 900 (seconds)
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import subprocess
import sys
import threading
import time
import uuid
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TOKEN = os.environ.get("NIGHTSHIFT_SHIM_TOKEN", "")
HOST = os.environ.get("NIGHTSHIFT_SHIM_HOST", "127.0.0.1")
PORT = int(os.environ.get("NIGHTSHIFT_SHIM_PORT", "18791"))
SESSION = os.environ.get("NIGHTSHIFT_SESSION", "oncall")
PICOCLAW_BIN = os.environ.get("PICOCLAW_BIN", "picoclaw")
LOG_DIR = os.environ.get("NIGHTSHIFT_LOG_DIR", "/var/log/nightshift")
JOB_TIMEOUT = int(os.environ.get("NIGHTSHIFT_JOB_TIMEOUT", "900"))

MAX_BODY = 64 * 1024          # a Grafana alerting webhook is a few KB at most
MAX_JOBS = 50                 # ring of recent jobs kept in memory

os.makedirs(LOG_DIR, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(os.path.join(LOG_DIR, "task-shim.log")),
    ],
)
log = logging.getLogger("task-shim")

JOBS: "OrderedDict[str, dict]" = OrderedDict()
JOBS_LOCK = threading.Lock()


# -----------------------------------------------------------------------------
# Prompt construction
# -----------------------------------------------------------------------------
def build_prompt(payload: dict) -> str:
    """
    Turn an incident payload into the message the agent wakes up to.

    Kept deliberately thin. The investigation procedure lives in AGENT.md, which
    hot-reloads on mtime — so you can improve the agent's behaviour between
    rehearsals by editing one markdown file, with no restart and no change here.
    That separation is worth mentioning if someone asks how you iterate on agent
    behaviour safely.

    Accepts a flat payload (what trigger-agent.sh sends) or a GRAFANA ALERTING
    webhook envelope (what break-it.sh's real chain delivers, via
    an authenticated operator over the SSH tunnel).

    The PagerDuty V3 unwrap that used to live here is gone with PagerDuty
    itself — CloudWatch, SNS, Lambda and PagerDuty were all replaced by Grafana
    Alerting (§4.1).
    """
    # ------------------------------------------------------------------------
    # Unwrap a Grafana alerting webhook if that is what we got.
    #
    # ONE HONEST LIMITATION, AND IT IS WHY THE STAGE PATH IS trigger-agent.sh.
    # Grafana's webhook body has no IRM incident ID in it — an alert firing and
    # an incident being opened are two different things in Grafana, and the
    # webhook only knows about the first. The best identifier available here is
    # the alert fingerprint, which is stable per alert instance but is NOT
    # something `get_incident` can look up.
    #
    # So on this path the agent is paged with a real alert and no incident to
    # read, and Act 3 is thin. scripts/trigger-agent.sh opens a REAL IRM
    # incident and hands over its real ID, which is exactly what §6 means by
    # "the incident the agent reads must be real even on the fast path".
    # ------------------------------------------------------------------------
    if isinstance(payload.get("alerts"), list):
        alerts = payload.get("alerts") or []
        first = alerts[0] if alerts and isinstance(alerts[0], dict) else {}
        labels = first.get("labels") or payload.get("commonLabels") or {}
        annotations = first.get("annotations") or payload.get("commonAnnotations") or {}

        payload = {
            "incident_id": str(
                first.get("fingerprint")
                or labels.get("alertname")
                or "GRAFANA-ALERT"
            ),
            "title": payload.get("title")
            or annotations.get("summary")
            or labels.get("alertname", ""),
            "service": labels.get("service", "orders-api"),
            # Grafana calls it severity; the rest of this shim calls it urgency.
            "urgency": labels.get("severity", "high"),
            "status": payload.get("status", "firing"),
            "created_at": first.get("startsAt", ""),
            "html_url": first.get("generatorURL") or payload.get("externalURL", ""),
            "details": (
                payload.get("message")
                or annotations.get("description", "")
            )[:2000],
        }

    incident_id = str(payload.get("incident_id", "UNKNOWN"))
    title = str(payload.get("title", "Untitled alert"))
    service = str(payload.get("service", "orders-api"))
    urgency = str(payload.get("urgency", "high"))
    created = str(payload.get("created_at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
    details = str(payload.get("details", ""))
    html_url = str(payload.get("html_url", ""))

    lines = [
        f"GRAFANA INCIDENT {incident_id} — you are on call.",
        "",
        f"Title:    {title}",
        f"Service:  {service}",
        f"Urgency:  {urgency}",
        f"Opened:   {created}",
    ]
    if html_url:
        lines.append(f"Link:     {html_url}")
    if details:
        lines += ["", "Alert detail:", details]

    lines += [
        "",
        "Triage this now, following the procedure in AGENT.md section 3.",
        "",
        "Reminders:",
        f"- Quote the incident ID ({incident_id}) in every Slack post and every "
        "access request.",
        "- Add your triage summary to the incident timeline before remediation.",
        "- Return the same summary in your completed job output.",
        "- If the platform refuses an action, read the reason, do not retry, and "
        "escalate via the documented path (AGENT.md section 5).",
        "- Leave the incident open. A human closes it.",
    ]
    return "\n".join(lines)


# -----------------------------------------------------------------------------
# Job execution
# -----------------------------------------------------------------------------
def run_job(job_id: str, prompt: str, session: str) -> None:
    """Shell out to `picoclaw agent -m` in a worker thread."""
    argv = [PICOCLAW_BIN, "agent", "-m", prompt, "-s", session]
    log.info("job %s starting (session=%s, prompt %d chars)", job_id, session, len(prompt))

    started = time.time()
    try:
        proc = subprocess.run(
            argv,                    # argument vector: never a shell string
            capture_output=True,
            text=True,
            env={**os.environ, "PICOCLAW_SESSION": session},
            timeout=JOB_TIMEOUT,
            check=False,
        )
        result = {
            "state": "finished" if proc.returncode == 0 else "failed",
            "exit_code": proc.returncode,
            "stdout": proc.stdout[-20000:],
            "stderr": proc.stderr[-8000:],
        }
        log.info("job %s finished rc=%s in %.1fs", job_id, proc.returncode, time.time() - started)
    except subprocess.TimeoutExpired:
        result = {
            "state": "timeout",
            "exit_code": None,
            "stdout": "",
            "stderr": f"picoclaw agent exceeded {JOB_TIMEOUT}s and was killed",
        }
        log.error("job %s timed out after %ss", job_id, JOB_TIMEOUT)
    except FileNotFoundError:
        result = {
            "state": "failed",
            "exit_code": None,
            "stdout": "",
            "stderr": f"{PICOCLAW_BIN} not found on PATH",
        }
        log.error("job %s: %s not on PATH", job_id, PICOCLAW_BIN)
    except Exception as exc:  # noqa: BLE001 - a worker must never die silently
        result = {"state": "failed", "exit_code": None, "stdout": "", "stderr": str(exc)}
        log.exception("job %s crashed", job_id)

    result["duration_seconds"] = round(time.time() - started, 1)
    with JOBS_LOCK:
        JOBS[job_id].update(result)


# -----------------------------------------------------------------------------
# HTTP
# -----------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "nightshift-task-shim/1.0"

    # ---- helpers ------------------------------------------------------------
    def _send(self, status: int, body: dict) -> None:
        blob = json.dumps(body, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(blob)))
        self.end_headers()
        self.wfile.write(blob)

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return False
        # constant time: a timing oracle on a demo box is still a bad habit
        return hmac.compare_digest(header[7:].strip(), TOKEN)

    def log_message(self, fmt: str, *args) -> None:   # noqa: A003
        log.info("%s %s", self.address_string(), fmt % args)

    # ---- routes -------------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._send(200, {
                "status": "ok",
                "service": "nightshift-task-shim",
                "session": SESSION,
                "picoclaw": PICOCLAW_BIN,
            })
            return

        if not self._authorized():
            self._send(401, {"error": "unauthorized"})
            return

        if self.path == "/jobs":
            with JOBS_LOCK:
                jobs = list(reversed(list(JOBS.values())))[:20]
            self._send(200, {"count": len(jobs), "jobs": jobs})
            return

        if self.path.startswith("/jobs/"):
            job_id = self.path.split("/", 2)[2]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if job is None:
                self._send(404, {"error": "no such job", "job_id": job_id})
            else:
                self._send(200, job)
            return

        self._send(404, {"error": "not found", "path": self.path})

    def do_POST(self) -> None:  # noqa: N802
        if self.path not in ("/incident", "/task"):
            self._send(404, {"error": "not found", "path": self.path})
            return

        if not self._authorized():
            log.warning("rejected unauthorized POST from %s", self.address_string())
            self._send(401, {"error": "unauthorized"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, {"error": "bad Content-Length"})
            return
        if length <= 0 or length > MAX_BODY:
            self._send(413, {"error": f"body must be 1..{MAX_BODY} bytes"})
            return

        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            self._send(400, {"error": f"invalid JSON: {exc}"})
            return
        if not isinstance(payload, dict):
            self._send(400, {"error": "body must be a JSON object"})
            return

        # /task lets an operator send free text straight through — handy for
        # the "ask it a business question" opening beat of the demo.
        if self.path == "/task" and payload.get("message"):
            prompt = str(payload["message"])[:8000]
        else:
            prompt = build_prompt(payload)

        session = str(payload.get("session", SESSION))[:64]
        with JOBS_LOCK:
            if any(
                job.get("session") == session and job.get("state") == "running"
                for job in JOBS.values()
            ):
                self._send(409, {
                    "error": "session already has a running job",
                    "session": session,
                })
                return
            job_id = uuid.uuid4().hex[:12]
            job = {
                "job_id": job_id,
                "state": "running",
                "session": session,
                "submitted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "prompt": prompt,
                "exit_code": None,
                "stdout": "",
                "stderr": "",
            }
            JOBS[job_id] = job
            while len(JOBS) > MAX_JOBS:
                JOBS.popitem(last=False)

        threading.Thread(
            target=run_job, args=(job_id, prompt, session), daemon=True
        ).start()

        # 202: accepted, work continues. The caller (and the stage) does not
        # block for 60 seconds while the model thinks.
        self._send(202, {
            "job_id": job_id,
            "state": "running",
            "session": session,
            "poll": f"/jobs/{job_id}",
        })


def main() -> int:
    if not TOKEN:
        sys.exit(
            "NIGHTSHIFT_SHIM_TOKEN is not set. Refusing to start an unauthenticated\n"
            "task endpoint for an agent that can reach production.\n"
            "  export NIGHTSHIFT_SHIM_TOKEN=\"$(openssl rand -hex 24)\""
        )
    if HOST not in ("127.0.0.1", "localhost", "::1"):
        log.warning(
            "binding %s (not loopback) — the security group MUST restrict this "
            "to Grafana Cloud alerting egress ranges only", HOST,
        )

    server = ThreadingHTTPServer((HOST, PORT), Handler)
    log.info("task-shim listening on http://%s:%d (session=%s)", HOST, PORT, SESSION)
    log.info("POST /incident  with Authorization: Bearer <token>")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
