#!/bin/bash

# AlloyKit - Complete Observability Stack Installer
# Single-file installer for Grafana Observability Stack with Podman
# Run with: curl -sSL https://your-server/alloykit.sh | bash
# 
# Usage: ./alloykit.sh [OPTIONS]
# Options:
#   --non-interactive    Run without prompts using defaults or config file
#   --dry-run           Preview changes without executing them
#   --config FILE       Use configuration file instead of prompts
#   --uninstall         Remove AlloyKit installation
#   --help              Show this help message

set -e  # Exit on any error

# Global flags
NON_INTERACTIVE=false
DRY_RUN=false
CONFIG_FILE=""
UNINSTALL=false
COMMAND=""
INSTANCE_FILTER=""
LOG_SERVICE=""

# Error handling and logging
LOG_FILE=""
ROLLBACK_ACTIONS=()
TEMP_FILES=()

# Network timeouts (in seconds)
CURL_TIMEOUT=30
CURL_CONNECT_TIMEOUT=10

# Component versions
ALLOY_VERSION="v1.9.2"
PROMETHEUS_VERSION="v3.4.2"
LOKI_VERSION="3.5.1"
GRAFANA_VERSION="12.0.2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    log_message "INFO" "$msg"
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    log_message "SUCCESS" "$msg"
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    log_message "WARNING" "$msg"
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg"
    log_message "ERROR" "$msg"
}

# Logging function
log_message() {
    local level="$1"
    local msg="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -n "$LOG_FILE" ]; then
        echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
    fi
}

# Setup logging
setup_logging() {
    if [ "$DRY_RUN" = false ]; then
        LOG_FILE="${INSTALL_DIR:-./alloykit}/alloykit-install.log"
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "AlloyKit Installation Log - $(date)" > "$LOG_FILE"
        log_message "INFO" "Installation started with PID: $$"
        log_message "INFO" "Command line: $0 $*"
    fi
}

# Cleanup function for exit
cleanup_on_exit() {
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        print_error "Installation failed with exit code: $exit_code"
        
        if [ ${#ROLLBACK_ACTIONS[@]} -gt 0 ]; then
            print_status "Performing rollback..."
            for ((i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i--)); do
                eval "${ROLLBACK_ACTIONS[i]}" 2>/dev/null || true
            done
        fi
    fi
    
    # Clean up temporary files
    for temp_file in "${TEMP_FILES[@]}"; do
        rm -f "$temp_file" 2>/dev/null || true
    done
    
    if [ -n "$LOG_FILE" ] && [ $exit_code -ne 0 ]; then
        echo ""
        print_error "Installation failed. Check log file: $LOG_FILE"
        echo "Last 10 log entries:"
        tail -10 "$LOG_FILE" 2>/dev/null || true
    fi
}

# Set up exit trap
trap cleanup_on_exit EXIT

# Add rollback action
add_rollback() {
    local action="$1"
    ROLLBACK_ACTIONS+=("$action")
    log_message "DEBUG" "Added rollback action: $action"
}

# Retry function for transient failures
retry_command() {
    local max_attempts="$1"
    local delay="$2"
    local description="$3"
    shift 3
    local cmd="$*"
    
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if [ $attempt -gt 1 ]; then
            print_status "Retry attempt $attempt/$max_attempts: $description"
            sleep $delay
        fi
        
        if eval "$cmd"; then
            return 0
        fi
        
        attempt=$((attempt + 1))
    done
    
    print_error "Failed after $max_attempts attempts: $description"
    return 1
}

# Container management functions
find_observability_containers() {
    local instance_filter="$1"
    local filter_pattern="obs-"
    
    local containers=$(podman ps -a --filter "name=${filter_pattern}" --format "{{.Names}}" 2>/dev/null | sort)
    
    if [ -z "$containers" ]; then
        if [ -n "$instance_filter" ]; then
            print_warning "No AlloyKit containers found for instance: $instance_filter"
        else
            print_warning "No AlloyKit containers found"
        fi
    fi
    
    echo "$containers"
}

find_observability_instances() {
    # Find all unique instance names from container names
    podman ps -a --filter "name=obs-" --format "{{.Names}}" 2>/dev/null | \
        sed -n 's/obs-.*-\(.*\)/\1/p' | sort -u
}

container_status() {
    local instance_filter="$1"
    
    print_status "AlloyKit Container Status"
    echo
    
    local containers
    containers=$(find_observability_containers "$instance_filter")
    
    if [ -z "$containers" ]; then
        if [ -n "$instance_filter" ]; then
            print_warning "No observability containers found for instance: $instance_filter"
        else
            print_warning "No observability containers found"
        fi
        echo
        echo "Available instances:"
        local instances
        instances=$(find_observability_instances)
        if [ -n "$instances" ]; then
            echo "$instances" | sed 's/^/  /'
        else
            echo "  None"
        fi
        return 0
    fi
    
    # Show detailed status
    echo "Container Status:"
    printf "%-30s %-15s %-20s %s\n" "NAME" "STATUS" "PORTS" "IMAGE"
    echo "$(printf '%.80s' "$(printf '%*s' 80 '' | tr ' ' '-')")"
    
    echo "$containers" | while read -r container; do
        if [ -n "$container" ]; then
            local status ports image
            status=$(podman ps -a --filter "name=$container" --format "{{.Status}}" 2>/dev/null)
            ports=$(podman ps -a --filter "name=$container" --format "{{.Ports}}" 2>/dev/null)
            image=$(podman ps -a --filter "name=$container" --format "{{.Image}}" 2>/dev/null | sed 's/.*\///')
            
            printf "%-30s %-15s %-20s %s\n" "$container" "$status" "$ports" "$image"
        fi
    done
    
    echo
    
    # Show summary by instance
    local instances
    instances=$(find_observability_instances)
    if [ -n "$instances" ]; then
        echo "Instance Summary:"
        echo "$instances" | while read -r instance; do
            if [ -n "$instance" ]; then
                local running stopped
                running=$(podman ps --filter "name=obs-.*-${instance}" --format "{{.Names}}" 2>/dev/null | wc -l)
                stopped=$(podman ps -a --filter "name=obs-.*-${instance}" --format "{{.Names}}" 2>/dev/null | wc -l)
                stopped=$((stopped - running))
                
                printf "  %-15s Running: %d, Stopped: %d\n" "$instance" "$running" "$stopped"
            fi
        done
    fi
}

container_start() {
    local instance_filter="$1"
    
    if [ -n "$instance_filter" ]; then
        print_status "Starting AlloyKit containers for instance: $instance_filter"
    else
        print_status "Starting all AlloyKit containers"
    fi
    
    local containers
    containers=$(find_observability_containers "$instance_filter")
    
    if [ -z "$containers" ]; then
        if [ -n "$instance_filter" ]; then
            print_error "No AlloyKit containers found for instance: $instance_filter"
        else
            print_error "No AlloyKit containers found"
            echo "Run AlloyKit installer first to create containers"
        fi
        return 1
    fi
    
    local started=0
    local failed=0
    
    echo "$containers" | while read -r container; do
        if [ -n "$container" ]; then
            echo -n "Starting $container... "
            if podman start "$container" >/dev/null 2>&1; then
                echo "✓"
                started=$((started + 1))
            else
                echo "✗"
                failed=$((failed + 1))
            fi
        fi
    done
    
    echo
    if [ $failed -eq 0 ]; then
        print_success "All containers started successfully"
    else
        print_warning "Some containers failed to start. Check logs with --logs"
    fi
    
    # Wait a moment and show status
    sleep 2
    container_status "$instance_filter"
}

container_stop() {
    local instance_filter="$1"
    
    if [ -n "$instance_filter" ]; then
        print_status "Stopping AlloyKit containers for instance: $instance_filter"
    else
        print_status "Stopping all AlloyKit containers"
    fi
    
    local containers
    containers=$(find_observability_containers "$instance_filter")
    
    if [ -z "$containers" ]; then
        if [ -n "$instance_filter" ]; then
            print_warning "No observability containers found for instance: $instance_filter"
        else
            print_warning "No observability containers found"
        fi
        return 0
    fi
    
    local stopped=0
    local failed=0
    
    echo "$containers" | while read -r container; do
        if [ -n "$container" ]; then
            echo -n "Stopping $container... "
            if podman stop "$container" >/dev/null 2>&1; then
                echo "✓"
                stopped=$((stopped + 1))
            else
                echo "✗"
                failed=$((failed + 1))
            fi
        fi
    done
    
    echo
    if [ $failed -eq 0 ]; then
        print_success "All containers stopped successfully"
    else
        print_warning "Some containers failed to stop"
    fi
}

container_restart() {
    local instance_filter="$1"
    
    print_status "Restarting AlloyKit containers"
    container_stop "$instance_filter"
    sleep 2
    container_start "$instance_filter"
}

container_logs() {
    local service="$1"
    local instance_filter="$2"
    
    case "$service" in
        prometheus)
            local container_pattern="obs-prometheus"
            ;;
        loki)
            local container_pattern="obs-loki"
            ;;
        grafana)
            local container_pattern="obs-grafana"
            ;;
        alloy)
            local container_pattern="obs-alloy"
            ;;
        *)
            print_error "Unknown service: $service"
            echo "Available services: prometheus, loki, grafana, alloy"
            return 1
            ;;
    esac
    
    if [ -n "$instance_filter" ]; then
        container_pattern="${container_pattern}-${instance_filter}"
    fi
    
    local containers
    containers=$(podman ps -a --filter "name=${container_pattern}" --format "{{.Names}}" 2>/dev/null)
    
    if [ -z "$containers" ]; then
        print_error "No $service containers found"
        if [ -n "$instance_filter" ]; then
            echo "Instance filter: $instance_filter"
        fi
        return 1
    fi
    
    local container_count
    container_count=$(echo "$containers" | wc -l)
    
    if [ "$container_count" -eq 1 ]; then
        local container
        container=$(echo "$containers" | head -1)
        print_status "Showing logs for: $container"
        echo "Press Ctrl+C to exit"
        echo
        podman logs -f "$container"
    else
        echo "Multiple $service containers found:"
        echo "$containers" | nl
        echo
        read -p "Select container number [1]: " selection
        selection=${selection:-1}
        
        local container
        container=$(echo "$containers" | sed -n "${selection}p")
        
        if [ -n "$container" ]; then
            print_status "Showing logs for: $container"
            echo "Press Ctrl+C to exit"
            echo
            podman logs -f "$container"
        else
            print_error "Invalid selection"
            return 1
        fi
    fi
}

container_clean() {
    local instance_filter="$1"
    
    if [ -n "$instance_filter" ]; then
        print_status "Cleaning AlloyKit containers and volumes for instance: $instance_filter"
    else
        print_status "Cleaning all AlloyKit containers and volumes"
    fi
    
    # Stop containers first
    container_stop "$instance_filter"
    
    # Remove containers
    local containers
    containers=$(find_observability_containers "$instance_filter")
    
    if [ -n "$containers" ]; then
        echo
        print_status "Removing containers..."
        echo "$containers" | while read -r container; do
            if [ -n "$container" ]; then
                echo -n "Removing $container... "
                if podman rm "$container" >/dev/null 2>&1; then
                    echo "✓"
                else
                    echo "✗"
                fi
            fi
        done
    fi
    
    # Remove volumes
    echo
    print_status "Removing volumes..."
    local volume_pattern="obs_.*_data"
    if [ -n "$instance_filter" ]; then
        volume_pattern="obs_.*_data_${instance_filter}"
    fi
    
    local volumes
    volumes=$(podman volume ls --format "{{.Name}}" | grep -E "${volume_pattern}" 2>/dev/null || true)
    
    if [ -n "$volumes" ]; then
        echo "$volumes" | while read -r volume; do
            if [ -n "$volume" ]; then
                echo -n "Removing volume $volume... "
                if podman volume rm "$volume" >/dev/null 2>&1; then
                    echo "✓"
                else
                    echo "✗"
                fi
            fi
        done
    else
        echo "No volumes found to remove"
    fi
    
    echo
    print_success "Cleanup completed"
}

# Check file/directory permissions for log monitoring
check_log_permissions() {
    local log_path="$1"
    local current_user=$(whoami)
    local current_uid=$(id -u)
    local current_gid=$(id -g)
    
    print_status "Checking permissions for log path: $log_path"
    
    # Expand tilde to home directory
    log_path="${log_path/#\~/$HOME}"
    
    # Expand wildcards and check each path
    for path in $log_path; do
        if [ -e "$path" ]; then
            # Check if file/directory is readable
            if [ -r "$path" ]; then
                print_success "✓ $path is readable"
            else
                print_warning "✗ $path is not readable by user $current_user"
                
                # Get file owner and permissions
                local file_info
                file_info=$(ls -la "$path" 2>/dev/null || echo "Permission denied")
                echo "  File info: $file_info"
                
                # Suggest solutions
                echo "  Possible solutions:"
                echo "    1. Add user to appropriate group: sudo usermod -a -G <group> $current_user"
                echo "    2. Change file permissions: sudo chmod +r $path"
                echo "    3. Run Alloy with elevated privileges"
                return 1
            fi
        else
            # Check parent directory permissions for wildcard paths
            local parent_dir=$(dirname "$path")
            if [ -d "$parent_dir" ]; then
                if [ -r "$parent_dir" ] && [ -x "$parent_dir" ]; then
                    print_success "✓ Parent directory $parent_dir is accessible"
                else
                    print_warning "✗ Parent directory $parent_dir is not accessible"
                    echo "  This may prevent log file discovery"
                    return 1
                fi
            else
                print_warning "✗ Path $path does not exist"
                echo "  Alloy will monitor for file creation"
            fi
        fi
    done
    
    return 0
}

# Add log location with permission checks
add_log_location() {
    local log_path="$1"
    local job_name="${2:-$(basename "$log_path" .log)}"
    local instance_name="${3:-${INSTANCE_NAME:-default}}"
    
    print_status "Adding log location: $log_path"
    
    # Check permissions first
    if ! check_log_permissions "$log_path"; then
        print_error "Permission check failed for $log_path"
        echo "Fix permissions before adding this log location"
        return 1
    fi
    
    # Expand tilde to home directory for Alloy config
    local expanded_log_path="${log_path/#\~/$HOME}"
    
    # Convert to container-accessible path (since host filesystem is mounted at /host/root)
    local container_log_path="/host/root${expanded_log_path}"
    
    # Sanitize job name
    job_name=$(echo "$job_name" | tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
    
    # Generate unique identifier
    local log_id="${job_name}_$(date +%s)"
    
    # Update Alloy configuration in the running container
    local alloy_container="obs-alloy-${instance_name}"
    
    if ! podman ps --filter "name=$alloy_container" --format "{{.Names}}" | grep -q "$alloy_container"; then
        print_error "Alloy container $alloy_container is not running"
        echo "Start the observability stack first"
        return 1
    fi
    
    # Create configuration snippet
    local config_snippet="
// SECTION: Custom Log - $job_name
// Added on $(date)

local.file_match \"$log_id\" {
  path_targets = [{
    __address__ = \"localhost\",
    __path__    = \"$container_log_path\",
    instance    = constants.hostname,
    job         = \"$job_name\",
  }]
}

loki.source.file \"$log_id\" {
  targets    = local.file_match.$log_id.targets
  forward_to = [loki.write.default.receiver]
}
"
    
    # Determine config file path
    local config_file="$INSTALL_DIR/config/alloy.alloy"
    if [ -z "$INSTALL_DIR" ]; then
        # Try to find config in current directory or common locations
        if [ -f "./config/alloy.alloy" ]; then
            config_file="./config/alloy.alloy"
        elif [ -f "./alloykit/config/alloy.alloy" ]; then
            config_file="./alloykit/config/alloy.alloy"
        else
            print_error "Cannot find Alloy configuration file"
            echo "Make sure you're in the AlloyKit installation directory"
            return 1
        fi
    fi
    
    if [ ! -f "$config_file" ]; then
        print_error "Alloy configuration file not found: $config_file"
        return 1
    fi
    
    print_status "Updating Alloy configuration: $config_file"
    
    # Backup original config
    local backup_file="${config_file}.backup.$(date +%s)"
    if ! cp "$config_file" "$backup_file"; then
        print_error "Failed to backup configuration file"
        return 1
    fi
    print_status "Created backup: $backup_file"
    
    # Append new configuration to the file
    echo "$config_snippet" >> "$config_file"
    
    print_success "Configuration updated for log path: $log_path"
    print_status "Job name: $job_name"
    
    # Restart Alloy container to apply changes
    print_status "Restarting Alloy container to apply configuration..."
    if podman restart "$alloy_container" >/dev/null 2>&1; then
        print_success "Alloy container restarted successfully"
        
        # Wait for Alloy to be ready (with retries)
        local alloy_port="${ALLOY_PORT:-12345}"
        local max_wait=30
        local wait_time=0
        
        print_status "Waiting for Alloy to be ready..."
        while [ $wait_time -lt $max_wait ]; do
            if curl -s "http://localhost:${alloy_port}/-/ready" >/dev/null 2>&1; then
                print_success "Alloy is running and ready"
                print_success "Log monitoring for '$job_name' is now active"
                break
            fi
            sleep 2
            wait_time=$((wait_time + 2))
            if [ $((wait_time % 10)) -eq 0 ]; then
                echo -n "."
            fi
        done
        
        if [ $wait_time -ge $max_wait ]; then
            print_warning "Alloy may still be starting up. Check logs if issues persist."
            echo "Check logs with: podman logs $alloy_container"
        fi
    else
        print_error "Failed to restart Alloy container"
        echo "You may need to restart manually: podman restart $alloy_container"
        return 1
    fi
    
    return 0
}

# Show help message
show_help() {
    cat << EOF
AlloyKit - Complete Observability Stack Installer & Container Manager

USAGE:
    $0 [OPTIONS] [COMMAND]

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

EXAMPLES:
    # Interactive installation
    $0

    # Non-interactive with defaults
    $0 --non-interactive

    # Use configuration file
    $0 --config observability.conf

    # Preview installation
    $0 --dry-run

    # Remove installation
    $0 --uninstall

    # Container management
    $0 --status                    # Show all containers
    $0 --status default            # Show containers for 'default' instance
    $0 --start                     # Start all containers
    $0 --start prod                # Start containers for 'prod' instance
    $0 --stop default              # Stop containers for 'default' instance
    $0 --restart                   # Restart all containers
    $0 --logs grafana              # Show Grafana logs
    $0 --logs alloy                # Show Alloy logs
    $0 --clean                     # Clean up all containers and volumes
    $0 --add-logs /var/log/nginx/*.log nginx  # Add nginx logs

CONFIGURATION FILE FORMAT:
    INSTALL_DIR=./alloykit
    INSTANCE_NAME=default
    GRAFANA_PORT=3000
    PROMETHEUS_PORT=9090
    LOKI_PORT=3100
    ALLOY_PORT=12345

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            --start)
                COMMAND="start"
                INSTANCE_FILTER="$2"
                if [[ "$2" =~ ^-- ]] || [[ -z "$2" ]]; then
                    shift
                else
                    shift 2
                fi
                ;;
            --stop)
                COMMAND="stop"
                INSTANCE_FILTER="$2"
                if [[ "$2" =~ ^-- ]] || [[ -z "$2" ]]; then
                    shift
                else
                    shift 2
                fi
                ;;
            --restart)
                COMMAND="restart"
                INSTANCE_FILTER="$2"
                if [[ "$2" =~ ^-- ]] || [[ -z "$2" ]]; then
                    shift
                else
                    shift 2
                fi
                ;;
            --status)
                COMMAND="status"
                INSTANCE_FILTER="$2"
                if [[ "$2" =~ ^-- ]] || [[ -z "$2" ]]; then
                    shift
                else
                    shift 2
                fi
                ;;
            --logs)
                COMMAND="logs"
                LOG_SERVICE="$2"
                if [[ -z "$2" ]] || [[ "$2" =~ ^-- ]]; then
                    print_error "--logs requires a service name (prometheus|loki|grafana|alloy)"
                    exit 1
                fi
                shift 2
                ;;
            --clean)
                COMMAND="clean"
                INSTANCE_FILTER="$2"
                if [[ "$2" =~ ^-- ]] || [[ -z "$2" ]]; then
                    shift
                else
                    shift 2
                fi
                ;;
            --add-logs)
                COMMAND="add-logs"
                LOG_PATH="$2"
                LOG_JOB="$3"
                
                if [[ -z "$LOG_PATH" ]]; then
                    print_error "--add-logs requires a log path"
                    exit 1
                fi
                
                # Shift past the log path and optional job name
                shift 2
                if [[ -n "$LOG_JOB" ]] && [[ ! "$LOG_JOB" =~ ^-- ]]; then
                    shift
                else
                    LOG_JOB=""
                fi
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Execute command with dry-run support
execute_cmd() {
    local cmd="$1"
    local description="$2"
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would execute: $description"
        echo "  Command: $cmd"
        return 0
    else
        if [ -n "$description" ]; then
            print_status "$description"
        fi
        eval "$cmd"
    fi
}

# Progress indicator for long operations
show_progress() {
    local pid=$1
    local message="$2"
    local delay=0.5
    local spinstr='|/-\'
    
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi
    
    echo -n "$message "
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
    echo ""
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validation functions
validate_port() {
    local port="$1"
    local name="$2"
    
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        print_error "Invalid $name port: $port (must be 1-65535)"
        return 1
    fi
    
    # Check if port is already in use
    if command_exists ss; then
        if ss -tuln | grep -q ":$port "; then
            print_warning "$name port $port is already in use"
            return 1
        fi
    elif command_exists netstat; then
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            print_warning "$name port $port is already in use"
            return 1
        fi
    fi
    
    return 0
}

validate_path() {
    local path="$1"
    local name="$2"
    
    # Check for invalid characters
    if [[ "$path" =~ [[:cntrl:]] ]]; then
        print_error "Invalid $name path: contains control characters"
        return 1
    fi
    
    # Check if parent directory exists or can be created
    local parent_dir=$(dirname "$path")
    if [ ! -d "$parent_dir" ]; then
        if ! mkdir -p "$parent_dir" 2>/dev/null; then
            print_error "Cannot create parent directory for $name: $parent_dir"
            return 1
        fi
    fi
    
    return 0
}

validate_name() {
    local name="$1"
    local field="$2"
    
    # Check for valid identifier (alphanumeric, underscore, hyphen)
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_error "Invalid $field: $name (only alphanumeric, underscore, and hyphen allowed)"
        return 1
    fi
    
    return 0
}

validate_config() {
    local errors=0
    
    print_status "Validating configuration..."
    
    # Validate paths
    if ! validate_path "$INSTALL_DIR" "installation directory"; then
        errors=$((errors + 1))
    fi
    
    # Validate names
    if ! validate_name "$INSTANCE_NAME" "instance name"; then
        errors=$((errors + 1))
    fi
    
    # Validate ports
    if ! validate_port "$GRAFANA_PORT" "Grafana"; then
        errors=$((errors + 1))
    fi
    
    if ! validate_port "$PROMETHEUS_PORT" "Prometheus"; then
        errors=$((errors + 1))
    fi
    
    if ! validate_port "$LOKI_PORT" "Loki"; then
        errors=$((errors + 1))
    fi
    
    if ! validate_port "$ALLOY_PORT" "Alloy"; then
        errors=$((errors + 1))
    fi
    
    # Check for port conflicts between services
    local ports=("$GRAFANA_PORT" "$PROMETHEUS_PORT" "$LOKI_PORT" "$ALLOY_PORT")
    for i in "${!ports[@]}"; do
        for j in "${!ports[@]}"; do
            if [ $i -ne $j ] && [ "${ports[$i]}" = "${ports[$j]}" ]; then
                print_error "Port conflict: Multiple services cannot use port ${ports[$i]}"
                errors=$((errors + 1))
                break 2
            fi
        done
    done
    
    if [ $errors -gt 0 ]; then
        print_error "Configuration validation failed with $errors error(s)"
        return 1
    fi
    
    print_success "Configuration validation passed"
    return 0
}

# Check and setup user namespaces for podman
setup_user_namespaces() {
    print_status "Checking user namespace configuration..."
    
    local user=$(whoami)
    local uid=$(id -u)
    local subuid_exists=false
    local subgid_exists=false
    
    # Check if user has subuid/subgid entries
    if [ -f /etc/subuid ] && grep -q "^${user}:" /etc/subuid; then
        subuid_exists=true
    fi
    
    if [ -f /etc/subgid ] && grep -q "^${user}:" /etc/subgid; then
        subgid_exists=true
    fi
    
    if [ "$subuid_exists" = false ] || [ "$subgid_exists" = false ]; then
        print_warning "User namespace configuration incomplete"
        echo "Adding user namespace entries..."
        
        # Try to add entries (may require sudo)
        if command_exists sudo; then
            if [ "$subuid_exists" = false ]; then
                echo "${user}:100000:65536" | sudo tee -a /etc/subuid >/dev/null
            fi
            if [ "$subgid_exists" = false ]; then
                echo "${user}:100000:65536" | sudo tee -a /etc/subgid >/dev/null
            fi
            print_success "User namespace entries added"
        else
            print_error "Cannot configure user namespaces without sudo access"
            echo "Please ask your administrator to add these lines:"
            echo "To /etc/subuid: ${user}:100000:65536"
            echo "To /etc/subgid: ${user}:100000:65536"
            exit 1
        fi
    else
        print_success "User namespaces properly configured"
    fi
}

# Load configuration from file
load_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        print_error "Configuration file not found: $config_file"
        exit 1
    fi
    
    print_status "Loading configuration from: $config_file"
    
    # Source the config file safely
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ -z $key ]] && continue
        
        # Remove quotes from value
        value=$(echo "$value" | sed 's/^["'\'']//' | sed 's/["'\'']$//')
        
        case $key in
            INSTALL_DIR|INSTANCE_NAME|GRAFANA_PORT|PROMETHEUS_PORT|LOKI_PORT|ALLOY_PORT)
                export "$key=$value"
                ;;
        esac
    done < "$config_file"
}

# Get user configuration
get_user_config() {
    # If config file specified, load it
    if [ -n "$CONFIG_FILE" ]; then
        load_config "$CONFIG_FILE"
        print_success "Configuration loaded from file"
        # Continue to validation and display
    fi
    
    # Set defaults for non-interactive mode (only if config file wasn't used)
    if [ "$NON_INTERACTIVE" = true ] && [ -z "$CONFIG_FILE" ]; then
        INSTALL_DIR=${INSTALL_DIR:-./alloykit}
        INSTANCE_NAME=${INSTANCE_NAME:-default}
        GRAFANA_PORT=${GRAFANA_PORT:-3000}
        PROMETHEUS_PORT=${PROMETHEUS_PORT:-9090}
        LOKI_PORT=${LOKI_PORT:-3100}
        ALLOY_PORT=${ALLOY_PORT:-12345}
        
        print_status "Using default configuration (non-interactive mode)"
    elif [ -z "$CONFIG_FILE" ]; then
        print_status "AlloyKit Configuration Setup"
        echo
        
        # Get installation directory
        read -p "Enter installation directory [./alloykit]: " INSTALL_DIR
        INSTALL_DIR=${INSTALL_DIR:-./alloykit}
        
        # Get instance name
        read -p "Enter instance name [default]: " INSTANCE_NAME
        INSTANCE_NAME=${INSTANCE_NAME:-default}
        
        # Get port numbers
        read -p "Enter Grafana port [3000]: " GRAFANA_PORT
        GRAFANA_PORT=${GRAFANA_PORT:-3000}
        
        read -p "Enter Prometheus port [9090]: " PROMETHEUS_PORT
        PROMETHEUS_PORT=${PROMETHEUS_PORT:-9090}
        
        read -p "Enter Loki port [3100]: " LOKI_PORT
        LOKI_PORT=${LOKI_PORT:-3100}
        
        read -p "Enter Alloy port [12345]: " ALLOY_PORT
        ALLOY_PORT=${ALLOY_PORT:-12345}
    fi
    
    # Create directory if it doesn't exist
    if [ ! -d "$INSTALL_DIR" ]; then
        execute_cmd "mkdir -p \"$INSTALL_DIR\"" "Creating directory: $INSTALL_DIR"
    fi
    
    # Convert to absolute path and change to it
    INSTALL_DIR=$(realpath "$INSTALL_DIR")
    if [ "$DRY_RUN" = false ]; then
        cd "$INSTALL_DIR"
    fi
    print_status "Using installation directory: $INSTALL_DIR"
    echo
    
    # Export for use in other functions
    export INSTALL_DIR INSTANCE_NAME GRAFANA_PORT PROMETHEUS_PORT LOKI_PORT ALLOY_PORT
    
    # Validate configuration
    if ! validate_config; then
        exit 1
    fi
    
    echo
    print_success "Configuration:"
    echo "  Installation: $INSTALL_DIR"
    echo "  Instance: $INSTANCE_NAME"
    echo "  Grafana Port: $GRAFANA_PORT"
    echo "  Prometheus Port: $PROMETHEUS_PORT"
    echo "  Loki Port: $LOKI_PORT"
    echo "  Alloy Port: $ALLOY_PORT"
    echo
}

# Get server IP for remote connections
get_server_ip() {
    local ip=""
    
    # Try multiple methods to get external IPv4 IP with timeouts
    if command_exists curl; then
        ip=$(curl -s -4 --connect-timeout $CURL_CONNECT_TIMEOUT --max-time $CURL_TIMEOUT ifconfig.me 2>/dev/null) || \
        ip=$(curl -s -4 --connect-timeout $CURL_CONNECT_TIMEOUT --max-time $CURL_TIMEOUT ipinfo.io/ip 2>/dev/null) || \
        ip=$(curl -s -4 --connect-timeout $CURL_CONNECT_TIMEOUT --max-time $CURL_TIMEOUT icanhazip.com 2>/dev/null)
    fi
    
    # Fallback to local IP
    if [ -z "$ip" ]; then
        ip=$(hostname -I | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    fi
    
    echo "$ip"
}

# Uninstall AlloyKit
uninstall_alloykit() {
    print_status "Starting AlloyKit uninstallation..."
    
    # Try to find existing installations
    local found_installations=()
    
    # Look for common installation directories
    for dir in "./alloykit" "$HOME/alloykit" "/opt/alloykit"; do
        if [ -d "$dir" ] && [ -f "$dir/docker-compose.yml" ]; then
            found_installations+=("$dir")
        fi
    done
    
    if [ ${#found_installations[@]} -eq 0 ]; then
        print_warning "No AlloyKit installations found"
        return 0
    fi
    
    echo "Found AlloyKit installations:"
    for i in "${!found_installations[@]}"; do
        echo "  $((i+1)). ${found_installations[$i]}"
    done
    echo
    
    if [ "$NON_INTERACTIVE" = false ]; then
        read -p "Select installation to remove [1]: " selection
        selection=${selection:-1}
    else
        selection=1
    fi
    
    if [ "$selection" -ge 1 ] && [ "$selection" -le ${#found_installations[@]} ]; then
        local install_dir="${found_installations[$((selection-1))]}"
        
        print_status "Removing AlloyKit installation: $install_dir"
        
        # Change to installation directory
        if [ "$DRY_RUN" = false ]; then
            cd "$install_dir"
        fi
        
        # Stop and clean containers
        container_clean ""
        
        # Remove installation directory
        execute_cmd "rm -rf \"$install_dir\"" "Removing installation directory"
        
        print_success "AlloyKit uninstalled successfully"
    else
        print_error "Invalid selection"
        exit 1
    fi
}

# Create Podman network for services
create_podman_network() {
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would create Podman network"
        return 0
    fi
    
    local network_name="obs-network-${INSTANCE_NAME}"
    
    # Check if network already exists
    if podman network exists "$network_name" 2>/dev/null; then
        print_status "Network $network_name already exists"
        return 0
    fi
    
    print_status "Creating Podman network: $network_name"
    if podman network create "$network_name" >/dev/null 2>&1; then
        print_success "Network created successfully"
        add_rollback "podman network rm $network_name 2>/dev/null || true"
    else
        print_error "Failed to create network"
        return 1
    fi
}

# Start containers using individual podman run commands
start_containers() {
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would start containers"
        return 0
    fi
    
    local network_name="obs-network-${INSTANCE_NAME}"
    
    # Detect if we need special userns flags for high UIDs
    local current_uid=$(id -u)
    local userns_flag=""
    
    if [ "$current_uid" -gt 100000 ]; then
        userns_flag="--user=0:0"
        print_status "Detected high UID ($current_uid), running containers as root user inside container"
    fi
    
    print_status "Starting containers..."
    
    # Start Prometheus
    print_status "Starting Prometheus..."
    podman run -d \
        --name "obs-prometheus-${INSTANCE_NAME}" \
        --replace \
        $userns_flag \
        --network "$network_name" \
        -p "${PROMETHEUS_PORT}:9090" \
        -v "${PWD}/config/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
        -v "obs_prometheus_data_${INSTANCE_NAME}:/prometheus" \
        docker.io/prom/prometheus:v${PROMETHEUS_VERSION#v} \
        --config.file=/etc/prometheus/prometheus.yml \
        --storage.tsdb.path=/prometheus \
        --web.console.libraries=/etc/prometheus/console_libraries \
        --web.console.templates=/etc/prometheus/consoles \
        --web.enable-lifecycle \
        --web.enable-remote-write-receiver
    
    add_rollback "podman stop obs-prometheus-${INSTANCE_NAME} 2>/dev/null || true"
    add_rollback "podman rm obs-prometheus-${INSTANCE_NAME} 2>/dev/null || true"
    
    # Start Loki
    print_status "Starting Loki..."
    podman run -d \
        --name "obs-loki-${INSTANCE_NAME}" \
        --replace \
        $userns_flag \
        --network "$network_name" \
        -p "${LOKI_PORT}:3100" \
        -v "${PWD}/config/loki.yml:/etc/loki/local-config.yaml:ro" \
        -v "obs_loki_data_${INSTANCE_NAME}:/loki" \
        docker.io/grafana/loki:${LOKI_VERSION} \
        -config.file=/etc/loki/local-config.yaml
    
    add_rollback "podman stop obs-loki-${INSTANCE_NAME} 2>/dev/null || true"
    add_rollback "podman rm obs-loki-${INSTANCE_NAME} 2>/dev/null || true"
    
    # Start Grafana
    print_status "Starting Grafana..."
    podman run -d \
        --name "obs-grafana-${INSTANCE_NAME}" \
        --replace \
        $userns_flag \
        --network "$network_name" \
        -p "${GRAFANA_PORT}:3000" \
        -v "obs_grafana_data_${INSTANCE_NAME}:/var/lib/grafana" \
        -v "${PWD}/config/grafana/provisioning:/etc/grafana/provisioning:ro" \
        -v "${PWD}/config/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
        -e GF_SECURITY_ADMIN_PASSWORD=admin \
        -e GF_USERS_ALLOW_SIGN_UP=false \
        docker.io/grafana/grafana:${GRAFANA_VERSION}
    
    add_rollback "podman stop obs-grafana-${INSTANCE_NAME} 2>/dev/null || true"
    add_rollback "podman rm obs-grafana-${INSTANCE_NAME} 2>/dev/null || true"
    
    # Start Alloy
    print_status "Starting Alloy..."
    podman run -d \
        --name "obs-alloy-${INSTANCE_NAME}" \
        --replace \
        $userns_flag \
        --network "$network_name" \
        --privileged \
        -p "${ALLOY_PORT}:12345" \
        -v "${PWD}/config/alloy.alloy:/etc/alloy/config.alloy:ro" \
        -v "obs_alloy_data_${INSTANCE_NAME}:/var/lib/alloy/data" \
        -v "/var/log:/var/log:ro" \
        -v "/proc:/host/proc:ro" \
        -v "/sys:/host/sys:ro" \
        -v "/:/host/root:ro" \
        docker.io/grafana/alloy:${ALLOY_VERSION} \
        run \
        --server.http.listen-addr=0.0.0.0:12345 \
        --storage.path=/var/lib/alloy/data \
        /etc/alloy/config.alloy
    
    add_rollback "podman stop obs-alloy-${INSTANCE_NAME} 2>/dev/null || true"
    add_rollback "podman rm obs-alloy-${INSTANCE_NAME} 2>/dev/null || true"
    
    print_success "All containers started"
}

# Wait for services to be ready
wait_for_services() {
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would wait for services to be ready"
        return 0
    fi
    
    print_status "Waiting for services to be ready..."
    
    local max_attempts=60
    local attempt=0
    
    # Wait for Prometheus
    print_status "Checking Prometheus..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://localhost:${PROMETHEUS_PORT}/-/ready" >/dev/null 2>&1; then
            print_success "Prometheus is ready"
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            echo -n "."
        fi
    done
    
    if [ $attempt -eq $max_attempts ]; then
        print_warning "Prometheus may not be fully ready yet"
    fi
    
    # Wait for Loki
    attempt=0
    print_status "Checking Loki..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://localhost:${LOKI_PORT}/ready" >/dev/null 2>&1; then
            print_success "Loki is ready"
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            echo -n "."
        fi
    done
    
    if [ $attempt -eq $max_attempts ]; then
        print_warning "Loki may not be fully ready yet"
    fi
    
    # Wait for Grafana
    attempt=0
    print_status "Checking Grafana..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://localhost:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
            print_success "Grafana is ready"
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            echo -n "."
        fi
    done
    
    if [ $attempt -eq $max_attempts ]; then
        print_warning "Grafana may not be fully ready yet"
    fi
    
    # Wait for Alloy
    attempt=0
    print_status "Checking Alloy..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "http://localhost:${ALLOY_PORT}/-/ready" >/dev/null 2>&1; then
            print_success "Alloy is ready"
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            echo -n "."
        fi
    done
    
    if [ $attempt -eq $max_attempts ]; then
        print_warning "Alloy may not be fully ready yet"
    fi
    
    print_success "Service health checks completed"
}

# Create embedded files function
create_files() {
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would create configuration files in: $INSTALL_DIR"
        return 0
    fi
    
    print_status "Creating configuration files..."
    
    # Create pyproject.toml for UV
    cat > pyproject.toml << EOF
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "alloykit"
version = "0.1.0"
description = "AlloyKit - Complete observability stack with Grafana, Prometheus, Loki, and Alloy"
requires-python = ">=3.10"

dependencies = [
    "click>=8.0.0",
    "rich>=13.0.0",
    "pyyaml>=6.0.0",
    "taskipy>=1.12.0",
]

[tool.hatch.build.targets.wheel]
packages = ["alloykit"]

[tool.taskipy.tasks]
# Container management
start = "podman start obs-prometheus-${INSTANCE_NAME} obs-loki-${INSTANCE_NAME} obs-grafana-${INSTANCE_NAME} obs-alloy-${INSTANCE_NAME} 2>/dev/null || echo 'Some containers may not exist yet. Run installer first.'"
stop = "podman stop obs-prometheus-${INSTANCE_NAME} obs-loki-${INSTANCE_NAME} obs-grafana-${INSTANCE_NAME} obs-alloy-${INSTANCE_NAME} 2>/dev/null || true"
restart = "podman restart obs-prometheus-${INSTANCE_NAME} obs-loki-${INSTANCE_NAME} obs-grafana-${INSTANCE_NAME} obs-alloy-${INSTANCE_NAME} 2>/dev/null || true"
status = "podman ps --filter 'name=obs-.*-${INSTANCE_NAME}'"
logs = "echo 'Use logs-<service> for specific service logs'"
clean = "podman stop obs-prometheus-${INSTANCE_NAME} obs-loki-${INSTANCE_NAME} obs-grafana-${INSTANCE_NAME} obs-alloy-${INSTANCE_NAME} 2>/dev/null || true && podman rm obs-prometheus-${INSTANCE_NAME} obs-loki-${INSTANCE_NAME} obs-grafana-${INSTANCE_NAME} obs-alloy-${INSTANCE_NAME} 2>/dev/null || true && podman volume rm obs_prometheus_data_${INSTANCE_NAME} obs_loki_data_${INSTANCE_NAME} obs_grafana_data_${INSTANCE_NAME} obs_alloy_data_${INSTANCE_NAME} 2>/dev/null || true"

# Individual service logs
logs-prometheus = "podman logs -f obs-prometheus-${INSTANCE_NAME}"
logs-loki = "podman logs -f obs-loki-${INSTANCE_NAME}"
logs-grafana = "podman logs -f obs-grafana-${INSTANCE_NAME}"
logs-alloy = "podman logs -f obs-alloy-${INSTANCE_NAME}"
EOF

    # Create dummy Python module to satisfy packaging
    mkdir -p alloykit
    echo "# AlloyKit - Complete Observability Stack" > alloykit/__init__.py
    
    # Create docker-compose.yml for podman compose
    cat > docker-compose.yml << EOF
version: '3.8'

services:
  prometheus:
    image: docker.io/prom/prometheus:v${PROMETHEUS_VERSION#v}
    container_name: obs-prometheus-${INSTANCE_NAME}
    ports:
      - "${PROMETHEUS_PORT}:9090"
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - obs_prometheus_data_${INSTANCE_NAME}:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
      - '--web.enable-remote-write-receiver'
    restart: unless-stopped

  loki:
    image: docker.io/grafana/loki:${LOKI_VERSION}
    container_name: obs-loki-${INSTANCE_NAME}
    ports:
      - "${LOKI_PORT}:3100"
    volumes:
      - ./config/loki.yml:/etc/loki/local-config.yaml:ro
      - obs_loki_data_${INSTANCE_NAME}:/loki
    command: -config.file=/etc/loki/local-config.yaml
    restart: unless-stopped

  grafana:
    image: docker.io/grafana/grafana:${GRAFANA_VERSION}
    container_name: obs-grafana-${INSTANCE_NAME}
    ports:
      - "${GRAFANA_PORT}:3000"
    volumes:
      - obs_grafana_data_${INSTANCE_NAME}:/var/lib/grafana
      - ./config/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./config/grafana/dashboards:/var/lib/grafana/dashboards:ro
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    restart: unless-stopped

  alloy:
    image: docker.io/grafana/alloy:${ALLOY_VERSION}
    container_name: obs-alloy-${INSTANCE_NAME}
    ports:
      - "${ALLOY_PORT}:12345"
    volumes:
      - ./config/alloy.alloy:/etc/alloy/config.alloy:ro
      - obs_alloy_data_${INSTANCE_NAME}:/var/lib/alloy/data
      - /var/log:/var/log:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host/root:ro
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    restart: unless-stopped
    privileged: true

volumes:
  obs_prometheus_data_${INSTANCE_NAME}:
  obs_loki_data_${INSTANCE_NAME}:
  obs_grafana_data_${INSTANCE_NAME}:
  obs_alloy_data_${INSTANCE_NAME}:
EOF

    # Create config directory structure
    mkdir -p config/grafana/{provisioning/datasources,provisioning/dashboards,dashboards}
    
    # Create Prometheus configuration
    cat > config/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  # - "first_rules.yml"
  # - "second_rules.yml"

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'alloy'
    static_configs:
      - targets: ['obs-alloy-${INSTANCE_NAME}:12345']
EOF

    # Create Loki configuration
    cat > config/loki.yml << EOF
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

ruler:
  alertmanager_url: http://localhost:9093

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h

compactor:
  working_directory: /loki/compactor

ingester:
  wal:
    enabled: true
    dir: /loki/wal
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
    final_sleep: 0s
  chunk_idle_period: 1h
  max_chunk_age: 1h
  chunk_target_size: 1048576
  chunk_retain_period: 30s
EOF

    # Create Alloy configuration based on the comprehensive boilerplate
    cat > config/alloy.alloy << EOF
/* AlloyKit Configuration
 * Based on Grafana Alloy Configuration Examples
 * For more details, visit https://github.com/grafana/alloy-scenarios
 */

// SECTION: TARGETS

loki.write "default" {
	endpoint {
		url = "http://obs-loki-${INSTANCE_NAME}:3100/loki/api/v1/push"
	}
	external_labels = {}
}

prometheus.remote_write "default" {
  endpoint {
    url = "http://obs-prometheus-${INSTANCE_NAME}:9090/api/v1/write"
  }
}

// SECTION: SYSTEM LOGS & JOURNAL

loki.source.journal "journal" {
  max_age       = "24h0m0s"
  relabel_rules = discovery.relabel.journal.rules
  forward_to    = [loki.write.default.receiver]
  labels        = {component = string.format("%s-journal", constants.hostname)}
  // NOTE: This is important to fix https://github.com/grafana/alloy/issues/924
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

// SECTION: CONTAINER METRICS (Podman/Docker)

prometheus.exporter.cadvisor "containermetrics" {
  docker_host = "unix:///run/user/\$(id -u)/podman/podman.sock"
  storage_duration = "5m"
}

prometheus.scrape "containermetrics" {
  targets    = prometheus.exporter.cadvisor.containermetrics.targets
  forward_to = [ prometheus.remote_write.default.receiver ]
  scrape_interval = "10s"
}

// SECTION: CONTAINER LOGS (Podman/Docker)

discovery.docker "containerlogs" {
  host = "unix:///run/user/\$(id -u)/podman/podman.sock"
}

discovery.relabel "containerlogs" {
      targets = []
  
      rule {
          source_labels = ["__meta_docker_container_name"]
          regex = "/(.*)"
          target_label = "service_name"
      }
  }

loki.source.docker "containers" {
  host       = "unix:///run/user/\$(id -u)/podman/podman.sock"
  targets    = discovery.docker.containerlogs.targets
  labels     = {"platform" = "podman"}
  relabel_rules = discovery.relabel.containerlogs.rules
  forward_to = [loki.write.default.receiver]
}
EOF

    # Create Grafana datasource provisioning
    cat > config/grafana/provisioning/datasources/datasources.yml << EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://obs-prometheus-${INSTANCE_NAME}:9090
    isDefault: true
    editable: true
    version: 1
    uid: prometheus
    basicAuth: false
    jsonData:
      timeInterval: "5s"
      queryTimeout: "60s"
    
  - name: Loki
    type: loki
    access: proxy
    url: http://obs-loki-${INSTANCE_NAME}:3100
    isDefault: false
    editable: true
    version: 1
    uid: loki
    basicAuth: false
    jsonData:
      maxLines: 1000
      timeout: 60
      derivedFields:
        - datasourceUid: prometheus
          matcherRegex: "traceID=([a-zA-Z0-9]+)"
          name: TraceID
          url: "\$\${__value.raw}"
EOF

    # Create dashboard provisioning
    cat > config/grafana/provisioning/dashboards/dashboards.yml << EOF
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
      path: /var/lib/grafana/dashboards
EOF

    # Create system metrics dashboard
    cat > config/grafana/dashboards/system-metrics.json << 'EOF'
{
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
      }
    ],
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "30s",
    "version": 1
}
EOF

    # Create system logs dashboard
    cat > config/grafana/dashboards/system-logs.json << 'EOF'
{
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
EOF

    # Copy and process main dashboard.json if it exists
    if [ -f "../dashboard.json" ]; then
        print_status "Processing dashboard template..."
        # Create temporary jq script
        cat > /tmp/process_dashboard.jq << 'EOF'
del(.__inputs, .__elements) | 
walk(if type == "string" and . == "${DS_PROMETHEUS}" then "prometheus" else . end)
EOF
        # Process dashboard template
        if command_exists jq; then
            jq -f /tmp/process_dashboard.jq "../dashboard.json" > "config/grafana/dashboards/main-dashboard.json"
            rm -f /tmp/process_dashboard.jq
            print_success "Dashboard template processed with jq"
        else
            # Fallback to simple copy
            cp "../dashboard.json" "config/grafana/dashboards/main-dashboard.json"
            print_warning "jq not found, dashboard may need manual datasource configuration"
        fi
    fi

    print_success "Configuration files created"
}

# Install podman if missing
install_podman() {
    if ! command_exists podman; then
        if [ "$DRY_RUN" = true ]; then
            print_status "[DRY RUN] Would install Podman"
            return 0
        fi
        
        print_status "Installing Podman..."
        
        # Detect OS and install podman
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case $ID in
                ubuntu|debian)
                    if command_exists apt-get; then
                        execute_cmd "sudo apt-get update && sudo apt-get install -y podman" "Installing Podman via apt"
                    else
                        print_error "apt-get not found on Debian/Ubuntu system"
                        exit 1
                    fi
                    ;;
                fedora|centos|rhel)
                    if command_exists dnf; then
                        execute_cmd "sudo dnf install -y podman" "Installing Podman via dnf"
                    elif command_exists yum; then
                        execute_cmd "sudo yum install -y podman" "Installing Podman via yum"
                    else
                        print_error "Package manager not found on RHEL/CentOS/Fedora system"
                        exit 1
                    fi
                    ;;
                *)
                    print_error "Unsupported OS: $ID"
                    echo "Please install Podman manually: https://podman.io/docs/installation"
                    exit 1
                    ;;
            esac
        else
            print_error "Cannot detect OS. Please install Podman manually."
            exit 1
        fi
        
        if command_exists podman; then
            print_success "Podman installed successfully"
        else
            print_error "Failed to install Podman"
            exit 1
        fi
    else
        print_success "Podman found"
    fi
}

# Install UV package manager if missing
install_uv() {
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would install UV package manager"
        return 0
    fi
    
    print_status "UV not found. Installing UV..."
    
    # Create temp directory for download
    TEMP_DIR=$(mktemp -d)
    TEMP_FILES+=("$TEMP_DIR")
    
    # Download installer script with timeout and retry
    local install_script="$TEMP_DIR/install.sh"
    
    if ! retry_command 3 2 "UV installer download" \
        "curl -LsSf --connect-timeout $CURL_CONNECT_TIMEOUT --max-time $CURL_TIMEOUT https://astral.sh/uv/install.sh -o \"$install_script\""; then
        print_error "Failed to download UV installer after multiple attempts"
        echo "Manual installation: curl -LsSf https://astral.sh/uv/install.sh | sh"
        return 1
    fi
    
    # Verify download
    if [ ! -f "$install_script" ] || [ ! -s "$install_script" ]; then
        print_error "UV installer download appears to be corrupted"
        return 1
    fi
    
    # Install UV
    if ! bash "$install_script"; then
        print_error "UV installation failed"
        echo "Try manual installation: curl -LsSf https://astral.sh/uv/install.sh | sh"
        return 1
    fi
    
    # Add to PATH and reload
    export PATH="$HOME/.local/bin:$PATH"
    add_rollback "export PATH=\"\${PATH//:$HOME\/.local\/bin/}\""
    
    # Source shell profile to persist PATH changes
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
            add_rollback "sed -i '/export PATH=\"\$HOME\/.local\/bin:\$PATH\"/d' \"$HOME/.bashrc\""
        fi
    fi
    
    # Verify installation
    if command_exists uv; then
        print_success "UV installed successfully"
        return 0
    else
        print_error "UV installation completed but command not found"
        echo "Try adding $HOME/.local/bin to your PATH manually"
        return 1
    fi
}

# Parse command line arguments first
parse_args "$@"

# Handle container management commands
if [ -n "$COMMAND" ]; then
    case "$COMMAND" in
        status)
            container_status "$INSTANCE_FILTER"
            exit 0
            ;;
        start)
            container_start "$INSTANCE_FILTER"
            exit 0
            ;;
        stop)
            container_stop "$INSTANCE_FILTER"
            exit 0
            ;;
        restart)
            container_restart "$INSTANCE_FILTER"
            exit 0
            ;;
        logs)
            container_logs "$LOG_SERVICE" "$INSTANCE_FILTER"
            exit 0
            ;;
        clean)
            container_clean "$INSTANCE_FILTER"
            exit 0
            ;;
        add-logs)
            add_log_location "$LOG_PATH" "$LOG_JOB"
            exit 0
            ;;
        *)
            print_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
fi

# Handle uninstall mode
if [ "$UNINSTALL" = true ]; then
    uninstall_alloykit
    exit 0
fi

echo "=================================================="
echo "         AlloyKit - Observability Stack"
echo "=================================================="
if [ "$DRY_RUN" = true ]; then
    echo "                   [DRY RUN MODE]"
    echo "=================================================="
fi
echo ""

# Get user configuration
get_user_config

# Setup logging after we know the install directory
setup_logging

# Check prerequisites
print_status "Checking prerequisites..."

# Check if running as root (not recommended for podman)
if [ "$EUID" -eq 0 ]; then
    print_warning "Running as root. Podman rootless mode is recommended."
    echo "Consider running as a regular user instead."
fi

# Install podman if needed
install_podman

# Setup user namespaces for podman
setup_user_namespaces

# Check UV package manager with enhanced error handling
if ! command_exists uv; then
    if ! install_uv; then
        exit 1
    fi
else
    print_success "UV found"
    # Check UV version for compatibility
    UV_VERSION=$(uv --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$UV_VERSION" ]; then
        log_message "INFO" "UV version: $UV_VERSION"
    fi
fi

# Test podman configuration
if [ "$DRY_RUN" = false ]; then
    print_status "Testing podman configuration..."
    if ! podman info >/dev/null 2>&1; then
        print_error "Podman configuration issues detected"
        echo "Try: podman system reset (WARNING: removes all containers/images)"
        exit 1
    fi
    print_success "Podman configuration verified"
fi

# Create all configuration files
create_files
add_rollback "rm -rf \"$INSTALL_DIR\" 2>/dev/null || true"

# Install Python dependencies with error handling
install_python_deps() {
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would install Python dependencies"
        return 0
    fi
    
    print_status "Installing Python dependencies..."
    
    # Force UV to use local directory, not parent venv
    unset VIRTUAL_ENV
    
    # Create virtual environment with Python 3.10+ and error handling
    if ! uv venv --python 3.10; then
        print_warning "Failed to create venv with Python 3.10, trying default Python"
        if ! uv venv; then
            print_error "Failed to create virtual environment"
            echo "Try manually: cd $INSTALL_DIR && uv venv"
            return 1
        fi
    fi
    add_rollback "rm -rf \"$INSTALL_DIR/.venv\" 2>/dev/null || true"
    
    # Install dependencies with retry
    if ! retry_command 3 5 "Python dependency installation" "uv sync"; then
        print_error "Failed to install Python dependencies"
        echo ""
        echo "Troubleshooting steps:"
        echo "1. Check internet connection"
        echo "2. Try manual installation: cd $INSTALL_DIR && uv sync"
        echo "3. Check UV configuration: uv --version"
        echo "4. Clear UV cache: uv cache clean"
        return 1
    fi
    
    print_success "Python dependencies installed"
    return 0
}

if ! install_python_deps; then
    exit 1
fi

# Create Podman network
create_podman_network

# Start services
if [ "$DRY_RUN" = true ]; then
    print_status "[DRY RUN] Would start AlloyKit services"
else
    start_containers
    wait_for_services
fi

# Get server IP for remote connections
SERVER_IP=$(get_server_ip)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_SERVER_IP"
    print_warning "Could not determine server IP automatically"
fi

# Print connection information
echo ""
echo "=================================================="
print_success "AlloyKit Setup Complete!"
echo "=================================================="
echo ""
echo "Services Status:"
echo "  Grafana:    http://$SERVER_IP:$GRAFANA_PORT (admin/admin)"
echo "  Prometheus: http://$SERVER_IP:$PROMETHEUS_PORT"
echo "  Loki:       http://$SERVER_IP:$LOKI_PORT"
echo "  Alloy:      http://$SERVER_IP:$ALLOY_PORT"
echo ""
echo "Management Commands:"
echo "  Status:     ./alloykit.sh --status"
echo "  Stop:       ./alloykit.sh --stop"
echo "  Restart:    ./alloykit.sh --restart"
echo "  Logs:       ./alloykit.sh --logs grafana"
echo "  Add logs:   ./alloykit.sh --add-logs /var/log/nginx/*.log nginx"
echo "  Cleanup:    ./alloykit.sh --clean"
echo ""
echo "UV Task Commands (from installation directory):"
echo "  Start:      uv run task start"
echo "  Stop:       uv run task stop"
echo "  Restart:    uv run task restart"
echo "  Status:     uv run task status"
echo "  Logs:       uv run task logs"
echo "  Clean:      uv run task clean"
echo ""
echo "Installation Directory: $INSTALL_DIR"
echo ""
echo "=================================================="
print_success "AlloyKit ready for monitoring and observability!"
echo "=================================================="