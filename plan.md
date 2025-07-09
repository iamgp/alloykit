# Carmack-Style Plan: Native Observability Stack Installation

## Executive Summary

Transform a Docker-based Grafana observability stack into native Linux services, eliminating container overhead while preserving functionality. The stack comprises Grafana Alloy (telemetry collector), Prometheus (metrics), Loki (logs), and Grafana (visualization).

## Cross-Platform Update

This plan has been updated to support both macOS and Linux without requiring system service managers (systemd/launchd). The installation runs components as standalone processes managed through shell scripts with PID tracking.

## System Architecture Overview

### Component Versions
- **Grafana Alloy v1.9.2**: Unified telemetry collector (successor to Grafana Agent)
- **Prometheus v3.4.2**: Time-series metrics database  
- **Loki v3.5.1**: Log aggregation system
- **Grafana v12.0.2**: Analytics and visualization platform

### Data Flow Architecture
```
┌─────────────┐     ┌──────────────┐
│   System    │────▶│              │────▶┌─────────────┐
│  Metrics    │     │    Alloy     │     │ Prometheus  │
│  & Logs     │     │  (Port 12345)│     │ (Port 9090) │
└─────────────┘     │              │     └─────────────┘
                    │              │                     │
                    │              │────▶┌─────────────┐ │
                    │              │     │    Loki     │ │
                    └──────────────┘     │ (Port 3100) │ │
                                        └─────────────┘ │
                                                       │ │
                                        ┌─────────────┐ │
                                        │   Grafana   │◀┘
                                        │ (Port 3000) │
                                        └─────────────┘
```

## Critical Constraints & Requirements

### 1. System Requirements
- **OS**: macOS (10.15+) or Linux (Ubuntu 20.04+, RHEL 8+, Debian 10+)
- **Architecture**: amd64 (x86_64), arm64, or armv7
- **Memory**: Minimum 2GB RAM (4GB recommended)
- **Storage**: 10GB minimum free space
- **Privileges**: Root/sudo access recommended for Alloy system metrics (optional)

### 2. Port Allocations
| Component | Port  | Protocol | Purpose |
|-----------|-------|----------|---------|
| Alloy     | 12345 | HTTP     | Admin UI & API |
| Prometheus| 9090  | HTTP     | Query API & UI |
| Loki      | 3100  | HTTP     | Push/Query API |
| Grafana   | 3000  | HTTP     | Web UI |

### 3. File System Access Requirements
- Alloy requires root access to:
  - `/var/log/journal` - systemd journal
  - `/var/log/*.log` - system logs
  - `/sys`, `/proc` - system metrics
  - `/run/udev/data` - device information

### 4. Configuration Adaptations
Docker-specific configurations must be modified:
- Container names → localhost
- Docker socket paths → removed
- Volume mounts → local paths
- Network aliases → 127.0.0.1

## Directory Structure

```
observability-stack/
├── bin/                    # Binary executables
│   ├── alloy              # ~140MB
│   ├── prometheus         # ~100MB
│   ├── promtool           # ~100MB
│   ├── loki               # ~80MB
│   └── grafana-server     # ~120MB (Linux)
│   └── grafana            # ~120MB (macOS)
├── config/                 # Configuration files
│   ├── alloy/
│   │   └── config.alloy   # Telemetry collection rules
│   ├── prometheus/
│   │   └── prometheus.yaml # Scrape configs & storage
│   ├── loki/
│   │   └── config.yaml    # Ingestion & storage rules
│   └── grafana/
│       └── grafana.ini    # Server configuration
├── data/                   # Persistent storage (grows over time)
│   ├── alloy/             # WAL and positions
│   ├── prometheus/        # TSDB blocks
│   ├── loki/
│   │   ├── chunks/        # Compressed log chunks
│   │   └── rules/         # Alerting rules
│   └── grafana/           # Dashboards, users, plugins
├── logs/                   # Component logs
│   ├── alloy.log
│   ├── prometheus.log
│   ├── loki.log
│   └── grafana.log
├── run/                    # PID files for process management
│   ├── alloy.pid
│   ├── prometheus.pid
│   ├── loki.pid
│   └── grafana.pid
├── scripts/                # Management utilities
│   ├── run-alloy.sh       # Run Alloy in foreground
│   ├── run-prometheus.sh  # Run Prometheus in foreground
│   ├── run-loki.sh        # Run Loki in foreground
│   ├── run-grafana.sh     # Run Grafana in foreground
│   ├── start-all.sh       # Start all services in background
│   ├── stop-all.sh        # Stop all services
│   ├── status.sh          # Check service status
│   └── run-foreground.sh  # Instructions for debugging
└── share/                  # Shared resources
    └── grafana/
        ├── public/         # Web assets
        └── conf/           # Default configs
```

## Installation Process

### Phase 1: Directory Creation
1. Create base directory structure
2. Set appropriate permissions (755 for dirs, 644 for configs)
3. Ensure data directories are writable by service users

### Phase 2: Binary Installation
Each component requires:
1. Download from official GitHub releases
2. Verify checksums (if provided)
3. Extract and place in bin/
4. Set executable permissions

### Phase 3: Configuration Migration

#### Alloy Configuration Changes
- `http://loki:3100` → `http://localhost:3100`
- `http://prometheus:9090` → `http://localhost:9090`
- Remove Docker-specific collectors:
  - `prometheus.exporter.cadvisor`
  - `discovery.docker`
  - `loki.source.docker`

#### Prometheus Configuration
- Enable remote write receiver: `--web.enable-remote-write-receiver`
- No configuration changes needed (already uses localhost)

#### Loki Configuration
- Update storage paths to absolute paths
- `/loki/chunks` → `$INSTALL_DIR/data/loki/chunks`
- `/loki/rules` → `$INSTALL_DIR/data/loki/rules`

#### Grafana Configuration
- Create minimal grafana.ini
- Set data, logs, and plugin paths
- Configure SQLite database location

### Phase 4: Process Management

#### Cross-Platform Approach
Instead of systemd (Linux) or launchd (macOS), the installation uses shell scripts with PID tracking:

1. **Individual run scripts**: Each component has its own `run-*.sh` script that runs the binary in foreground
2. **Background execution**: `start-all.sh` uses `nohup` to run services in background
3. **PID tracking**: Process IDs stored in `run/*.pid` files for management
4. **Log management**: Output redirected to `logs/*.log` with `tee` for live viewing

#### Service Start Order
```
loki (port 3100)
  └── prometheus (port 9090) 
      └── alloy (port 12345)
          └── grafana (port 3000)
```

### Phase 5: Post-Installation

1. **Quick Start**:
   ```bash
   # Start all services in background
   ./observability-stack/scripts/start-all.sh
   
   # Check status
   ./observability-stack/scripts/status.sh
   ```

2. **Alternative: Run in Foreground** (for debugging):
   ```bash
   # In separate terminals:
   ./observability-stack/scripts/run-loki.sh
   ./observability-stack/scripts/run-prometheus.sh
   ./observability-stack/scripts/run-alloy.sh
   ./observability-stack/scripts/run-grafana.sh
   ```

3. **Initial Configuration**:
   - Access Grafana at http://localhost:3000
   - Default credentials: admin/admin
   - Data sources are automatically provisioned:
     - Prometheus: http://localhost:9090 (default)
     - Loki: http://localhost:3100
   - Pre-loaded dashboards: System Metrics & System Logs

## Operational Considerations

### Resource Usage
- **Alloy**: ~200MB RAM, minimal CPU
- **Prometheus**: 1-2GB RAM (depends on metrics volume)
- **Loki**: 500MB-1GB RAM (depends on log volume)
- **Grafana**: 200-500MB RAM

### Data Retention
- **Prometheus**: Default 15 days (configurable)
- **Loki**: Default 168h/7 days (configurable)
- **Grafana**: Indefinite (dashboards, users)

### Backup Strategy
Critical paths to backup:
- `data/prometheus/` - Metrics history
- `data/loki/` - Log history
- `data/grafana/grafana.db` - Dashboards, users
- `config/` - All configurations

### Security Considerations
1. **Network Security**:
   - All services bind to 0.0.0.0 by default
   - Consider binding to 127.0.0.1 for local-only access
   - Use reverse proxy for external access

2. **File Permissions**:
   - Alloy runs as root (required for journal access)
   - Other services run as regular user
   - Restrict config file access (may contain secrets)

3. **Authentication**:
   - Grafana has built-in authentication
   - Prometheus/Loki have no auth by default
   - Consider adding reverse proxy with auth

## Platform-Specific Considerations

### macOS
1. **Alloy Limitations**: 
   - No systemd journal access (journalctl not available)
   - Limited to file-based log collection
   - Some system metrics may be unavailable without root

2. **Port Permissions**: 
   - Ports above 1024 don't require root
   - First run may trigger firewall permission dialogs

3. **Binary Differences**:
   - Grafana binary is named `grafana` instead of `grafana-server`
   - Different archive structure for some components

### Linux
1. **Full Feature Set**:
   - Complete systemd journal access with root
   - All system metrics available
   - Docker metrics if Docker is installed

2. **Alternative Service Management**:
   - Can still use systemd if desired (create your own service files)
   - Script approach works identically to macOS

## Troubleshooting Guide

### Common Issues

1. **Port Conflicts**:
   - Check with `ss -tlnp | grep <port>`
   - Modify ports in configs and systemd files

2. **Permission Denied**:
   - Alloy journal access requires root
   - Data directories must be writable

3. **Service Failures**:
   - Check logs in `$INSTALL_DIR/logs/`
   - Verify binary permissions
   - Ensure config syntax is valid

4. **Missing Metrics/Logs**:
   - Verify Alloy can reach Prometheus/Loki
   - Check Alloy logs for errors
   - Ensure system has systemd journal

### Validation Tests

1. **Component Health**:
   ```bash
   curl -s http://localhost:12345/api/v1/metrics/metadata | jq
   curl -s http://localhost:9090/-/healthy
   curl -s http://localhost:3100/ready
   curl -s http://localhost:3000/api/health
   ```

2. **Data Flow Verification**:
   - Check Prometheus targets: http://localhost:9090/targets
   - Query test metric: `up{job="prometheus"}`
   - Check Loki ingestion: `{job=~".+"}`

## Performance Optimization

### Alloy Optimizations
- Adjust scrape intervals based on needs
- Disable unnecessary collectors
- Use relabeling to reduce cardinality

### Prometheus Optimizations
- Configure appropriate retention
- Set memory limits in systemd
- Enable compression

### Loki Optimizations
- Configure chunk_target_size
- Set appropriate retention_period
- Enable compression

### Grafana Optimizations
- Use caching for dashboards
- Limit concurrent queries
- Configure appropriate timeouts

## Migration from Docker

### Data Migration
1. Stop Docker containers
2. Copy data volumes:
   ```bash
   docker cp alloy:/var/lib/alloy/data/* $INSTALL_DIR/data/alloy/
   docker cp prometheus:/prometheus/* $INSTALL_DIR/data/prometheus/
   docker cp loki:/loki/* $INSTALL_DIR/data/loki/
   docker cp grafana:/var/lib/grafana/* $INSTALL_DIR/data/grafana/
   ```
3. Update file ownership
4. Start native services

### Rollback Plan
1. Keep Docker compose files
2. Stop native services
3. Start Docker containers
4. Restore from backups if needed

## Future Enhancements

1. **High Availability**:
   - Prometheus federation
   - Loki replication
   - Grafana database replication

2. **Monitoring the Monitors**:
   - External health checks
   - Alerting configuration
   - Backup automation

3. **Security Hardening**:
   - TLS between components
   - Authentication tokens
   - Audit logging

## Implementation Timeline

- **Phase 1** (Minutes 0-2): Platform detection and prerequisite checks
- **Phase 2** (Minutes 2-15): Binary downloads and extraction
- **Phase 3** (Minutes 15-18): Configuration file adaptation
- **Phase 4** (Minutes 18-20): Script creation and permissions
- **Phase 5** (Minutes 20-25): Service startup and validation
- **Phase 6** (Minutes 25-30): Grafana access and data source configuration

Total estimated time: 30 minutes for fresh installation

## Usage Summary

```bash
# Install (macOS or Linux)
./install-observability-stack.sh [install-directory]

# Start all services
./observability-stack/scripts/start-all.sh

# Check status
./observability-stack/scripts/status.sh

# View logs
tail -f ./observability-stack/logs/*.log

# Stop all services
./observability-stack/scripts/stop-all.sh
```