#!/bin/bash
# Tests for the optional netifyd (DPI) integration.
# Feeds recorded agent output via TCTL_NETIFY_FEED instead of a live socket,
# and verifies the integration stays inert when netifyd is absent.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"
FWLIB="$BIN/trafficctl-fw.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"

CACHE="$TMPDIR/netify_cache.json"
LABELS="$TMPDIR/netify_labels"
export TCTL_NETIFY_LABELS="$LABELS"

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected NOT to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}

sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FWLIB|" \
    -e "s|CACHE=\"/tmp/trafficctl_netify.json\"|CACHE=\"$CACHE\"|" \
    -e "s|LOCK=\"/tmp/trafficctl_netify.lock\"|LOCK=\"$TMPDIR/netify.lock\"|" \
    "$BIN/trafficctl-netify.sh" > "$TMPDIR/netify.sh"

printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/uci"
chmod +x "$MOCKBIN/uci"

# Recorded agent output: a flow that is later updated (same digest), a second
# app for the same device, a routed device, an unclassified flow, and a
# hostile host_server_name.
FEED="$TMPDIR/feed.jsonl"
cat > "$FEED" <<'EOF'
{"type":"agent_hello","version":"5.0.1"}
{"type":"flow","interface":"br-lan","flow":{"digest":"aaa111","local_ip":"192.168.1.50","other_ip":"45.57.0.1","detected_protocol_name":"TLS","detected_application_name":"netify.netflix","host_server_name":"www.netflix.com","total_bytes":1500}}
{"type":"flow_dpi_update","interface":"br-lan","flow":{"digest":"aaa111","local_ip":"192.168.1.50","other_ip":"45.57.0.1","detected_application_name":"netify.netflix","total_bytes":900000}}
{"type":"flow","interface":"br-lan","flow":{"digest":"bbb222","local_ip":"192.168.1.50","other_ip":"142.250.1.1","detected_protocol_name":"QUIC","detected_application_name":"netify.youtube","total_bytes":250000}}
{"type":"flow","interface":"br-lan","flow":{"digest":"ccc333","local_ip":"10.0.0.55","other_ip":"5.5.5.5","detected_protocol_name":"BitTorrent","detected_application_name":"","total_bytes":7000000}}
{"type":"flow","interface":"br-lan","flow":{"digest":"ddd444","local_ip":"10.0.0.55","other_ip":"9.9.9.9","detected_protocol_name":"Unknown","detected_application_name":"unknown","host_server_name":"evil\"host;rm -rf /","total_bytes":42}}
{"type":"agent_status","flows":1234}
EOF

run_netify() { PATH="$MOCKBIN:$PATH" sh "$TMPDIR/netify.sh" "$@" 2>/dev/null; }

# ── collect ──────────────────────────────────────────────────────────────────

OUT=$(TCTL_NETIFY_FEED="$FEED" run_netify collect 2)
assert_contains "collect: ok" '"ok":true' "$OUT"
assert_contains "collect: counted both devices" '"devices":2' "$OUT"

CACHED=$(cat "$CACHE")
assert_contains "cache: valid JSON" "VALID" \
    "$(python3 -c "import json,sys; json.load(sys.stdin); print('VALID')" < "$CACHE" 2>/dev/null)"

# The "netify." catalogue prefix is noise in a table.
assert_contains "parse: app prefix stripped" '"name":"netflix"' "$CACHED"
assert_not_contains "parse: no netify. prefix leaks" 'netify.netflix' "$CACHED"

# A flow re-emitted with growing counters must not be double-counted:
# 1500 then 900000 for digest aaa111 means 900000, not 901500.
assert_contains "parse: digest updates replace, not accumulate" '"bytes":900000' "$CACHED"
assert_not_contains "parse: no accumulated total" '901500' "$CACHED"

# Falls back to the protocol name when the application is unknown.
assert_contains "parse: protocol fallback for unnamed app" '"name":"BitTorrent"' "$CACHED"

# Highest-byte app becomes the device's headline label.
assert_contains "parse: top app for LAN device" '"ip":"192.168.1.50","top":"netflix"' "$CACHED"
assert_contains "parse: top app for routed device" '"ip":"10.0.0.55","top":"BitTorrent"' "$CACHED"

# Hostile hostnames must not break the JSON or reach the output verbatim.
assert_not_contains "sanitize: no injected quotes" 'evil"host' "$CACHED"
assert_not_contains "sanitize: no shell metacharacters" 'rm -rf /' "$CACHED"

# Labels for the device detail view: one row per remote 4-tuple.
# The first Netflix flow has other_ip + host_server_name; proto falls out
# of "TLS" as tcp.
assert_contains "labels: file is written" "yes" "$([ -f "$LABELS" ] && echo yes || echo no)"
LABELTXT=$(cat "$LABELS" 2>/dev/null)
assert_contains "labels: netflix mapped to its remote IP" "192.168.1.50 45.57.0.1 tcp 0 netflix www.netflix.com" "$LABELTXT"
# other_port was absent in this fixture, so port is 0; YouTube still gets a row.
assert_contains "labels: youtube mapped to its remote IP" "192.168.1.50 142.250.1.1 udp 0 youtube" "$LABELTXT"
assert_contains "labels: BitTorrent keeps the protocol name" "10.0.0.55 5.5.5.5" "$LABELTXT"
assert_not_contains "labels: no shell metacharacters in hostname" ';' "$LABELTXT"
assert_not_contains "labels: no raw quotes in the label file" '"' "$LABELTXT"
assert_not_contains "labels: spaces stripped from hostile hostname" 'rm -rf' "$LABELTXT"

# ── flow_stats bytes (the bytes:0 bug) ──────────────────────────────────────
# Identifying flow arrives first with total_bytes still 0; the counters
# live on a later flow_stats record that has a digest but no local_ip.
# Without merging those, the app is listed with bytes:0.
FEED_STATS="$TMPDIR/feed_stats.jsonl"
cat > "$FEED_STATS" <<'EOF'
{"type":"agent_hello","version":"5.1.0"}
{"type":"flow","interface":"br-lan","flow":{"digest":"abc999","local_ip":"192.168.1.80","other_ip":"199.9.9.9","other_port":443,"ip_protocol":6,"detected_application_name":"netify.icloud","host_server_name":"gateway.icloud.com","total_bytes":0}}
{"type":"flow_stats","interface":"br-lan","flow":{"digest":"abc999","local_bytes":1200,"other_bytes":8800,"total_bytes":10000}}
{"type":"flow_stats","interface":"br-lan","flow":{"digest":"abc999","local_bytes":1500,"other_bytes":18500,"total_bytes":20000}}
{"type":"flow","interface":"br-lan","flow":{"digest":"zzz111","local_ip":"192.168.1.80","other_ip":"1.1.1.1","other_port":53,"ip_protocol":17,"detected_protocol_name":"DNS","total_bytes":80}}
EOF
rm -f "$CACHE" "$LABELS"
OUT=$(TCTL_NETIFY_FEED="$FEED_STATS" run_netify collect 2)
assert_contains "flow_stats: collected" '"ok":true' "$OUT"
CACHED=$(cat "$CACHE")
assert_contains "flow_stats: cumulative bytes win over the zero on the first record" '"name":"icloud","bytes":20000' "$CACHED"
assert_not_contains "flow_stats: zero from the identifying record is not kept" '"bytes":0' "$CACHED"
assert_contains "flow_stats: a flow that already had bytes is unchanged" '"name":"DNS","bytes":80' "$CACHED"
LABELTXT=$(cat "$LABELS")
assert_contains "flow_stats: label carries proto, port and SNI" "192.168.1.80 199.9.9.9 tcp 443 icloud gateway.icloud.com" "$LABELTXT"
assert_contains "flow_stats: DNS label uses the protocol name and port" "192.168.1.80 1.1.1.1 udp 53 DNS" "$LABELTXT"

# A later collect that sees only the tiny flow must not wipe the icloud label.
FEED_TINY="$TMPDIR/feed_tiny.jsonl"
cat > "$FEED_TINY" <<'EOF'
{"type":"flow","interface":"br-lan","flow":{"digest":"tiny1","local_ip":"192.168.1.80","other_ip":"8.8.8.8","other_port":53,"ip_protocol":17,"detected_protocol_name":"DNS","total_bytes":40}}
EOF
OUT=$(TCTL_NETIFY_FEED="$FEED_TINY" run_netify collect 2)
LABELTXT=$(cat "$LABELS")
assert_contains "labels: previous mapping survives a later short collect" "192.168.1.80 199.9.9.9 tcp 443 icloud gateway.icloud.com" "$LABELTXT"
assert_contains "labels: the new mapping is added" "192.168.1.80 8.8.8.8 udp 53 DNS" "$LABELTXT"

# ── list ─────────────────────────────────────────────────────────────────────
# Re-collect the first fixture so list still sees the original cache.
rm -f "$CACHE"
OUT=$(TCTL_NETIFY_FEED="$FEED" run_netify collect 2)
OUT=$(run_netify list)
assert_contains "list: returns cached data" '"top":"netflix"' "$OUT"

# ── Agent v5 aggregator payload ──────────────────────────────────────────────
# Real shape from netify-sink-socket: one object holding a "stats" array, with
# "<id>.netify.<app>" names and separate download/upload counters.
FEED5="$TMPDIR/feed_v5.json"
cat > "$FEED5" <<'EOF'
{"log_time_end":1787138795,"log_time_start":1787138780,"stats":[{"application_id":"10472.netify.amazon-alexa","download":4230,"local_ip":"10.0.20.142","local_mac":"74:4d:28:c3:29:6c","packets":11,"protocol_id":196,"upload":1477},{"application_id":"11800.netify.claude","download":1357,"local_ip":"10.0.20.190","packets":4,"protocol_id":188,"upload":146},{"application_id":"10002.netify.github","download":196,"local_ip":"10.0.20.190","packets":2,"protocol_id":196,"upload":52},{"application_id":"10307.netify.qnap","download":83,"local_ip":"192.168.2.153","packets":3,"protocol_id":196,"upload":143}]}
EOF

rm -f "$CACHE"
OUT=$(TCTL_NETIFY_FEED="$FEED5" run_netify collect 2)
assert_contains "v5: collected" '"ok":true' "$OUT"
assert_contains "v5: every device in the stats array" '"devices":3' "$OUT"

CACHED=$(cat "$CACHE")
assert_contains "v5: valid JSON" "VALID" \
    "$(python3 -c "import json,sys; json.load(sys.stdin); print('VALID')" < "$CACHE" 2>/dev/null)"

# "<numeric id>.netify.<name>" must reduce to the bare app name.
assert_contains "v5: numeric id prefix stripped" '"name":"amazon-alexa"' "$CACHED"
assert_not_contains "v5: no raw application_id leaks" '10472' "$CACHED"

# bytes = download + upload (1357 + 146 = 1503, 196 + 52 = 248)
assert_contains "v5: download+upload summed" '"bytes":1503' "$CACHED"
assert_contains "v5: top app is the biggest by bytes" '"ip":"10.0.20.190","top":"claude"' "$CACHED"

# Routed devices must be represented, not just LAN ones.
assert_contains "v5: routed device present" '"ip":"10.0.20.142"' "$CACHED"

# Type 1 aggregator records have no other_ip, so they cannot label a conntrack
# row — that is expected, not a parse failure.
# A Type 2/3 record (other_ip + other_port) plus a bare numeric application_id
# must still produce a usable label, using detected_application_name for the
# numeric id rather than the number itself.
FEED_T2="$TMPDIR/feed_type2.jsonl"
cat > "$FEED_T2" <<'EOF'
{"log_time_end":1,"stats":[{"application_id":"10002.netify.github","download":196,"local_ip":"10.0.20.190","other_ip":"140.82.112.3","other_port":443,"ip_protocol":6,"upload":52}]}
{"type":"flow","interface":"br-lan","flow":{"digest":"n1","local_ip":"10.0.20.190","other_ip":"8.8.4.4","other_port":853,"ip_protocol":6,"application_id":"12345","detected_application_name":"netify.dot","total_bytes":50}}
EOF
rm -f "$CACHE" "$LABELS"
OUT=$(TCTL_NETIFY_FEED="$FEED_T2" run_netify collect 2)
assert_contains "type2: collected" '"ok":true' "$OUT"
CACHED=$(cat "$CACHE")
assert_contains "type2: github rollup uses the bare app name" '"name":"github"' "$CACHED"
assert_not_contains "type2: bare numeric application_id is not a name" '"name":"12345"' "$CACHED"
assert_contains "type2: numeric id falls back to detected application" '"name":"dot"' "$CACHED"
LABELTXT=$(cat "$LABELS")
assert_contains "type2: label has proto, port and app" "10.0.20.190 140.82.112.3 tcp 443 github" "$LABELTXT"
assert_contains "type2: numeric id became the detected name" "10.0.20.190 8.8.4.4 tcp 853 dot" "$LABELTXT"

# ── graceful degradation ─────────────────────────────────────────────────────

OUT=$(run_netify status)
assert_contains "status: reports not installed" '"installed":false' "$OUT"
assert_contains "status: reports not running" '"running":false' "$OUT"
assert_contains "status: valid JSON" "VALID" \
    "$(printf '%s' "$OUT" | python3 -c "import json,sys; json.load(sys.stdin); print('VALID')" 2>/dev/null)"

# No socket and no feed: must fail soft, never hang or emit garbage.
OUT=$(run_netify collect 1)
assert_contains "collect: fails soft without netifyd" '"ok":false' "$OUT"

rm -f "$CACHE"
OUT=$(run_netify list)
assert_contains "list: empty array when no cache" '[]' "$OUT"

# Disabled by config → inert even if data is available.
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    trafficctl.main.netify_enabled) echo "0" ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/uci"
OUT=$(TCTL_NETIFY_FEED="$FEED" run_netify collect 2)
assert_contains "collect: respects netify_enabled=0" 'disabled' "$OUT"

# ── Results ──────────────────────────────────────────────────────────────────

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
