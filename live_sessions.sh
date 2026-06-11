#!/bin/bash
TIMESTAMP=$(date -Iseconds)
SCRIPT_DIR="$(dirname "$0")"
OUTPUT_FILE="${SCRIPT_DIR}/live_sessions.json"
CACHE_FILE="${SCRIPT_DIR}/session_cache.json"

# Load password from .env
CONFIG="${SCRIPT_DIR}/.env"
if [ ! -f "$CONFIG" ]; then echo "Error: config file not found at $CONFIG"; exit 1; fi
source "$CONFIG"
if [ -z "$PASSWORD" ]; then echo "Error: PASSWORD not set in $CONFIG"; exit 1; fi

# ── Cache helpers ─────────────────────────────────────────────────────────
[ -f "$CACHE_FILE" ] || echo '{}' > "$CACHE_FILE"

cache_get() {
    jq -r --arg id "$1" --arg f "$2" '.[$id][$f] // empty' "$CACHE_FILE" 2>/dev/null
}

cache_set() {
    local session_id=$1 earnings=$2 bytes=$3
    local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp=$(mktemp)
    jq --arg id "$session_id" --arg e "$earnings" --argjson b "$bytes" --arg t "$now" \
       '.[$id] = {earnings_myst: $e, bytes_transferred: $b, last_updated: $t}' \
       "$CACHE_FILE" > "$tmp" && mv "$tmp" "$CACHE_FILE"
}

cache_age() {
    local last_updated=$(cache_get "$1" "last_updated")
    [ -z "$last_updated" ] && echo 99999 && return
    echo $(( $(date +%s) - $(date -d "$last_updated" +%s 2>/dev/null || echo 0) ))
}

cache_prune() {
    # Keep only sessions in the provided list
    local ids_json=$1
    local tmp=$(mktemp)
    jq --argjson ids "$ids_json" 'with_entries(select(.key as $k | $ids | index($k) != null))' \
       "$CACHE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$CACHE_FILE"
}

# ── API helpers ───────────────────────────────────────────────────────────
get_auth_token() {
    curl -s -X POST "http://192.168.1.101:${1}/tequilapi/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"myst\",\"password\":\"$PASSWORD\"}" | jq -r '.token // empty'
}

get_pricing() {
    curl -s -H "Authorization: Bearer $2" \
        "http://192.168.1.101:${1}/tequilapi/services" | \
        jq 'map({key: .type, value: {per_hour_wei: (.proposal.price.per_hour | tostring), per_gib_wei: (.proposal.price.per_gib | tostring)}}) | from_entries'
}

get_session_tokens_wei() {
    echo "$1" | grep "SessionTokensEarned" | grep "SessionID:${2}" | tail -1 | grep -oP 'Total:\+\K[0-9]+'
}

calc_bytes() {
    python3 -c "
total=$1; duration=$2; per_hour=$3; per_gib=$4
time_cost=int(duration/3600*per_hour)
data=total-time_cost
print(0 if data<=0 or per_gib<=0 else int(data/per_gib*1073741824))
"
}

# ── Process a node ────────────────────────────────────────────────────────
process_node() {
    local node_name=$1 api_port=$2 container_name=$3

    local token=$(get_auth_token "$api_port")
    [ -z "$token" ] || [ "$token" = "null" ] && return

    local pricing=$(get_pricing "$api_port" "$token")

    local sessions=$(curl -s -H "Authorization: Bearer $token" \
        "http://192.168.1.101:${api_port}/tequilapi/sessions?page_size=500" | \
        jq -c '.items[]? | select(.status == "New")')

    [ -z "$sessions" ] && return

    # Check if any session needs a log refresh (cache older than 3 mins)
    local needs_log_fetch=false
    while IFS= read -r session; do
        local sid=$(echo "$session" | jq -r '.id')
        [ "$(cache_age "$sid")" -gt 180 ] && needs_log_fetch=true && break
    done < <(echo "$sessions")

    local log_data=""
    if [ "$needs_log_fetch" = true ]; then
        if [ "$container_name" = "native" ]; then
            log_data=$(sudo journalctl -u mysterium-node -n 50000 --no-pager 2>/dev/null)
        else
            log_data=$(sudo docker logs --tail 50000 "${container_name}" 2>&1)
        fi
    fi

    echo "$sessions" | while IFS= read -r session; do
        local session_id=$(echo "$session" | jq -r '.id')
        local duration=$(echo "$session" | jq -r '.duration')
        local service_type=$(echo "$session" | jq -r '.service_type')
        local age=$(cache_age "$session_id")

        local earnings_myst="0"
        local bytes_transferred=0

        if [ "$age" -gt 180 ] && [ -n "$log_data" ]; then
            local total_wei=$(get_session_tokens_wei "$log_data" "$session_id")
            if [ -n "$total_wei" ] && [ "$total_wei" != "0" ]; then
                earnings_myst=$(python3 -c "print('%.6f' % ($total_wei / 1e18))")
                local per_hour_wei=$(echo "$pricing" | jq -r --arg st "$service_type" '.[$st].per_hour_wei // "0"')
                local per_gib_wei=$(echo "$pricing"  | jq -r --arg st "$service_type" '.[$st].per_gib_wei  // "0"')
                if [ "$per_gib_wei" != "0" ] && [ "$per_gib_wei" != "null" ]; then
                    bytes_transferred=$(calc_bytes "$total_wei" "$duration" "$per_hour_wei" "$per_gib_wei")
                fi
                cache_set "$session_id" "$earnings_myst" "$bytes_transferred"
            fi
        else
            local cached_earnings=$(cache_get "$session_id" "earnings_myst")
            local cached_bytes=$(cache_get "$session_id" "bytes_transferred")
            [ -n "$cached_earnings" ] && earnings_myst="$cached_earnings"
            [ -n "$cached_bytes" ]   && bytes_transferred="$cached_bytes"
        fi

        # Zombie check: never earned anything after 10+ minutes = skip
        if [ "$earnings_myst" = "0" ] && [ "$duration" -gt 600 ]; then
            continue
        fi

        echo "$session" | jq -c \
            --arg node_name "$node_name" \
            --arg earnings  "$earnings_myst" \
            --argjson bytes "$bytes_transferred" \
            '{id: .id, service_type: .service_type, consumer_country: .consumer_country,
              duration: .duration, bytes_transferred: $bytes,
              earnings_myst: ($earnings | tonumber), node_name: $node_name}'
    done
}

# ── Collect ALL active session IDs across all nodes (for cache pruning) ───
collect_active_ids() {
    local all_ids=()
    for port in 4449 44491 44492 44493 44494; do
        local token=$(get_auth_token "$port")
        [ -z "$token" ] || [ "$token" = "null" ] && continue
        while IFS= read -r id; do
            all_ids+=("$id")
        done < <(curl -s -H "Authorization: Bearer $token" \
            "http://192.168.1.101:${port}/tequilapi/sessions?page_size=500" | \
            jq -r '.items[]? | select(.status == "New") | .id' 2>/dev/null)
    done
    # Output as JSON array
    printf '%s\n' "${all_ids[@]}" | jq -R . | jq -s .
}

# ── Main ──────────────────────────────────────────────────────────────────
TEMP_FILE=$(mktemp)

process_node "Node 1 (.187)" "44491" "mysterium-node-1" >> "$TEMP_FILE"
process_node "Node 2 (.188)" "44492" "mysterium-node-2" >> "$TEMP_FILE"
process_node "Node 3 (.189)" "44493" "mysterium-node-3" >> "$TEMP_FILE"
process_node "Node 4 (.190)" "44494" "mysterium-node-4" >> "$TEMP_FILE"
process_node "Native (.186)" "4449"  "native"            >> "$TEMP_FILE"

# Prune cache — only remove sessions genuinely gone from all nodes
ACTIVE_IDS_JSON=$(collect_active_ids)
cache_prune "$ACTIVE_IDS_JSON"

jq -s -n \
    --arg timestamp "$TIMESTAMP" \
    --slurpfile sessions "$TEMP_FILE" \
    '{timestamp: $timestamp, sessions: $sessions}' > "$OUTPUT_FILE"

rm "$TEMP_FILE"
