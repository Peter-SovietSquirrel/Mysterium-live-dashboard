#!/bin/bash

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Mysterium Live Dashboard Uninstaller                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root (use sudo)"
    exit 1
fi

read -p "This will remove all dashboard files and services. Continue? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled"
    exit 0
fi

echo ""
echo "Removing services..."

for service in mysterium-sessions mysterium-quality mysterium-webserver; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        systemctl stop "$service"
        echo "✓ Stopped $service"
    fi
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        systemctl disable "$service"
        echo "✓ Disabled $service"
    fi
    if [ -f "/etc/systemd/system/${service}.service" ]; then
        rm -f "/etc/systemd/system/${service}.service"
        echo "✓ Removed ${service}.service"
    fi
done

systemctl daemon-reload
echo "✓ systemd reloaded"

echo ""
echo "Removing installation directory..."
if [ -d "/opt/mysterium-dashboard" ]; then
    rm -rf /opt/mysterium-dashboard
    echo "✓ Removed /opt/mysterium-dashboard"
else
    echo "  /opt/mysterium-dashboard not found, skipping"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Uninstall Complete                                      ║"
echo "╚════════════════════════════════════════════════════════════╝"
