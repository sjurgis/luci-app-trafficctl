#!/bin/bash
# Egress interface of policy-routed connections is reported by its uci name,
# not only by the kernel device it resolved to (#10): mwan3 sends a flow out of
# "awg3", the user calls that network "Finland".
#
# Runs trafficctl-device.sh end to end against a recorded conntrack table, a
# mocked `ip route get` and a role map in the format trafficctl-ifaces.sh
# memoizes, with every absolute path rewritten into a temp dir.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"
FWLIB="$BIN/trafficctl-fw.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"

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

CONNTRACK="$TMPDIR/nf_conntrack"
ROLES="$TMPDIR/ifroles"
BUILT="$TMPDIR/ifaces-built"

# mark=256 -> awg3 (has a uci name), mark=512 -> usb0 (no uci interface),
# mark=0 -> not policy-routed, left blank.
cat > "$CONNTRACK" <<'CT'
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.37 dst=17.248.239.10 sport=54195 dport=443 packets=10 bytes=1000 src=17.248.239.10 dst=10.8.0.2 sport=443 dport=54195 packets=10 bytes=5000 [ASSURED] mark=256 zone=0 use=2
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.37 dst=198.41.200.43 sport=40853 dport=443 packets=10 bytes=1000 src=198.41.200.43 dst=100.64.0.2 sport=443 dport=40853 packets=10 bytes=5000 [ASSURED] mark=512 zone=0 use=2
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.37 dst=1.1.1.1 sport=40000 dport=443 packets=10 bytes=1000 src=1.1.1.1 dst=203.0.113.2 sport=443 dport=40000 packets=10 bytes=5000 [ASSURED] mark=0 zone=0 use=2
CT

cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
if [ "$1" = route ] && [ "$2" = get ]; then
    case "$5" in
        256) echo "$3 dev awg3 table 1 src 10.8.0.2 uid 0" ;;
        512) echo "$3 dev usb0 table 2 src 100.64.0.2 uid 0" ;;
        *)   echo "$3 via 203.0.113.1 dev eth1 src 203.0.113.2 uid 0" ;;
    esac
fi
exit 0
MOCK
# Stand-in for trafficctl-ifaces.sh: builds the role map and records that it ran.
cat > "$MOCKBIN/ifaces.sh" <<MOCK
#!/bin/sh
: > "$BUILT"
printf '# 1\nawg3 wan 1 0 0 0 Finland\nusb0 wan 0 0 0 0 -\neth1 wan 0 1 1 0 wan\n' > "$ROLES"
echo '[]'
MOCK
for c in uci ubus nft iptables iw conntrack; do printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/$c"; done
chmod +x "$MOCKBIN"/*

sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FWLIB|" \
    -e "s|/usr/libexec/trafficctl/trafficctl-ifaces.sh|$MOCKBIN/ifaces.sh|" \
    -e "s|/proc/net/nf_conntrack|$CONNTRACK|" \
    -e "s|/tmp/trafficctl_conn_cache|$TMPDIR/conn_cache|" \
    "$BIN/trafficctl-device.sh" > "$TMPDIR/device.sh"

LABELS="$TMPDIR/netify_labels"
run_device() { PATH="$MOCKBIN:$PATH" TCTL_IFROLE_CACHE="$ROLES" TCTL_NETIFY_LABELS="$LABELS" sh "$TMPDIR/device.sh" 192.168.1.37 2>/dev/null; }

# ── cold: no role map yet, so the device script has it built once ───────────
OUT=$(run_device)
assert_contains "cold: role map built when missing" "yes" "$([ -f "$BUILT" ] && echo yes)"
assert_contains "policy-routed flow present" '"dst":"17.248.239.10"' "$OUT"
assert_contains "awg3 reported as Finland" '"oif":"Finland","oif_dev":"awg3"' "$OUT"
assert_contains "device without a uci name keeps the device" '"oif":"usb0","oif_dev":"usb0"' "$OUT"
assert_contains "mark=0 stays blank" '"dst":"1.1.1.1","host":"","port":443,"service":"https","bytes":1000,"state":"ESTABLISHED","oif":"","oif_dev":""' "$OUT"

# ── warm: an existing map is used as is, never rebuilt from the device poll ──
rm -f "$BUILT"
printf '# 1\nawg3 wan 1 0 0 0 Riga\n' > "$ROLES"
OUT=$(run_device)
assert_contains "warm: role map not rebuilt" "no" "$([ -f "$BUILT" ] && echo yes || echo no)"
assert_contains "warm: label read from the existing map" '"oif":"Riga","oif_dev":"awg3"' "$OUT"

# ── no policy-routed flows: nothing to label, nothing built ──────────────────
rm -f "$BUILT" "$ROLES"
sed -i.bak 's/mark=[0-9]*/mark=0/' "$CONNTRACK"
OUT=$(run_device)
assert_contains "no marks: role map not built" "no" "$([ -f "$BUILT" ] && echo yes || echo no)"

# ── netify labels on the connection list ────────────────────────────────────
# Restore a marked table so the three destinations are present again, then
# annotate from a labels file. The device path must not sample netifyd.
LABELS="$TMPDIR/netify_labels"
cat > "$CONNTRACK" <<'CT'
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.37 dst=17.248.239.10 sport=54195 dport=443 packets=10 bytes=1000 src=17.248.239.10 dst=10.8.0.2 sport=443 dport=54195 packets=10 bytes=5000 [ASSURED] mark=256 zone=0 use=2
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.37 dst=198.41.200.43 sport=40853 dport=443 packets=10 bytes=2000 src=198.41.200.43 dst=100.64.0.2 sport=443 dport=40853 packets=10 bytes=5000 [ASSURED] mark=512 zone=0 use=2
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.37 dst=1.1.1.1 sport=40000 dport=443 packets=10 bytes=1000 src=1.1.1.1 dst=203.0.113.2 sport=443 dport=40000 packets=10 bytes=5000 [ASSURED] mark=0 zone=0 use=2
ipv4     2 udp      17 30 src=192.168.1.37 dst=8.8.8.8 sport=50000 dport=53 packets=1 bytes=80 src=8.8.8.8 dst=192.168.1.37 sport=53 dport=50000 packets=1 bytes=120 mark=0 zone=0 use=2
CT
# Exact 4-tuple, a port-0 fallback (no other_port on the original flow), and a
# dest-only fallback. A fourth dest (8.8.8.8) has no label at all.
printf '%s\n' \
    '192.168.1.37 17.248.239.10 tcp 443 icloud gateway.icloud.com' \
    '192.168.1.37 198.41.200.43 tcp 0 youtube www.youtube.com' \
    '192.168.1.37 1.1.1.1 - 0 cloudflare -' \
    > "$LABELS"

run_labelled() { PATH="$MOCKBIN:$PATH" TCTL_IFROLE_CACHE="$ROLES" TCTL_NETIFY_LABELS="$LABELS" sh "$TMPDIR/device.sh" 192.168.1.37 2>/dev/null; }
OUT=$(run_labelled)
assert_contains "labels: exact 4-tuple match" '"dst":"17.248.239.10"' "$OUT"
assert_contains "labels: exact match carries app and SNI" '"app":"icloud","app_host":"gateway.icloud.com"' "$OUT"
assert_contains "labels: port-0 fallback" '"dst":"198.41.200.43"' "$OUT"
assert_contains "labels: port-0 carries youtube and SNI" '"app":"youtube","app_host":"www.youtube.com"' "$OUT"
assert_contains "labels: dest-only fallback (unknown proto in the cache)" '"dst":"1.1.1.1"' "$OUT"
assert_contains "labels: dest-only carries the app name" '"app":"cloudflare","app_host":""' "$OUT"
assert_not_contains "labels: unlabelled dest is left alone" '"dst":"8.8.8.8","host":"","port":53,"service":"dns","bytes":80,"state":"","oif":"","oif_dev":"","app"' "$OUT"
assert_contains "labels: unlabelled dest still present" '"dst":"8.8.8.8"' "$OUT"

# Disabled integration must ignore a stale labels file.
printf '#!/bin/sh\ncase "$3" in trafficctl.main.netify_enabled) echo 0 ;; *) exit 1 ;; esac\n' > "$MOCKBIN/uci"
chmod +x "$MOCKBIN/uci"
OUT=$(run_labelled)
assert_not_contains "labels: netify_enabled=0 leaves connections unannotated" '"app":' "$OUT"
# Restore the inert uci mock used by the earlier cases.
printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/uci"
chmod +x "$MOCKBIN/uci"
rm -f "$LABELS"
OUT=$(run_labelled)
assert_not_contains "labels: missing cache leaves connections unannotated" '"app":' "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
