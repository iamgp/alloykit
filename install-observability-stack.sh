#!/bin/bash
set -euo pipefail

# Grafana Observability Stack Native Installation Script
# Converts Docker-based stack to run natively without containers

# Configuration
INSTALL_DIR="${1:-./observability-stack}"

# Detect OS and architecture
detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$OS" in
        darwin) OS="darwin" ;;
        linux) OS="linux" ;;
        *) error "Unsupported OS: $OS"; exit 1 ;;
    esac
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    
    log "Detected platform: $OS/$ARCH"
}

# Component versions
ALLOY_VERSION="v1.9.2"
PROMETHEUS_VERSION="v3.4.2"
LOKI_VERSION="3.5.1"
GRAFANA_VERSION="12.0.2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Create directory structure
create_directories() {
    log "Creating directory structure..."
    mkdir -p "$INSTALL_DIR"/{bin,config/{alloy,prometheus,loki,grafana},data/{alloy,prometheus,loki/{chunks,rules},grafana},logs,scripts,run}
    mkdir -p "$INSTALL_DIR/../downloads"
}

# Download function for each component
download_prometheus() {
    local version_clean="${PROMETHEUS_VERSION#v}"
    local filename="prometheus-${version_clean}.${OS}-${ARCH}.tar.gz"
    local download_path="$INSTALL_DIR/../downloads/$filename"
    local url="https://github.com/prometheus/prometheus/releases/download/${PROMETHEUS_VERSION}/prometheus-${version_clean}.${OS}-${ARCH}.tar.gz"
    
    if [[ -f "$download_path" ]]; then
        log "Prometheus already downloaded: $filename"
    else
        log "Downloading Prometheus..."
        curl -L -s "$url" -o "$download_path" || error "Failed to download Prometheus"
    fi
}

download_loki() {
    local filename="loki-${LOKI_VERSION}-${OS}-${ARCH}.zip"
    local download_path="$INSTALL_DIR/../downloads/$filename"
    local url="https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-${OS}-${ARCH}.zip"
    
    if [[ -f "$download_path" ]]; then
        log "Loki already downloaded: $filename"
    else
        log "Downloading Loki..."
        curl -L -s "$url" -o "$download_path" || error "Failed to download Loki"
    fi
}

download_alloy() {
    local filename="alloy-${ALLOY_VERSION}-${OS}-${ARCH}.zip"
    local download_path="$INSTALL_DIR/../downloads/$filename"
    local url="https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}/alloy-${OS}-${ARCH}.zip"
    
    if [[ -f "$download_path" ]]; then
        log "Alloy already downloaded: $filename"
    else
        log "Downloading Alloy..."
        curl -L -s "$url" -o "$download_path" || error "Failed to download Alloy"
    fi
}

download_grafana() {
    local filename="grafana-${GRAFANA_VERSION}.${OS}-${ARCH}.tar.gz"
    local download_path="$INSTALL_DIR/../downloads/$filename"
    local url="https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.${OS}-${ARCH}.tar.gz"
    
    if [[ -f "$download_path" ]]; then
        log "Grafana already downloaded: $filename"
    else
        log "Downloading Grafana..."
        curl -L -s "$url" -o "$download_path" || error "Failed to download Grafana"
    fi
}

# Download all components in parallel
download_all_components() {
    log "Starting parallel downloads..."
    
    # Run all downloads in background
    download_prometheus &
    local prom_pid=$!
    
    download_loki &
    local loki_pid=$!
    
    download_alloy &
    local alloy_pid=$!
    
    download_grafana &
    local grafana_pid=$!
    
    # Wait for all downloads to complete
    log "Waiting for downloads to complete (this may take a few minutes)..."
    
    local failed=0
    local all_pids=($prom_pid $loki_pid $alloy_pid $grafana_pid)
    
    # Show progress while waiting
    while true; do
        local running=0
        for pid in "${all_pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                running=$((running + 1))
            fi
        done
        
        if [[ $running -eq 0 ]]; then
            break
        fi
        
        echo -ne "\r${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} Downloads in progress: $running remaining...    "
        sleep 2
    done
    echo  # New line after progress
    
    # Check if any downloads failed
    if ! wait $prom_pid 2>/dev/null; then
        error "Prometheus download failed"
        failed=1
    fi
    
    if ! wait $loki_pid 2>/dev/null; then
        error "Loki download failed"
        failed=1
    fi
    
    if ! wait $alloy_pid 2>/dev/null; then
        error "Alloy download failed"
        failed=1
    fi
    
    if ! wait $grafana_pid 2>/dev/null; then
        error "Grafana download failed"
        failed=1
    fi
    
    if [[ $failed -eq 1 ]]; then
        error "One or more downloads failed"
        exit 1
    fi
    
    log "All downloads completed successfully!"
}

# Install Alloy from downloaded file
install_alloy() {
    log "Installing Grafana Alloy ${ALLOY_VERSION}..."
    local filename="alloy-${ALLOY_VERSION}-${OS}-${ARCH}.zip"
    local download_path="$INSTALL_DIR/../downloads/$filename"
    
    log "Extracting Alloy..."
    if ! unzip -q -o "$download_path" -d "$INSTALL_DIR/../downloads/"; then
        error "Failed to extract Alloy"
        exit 1
    fi
    
    if ! mv "$INSTALL_DIR/../downloads/alloy-${OS}-${ARCH}" "$INSTALL_DIR/bin/alloy"; then
        error "Failed to install Alloy binary"
        exit 1
    fi
    
    chmod +x "$INSTALL_DIR/bin/alloy"
    
    # Adapt configuration
    cat > "$INSTALL_DIR/config/alloy/config.alloy" << 'EOF'
// Native installation configuration
// Modified from Docker version to use localhost endpoints

// SECTION: TARGETS

loki.write "default" {
	endpoint {
		url = "http://localhost:3100/loki/api/v1/push"
	}
	external_labels = {}
}

prometheus.remote_write "default" {
  endpoint {
    url = "http://localhost:9090/api/v1/write"
  }
}

// SECTION: SYSTEM LOGS & JOURNAL

loki.source.journal "journal" {
  max_age       = "24h0m0s"
  relabel_rules = discovery.relabel.journal.rules
  forward_to    = [loki.write.default.receiver]
  labels        = {component = string.format("%s-journal", constants.hostname)}
  path          = "/var/log/journal" 
}

local.file_match "system" {
  path_targets = [{
    __address__ = "localhost",
    __path__    = "/var/log/{syslog,messages,*.log}",
    instance    = constants.hostname,
    job         = string.format("%s-logs", constants.hostname),
  }]
}

discovery.relabel "journal" {
  targets = []
  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal__boot_id"]
    target_label  = "boot_id"
  }
  rule {
    source_labels = ["__journal__transport"]
    target_label  = "transport"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
}

loki.source.file "system" {
  targets    = local.file_match.system.targets
  forward_to = [loki.write.default.receiver]
}

// SECTION: SYSTEM METRICS

discovery.relabel "metrics" {
  targets = prometheus.exporter.unix.metrics.targets
  rule {
    target_label = "instance"
    replacement  = constants.hostname
  }
  rule {
    target_label = "job"
    replacement = string.format("%s-metrics", constants.hostname)
  }
}

prometheus.exporter.unix "metrics" {
  disable_collectors = ["ipvs", "btrfs", "infiniband", "xfs", "zfs"]
  enable_collectors = ["meminfo"]
  filesystem {
    fs_types_exclude     = "^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|tmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
    mount_points_exclude = "^/(dev|proc|run/credentials/.+|sys|var/lib/docker/.+)($|/)"
    mount_timeout        = "5s"
  }
  netclass {
    ignored_devices = "^(veth.*|cali.*|[a-f0-9]{15})$"
  }
  netdev {
    device_exclude = "^(veth.*|cali.*|[a-f0-9]{15})$"
  }
}

prometheus.scrape "metrics" {
scrape_interval = "15s"
  targets    = discovery.relabel.metrics.output
  forward_to = [prometheus.remote_write.default.receiver]
}

// Note: Docker-specific sections removed for native installation
EOF
}

# Install Prometheus from downloaded file
install_prometheus() {
    log "Installing Prometheus ${PROMETHEUS_VERSION}..."
    local version_clean="${PROMETHEUS_VERSION#v}"
    local filename="prometheus-${version_clean}.${OS}-${ARCH}.tar.gz"
    local download_path="$INSTALL_DIR/../downloads/$filename"
    
    log "Extracting Prometheus..."
    if ! tar -xzf "$download_path" -C "$INSTALL_DIR/../downloads/"; then
        error "Failed to extract Prometheus"
        exit 1
    fi
    
    local prom_dir="$INSTALL_DIR/../downloads/prometheus-${version_clean}.${OS}-${ARCH}"
    if [[ ! -d "$prom_dir" ]]; then
        error "Prometheus directory not found after extraction"
        exit 1
    fi
    
    mv "$prom_dir/prometheus" "$INSTALL_DIR/bin/"
    mv "$prom_dir/promtool" "$INSTALL_DIR/bin/"
    chmod +x "$INSTALL_DIR/bin/prometheus" "$INSTALL_DIR/bin/promtool"
    rm -rf "$prom_dir" 
    
    # Copy configuration
    cp "$INSTALL_DIR/../boilerplates/docker-compose/prometheus/config/prometheus.yaml" "$INSTALL_DIR/config/prometheus/"
}

# Install Loki from downloaded file
install_loki() {
    log "Installing Loki ${LOKI_VERSION}..."
    local filename="loki-${LOKI_VERSION}-${OS}-${ARCH}.zip"
    local download_path="$INSTALL_DIR/../downloads/$filename"
    
    log "Extracting Loki..."
    if ! unzip -q -o "$download_path" -d "$INSTALL_DIR/../downloads/"; then
        error "Failed to extract Loki"
        exit 1
    fi
    
    if ! mv "$INSTALL_DIR/../downloads/loki-${OS}-${ARCH}" "$INSTALL_DIR/bin/loki"; then
        error "Failed to install Loki binary"
        exit 1
    fi
    
    chmod +x "$INSTALL_DIR/bin/loki"
    
    # Copy and adapt configuration
    cp "$INSTALL_DIR/../boilerplates/docker-compose/loki/config/config.yaml" "$INSTALL_DIR/config/loki/"
    # Update paths in config to use relative paths (handle macOS vs Linux sed differences)
    if [[ "$OS" == "darwin" ]]; then
        sed -i '' "s|/loki/chunks|./data/loki/chunks|g" "$INSTALL_DIR/config/loki/config.yaml"
        sed -i '' "s|/loki/rules|./data/loki/rules|g" "$INSTALL_DIR/config/loki/config.yaml"
        sed -i '' "s|path_prefix: /loki|path_prefix: ./data/loki|g" "$INSTALL_DIR/config/loki/config.yaml"
        sed -i '' "s|instance_addr: 127.0.0.1|instance_addr: 0.0.0.0|g" "$INSTALL_DIR/config/loki/config.yaml"
        sed -i '' "s|http_listen_port: 3100|http_listen_port: 3100\n  http_listen_address: 0.0.0.0|g" "$INSTALL_DIR/config/loki/config.yaml"
    else
        sed -i "s|/loki/chunks|./data/loki/chunks|g" "$INSTALL_DIR/config/loki/config.yaml"
        sed -i "s|/loki/rules|./data/loki/rules|g" "$INSTALL_DIR/config/loki/config.yaml"
        sed -i "s|path_prefix: /loki|path_prefix: ./data/loki|g" "$INSTALL_DIR/config/loki/config.yaml"
        sed -i "s|instance_addr: 127.0.0.1|instance_addr: 0.0.0.0|g" "$INSTALL_DIR/config/loki/config.yaml"
        sed -i "s|http_listen_port: 3100|http_listen_port: 3100\n  http_listen_address: 0.0.0.0|g" "$INSTALL_DIR/config/loki/config.yaml"
    fi
}

# Install Grafana from downloaded file
install_grafana() {
    log "Installing Grafana ${GRAFANA_VERSION}..."
    
    local filename="grafana-${GRAFANA_VERSION}.${OS}-${ARCH}.tar.gz"
    local download_path="$INSTALL_DIR/../downloads/$filename"
    
    log "Extracting Grafana..."
    # Clean up any previous extraction attempts
    rm -rf "$INSTALL_DIR/../downloads/grafana-"*/ 2>/dev/null || true
    
    if ! tar -xzf "$download_path" -C "$INSTALL_DIR/../downloads/"; then
        error "Failed to extract Grafana"
        exit 1
    fi
    
    # Find the extracted directory (name varies between versions)
    local grafana_dir=""
    for dir in "$INSTALL_DIR/../downloads"/grafana-*; do
        if [[ -d "$dir" ]]; then
            grafana_dir="$dir"
            break
        fi
    done
    
    if [[ -z "$grafana_dir" ]] || [[ ! -d "$grafana_dir" ]]; then
        error "Could not find extracted Grafana directory"
        log "Contents of downloads directory:"
        ls -la "$INSTALL_DIR/../downloads/" | grep grafana || true
        exit 1
    fi
    
    log "Found Grafana directory: $grafana_dir"
    
    log "Installing Grafana binaries..."
    if [[ -d "$grafana_dir/bin" ]]; then
        cp "$grafana_dir/bin/"* "$INSTALL_DIR/bin/"
        chmod +x "$INSTALL_DIR/bin/grafana"*
    else
        error "Grafana bin directory not found"
        exit 1
    fi
    
    # Copy resources
    log "Installing Grafana resources..."
    mkdir -p "$INSTALL_DIR/share/grafana"
    if [[ -d "$grafana_dir/public" ]] && [[ -d "$grafana_dir/conf" ]]; then
        cp -r "$grafana_dir"/{public,conf} "$INSTALL_DIR/share/grafana/"
    else
        error "Grafana resources (public/conf) not found"
        exit 1
    fi
    
    # Create datasource provisioning
    log "Creating datasource provisioning..."
    mkdir -p "$INSTALL_DIR/share/grafana/conf/provisioning/datasources"
    
    cat > "$INSTALL_DIR/share/grafana/conf/provisioning/datasources/datasources.yaml" << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
    version: 1
    uid: prometheus
    basicAuth: false
    
  - name: Loki
    type: loki
    access: proxy
    url: http://localhost:3100
    isDefault: false
    editable: true
    version: 1
    uid: loki
    basicAuth: false
    jsonData:
      maxLines: 1000
      derivedFields:
        - datasourceUid: prometheus
          matcherRegex: "traceID=(\\w+)"
          name: TraceID
          url: "$${__value.raw}"
EOF

    # Create default dashboard provisioning directory
    mkdir -p "$INSTALL_DIR/share/grafana/conf/provisioning/dashboards"
    mkdir -p "$INSTALL_DIR/data/grafana/dashboards"
    
    cat > "$INSTALL_DIR/share/grafana/conf/provisioning/dashboards/dashboards.yaml" << EOF
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: $INSTALL_DIR/data/grafana/dashboards
EOF

    # Create a simple system metrics dashboard
    cat > "$INSTALL_DIR/data/grafana/dashboards/system-metrics.json" << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "System Metrics",
    "tags": ["system", "metrics"],
    "style": "dark",
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "CPU Usage",
        "type": "stat",
        "targets": [
          {
            "expr": "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "percent"
          }
        },
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
      },
      {
        "id": 2,
        "title": "Memory Usage",
        "type": "stat",
        "targets": [
          {
            "expr": "100 * (1 - ((node_memory_MemAvailable_bytes or node_memory_MemFree_bytes) / node_memory_MemTotal_bytes))",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "percent"
          }
        },
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
      },
      {
        "id": 3,
        "title": "System Load",
        "type": "timeseries",
        "targets": [
          {
            "expr": "node_load1",
            "refId": "A",
            "legendFormat": "1m"
          },
          {
            "expr": "node_load5",
            "refId": "B",
            "legendFormat": "5m"
          },
          {
            "expr": "node_load15",
            "refId": "C",
            "legendFormat": "15m"
          }
        ],
        "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8}
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "30s",
    "version": 1
  }
}
EOF

    # Create a simple logs dashboard
    cat > "$INSTALL_DIR/data/grafana/dashboards/system-logs.json" << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "System Logs",
    "tags": ["logs", "system"],
    "style": "dark",
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "Recent Logs",
        "type": "logs",
        "targets": [
          {
            "expr": "{job=~\".+\"}",
            "refId": "A"
          }
        ],
        "gridPos": {"h": 20, "w": 24, "x": 0, "y": 0}
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "30s",
    "version": 1
  }
}
EOF
    
    # Clean up extracted directory but keep the downloaded archive
    rm -rf "$grafana_dir" 2>/dev/null || true
    
    # Create minimal config with relative paths (since grafana runs from install directory)
    cat > "$INSTALL_DIR/config/grafana/grafana.ini" << EOF
[paths]
data = data/grafana
logs = logs
plugins = data/grafana/plugins

[server]
http_port = 3000
http_addr = 0.0.0.0
domain = localhost
root_url = http://localhost:3000

[database]
type = sqlite3
path = data/grafana/grafana.db

[log]
mode = console file
level = info
EOF
}

# Create run scripts for each component
create_run_scripts() {
    log "Creating run scripts..."
    
    # Prometheus run script
    cat > "$INSTALL_DIR/scripts/run-prometheus.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INSTALL_DIR"

echo "Starting Prometheus on port 9090..."
"$INSTALL_DIR/bin/prometheus" \
  --config.file="$INSTALL_DIR/config/prometheus/prometheus.yaml" \
  --storage.tsdb.path="$INSTALL_DIR/data/prometheus" \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-remote-write-receiver \
  2>&1 | tee -a "$INSTALL_DIR/logs/prometheus.log"
EOF

    # Loki run script
    cat > "$INSTALL_DIR/scripts/run-loki.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INSTALL_DIR"

echo "Starting Loki on port 3100..."
"$INSTALL_DIR/bin/loki" \
  -config.file="$INSTALL_DIR/config/loki/config.yaml" \
  2>&1 | tee -a "$INSTALL_DIR/logs/loki.log"
EOF

    # Alloy run script
    cat > "$INSTALL_DIR/scripts/run-alloy.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INSTALL_DIR"

echo "Starting Alloy on port 12345..."
echo "Note: Alloy may need sudo/root access to read system logs"
"$INSTALL_DIR/bin/alloy" run \
  --server.http.listen-addr=0.0.0.0:12345 \
  --storage.path="$INSTALL_DIR/data/alloy" \
  "$INSTALL_DIR/config/alloy/config.alloy" \
  2>&1 | tee -a "$INSTALL_DIR/logs/alloy.log"
EOF

    # Grafana run script
    cat > "$INSTALL_DIR/scripts/run-grafana.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INSTALL_DIR/share/grafana"

echo "Starting Grafana on port 3000..."
# macOS vs Linux binary name difference
if [[ -f "$INSTALL_DIR/bin/grafana-server" ]]; then
    "$INSTALL_DIR/bin/grafana-server" \
      --config="$INSTALL_DIR/config/grafana/grafana.ini" \
      --homepath="$INSTALL_DIR/share/grafana" \
      2>&1 | tee -a "$INSTALL_DIR/logs/grafana.log"
else
    "$INSTALL_DIR/bin/grafana" server \
      --config="$INSTALL_DIR/config/grafana/grafana.ini" \
      --homepath="$INSTALL_DIR/share/grafana" \
      2>&1 | tee -a "$INSTALL_DIR/logs/grafana.log"
fi
EOF

    chmod +x "$INSTALL_DIR/scripts/run-"*.sh
}

# Create management scripts
create_management_scripts() {
    log "Creating management scripts..."
    
    # Start all script
    cat > "$INSTALL_DIR/scripts/start-all.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

echo "Starting observability stack..."
echo "Components will run in background. Use 'tail -f $INSTALL_DIR/logs/*.log' to view logs."
echo ""

# Start Loki first
echo "Starting Loki..."
nohup "$SCRIPT_DIR/run-loki.sh" > /dev/null 2>&1 &
echo $! > "$INSTALL_DIR/run/loki.pid"
sleep 2

# Start Prometheus
echo "Starting Prometheus..."
nohup "$SCRIPT_DIR/run-prometheus.sh" > /dev/null 2>&1 &
echo $! > "$INSTALL_DIR/run/prometheus.pid"
sleep 2

# Start Alloy (may need sudo)
echo "Starting Alloy..."
if [[ $EUID -eq 0 ]]; then
    nohup "$SCRIPT_DIR/run-alloy.sh" > /dev/null 2>&1 &
    echo $! > "$INSTALL_DIR/run/alloy.pid"
else
    echo "Note: Running Alloy without root access. Some system metrics may be unavailable."
    echo "Run with sudo for full system access."
    nohup "$SCRIPT_DIR/run-alloy.sh" > /dev/null 2>&1 &
    echo $! > "$INSTALL_DIR/run/alloy.pid"
fi
sleep 2

# Start Grafana
echo "Starting Grafana..."
nohup "$SCRIPT_DIR/run-grafana.sh" > /dev/null 2>&1 &
echo $! > "$INSTALL_DIR/run/grafana.pid"

echo ""
echo "Stack started! Access points:"
echo "  Grafana:    http://localhost:3000 (admin/admin)"
echo "  Prometheus: http://localhost:9090"
echo "  Loki:       http://localhost:3100"
echo "  Alloy:      http://localhost:12345"
echo ""
echo "Use '$SCRIPT_DIR/status.sh' to check status"
echo "Use '$SCRIPT_DIR/stop-all.sh' to stop all services"
EOF

    # Stop all script
    cat > "$INSTALL_DIR/scripts/stop-all.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

echo "Stopping observability stack..."

# Stop each service
for service in grafana alloy prometheus loki; do
    if [[ -f "$INSTALL_DIR/run/$service.pid" ]]; then
        PID=$(cat "$INSTALL_DIR/run/$service.pid")
        if ps -p $PID > /dev/null 2>&1; then
            echo "Stopping $service (PID: $PID)..."
            kill $PID
            # Give it time to shut down gracefully
            sleep 2
            # Force kill if still running
            if ps -p $PID > /dev/null 2>&1; then
                kill -9 $PID
            fi
        fi
        rm -f "$INSTALL_DIR/run/$service.pid"
    fi
done

echo "Stack stopped."
EOF

    # Status script
    cat > "$INSTALL_DIR/scripts/status.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Service Status ==="
for service in loki prometheus alloy grafana; do
    if [[ -f "$INSTALL_DIR/run/$service.pid" ]]; then
        PID=$(cat "$INSTALL_DIR/run/$service.pid")
        if ps -p $PID > /dev/null 2>&1; then
            echo "✓ $service is running (PID: $PID)"
        else
            echo "✗ $service is not running (stale PID file)"
        fi
    else
        echo "✗ $service is not running"
    fi
done

echo -e "\n=== Port Status ==="
echo "Checking ports..."
for port in 3000:Grafana 9090:Prometheus 3100:Loki 12345:Alloy; do
    IFS=':' read -r port_num service_name <<< "$port"
    if lsof -i :$port_num > /dev/null 2>&1 || netstat -an | grep -q ":$port_num.*LISTEN"; then
        echo "✓ $service_name ($port_num) is listening"
    else
        echo "✗ $service_name ($port_num) is not listening"
    fi
done

echo -e "\n=== Access URLs ==="
echo "Grafana:    http://localhost:3000 (admin/admin)"
echo "Prometheus: http://localhost:9090"
echo "Loki:       http://localhost:3100"  
echo "Alloy:      http://localhost:12345"
EOF

    # Run in foreground script (useful for debugging)
    cat > "$INSTALL_DIR/scripts/run-foreground.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running services in foreground (Ctrl+C to stop)..."
echo "Start each service in a separate terminal:"
echo ""
echo "Terminal 1: $SCRIPT_DIR/run-loki.sh"
echo "Terminal 2: $SCRIPT_DIR/run-prometheus.sh"
echo "Terminal 3: $SCRIPT_DIR/run-alloy.sh"
echo "Terminal 4: $SCRIPT_DIR/run-grafana.sh"
EOF

    chmod +x "$INSTALL_DIR/scripts/"*.sh
}

# Main installation flow
main() {
    log "Starting Grafana Observability Stack installation..."
    log "Install directory: $INSTALL_DIR"
    
    # Detect platform
    detect_platform
    
    # Check prerequisites
    command -v curl >/dev/null 2>&1 || { error "curl is required"; exit 1; }
    command -v unzip >/dev/null 2>&1 || { error "unzip is required"; exit 1; }
    
    # Check for tar (needed for archives)
    command -v tar >/dev/null 2>&1 || { error "tar is required"; exit 1; }
    
    # Check optional tools
    if command -v lsof >/dev/null 2>&1; then
        log "lsof found - port checking will work"
    else
        warn "lsof not found - port status checking may be limited"
    fi
    
    create_directories
    
    # Download all components in parallel
    download_all_components
    
    # Install components in order
    install_prometheus
    install_loki
    install_alloy
    install_grafana
    
    # Create management scripts
    create_run_scripts
    create_management_scripts
    
    # Clean up any remaining extracted files (but keep downloads)
    rm -rf "$INSTALL_DIR/../downloads"/prometheus-*/ 2>/dev/null || true
    rm -rf "$INSTALL_DIR/../downloads"/grafana-*/ 2>/dev/null || true
    rm -rf "$INSTALL_DIR/../downloads"/alloy-${OS}-${ARCH} 2>/dev/null || true
    rm -rf "$INSTALL_DIR/../downloads"/loki-${OS}-${ARCH} 2>/dev/null || true
    
    log "Installation complete!"
    echo
    echo "=== Quick Start ==="
    echo "1. Start all services:"
    echo "   $INSTALL_DIR/scripts/start-all.sh"
    echo
    echo "2. Or run individually in separate terminals:"
    echo "   $INSTALL_DIR/scripts/run-loki.sh"
    echo "   $INSTALL_DIR/scripts/run-prometheus.sh"
    echo "   $INSTALL_DIR/scripts/run-alloy.sh"
    echo "   $INSTALL_DIR/scripts/run-grafana.sh"
    echo
    echo "3. Access Grafana at http://localhost:3000 (admin/admin)"
    echo
    echo "4. Datasources are automatically configured:"
    echo "   - Prometheus: http://localhost:9090 (default)"
    echo "   - Loki: http://localhost:3100"
    echo "   - Pre-loaded dashboards: System Metrics & System Logs"
    echo
    echo "=== Management Scripts ==="
    echo "Start all:  $INSTALL_DIR/scripts/start-all.sh"
    echo "Stop all:   $INSTALL_DIR/scripts/stop-all.sh"
    echo "Status:     $INSTALL_DIR/scripts/status.sh"
    echo "View logs:  tail -f $INSTALL_DIR/logs/*.log"
}

main "$@"