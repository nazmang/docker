#!/usr/bin/env python3
"""Per-service replica metrics for Docker Swarm.

Why this exists: nothing else here can answer "is service X running?".
ServiceDown in alert.rules.yml is `up == 0`, which only covers the four jobs
Prometheus scrapes -- node-exporter and cAdvisor stay up while every
application service on the node dies. cAdvisor would normally fill the gap
with container-level metrics, but it cannot: Docker 29 stores images through
the containerd snapshotter and cAdvisor still looks for the legacy graph
driver layout, so it reports no containers at all on these hosts (which is
also why the five Jenkins container rules can never fire).

The data comes from the Docker API through the existing read-only socket proxy
(POST=0), so this process cannot change anything even if it is compromised.

Deliberately stdlib-only: it runs on a stock python:*-alpine image with the
source delivered as a Swarm config, so there is no image to build, publish or
keep patched.

It also probes the transit Vault's /v1/sys/health (VAULT_HEALTH_URLS). That
Vault holds the cluster Vault's unseal key and is Shamir-sealed itself; it sat
sealed from 2026-09-24 to 2026-10-14 without a word, the cluster's token to it
expired meanwhile, and the next restart of the cluster Vault failed. Vault's
own metrics need a token, sys/health does not -- and this is the one in-house
exporter already running next to it, so the probe lives here instead of a
blackbox exporter deployed for a single target.
"""

import json
import os
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DOCKER_API = os.environ.get("DOCKER_API", "http://dockerproxy:2375")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9107"))
TIMEOUT = float(os.environ.get("DOCKER_TIMEOUT", "10"))
# Comma-separated Vault base URLs, e.g. http://10.163.11.105:8200
VAULT_HEALTH_URLS = [u.strip().rstrip("/") for u in
                     os.environ.get("VAULT_HEALTH_URLS", "").split(",") if u.strip()]

# States a task passes through on the way up. A task sitting in one of these is
# not a failure yet, but it is not running either.
PENDING_STATES = {"new", "allocated", "pending", "assigned", "accepted",
                  "preparing", "ready", "starting"}
FAILED_STATES = {"failed", "rejected", "orphaned"}


def api(path):
    req = urllib.request.Request(DOCKER_API + path, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def escape(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def collect():
    services = api("/services")
    tasks = api("/tasks")
    nodes = api("/nodes")

    # A global service has one task per eligible node, so its desired count is
    # not in the spec -- it is however many tasks the manager wants running.
    ready_nodes = sum(
        1 for n in nodes
        if n.get("Status", {}).get("State") == "ready"
        and n.get("Spec", {}).get("Availability") == "active"
    )

    by_service = {}
    for t in tasks:
        by_service.setdefault(t.get("ServiceID"), []).append(t)

    lines = []

    def emit(name, labels, value):
        label_str = ",".join(f'{k}="{escape(v)}"' for k, v in labels.items())
        lines.append(f"{name}{{{label_str}}} {value}")

    lines.append("# HELP swarm_service_replicas_desired Replicas the manager wants running.")
    lines.append("# TYPE swarm_service_replicas_desired gauge")
    lines.append("# HELP swarm_service_replicas_running Tasks actually in state running.")
    lines.append("# TYPE swarm_service_replicas_running gauge")
    lines.append("# HELP swarm_service_tasks Tasks per service grouped by current state.")
    lines.append("# TYPE swarm_service_tasks gauge")

    for svc in services:
        spec = svc.get("Spec", {})
        name = spec.get("Name", "")
        stack = spec.get("Labels", {}).get("com.docker.stack.namespace", "")
        mode = spec.get("Mode", {})

        if "Replicated" in mode:
            desired = mode["Replicated"].get("Replicas", 0)
            mode_name = "replicated"
        elif "Global" in mode:
            desired = ready_nodes
            mode_name = "global"
        else:
            # Jobs (ReplicatedJob/GlobalJob) are meant to finish; a "running
            # count" is not a health signal for them, so they are skipped
            # rather than reported as permanently degraded.
            continue

        svc_tasks = by_service.get(svc.get("ID"), [])
        # Only tasks the manager still wants: shut-down predecessors of a
        # rolling update linger in the API for a while and would otherwise be
        # counted as failures forever.
        wanted = [t for t in svc_tasks if t.get("DesiredState") == "running"]

        running = sum(1 for t in wanted if t.get("Status", {}).get("State") == "running")
        pending = sum(1 for t in wanted if t.get("Status", {}).get("State") in PENDING_STATES)
        failed = sum(1 for t in wanted if t.get("Status", {}).get("State") in FAILED_STATES)

        labels = {"service": name, "stack": stack, "mode": mode_name}
        emit("swarm_service_replicas_desired", labels, desired)
        emit("swarm_service_replicas_running", labels, running)
        emit("swarm_service_tasks", {**labels, "state": "pending"}, pending)
        emit("swarm_service_tasks", {**labels, "state": "failed"}, failed)

    lines.append("# HELP swarm_node_ready Whether a Swarm node is ready and active.")
    lines.append("# TYPE swarm_node_ready gauge")
    for n in nodes:
        hostname = n.get("Description", {}).get("Hostname", "")
        role = n.get("Spec", {}).get("Role", "")
        ready = 1 if (n.get("Status", {}).get("State") == "ready"
                      and n.get("Spec", {}).get("Availability") == "active") else 0
        emit("swarm_node_ready", {"node": hostname, "role": role}, ready)

    return "\n".join(lines) + "\n"


def collect_vault():
    """sys/health answers 200 active, 429 standby, 501 not initialized, 503
    sealed -- with a JSON body in every case, so the body, not the status, is
    what gets read."""
    lines = [
        "# HELP vault_health_up Whether Vault answered sys/health at all.",
        "# TYPE vault_health_up gauge",
        "# HELP vault_health_sealed 1 if Vault reports itself sealed.",
        "# TYPE vault_health_sealed gauge",
        "# HELP vault_health_initialized 1 if Vault reports itself initialized.",
        "# TYPE vault_health_initialized gauge",
    ]
    for url in VAULT_HEALTH_URLS:
        lbl = f'instance="{escape(url)}"'
        try:
            try:
                with urllib.request.urlopen(url + "/v1/sys/health", timeout=TIMEOUT) as r:
                    data = json.load(r)
            except urllib.error.HTTPError as e:
                data = json.load(e)
            lines.append(f"vault_health_up{{{lbl}}} 1")
            lines.append(f"vault_health_sealed{{{lbl}}} {int(bool(data.get('sealed')))}")
            lines.append(f"vault_health_initialized{{{lbl}}} {int(bool(data.get('initialized')))}")
        except Exception as exc:  # noqa: BLE001 -- unreachable or not Vault
            lines.append(f"# vault {escape(url)}: {escape(exc)}")
            lines.append(f"vault_health_up{{{lbl}}} 0")
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/metrics"):
            start = time.time()
            try:
                body = collect()
                body += "swarm_exporter_up 1\n"
            except Exception as exc:  # noqa: BLE001 -- any failure is one signal
                # Report the failure as a metric instead of a 500: a scrape
                # error makes the whole target `up == 0`, which says "the
                # exporter is gone" when the truth is "the Docker API did not
                # answer". Those want different responses.
                body = f"# collection failed: {escape(exc)}\nswarm_exporter_up 0\n"
            if VAULT_HEALTH_URLS:
                body += collect_vault()
            body += f"swarm_exporter_scrape_duration_seconds {time.time() - start:.4f}\n"
            payload = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass  # one line per scrape at 30s intervals is noise, not a log


if __name__ == "__main__":
    ThreadingHTTPServer(("", LISTEN_PORT), Handler).serve_forever()
