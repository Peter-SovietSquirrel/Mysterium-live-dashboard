#!/bin/bash
TIMESTAMP=$(date -Iseconds)
OUTPUT_FILE="$(dirname "$0")/live_sessions.json"

PASSWORD="u8Mk6cYEJ6^@8X"

get_auth_token() {
    local api_port=$1
    curl -s -X POST "http://192.168.1.101:${api_port}/tequilapi/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"myst\",\"password\":\"$PASSWORD\"}" | jq -r '.token // empty'
}

get_pricing() {
    local api_port=$1
    local token=$2
    curl -s -H "Authorization: Bearer $token" \
        "http://192.168.1.101:${api_port}/tequilapi/services" | \
        jq 'map({
            key: .type,
            value: {
                per_hour_wei: (.proposal.price.per_hour | tostring),
                per_gib_wei:  (.proposal.price.per_gib  | tostring)
            }
        }) | from_entries'
}

get_session_tokens_wei() {
    local log_data=$1
    local session_id=$2
    echo "$log_data" | \
        grep "SessionTokensEarned" | \
        grep "SessionID:${session_id}" | \
        tail -1 | \
        grep -oP 'Total:\+\K[0-9]+'
}

calc_bytes() {
    local total_wei=$1
    local duration_secs=$2
    local per_hour_wei=$3
    local per_gib_wei=$4
    python3 -c "
total      = $total_wei
duration   = $duration_secs
per_hour   = $per_hour_wei
per_gib    = $per_gib_wei
time_cost  = int(duration / 3600 * per_hour)
data_tokens = total - time_cost
if data_tokens <= 0 or per_gib <= 0:
    print(0)
else:
    print(int(data_tokens / per_gib * 1073741824))
"
}

process_node() {
    local node_name=$1
    local api_port=$2
    local container_name=$3

    local token=$(get_auth_token "$api_port")
    if [ -z "$token" ] || [ "$token" = "null" ]; then return; fi

    local pricing=$(get_pricing "$api_port" "$token")

    local sessions=$(curl -s -H "Authorization: Bearer $token" \
        "http://192.168.1.101:${api_port}/tequilapi/sessions?page_size=50" | \
        jq -c '.items[]? | select(.status == "New")')

    if [ -z "$sessions" ]; then return; fi

    local log_data
    if [ "$container_name" = "native" ]; then
        log_data=$(sudo journalctl -u mysterium-node -n 10000 --no-pager 2>/dev/null)
    else
        log_data=$(sudo docker logs --tail 5000 "${container_name}" 2>&1)
    fi

    echo "$sessions" | while IFS= read -r session; do
        local session_id=$(echo "$session" | jq -r '.id')
        local duration=$(echo "$session" | jq -r '.duration')
        local service_type=$(echo "$session" | jq -r '.service_type')

        local total_wei=$(get_session_tokens_wei "$log_data" "$session_id")

        local earnings_myst="0"
        local bytes_transferred=0

        if [ -n "$total_wei" ] && [ "$total_wei" != "0" ]; then
            earnings_myst=$(python3 -c "print('%.6f' % ($total_wei / 1e18))")

            local per_hour_wei=$(echo "$pricing" | jq -r --arg st "$service_type" '.[$st].per_hour_wei // "0"')
            local per_gib_wei=$(echo "$pricing"  | jq -r --arg st "$service_type" '.[$st].per_gib_wei  // "0"')

            if [ "$per_gib_wei" != "0" ] && [ "$per_gib_wei" != "null" ]; then
                bytes_transferred=$(calc_bytes "$total_wei" "$duration" "$per_hour_wei" "$per_gib_wei")
            fi
        fi

        echo "$session" | jq -c \
            --arg node_name  "$node_name" \
            --arg earnings   "$earnings_myst" \
            --argjson bytes  "$bytes_transferred" \
            '{
                id: .id,
                service_type: .service_type,
                consumer_country: .consumer_country,
                duration: .duration,
                bytes_transferred: $bytes,
                earnings_myst: ($earnings | tonumber),
                node_name: $node_name
            }'
    done
}

TEMP_FILE=$(mktemp)
process_node "Node 1 (.187)" "44491" "mysterium-node-1" >> "$TEMP_FILE"
process_node "Node 2 (.188)" "44492" "mysterium-node-2" >> "$TEMP_FILE"
process_node "Node 3 (.189)" "44493" "mysterium-node-3" >> "$TEMP_FILE"
process_node "Node 4 (.190)" "44494" "mysterium-node-4" >> "$TEMP_FILE"
process_node "Native (.186)" "4449"  "native"            >> "$TEMP_FILE"

jq -s -n \
    --arg timestamp "$TIMESTAMP" \
    --slurpfile sessions "$TEMP_FILE" \
    '{timestamp: $timestamp, sessions: $sessions}' > "$OUTPUT_FILE"

rm "$TEMP_FILE"
