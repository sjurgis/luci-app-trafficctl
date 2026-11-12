#!/bin/bash
# Clearing the Status page device search returns to the all-devices overview.
#
# Selecting a device in the search dropdown opens that device's detail view.
# Clicking the field's ×, or deleting the field to empty, left the page on
# the device: × re-focused the input (so the dropdown opened again and it
# looked like a choice was still required), and backspace-to-empty only
# filtered the list — selectedValue stayed on the device, so the user had
# to pick "All active devices" by hand to get back.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}
assert_has() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n" "$1" "$2"
    fi
}
assert_lacks() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  must NOT contain: '%s'\n" "$1" "$2"
    else
        PASS=$((PASS + 1))
    fi
}

_p=$PASS; _f=$FAIL
assert_eq "self-check" "x" "x"
assert_has "self-check" "needle" "a needle here"
assert_lacks "self-check" "needle" "nothing here"
if [ "$PASS" -ne $((_p + 3)) ] || [ "$FAIL" -ne "$_f" ]; then
    echo "BROKEN SUITE: the assert helpers do not count correctly"
    exit 1
fi
PASS=$_p; FAIL=$_f

# Strip comments so prose in this file or in status.js cannot satisfy a check.
jsblock() {
    python3 - "$JS" "$1" <<'PY'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.index(sys.argv[2])
j = src.index('{', i)
depth = 0
body = ''
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            body = src[j:k+1]
            break
body = re.sub(r'//[^\n]*', '', body)
sys.stdout.write(re.sub(r'/\*.*?\*/', '', body, flags=re.S))
PY
}

search=$(jsblock 'function buildSearchSelect(')
query=$(jsblock 'function runQuery(')
single=$(jsblock 'function runSingle(')
all=$(jsblock 'function runAll(')

for pair in "buildSearchSelect:$search" "runQuery:$query" "runSingle:$single" "runAll:$all"; do
    name=${pair%%:*}; body=${pair#*:}
    case "$body" in
        "{"*"}") PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: extraction of %s is not a complete block (%s chars) — the assertions below would be vacuous\n" \
                "$name" "${#body}"
            ;;
    esac
done

# ── the widget treats an empty field as "All active devices" ──────────────
assert_has "× selects the all-devices value" "selectItem('__all__', '')" "$search"
assert_lacks "× does not refocus the input (that re-opens the dropdown)" "input.focus()" "$search"
assert_has "an empty input also selects all-devices" "selectedValue !== '__all__'" "$search"

# ── leaving a device must actually switch the page and its pollers ────────
assert_has "runQuery clears the status line when the selection changes" "clearStatus(statusDiv)" "$query"
assert_has "runQuery remembers which device the status line belongs to" "self._statusIp" "$query"
assert_has "runQuery runs the overview when the value is all-devices" "runAll()" "$query"
assert_has "runQuery starts the device poll only for a single device" "runSingle(ip)" "$query"
assert_has "runAll bumps the query generation so a late device reply is dropped" \
    "self._queryGen++" "$all"
assert_has "runSingle ignores a reply from a superseded query" \
    "gen !== self._queryGen" "$single"
assert_has "runAll ignores a reply from a superseded query" \
    "gen !== self._queryGen" "$all"

# ── exercise the real widget under node ───────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
    printf "SKIP: node is not installed — buildSearchSelect cannot be run here.\n"
else
    python3 - "$JS" "$TMP/search.js" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
needle = 'function buildSearchSelect('
i = src.index(needle)
j = src.index('{', i)
depth = 0
end = None
for k in range(j, len(src)):
    if src[k] == '{':
        depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            end = k + 1
            break
io.open(sys.argv[2], 'w', encoding='utf-8').write(src[i:end] + '\n')
PY

    cat > "$TMP/dom.js" <<'JS'
function ClassList(el) {
    this._el = el;
    this._set = {};
}
ClassList.prototype.add = function(c) {
    if (!c) return;
    this._set[c] = true;
    this._sync();
};
ClassList.prototype.remove = function(c) {
    delete this._set[c];
    this._sync();
};
ClassList.prototype.contains = function(c) { return !!this._set[c]; };
ClassList.prototype._sync = function() {
    var keys = [];
    for (var k in this._set) { if (this._set[k]) keys.push(k); }
    this._el.className = keys.join(' ');
};

function El(tag) {
    this.tagName = String(tag || 'div').toUpperCase();
    this.children = [];
    this.listeners = {};
    this.attributes = {};
    this.className = '';
    this.classList = new ClassList(this);
    this.style = {};
    this.value = '';
    this.textContent = '';
    this.innerHTML = '';
    this.firstChild = null;
}
El.prototype.appendChild = function(c) {
    this.children.push(c);
    this.firstChild = this.children[0] || null;
    return c;
};
El.prototype.removeChild = function(c) {
    var next = [];
    for (var i = 0; i < this.children.length; i++) {
        if (this.children[i] !== c) next.push(this.children[i]);
    }
    this.children = next;
    this.firstChild = this.children[0] || null;
    return c;
};
El.prototype.setAttribute = function(k, v) { this.attributes[k] = String(v); };
El.prototype.getAttribute = function(k) {
    return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null;
};
El.prototype.addEventListener = function(ev, fn) {
    if (!this.listeners[ev]) this.listeners[ev] = [];
    this.listeners[ev].push(fn);
};
El.prototype.dispatchEvent = function(ev, props) {
    var e = props || {};
    e.type = ev;
    e.preventDefault = e.preventDefault || function() { e.defaultPrevented = true; };
    e.stopPropagation = e.stopPropagation || function() {};
    var list = this.listeners[ev] || [];
    var self = this;
    for (var i = 0; i < list.length; i++) list[i].call(self, e);
    return e;
};
El.prototype.focus = function() { this.dispatchEvent('focus'); };
El.prototype.blur = function() { this.dispatchEvent('blur'); };

function E(tag, attrs, children) {
    var el = new El(tag);
    if (attrs) {
        Object.keys(attrs).forEach(function(k) {
            if (k === 'class') {
                String(attrs[k]).split(/\s+/).forEach(function(c) { el.classList.add(c); });
            } else {
                el.setAttribute(k, attrs[k]);
                if (k === 'type') el.type = attrs[k];
            }
        });
    }
    if (children == null) return el;
    if (!Array.isArray(children)) children = [children];
    children.forEach(function(c) {
        if (c == null) return;
        if (typeof c === 'string' || typeof c === 'number') el.textContent += String(c);
        else el.appendChild(c);
    });
    return el;
}
function _(s) { return s; }
function escHtml(s) {
    return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}
JS

    cat > "$TMP/driver.js" <<'JS'
var devices = [
    { ip: '10.0.0.22', name: 'printer', mac: 'aa:bb:cc:dd:ee:01' },
    { ip: '10.0.0.142', name: 'mova', mac: 'aa:bb:cc:dd:ee:02' }
];
var selected = [];
var sel = buildSearchSelect(devices, 'Search device…', function(v) { selected.push(v); });
var wrapper = sel.el;
var input = wrapper.children[0];
var clearBtn = wrapper.children[1];
var dropdown = wrapper.children[2];

function last() { return selected[selected.length - 1]; }
function out(k, v) { process.stdout.write(k + '=' + v + '\n'); }

out('initial', sel.getValue());

sel.setValue('10.0.0.22', 'printer  —  10.0.0.22');
out('after-set', sel.getValue());
out('set-is-silent', String(selected.length));
out('clear-visible', String(!clearBtn.classList.contains('tc-hidden')));
out('input-shows-device', input.value);

// Typing a partial filter must not leave the device.
input.value = 'print';
input.dispatchEvent('input');
out('partial-still-device', sel.getValue());
out('partial-no-select', String(selected.length));

// Backspace-to-empty is the same as picking "All active devices".
input.value = '';
input.dispatchEvent('input');
out('empty-value', sel.getValue());
out('empty-notified', last());
out('empty-input', input.value);
out('empty-clear-hidden', String(clearBtn.classList.contains('tc-hidden')));

// Re-select from the dropdown, then click ×. The click must go to all-devices
// and must not focus the input (focus would re-open the dropdown).
input.dispatchEvent('click');
var item = null;
dropdown.children.forEach(function(el) {
    if (el.getAttribute('data-value') === '10.0.0.142') item = el;
});
out('found-mova', String(!!item));
if (item) item.dispatchEvent('mousedown', {});
out('reselect', sel.getValue());
out('reselect-notified', last());
out('reselect-clear-visible', String(!clearBtn.classList.contains('tc-hidden')));

var focused = 0;
input.focus = function() { focused += 1; this.dispatchEvent('focus'); };
clearBtn.dispatchEvent('mousedown', {});
clearBtn.dispatchEvent('click', {});
out('x-value', sel.getValue());
out('x-notified', last());
out('x-input', input.value);
out('x-clear-hidden', String(clearBtn.classList.contains('tc-hidden')));
out('x-focused', String(focused));
out('x-dropdown-hidden', String(dropdown.classList.contains('tc-hidden')));

// Clearing again while already on the overview must not re-fire onSelect.
var n = selected.length;
input.value = '';
input.dispatchEvent('input');
out('already-all-no-refire', String(selected.length === n));
JS

    cat "$TMP/dom.js" "$TMP/search.js" "$TMP/driver.js" > "$TMP/run.js"
    RESULT=$(node "$TMP/run.js") || {
        FAIL=$((FAIL + 1))
        printf "FAIL: node failed to run buildSearchSelect\n%s\n" "$RESULT"
        RESULT=""
    }

    val() { printf '%s\n' "$RESULT" | sed -n "s/^$1=//p"; }

    assert_eq "harness produced output" "1" "$([ -n "$RESULT" ] && echo 1 || echo 0)"
    assert_eq "starts on all-devices" "__all__" "$(val initial)"
    assert_eq "setValue selects a device" "10.0.0.22" "$(val after-set)"
    assert_eq "setValue is silent (no onSelect)" "0" "$(val set-is-silent)"
    assert_eq "× is shown for a selected device" "true" "$(val clear-visible)"
    assert_eq "a partial filter keeps the selected device" "10.0.0.22" "$(val partial-still-device)"
    assert_eq "a partial filter does not notify" "0" "$(val partial-no-select)"
    assert_eq "backspace-to-empty selects all-devices" "__all__" "$(val empty-value)"
    assert_eq "backspace-to-empty notifies onSelect" "__all__" "$(val empty-notified)"
    assert_eq "backspace-to-empty clears the input" "" "$(val empty-input)"
    assert_eq "× is hidden after going back to the overview" "true" "$(val empty-clear-hidden)"
    assert_eq "the dropdown still lists the other device" "true" "$(val found-mova)"
    assert_eq "re-selecting a device from the list works" "10.0.0.142" "$(val reselect)"
    assert_eq "re-selecting notifies onSelect" "10.0.0.142" "$(val reselect-notified)"
    assert_eq "× is shown again after re-select" "true" "$(val reselect-clear-visible)"
    assert_eq "clicking × selects all-devices" "__all__" "$(val x-value)"
    assert_eq "clicking × notifies onSelect" "__all__" "$(val x-notified)"
    assert_eq "clicking × clears the input" "" "$(val x-input)"
    assert_eq "clicking × hides the clear button" "true" "$(val x-clear-hidden)"
    assert_eq "clicking × does not focus the input" "0" "$(val x-focused)"
    assert_eq "clicking × leaves the dropdown closed" "true" "$(val x-dropdown-hidden)"
    assert_eq "clearing an already-empty overview does not re-notify" "true" "$(val already-all-no-refire)"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
