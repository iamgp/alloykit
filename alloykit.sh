#!/bin/bash

# AlloyKit - Complete Observability Stack Installer
# Simple launcher that checks for gum and uses enhanced interface

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure PATH includes local bin
export PATH="$HOME/.local/bin:$PATH"

# Check if gum is available
if command -v gum >/dev/null 2>&1; then
    # Gum is available, use the enhanced interface
    exec "$SCRIPT_DIR/alloykit-gum" "$@"
fi

# Try to install gum if we can
if command -v wget >/dev/null 2>&1 && command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    echo "• Installing Gum for enhanced interface..."

    # Download and install gum
    if wget -q -O /tmp/gum.deb https://github.com/charmbracelet/gum/releases/download/v0.16.2/gum_0.16.2_amd64.deb 2>/dev/null; then
        mkdir -p ~/.local/bin
        cd /tmp
        ar x gum.deb 2>/dev/null
        tar -xf data.tar.gz 2>/dev/null
        cp usr/bin/gum ~/.local/bin/ 2>/dev/null
        chmod +x ~/.local/bin/gum 2>/dev/null
        rm -f control.tar.gz data.tar.gz debian-binary _gpgorigin 2>/dev/null
        rm -rf etc usr 2>/dev/null
        cd "$SCRIPT_DIR"

        # Check if installation worked
        if command -v gum >/dev/null 2>&1; then
            echo "✓ Gum installed successfully! Using enhanced interface..."
            exec "$SCRIPT_DIR/alloykit-gum" "$@"
        fi
    fi
fi
