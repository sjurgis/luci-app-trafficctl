#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=dash
# Optional Netify Agent (netifyd) integration — DPI application labels per device.
#
# Entirely optional: every entry point degrades to an empty result when netifyd
# is not installed, not running, or no socket reader is available, so the rest
# of trafficctl behaves exactly as before.
#
# Usage:
#   trafficctl-netify.sh status          — availability probe (JSON object)
#   trafficctl-netify.sh collect [secs]  — sample the socket, refresh the cache
#   trafficctl-netify.sh list            — cached per-device app breakdown
#   trafficctl-netify.sh raw [secs]      — raw socket lines (debugging)
#
# Telemetry comes from the agent's socket SINK, not from netifyd.sock: in
# Agent v5 that unix socket is a request/response API which never pushes flow
# data, so connecting to it returns nothing at all. The sink's bind address is
# read from netify-sink-socket.json (typically tcp://127.0.0.1:1780).
#
# Two payload shapes are handled: the aggregator's {"stats":[...]} records
# (application_id/local_ip/download/upload) and raw per-flow records
# (detected_application_name/local_ip/total_bytes). Records are parsed by field
# extraction rather than strict JSON, which tolerates either framing.

. /usr/libexec/trafficctl/trafficctl-fw.sh

CACHE="/tmp/trafficctl_netify.json"
# Per-flow labels (local_ip, other_ip, proto, port, app, host), used by the
# device detail view to tag conntrack rows. A separate file so the existing
# list/cache JSON (a top-level array of per-device rollups) stays unchanged.
LABELS="${TCTL_NETIFY_LABELS:-/tmp/trafficctl_netify_labels}"
LABELS_MAX=4000
LOCK="/tmp/trafficctl_netify.lock"
DEFAULT_SOCKET="/var/run/netifyd/netifyd.sock"

netify_socket() {
    local s
    s=$(uci -q get trafficctl.main.netify_socket 2>/dev/null)
    [ -n "$s" ] && { echo "$s"; return; }
    echo "$DEFAULT_SOCKET"
}

# Where flow telemetry is actually published: an explicit override, else the
# first enabled socket-sink channel, else the legacy unix socket (Agent v4).
netify_endpoint() {
    local ep
    ep=$(uci -q get trafficctl.main.netify_endpoint 2>/dev/null)
    [ -n "$ep" ] && { echo "$ep"; return; }
    ep=$(sed -n 's/.*"bind_address\"[ \t]*:[ \t]*"\(tcp:\/\/[^"]*\)".*/\1/p' \
        /etc/netifyd/netify-sink-socket.json 2>/dev/null | head -1)
    [ -n "$ep" ] && { echo "$ep"; return; }
    echo "unix://$(netify_socket)"
}

netify_enabled() {
    [ "$(uci -q get trafficctl.main.netify_enabled 2>/dev/null)" != "0" ]
}

# Echo the command able to stream the socket, or nothing.
socket_reader() {
    if command -v socat >/dev/null 2>&1; then
        echo "socat"
    elif command -v nc >/dev/null 2>&1; then
        echo "nc"
    fi
}

read_socket() {
    local secs="$1" ep reader hostport path
    ep=$(netify_endpoint)
    reader=$(socket_reader)
    [ -n "$reader" ] || return 1

    case "$ep" in
        tcp://*)
            hostport=${ep#tcp://}
            case "$reader" in
                socat) timeout "$secs" socat -u "TCP-CONNECT:$hostport" - 2>/dev/null ;;
                nc)    timeout "$secs" nc "${hostport%%:*}" "${hostport##*:}" 2>/dev/null ;;
            esac
            ;;
        unix://*|/*)
            path=${ep#unix://}
            [ -S "$path" ] || return 1
            case "$reader" in
                socat) timeout "$secs" socat -u "UNIX-CONNECT:$path" - 2>/dev/null ;;
                nc)    timeout "$secs" nc -U "$path" 2>/dev/null ;;
            esac
            ;;
        *) return 1 ;;
    esac
    return 0
}

# Tests (and offline debugging) feed recorded agent output instead of a socket.
feed_lines() {
    if [ -n "$TCTL_NETIFY_FEED" ] && [ -f "$TCTL_NETIFY_FEED" ]; then
        cat "$TCTL_NETIFY_FEED"
    else
        read_socket "$1"
    fi
}

do_status() {
    local sock reader installed=false running=false readable=false age=-1 now mtime
    sock=$(netify_socket)
    reader=$(socket_reader)
    command -v netifyd >/dev/null 2>&1 && installed=true
    [ -S "$sock" ] && running=true
    [ -n "$reader" ] && readable=true
    if [ -f "$CACHE" ]; then
        now=$(date +%s)
        mtime=$(date -r "$CACHE" +%s 2>/dev/null || echo 0)
        age=$(( now - mtime ))
    fi
    printf '{"enabled":%s,"installed":%s,"running":%s,"socket":"%s","endpoint":"%s","reader":"%s","readable":%s,"cache_age":%d}\n' \
        "$(netify_enabled && echo true || echo false)" \
        "$installed" "$running" "$sock" "$(netify_endpoint)" "${reader:-none}" "$readable" "$age"
}

# Aggregate flow records into "per local IP → per application" totals, and
# a compact per-flow label map used by the device detail view.
#
# The agent re-emits a flow as its byte counters grow (flow, flow_dpi_update,
# flow_dpi_complete, and — on Agent v5 — a separate flow_stats record). Totals
# are tracked per flow digest and only summed at the end: adding every
# sighting would multiply-count the same traffic.
#
# flow_stats carries digest + byte counters but not local_ip or the
# application name. Requiring local_ip on every line dropped those updates,
# so a device's apps were listed with bytes:0 (the identifying flow record
# often arrives first, with counters still at zero). Byte updates for a
# digest we already know, or that we will meet later, are kept even when
# the line has no local_ip. Counters are cumulative, so a later smaller
# value does not replace a larger one.
#
# Labels are written to the file in $1 when it is set: one "local_ip other_ip
# proto port app host" line per unique 4-tuple, so trafficctl-device.sh can
# tag conntrack rows without talking to the socket.
parse_flows() {
    # One JSON object per line so the field extractor sees one record at a
    # time — the aggregator packs every device into a single "stats" array.
    # awk gsub, not sed: BusyBox sed treats \n in the replacement as a
    # literal n, which left the whole array on one line. Braces in the
    # pattern are written as character classes — BusyBox awk otherwise
    # treats '{' as the start of an invalid interval (the persist-save bug).
    awk '{ gsub(/[}][ \t]*,[ \t]*[{]/, "}\n{"); print }' | awk -v labelfile="$1" '
    function field(line, key,   re, seg) {
        re = "\"" key "\"[ \t]*:[ \t]*"
        if (!match(line, re)) return ""
        seg = substr(line, RSTART + RLENGTH)
        if (substr(seg, 1, 1) == "\"") {
            seg = substr(seg, 2)
            if (!match(seg, /"/)) return ""
            return substr(seg, 1, RSTART - 1)
        }
        if (!match(seg, /^-?[0-9]+/)) return ""
        return substr(seg, RSTART, RLENGTH) + 0
    }
    function clean(s) {
        gsub(/[^a-zA-Z0-9._-]/, "", s)
        return s
    }
    function is_ipv4(s) {
        return s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/
    }
    {
        digest = field($0, "digest")
        ip = field($0, "local_ip")

        app = field($0, "application_id")
        sub(/^[0-9]+\./, "", app)
        # A bare numeric application_id (Aggregator Type 4) is not a name.
        if (app == "" || app ~ /^[0-9]+$/) app = field($0, "detected_application_name")
        sub(/^netify\./, "", app)
        host = field($0, "host_server_name")
        if (host == "") host = field($0, "dns_host_name")
        host = clean(host)
        if (app == "" || app == "unknown") app = field($0, "detected_protocol_name")
        if (app == "" || app == "Unknown") {
            if (host != "") app = host; else app = "unclassified"
        }
        app = clean(app)
        if (app == "") app = "unclassified"

        dst = field($0, "other_ip")
        port = field($0, "other_port") + 0
        ipproto = field($0, "ip_protocol") + 0
        proto = ""
        if (ipproto == 6) proto = "tcp"
        else if (ipproto == 17) proto = "udp"
        else {
            pn = tolower(field($0, "detected_protocol_name"))
            if (pn ~ /quic/) proto = "udp"
            else if (pn ~ /tcp|tls|http|ssl|ssh|ftp|smtp|imap|pop/) proto = "tcp"
            else if (pn ~ /udp|dns|wireguard/) proto = "udp"
        }
        # Empty proto would collapse awk fields in the label file (a blank
        # token is dropped), so use a placeholder the device matcher treats
        # as "any".
        if (proto == "") proto = "-"

        bytes = field($0, "download") + field($0, "upload")
        if (bytes == 0) bytes = field($0, "total_bytes")
        if (bytes == 0) bytes = field($0, "local_bytes") + field($0, "other_bytes")
        bytes = bytes + 0

        if (digest == "" && is_ipv4(ip)) digest = "agg|" ip "|" app "|" NR

        if (digest != "") {
            if (!(digest in dbytes) || bytes > dbytes[digest]) dbytes[digest] = bytes
        }

        if (!is_ipv4(ip)) next

        key = ip SUBSEP app
        if (digest != "" && !(digest in seen)) { seen[digest] = key; flows[key]++ }

        if (is_ipv4(dst) && labelfile != "") {
            lkey = ip " " dst " " proto " " port
            # Prefer a real app name over unclassified, and a hostname over
            # an empty one, if the same 4-tuple is seen more than once.
            if (!(lkey in lapp) || (lapp[lkey] == "unclassified" && app != "unclassified")) lapp[lkey] = app
            if (host != "" && (lhost[lkey] == "" || length(host) > length(lhost[lkey]))) lhost[lkey] = host
        }
    }
    END {
        for (d in seen) total[seen[d]] += dbytes[d]
        for (k in total) {
            split(k, p, SUBSEP)
            printf "%s %s %.0f %d\n", p[1], p[2], total[k], flows[k]
        }
        if (labelfile != "") {
            for (lkey in lapp) {
                h = lhost[lkey]
                if (h == "") h = "-"
                print lkey, lapp[lkey], h > labelfile
            }
            close(labelfile)
        }
    }'
}

# Keep labels learned on earlier samples so a short collect window does not
# wipe the detail view. New keys win; older keys fill the remainder, up to
# LABELS_MAX lines (~a few hundred KB — cheap on a 128 MB router).
merge_labels() {
    local fresh="$1" out="$2"
    {
        [ -f "$fresh" ] && cat "$fresh"
        [ -f "$LABELS" ] && cat "$LABELS"
    } | awk -v max="$LABELS_MAX" '
        NF >= 6 {
            key = $1 " " $2 " " $3 " " $4
            if (key in seen) next
            seen[key] = 1
            print
            if (++n >= max) exit
        }' > "$out"
    mv "$out" "$LABELS"
}

do_collect() {
    # The aggregator publishes on an interval (~15s), so a short sample window
    # usually catches nothing at all — wait long enough to span one report.
    local secs="${1:-18}" raw parsed tmp labels_tmp labels_new
    case "$secs" in ''|*[!0-9]*) secs=18 ;; esac
    [ "$secs" -lt 1 ] && secs=1
    [ "$secs" -gt 60 ] && secs=60

    netify_enabled || { echo '{"ok":false,"msg":"netify integration disabled"}'; return 0; }

    # One collector at a time — overlapping samples would double the socket
    # load and race on the cache file.
    mkdir "$LOCK" 2>/dev/null || { echo '{"ok":false,"msg":"collection already running"}'; return 0; }
    # shellcheck disable=SC2064
    trap "rmdir '$LOCK' 2>/dev/null" EXIT INT TERM

    raw=$(feed_lines "$secs")
    if [ -z "$raw" ]; then
        echo '{"ok":false,"msg":"no data from netifyd socket"}'
        return 0
    fi

    labels_tmp="${LABELS}.tmp"
    labels_new="${LABELS}.new"
    parsed=$(printf '%s\n' "$raw" | parse_flows "$labels_new")
    merge_labels "$labels_new" "$labels_tmp"
    rm -f "$labels_new"
    tmp="${CACHE}.tmp"
    # Group by IP, apps sorted by bytes descending.
    printf '%s\n' "$parsed" | sort -k1,1 -k3,3nr | awk '
    BEGIN { printf "[" }
    NF >= 4 {
        if ($1 != cur) {
            if (cur != "") printf "]},"
            printf "{\"ip\":\"%s\",\"top\":\"%s\",\"apps\":[", $1, $2
            cur = $1
            first = 1
        }
        if (!first) printf ","
        printf "{\"name\":\"%s\",\"bytes\":%.0f,\"flows\":%d}", $2, $3, $4
        first = 0
    }
    END {
        if (cur != "") printf "]}"
        printf "]\n"
    }' > "$tmp"
    mv "$tmp" "$CACHE"

    printf '{"ok":true,"msg":"collected %s","devices":%d}\n' \
        "${secs}s" "$(printf '%s\n' "$parsed" | awk 'NF{print $1}' | sort -u | wc -l)"
}

do_list() {
    if [ -f "$CACHE" ]; then
        cat "$CACHE"
    else
        echo '[]'
    fi
}

do_raw() {
    local secs="${1:-18}"
    case "$secs" in ''|*[!0-9]*) secs=18 ;; esac
    [ "$secs" -gt 60 ] && secs=60
    feed_lines "$secs"
}

case "$1" in
    status)  do_status ;;
    collect) do_collect "$2" ;;
    list)    do_list ;;
    raw)     do_raw "$2" ;;
    *)       echo '{"ok":false,"msg":"usage: trafficctl-netify.sh status|collect [secs]|list|raw [secs]"}'; exit 1 ;;
esac
