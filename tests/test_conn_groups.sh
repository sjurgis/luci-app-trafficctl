#!/bin/bash
# Grouping and hostname/app labels on the device connection table.
#
# Functions are sliced out of status.js (same pattern as test_subnet_ui.sh) so
# this cannot drift into testing a stale duplicate. Node is used only as an
# ES5 interpreter: the slices touch no DOM and no LuCI runtime.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

if ! command -v node >/dev/null 2>&1; then
    printf "SKIP: node is not installed — the frontend slices cannot be run here.\n"
    printf "0 passed, 0 failed\n"
    exit 0
fi

slice() {
    awk -v fn="$1" '
        $0 ~ "^function " fn "\\(" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$JS"
}

{
    slice connAppName
    slice connHostName
    slice connectionGroupKey
    slice groupConnections
} > "$TMP/slices.js"

for fn in connAppName connHostName connectionGroupKey groupConnections; do
    if grep -q "^function $fn(" "$TMP/slices.js"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: harness: %s was not sliced out of status.js\n" "$fn"
    fi
done
if [ "$FAIL" -ne 0 ]; then
    printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
    exit 1
fi

# SERVICE_PORTS is referenced by connectionGroupKey('service'). A tiny stub
# matching the ports the fixtures use is enough; the full table stays in JS.
cat > "$TMP/run.js" <<'DRIVER'
var SERVICE_PORTS = { 443: 'https', 53: 'dns' };

var src = require('fs').readFileSync(process.argv[2], 'utf8');
eval(src);

var conns = [
    { proto: 'tcp', dst: '45.57.0.1',   host: '',                  port: 443, service: 'https', bytes: 1000, app: 'netflix', app_host: 'www.netflix.com' },
    { proto: 'tcp', dst: '45.57.0.2',   host: '',                  port: 443, service: 'https', bytes: 4000, app: 'netflix', app_host: 'www.netflix.com' },
    { proto: 'udp', dst: '142.250.1.1', host: '',                  port: 443, service: 'https', bytes: 2500, app: 'youtube', app_host: 'www.youtube.com' },
    { proto: 'udp', dst: '8.8.8.8',     host: 'dns.google',        port: 53,  service: 'dns',   bytes: 80,   app: '',        app_host: '' },
    { proto: 'tcp', dst: '1.1.1.1',     host: '',                  port: 443, service: 'https', bytes: 200,  app: '',        app_host: '' },
    { proto: 'tcp', dst: '9.9.9.9',     host: '',                  port: 443, service: 'https', bytes: 10,   app: 'unclassified', app_host: '' }
];

function find(groups, key) {
    for (var i = 0; i < groups.length; i++) if (groups[i].key === key) return groups[i];
    return null;
}

var cmd = process.argv[3];
var arg = process.argv[4];

if (cmd === 'app-name') {
    var c = conns[Number(arg)];
    process.stdout.write(connAppName(c));
} else if (cmd === 'host-name') {
    var c = conns[Number(arg)];
    process.stdout.write(connHostName(c));
} else if (cmd === 'key') {
    var c = conns[Number(arg)];
    process.stdout.write(connectionGroupKey(c, process.argv[5]));
} else if (cmd === 'none') {
    process.stdout.write(String(groupConnections(conns, 'none')));
} else if (cmd === 'unknown') {
    process.stdout.write(String(groupConnections(conns, 'nope')));
} else if (cmd === 'group') {
    var groups = groupConnections(conns, arg);
    var want = process.argv[5];
    var g = find(groups, want);
    if (!g) { process.stdout.write('MISSING'); process.exit(0); }
    process.stdout.write([g.key, g.count, g.bytes, g.tcp, g.udp, g.conns.length].join(' '));
} else if (cmd === 'group-count') {
    process.stdout.write(String(groupConnections(conns, arg).length));
} else if (cmd === 'member-dsts') {
    var groups = groupConnections(conns, arg);
    var g = find(groups, process.argv[5]);
    if (!g) { process.stdout.write('MISSING'); process.exit(0); }
    process.stdout.write(g.conns.map(function(c){ return c.dst; }).join(','));
}
DRIVER

run() { node "$TMP/run.js" "$TMP/slices.js" "$@"; }

# Label helpers
assert_eq "app name from netify"              "netflix"           "$(run app-name 0)"
assert_eq "unclassified is treated as empty"  ""                  "$(run app-name 5)"
assert_eq "missing app is empty"              ""                  "$(run app-name 3)"
assert_eq "hostname prefers SNI over rDNS"    "www.netflix.com"   "$(run host-name 0)"
assert_eq "hostname falls back to rDNS"       "dns.google"        "$(run host-name 3)"
assert_eq "hostname empty when neither set"   ""                  "$(run host-name 4)"

# Group keys
assert_eq "app key uses the app name"         "netflix"           "$(run key 0 app)"
assert_eq "app key uses app when no SNI"      "netflix"           "$(node -e '
var SERVICE_PORTS={};
eval(require("fs").readFileSync(process.argv[1],"utf8"));
process.stdout.write(connectionGroupKey({app:"netflix",dst:"1.2.3.4"}, "app"));
' "$TMP/slices.js")"
assert_eq "app key falls back to rDNS"        "dns.google"        "$(run key 3 app)"
assert_eq "app key falls back to dest IP"     "1.1.1.1"           "$(run key 4 app)"
assert_eq "host key uses SNI"                 "www.netflix.com"   "$(run key 0 host)"
assert_eq "host key falls back to dest IP"    "1.1.1.1"           "$(run key 4 host)"
assert_eq "service key uses the service name" "https"             "$(run key 0 service)"

# groupConnections
assert_eq "groupBy none returns null"         "null"              "$(run none)"
assert_eq "unknown groupBy returns null"      "null"              "$(run unknown)"

# Two Netflix IPs share a hostname: 1000+4000 bytes, 2 tcp flows.
assert_eq "app groups every netflix flow together" \
    "netflix 2 5000 2 0 2" "$(run group app netflix)"
assert_eq "app groups youtube separately" \
    "youtube 1 2500 0 1 1" "$(run group app youtube)"
assert_eq "app fallback group is the dest IP" \
    "1.1.1.1 1 200 1 0 1" "$(run group app 1.1.1.1)"
assert_eq "app fallback group uses rDNS" \
    "dns.google 1 80 0 1 1" "$(run group app dns.google)"
# unclassified has no app and no host, so it groups by IP, not as "unclassified".
assert_eq "unclassified flows group by IP" \
    "9.9.9.9 1 10 1 0 1" "$(run group app 9.9.9.9)"

assert_eq "member list keeps both netflix IPs" \
    "45.57.0.1,45.57.0.2" "$(run member-dsts app netflix)"

# host grouping is the same key as app when a SNI is present, and still
# falls back to rDNS / IP.
assert_eq "host grouping sums the netflix flows" \
    "www.netflix.com 2 5000 2 0 2" "$(run group host www.netflix.com)"

# Distinct keys: netflix SNI, youtube SNI, dns.google, 1.1.1.1, 9.9.9.9
assert_eq "app grouping produces one group per label" "5" "$(run group-count app)"

# service grouping still works, and now keeps member rows.
assert_eq "service grouping sums https" \
    "https 5 7710 4 1 5" "$(run group service https)"
assert_eq "service grouping keeps dns separate" \
    "dns 1 80 0 1 1" "$(run group service dns)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
