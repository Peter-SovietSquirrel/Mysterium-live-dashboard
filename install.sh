#!/bin/bash

set -e

echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Mysterium Live Dashboard Installer                      ║"
echo "║   Created by Peter (Peter-SovietSquirrel)                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Please run as root (use sudo)"
    exit 1
fi

# Check dependencies
echo "Checking dependencies..."
MISSING_DEPS=()

if ! command -v curl &> /dev/null; then
    MISSING_DEPS+=("curl")
fi

if ! command -v jq &> /dev/null; then
    MISSING_DEPS+=("jq")
fi

if ! command -v python3 &> /dev/null; then
    MISSING_DEPS+=("python3")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "❌ Missing dependencies: ${MISSING_DEPS[*]}"
    echo "Install with: sudo apt-get install ${MISSING_DEPS[*]}"
    exit 1
fi

echo "✓ All dependencies found"
echo ""

# Detect nodes
echo "═══════════════════════════════════════════════════════════"
echo "STEP 1: Detecting Mysterium nodes..."
echo "═══════════════════════════════════════════════════════════"
DETECTED_NODES=()

# Check for native node
if systemctl is-active --quiet mysterium-node; then
    NATIVE_PORT=$(grep -r "tequilapi-port" /etc/mysterium-node/ 2>/dev/null | grep -oP '\d+' | head -1)
    NATIVE_PORT=${NATIVE_PORT:-4449}
    echo "✓ Found native node on port $NATIVE_PORT"
    DETECTED_NODES+=("native:127.0.0.1:$NATIVE_PORT")
fi

# Check for Docker nodes
if command -v docker &> /dev/null; then
    DOCKER_CONTAINERS=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i myst || true)
    for container in $DOCKER_CONTAINERS; do
        PORT=$(docker port "$container" 4449 2>/dev/null | cut -d: -f2 || true)
        if [ -n "$PORT" ]; then
            echo "✓ Found Docker node: $container on port $PORT"
            DETECTED_NODES+=("docker:127.0.0.1:$PORT:$container")
        fi
    done
fi

if [ ${#DETECTED_NODES[@]} -eq 0 ]; then
    echo "⚠ No nodes detected automatically"
    echo ""
    read -p "Do you want to manually add nodes? (y/n): " MANUAL_ADD
    if [[ ! "$MANUAL_ADD" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled"
        exit 1
    fi
fi

echo ""
echo "Found ${#DETECTED_NODES[@]} node(s)"
echo ""

# Get TequilAPI password
echo "═══════════════════════════════════════════════════════════"
echo "STEP 2: TequilAPI Configuration"
echo "═══════════════════════════════════════════════════════════"
read -sp "Enter your TequilAPI password (same for all nodes): " API_PASSWORD
echo ""

if [ -z "$API_PASSWORD" ]; then
    echo "❌ Password cannot be empty"
    exit 1
fi

# Get node identities
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "STEP 3: Node Identities"
echo "═══════════════════════════════════════════════════════════"
echo "Enter the identity address (0x...) for each node"
echo "Find this in your node dashboard or with: myst cli"
echo ""

NODES_CONFIG=()
NODE_NUM=1

for node in "${DETECTED_NODES[@]}"; do
    IFS=':' read -r TYPE IP PORT NAME <<< "$node"
    
    if [ "$TYPE" = "native" ]; then
        DISPLAY_NAME="Native Node"
    else
        DISPLAY_NAME="$NAME"
    fi
    
    while true; do
        read -p "Identity for $DISPLAY_NAME (port $PORT): " IDENTITY
        
        # Validate identity format
        if [[ "$IDENTITY" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
            NODES_CONFIG+=("$IP:$PORT:Node $NODE_NUM:$IDENTITY")
            ((NODE_NUM++))
            break
        else
            echo "❌ Invalid identity format. Must be 0x followed by 40 hex characters"
        fi
    done
done

# Manual node addition
while true; do
    echo ""
    read -p "Add another node manually? (y/n): " ADD_MORE
    if [[ ! "$ADD_MORE" =~ ^[Yy]$ ]]; then
        break
    fi
    
    read -p "Node IP (default: 127.0.0.1): " NODE_IP
    NODE_IP=${NODE_IP:-127.0.0.1}
    
    read -p "TequilAPI port: " NODE_PORT
    read -p "Identity (0x...): " IDENTITY
    
    if [[ "$IDENTITY" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        NODES_CONFIG+=("$NODE_IP:$NODE_PORT:Node $NODE_NUM:$IDENTITY")
        ((NODE_NUM++))
        echo "✓ Node added"
    else
        echo "❌ Invalid identity, skipping"
    fi
done

# Create installation directory
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "STEP 4: Installing files..."
echo "═══════════════════════════════════════════════════════════"

INSTALL_DIR="/opt/mysterium-dashboard"
mkdir -p "$INSTALL_DIR"

# Copy dashboard files
cp live_sessions.html "$INSTALL_DIR/"
cp quality_monitor.html "$INSTALL_DIR/"
echo "✓ Dashboard files copied"

# Create config file
cat > "$INSTALL_DIR/config.env" << CONFIGEOF
# Mysterium Dashboard Configuration
# Generated: $(date)

PASSWORD="$API_PASSWORD"

NODES=(
CONFIGEOF

for config in "${NODES_CONFIG[@]}"; do
    echo "    \"$config\"" >> "$INSTALL_DIR/config.env"
done

echo ")" >> "$INSTALL_DIR/config.env"
chmod 600 "$INSTALL_DIR/config.env"
echo "✓ Configuration saved"

# Create update_sessions.sh
cat > "$INSTALL_DIR/update_sessions.sh" << 'SESSIONEOF'
#!/bin/bash
source /opt/mysterium-dashboard/config.env

OUTPUT_FILE="/opt/mysterium-dashboard/live_sessions.json"
TEMP_FILE="${OUTPUT_FILE}.tmp"

echo '[' > "$TEMP_FILE"
first=true

for node_info in "${NODES[@]}"; do
    IFS=':' read -r IP PORT NAME IDENTITY <<< "$node_info"
    
    TOKEN=$(curl -s -X POST "http://$IP:$PORT/tequilapi/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"myst\",\"password\":\"$PASSWORD\"}" | jq -r '.token // empty')
    
    if [ -z "$TOKEN" ]; then
        continue
    fi
    
    SESSIONS=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "http://$IP:$PORT/tequilapi/sessions?page_size=50" | \
        jq --arg name "$NAME" '.items[] | 
        select(.status == "New") | 
        . + {node_name: $name}')
    
    if [ -n "$SESSIONS" ]; then
        if [ "$first" = false ]; then
            echo "," >> "$TEMP_FILE"
        fi
        first=false
        echo "$SESSIONS" >> "$TEMP_FILE"
    fi
done

echo ']' >> "$TEMP_FILE"
mv "$TEMP_FILE" "$OUTPUT_FILE"
SESSIONEOF

chmod +x "$INSTALL_DIR/update_sessions.sh"
echo "✓ Session updater created"

# Create update_quality.sh
cat > "$INSTALL_DIR/update_quality.sh" << 'QUALITYEOF'
#!/bin/bash
source /opt/mysterium-dashboard/config.env

OUTPUT_FILE="/opt/mysterium-dashboard/quality_latest.json"

echo '{"nodes":[' > "$OUTPUT_FILE"
first=true

for node_info in "${NODES[@]}"; do
    IFS=':' read -r IP PORT NAME IDENTITY <<< "$node_info"
    
    TOKEN=$(curl -s -X POST "http://$IP:$PORT/tequilapi/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"myst\",\"password\":\"$PASSWORD\"}" | jq -r '.token // empty')
    
    if [ -z "$TOKEN" ]; then
        continue
    fi
    
    QUALITY_RESPONSE=$(curl -s "https://discovery.mysterium.network/api/v4/proposals?provider_id=$IDENTITY")
    
    QUALITY=$(echo "$QUALITY_RESPONSE" | jq -r '.[0].quality.quality // 0' 2>/dev/null || echo "0")
    UPTIME=$(echo "$QUALITY_RESPONSE" | jq -r '.[0].quality.uptime // 0' 2>/dev/null || echo "0")
    BANDWIDTH=$(echo "$QUALITY_RESPONSE" | jq -r '.[0].quality.bandwidth // 0' 2>/dev/null || echo "0")
    LATENCY=$(echo "$QUALITY_RESPONSE" | jq -r '.[0].quality.latency // 0' 2>/dev/null || echo "0")
    
    SESSIONS=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "http://$IP:$PORT/tequilapi/sessions?page_size=100" | \
        jq '[.items[] | select(.created_at > (now - 86400))] | length' 2>/dev/null || echo "0")
    
    [[ ! "$QUALITY" =~ ^[0-9.]+$ ]] && QUALITY="0"
    [[ ! "$UPTIME" =~ ^[0-9.]+$ ]] && UPTIME="0"
    [[ ! "$BANDWIDTH" =~ ^[0-9.]+$ ]] && BANDWIDTH="0"
    [[ ! "$LATENCY" =~ ^[0-9.]+$ ]] && LATENCY="0"
    [[ ! "$SESSIONS" =~ ^[0-9]+$ ]] && SESSIONS="0"
    
    if [ "$first" = false ]; then
        echo ',' >> "$OUTPUT_FILE"
    fi
    first=false
    
    cat >> "$OUTPUT_FILE" << NODEDATA
{
  "node_name": "$NAME",
  "identity": "$IDENTITY",
  "quality": $QUALITY,
  "uptime_hours": $UPTIME,
  "bandwidth_mbps": $BANDWIDTH,
  "latency_ms": $LATENCY,
  "sessions_24h": $SESSIONS,
  "earnings_24h": 0
}
NODEDATA
done

echo ']}' >> "$OUTPUT_FILE"
QUALITYEOF

chmod +x "$INSTALL_DIR/update_quality.sh"
echo "✓ Quality updater created"

# Install systemd services
echo ""
cat > /etc/systemd/system/mysterium-sessions.service << 'SERVICEEOF'
[Unit]
Description=Mysterium Live Sessions Monitor
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do /opt/mysterium-dashboard/update_sessions.sh; sleep 10; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

cat > /etc/systemd/system/mysterium-quality.service << 'SERVICEEOF'
[Unit]
Description=Mysterium Quality Monitor
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do /opt/mysterium-dashboard/update_quality.sh; sleep 60; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

cat > /etc/systemd/system/mysterium-webserver.service << 'SERVICEEOF'
[Unit]
Description=Mysterium Dashboard Web Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/mysterium-dashboard
ExecStart=/usr/bin/python3 -m http.server 8888
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable mysterium-sessions mysterium-quality mysterium-webserver
systemctl start mysterium-sessions mysterium-quality mysterium-webserver

echo "✓ Services installed and started"

# Get server IP for display
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Installation Complete!                                  ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Your dashboards are available at:"
echo "  Live Sessions:  http://$SERVER_IP:8888/live_sessions.html"
echo "  Quality Monitor: http://$SERVER_IP:8888/quality_monitor.html"
echo ""
echo "Manage services:"
echo "  sudo systemctl status mysterium-sessions"
echo "  sudo systemctl status mysterium-quality"
echo "  sudo systemctl status mysterium-webserver"
echo ""
echo "Config file: $INSTALL_DIR/config.env"
echo ""
echo "To uninstall: sudo ./uninstall.sh"
