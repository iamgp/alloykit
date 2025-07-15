# AlloyKit - Complete Observability Stack

AlloyKit is a single-file installer for a complete observability stack using Grafana, Prometheus, Loki, and Alloy with Podman containers.

## Features

- **Complete Stack**: Grafana, Prometheus, Loki, and Alloy pre-configured and ready to use
- **Single File**: Everything in one script - no external dependencies
- **Permission Checking**: Validates log file access before adding monitoring
- **Container Management**: Start, stop, restart, status, logs, cleanup
- **UV Integration**: Uses UV for Python package management with taskipy
- **Health Checks**: Waits for services to be ready
- **Rollback**: Automatic cleanup on failure

## Quick Start

```bash
# Interactive installation
./alloykit.sh

# Non-interactive with defaults
./alloykit.sh --non-interactive

# Check status
./alloykit.sh --status
```

## Services

After installation, access these services:

- **Grafana**: http://localhost:3000 (admin/admin)
- **Prometheus**: http://localhost:9090
- **Loki**: http://localhost:3100
- **Alloy**: http://localhost:12345

## Management Commands

```bash
# Container management
./alloykit.sh --status                    # Show all containers
./alloykit.sh --start                     # Start all containers
./alloykit.sh --stop                      # Stop all containers
./alloykit.sh --restart                   # Restart all containers
./alloykit.sh --clean                     # Clean up containers and volumes

# Log monitoring (with permission checks)
./alloykit.sh --add-logs /var/log/nginx/*.log nginx

# Service logs
./alloykit.sh --logs grafana              # Show Grafana logs
./alloykit.sh --logs prometheus           # Show Prometheus logs
```

## UV Task Commands

From the installation directory:

```bash
cd alloykit/
uv run task status      # Show container status
uv run task start       # Start all containers
uv run task stop        # Stop all containers
uv run task restart     # Restart all containers
uv run task logs-grafana # Show Grafana logs
uv run task clean       # Clean up containers and volumes
```

## Configuration

Use a configuration file for non-interactive installation:

```bash
# alloykit.conf
INSTALL_DIR=./alloykit
INSTANCE_NAME=default
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
LOKI_PORT=3100
ALLOY_PORT=12345
```

```bash
./alloykit.sh --config alloykit.conf
```

### Multiple Environments

You can create different configuration files for different environments:

```bash
# Production (alloykit-prod.conf)
INSTALL_DIR=/opt/alloykit
INSTANCE_NAME=prod
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
LOKI_PORT=3100
ALLOY_PORT=12345

# Development (alloykit-dev.conf)
INSTALL_DIR=./alloykit-dev
INSTANCE_NAME=dev
GRAFANA_PORT=3001
PROMETHEUS_PORT=9091
LOKI_PORT=3101
ALLOY_PORT=12346

# Staging (alloykit-staging.conf)
INSTALL_DIR=./alloykit-staging
INSTANCE_NAME=staging
GRAFANA_PORT=3002
PROMETHEUS_PORT=9092
LOKI_PORT=3102
ALLOY_PORT=12347
```

Then install each environment:
```bash
./alloykit.sh --config alloykit-prod.conf
./alloykit.sh --config alloykit-dev.conf
./alloykit.sh --config alloykit-staging.conf
```

## Options

```
INSTALLATION OPTIONS:
    --non-interactive    Run without prompts using defaults or config file
    --dry-run           Preview changes without executing them
    --config FILE       Use configuration file instead of prompts
    --uninstall         Remove AlloyKit installation
    --help              Show this help message

CONTAINER MANAGEMENT COMMANDS:
    --start [INSTANCE]   Start AlloyKit containers
    --stop [INSTANCE]    Stop AlloyKit containers
    --restart [INSTANCE] Restart AlloyKit containers
    --status [INSTANCE]  Show container status
    --logs SERVICE       Show logs for service (prometheus|loki|grafana|alloy)
    --clean [INSTANCE]   Stop containers and remove volumes
    --add-logs PATH [JOB] Add log location to monitor
```

## Requirements

- **Podman**: Container runtime
- **UV**: Python package manager (auto-installed if missing)
- **curl**: For downloading components
- **unzip/tar**: For extracting archives

## Permission Checking

AlloyKit validates file permissions before adding log monitoring:

```bash
./alloykit.sh --add-logs /var/log/syslog system
# Checks if file is readable and provides fix suggestions if not
```

## Architecture

AlloyKit creates:
- **Podman network**: For service communication
- **Persistent volumes**: For data storage
- **Health checks**: Ensures services are ready
- **Configuration files**: Pre-configured for immediate use
- **Python environment**: UV-managed with taskipy for task management

## Troubleshooting

```bash
# Check logs
./alloykit.sh --logs grafana

# View installation log
tail -f alloykit/alloykit-install.log

# Clean and reinstall
./alloykit.sh --clean
./alloykit.sh --non-interactive
```

## Uninstall

```bash
./alloykit.sh --uninstall
```

This will find and remove AlloyKit installations, stop containers, and clean up volumes.