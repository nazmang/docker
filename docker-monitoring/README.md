# Monitoring stack

This document describes the services defined in the `docker-compose.yml` file and their environment variables.

## Grafana

Service for visualizing metrics and monitoring data.

-   **Image:** `grafana/grafana:10.3.5`
-   **Description:** A platform for analytics and interactive visualization. Allows creating dashboards for monitoring.

### Environment Variables:

-   `GF_SECURITY_ADMIN_USER=${ADMIN_USER:-admin}`: Grafana admin username. Defaults to `admin` if the `ADMIN_USER` variable is not set externally.
-   `GF_SECURITY_ADMIN_PASSWORD=${ADMIN_PASSWORD:-admin}`: Grafana admin password. Defaults to `admin` if the `ADMIN_PASSWORD` variable is not set externally.
-   `GF_USERS_ALLOW_SIGN_UP=false`: Disables users from signing up themselves.

## nodeexporter

Host system metrics exporter for Prometheus.

-   **Image:** `prom/node-exporter:v1.7.0`
-   **Description:** Collects hardware and operating system metrics (CPU, memory, disk, network, etc.).

### Environment Variables:

-   `NODE_ID={{.Node.ID}}`: Passes the Docker Swarm Node ID into the container. Used for node identification in Prometheus.

## cadvisor

Container resource usage analyzer.

-   **Image:** `nazman/cadvisor:v0.49.1` (Note: the official image is `gcr.io/cadvisor/cadvisor`) - [Custom image with arm64 support](https://github.com/nazmang/cadvisor-docker).
-   **Description:** Collects, aggregates, processes, and exports information about running containers (CPU, memory, filesystem, network usage).

### Environment Variables:

-   No specific environment variables defined for configuration in this file.

## prometheus

Monitoring system and time-series database.

-   **Image:** `prom/prometheus:v2.51.0`
-   **Description:** The core component of the monitoring system. Collects metrics from exporters (nodeexporter, cadvisor), stores them, and provides the PromQL query language for data analysis. Also responsible for evaluating alerting rules.

### Environment Variables:

-   No specific environment variables defined for configuration in this file (configuration is set via files and command-line flags).

## dockerproxy

Proxy for secure access to the Docker API socket.

-   **Image:** `ghcr.io/tecnativa/docker-socket-proxy:latest`
-   **Description:** Provides limited access to the Docker API, allowing Prometheus (via docker-sd configuration) to discover containers without granting full access to the Docker socket.

### Environment Variables:

-   `CONTAINERS=1`: Allow viewing containers.
-   `SERVICES=1`: Allow viewing services (for Docker Swarm).
-   `TASKS=1`: Allow viewing tasks (for Docker Swarm).
-   `NODES=1`: Allow viewing nodes (for Docker Swarm).
-   `POST=0`: Disallow any POST requests (read-only mode).
-   `SWARM=1`: Enable Swarm-related endpoints.
-   `NETWORKS=1`: Allow viewing networks.
-   `VOLUMES=1`: Allow viewing volumes.

## alertmanager

Alert handler for Prometheus.

-   **Image:** `quay.io/prometheus/alertmanager:v0.26.0`
-   **Description:** Receives alerts from Prometheus, deduplicates them, groups them, and routes them to configured receivers (e.g., Slack, Email, PagerDuty). Also manages silencing and inhibition of alerts.

### Environment Variables:

-   `SLACK_URL=${SLACK_URL:-https://hooks.slack.com/services/TOKEN}`: Slack webhook URL for sending notifications. Defaults to a placeholder if the `SLACK_URL` variable is not set externally. **A real URL needs to be set.**
-   `SLACK_CHANNEL=${SLACK_CHANNEL:-general}`: Default Slack channel for sending notifications. Defaults to `general` if the `SLACK_CHANNEL` variable is not set externally.
-   `SLACK_USER=${SLACK_USER:-alertmanager}`: Username displayed for notifications in Slack. Defaults to `alertmanager` if the `SLACK_USER` variable is not set externally.