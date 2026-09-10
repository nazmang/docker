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
"""

import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DOCKER_API = os.environ.get("DOCKER_API", "http://dockerproxy:2375")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9107"))
TIMEOUT = float(os.environ.get("DOCKER_TIMEOUT", "10"))

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
