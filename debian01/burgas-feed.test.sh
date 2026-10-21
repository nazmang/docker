#!/usr/bin/env bash
#
# Tests for burgas-feed.sh, no root and no real bucket needed:
#   bash debian01/burgas-feed.test.sh          local cases only
#   LIVE=1 bash debian01/burgas-feed.test.sh   plus the real www.burgas.bg feed (dry run)
#
# A tiny local HTTP server plays both the feed (a good feed, an empty one, a
# Cloudflare-style HTML challenge, a 403, a cut connection) and the bucket (it
# records the PUT so the test can check the signature header, the content type
# and that the secret never shows up in the script's output), plus article pages
# for the full-text step (a good one, a long one, a 403, one with no text).

set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/burgas-feed.sh"
work=$(mktemp -d)
trap 'kill "$srv" 2>/dev/null; rm -rf "$work"' EXIT
fails=0

ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 - "$port" "$work" <<'PY' &
import http.server, sys, pathlib
port, work = int(sys.argv[1]), pathlib.Path(sys.argv[2])
GOOD = b'<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>t</title><item><title>a</title></item></channel></rss>'
EMPTY = b'<?xml version="1.0"?><rss version="2.0"><channel><title>t</title></channel></rss>'
CHALLENGE = b'<!DOCTYPE html><html><head><title>Just a moment...</title></head><body>cf challenge<br></body></html>'
BASE = f"http://127.0.0.1:{port}"
TEASER = "Тизер от лентата, " * 5
def page(body):
    return ('<html><body><div id="nav">menu text</div><main><div id="content">'
            '<div class="event-meta clearfix"><span>Сряда, 21 Октомври 2026<br/>Публикувано от: X</span>'
            '<div class="float-right"><script>var share = 1;</script></div></div>'
            f'{body}</div></main><div class="sidebar"><h2>Последни новини</h2></div></body></html>').encode()
FULL = "<p>Пълен текст на статията &bdquo;с кавички&ldquo;, " + "дълъг абзац " * 20 + "</p><ul><li>точка едно</li><li>точка две</li></ul>"
PAGES = {
    "/a/full": (200, page(FULL)),
    "/a/long": (200, page("<p>" + "дума " * 1200 + "</p>")),
    "/a/short": (200, page("<p>Кратко.</p>")),
    "/a/notext": (200, b"<html><body><p>no content div</p></body></html>"),
    "/a/forbidden": (403, CHALLENGE),
    "/a/after": (200, page(FULL)),
}
def item(path):
    return f"<item><title>{path}</title><link>{BASE}{path}</link><guid>{BASE}{path}</guid><description>{TEASER}</description></item>"
ENRICH = ('<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>t</title>'
          + "".join(item(p) for p in PAGES)
          + "<item><title>off</title><link>https://elsewhere.invalid/x</link><guid>off</guid><description>t</description></item>"
          + "</channel></rss>").encode()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype="application/xml"):
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == "/good": self._send(200, GOOD)
        elif self.path == "/empty": self._send(200, EMPTY)
        elif self.path == "/challenge": self._send(200, CHALLENGE, "text/html")
        elif self.path == "/forbidden": self._send(403, CHALLENGE, "text/html")
        elif self.path == "/enrich": self._send(200, ENRICH)
        elif self.path in PAGES:
            with open(work / "gets", "a") as f: f.write(self.path + "\n")
            code, body = PAGES[self.path]; self._send(code, body, "text/html")
        elif self.path == "/cut":
            self.send_response(200); self.send_header("Content-Length", "100000"); self.end_headers()
            self.wfile.write(GOOD[:40]); self.wfile.flush(); self.connection.close()
        else: self._send(404, b"")
    def do_PUT(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        (work / "put.body").write_bytes(body)
        (work / "put.headers").write_text("".join(f"{k}: {v}\n" for k, v in self.headers.items()))
        self._send(403 if self.path == "/denied" else 200, b"")
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
srv=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/good" && break; sleep 0.1; done
base="http://127.0.0.1:$port"

run() {  # run <expected exit> <name> <args...> - env passed by the caller
    local want=$1 name=$2; shift 2
    out=$("$script" "$@" 2>&1); got=$?
    if [[ $got == "$want" ]]; then ok "$name (exit $got)"; else fail "$name: exit $got, want $want: $out"; fi
}

# --- validator on files ---
printf '%s' '<?xml version="1.0"?><rss version="2.0"><channel><item><title>x</title></item></channel></rss>' > "$work/g.xml"
printf '%s' '<?xml version="1.0"?><rss version="2.0"><channel></channel></rss>' > "$work/e.xml"
printf '%s' '<!DOCTYPE html><html><body>Just a moment<br></body></html>' > "$work/h.html"
printf '%s' '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"></feed>' > "$work/a.xml"
run 0 "check: valid rss"            --check "$work/g.xml"
run 3 "check: empty rss"            --check "$work/e.xml"
run 3 "check: html challenge page"  --check "$work/h.html"
run 3 "check: not rss (atom root)"  --check "$work/a.xml"

# --- fetch paths, dry run (no credentials needed) ---
FEED_URL=$base/good      run 0 "dry run: good feed"                --dry-run
FEED_URL=$base/empty     run 3 "dry run: empty feed rejected"      --dry-run
FEED_URL=$base/challenge run 3 "dry run: 200 html challenge"       --dry-run
FEED_URL=$base/forbidden run 2 "dry run: 403"                      --dry-run
FEED_URL=$base/cut       run 2 "dry run: connection cut mid-body"  --dry-run
FEED_URL=http://127.0.0.1:1/x run 2 "dry run: nothing listening"   --dry-run

# --- upload ---
mkdir -p "$work/cred"
printf 'AWS_ACCESS_KEY_ID=bgcn-feed-writer\nAWS_SECRET_ACCESS_KEY=s3cr3t-never-logged\n' > "$work/cred/credentials"
out=$(FEED_URL=$base/good TARGET_URL=$base/feeds/burgas.xml CREDENTIALS_DIRECTORY=$work/cred "$script" 2>&1); got=$?
[[ $got == 0 ]] && ok "upload: exit 0" || fail "upload: exit $got: $out"
grep -q '^Authorization: AWS4-HMAC-SHA256 Credential=bgcn-feed-writer/' "$work/put.headers" \
    && ok "upload: sigv4 signed with the writer key" || fail "upload: no sigv4 header: $(cat "$work/put.headers")"
grep -qi '^Content-Type: application/rss+xml' "$work/put.headers" \
    && ok "upload: content type" || fail "upload: content type: $(cat "$work/put.headers")"
cmp -s "$work/put.body" <(curl -s "$base/good") && ok "upload: body is the fetched feed" || fail "upload: body differs"
[[ $out != *s3cr3t* ]] && ok "upload: secret not in the output" || fail "upload: secret leaked: $out"

rm -f "$work/put.body"
FEED_URL=$base/challenge TARGET_URL=$base/feeds/burgas.xml CREDENTIALS_DIRECTORY=$work/cred "$script" >/dev/null 2>&1
[[ ! -e $work/put.body ]] && ok "invalid feed: nothing uploaded" || fail "invalid feed: a PUT happened"

FEED_URL=$base/good TARGET_URL=$base/denied CREDENTIALS_DIRECTORY=$work/cred run 4 "upload: bucket answers 403"
FEED_URL=$base/good TARGET_URL=$base/feeds/burgas.xml CREDENTIALS_DIRECTORY=$work/nowhere run 5 "upload: no credentials"

# --- full text ---
# Upload runs, so put.body is the feed as it would land in the bucket.
desc() {  # desc <title> - the description of that item in the uploaded feed
    python3 -c 'import sys, xml.etree.ElementTree as ET
for i in ET.parse(sys.argv[1]).getroot().iter("item"):
    if i.findtext("title") == sys.argv[2]: print(i.findtext("description"))' "$work/put.body" "$1"
}
gets() { grep -c "^$1\$" "$work/gets" 2>/dev/null; }
mkdir -p "$work/state"
export ARTICLE_PREFIX=$base/a/ PAUSE_MS=0 PAUSE_JITTER_MS=0
enr() { FEED_URL=$base/enrich TARGET_URL=$base/feeds/burgas.xml CREDENTIALS_DIRECTORY=$work/cred CACHE_DIR=$work/state "$@" "$script" 2>&1; }

rm -f "$work/gets" "$work/put.body"
out=$(enr env); got=$?
[[ $got == 0 ]] && ok "full text: exit 0" || fail "full text: exit $got: $out"
[[ $out == *"full text: 2 items, 5 pages fetched"* ]] && ok "full text: log line" || fail "full text: log: $out"
d=$(desc /a/full)
[[ $d == "Пълен текст на статията „с кавички“, дълъг"* && $d == *"- точка две" ]] \
    && ok "full text: plain text from #content" || fail "full text: description: $d"
[[ $d != *"<"* && $d != *Публикувано* && $d != *share* && $d != *"Последни новини"* && $d != *"menu text"* ]] \
    && ok "full text: no HTML, meta, script, sidebar or nav" || fail "full text: noise in: $d"
d=$(desc /a/long)
(( ${#d} <= 3500 )) && [[ $d == *… ]] && ok "full text: cut to 3500 chars with … (${#d})" || fail "full text: long text ${#d} chars"
[[ $(desc /a/short) == "$(desc /a/notext)" && $(desc /a/short) == Тизер* ]] \
    && ok "full text: short page and page without #content keep the teaser" || fail "full text: short/notext: $(desc /a/short)"
[[ $(desc /a/forbidden) == Тизер* ]] && ok "full text: 403 keeps the teaser" || fail "full text: 403: $(desc /a/forbidden)"
[[ $(gets /a/after) == 0 ]] && ok "full text: no more pages after a 403" || fail "full text: fetched /a/after after the 403"
[[ $(desc off) == t ]] && ok "full text: links outside ARTICLE_PREFIX are not fetched" || fail "full text: off-prefix item changed"

cp "$work/gets" "$work/gets.run1"
out=$(enr env); got=$?
tail -n +"$(( $(wc -l < "$work/gets.run1") + 1 ))" "$work/gets" > "$work/gets.run2"
[[ $(gets /a/full) == 1 && $(gets /a/notext) == 1 ]] && ok "full text: cached pages are not fetched again" \
    || fail "full text: refetched: $(sort "$work/gets" | uniq -c | tr '\n' ' ')"
[[ $(gets /a/forbidden) == 2 && $(gets /a/after) == 1 && $(head -1 "$work/gets.run2") == /a/after ]] \
    && ok "full text: a failed page goes to the back of the queue and is retried" \
    || fail "full text: retry: $(tr '\n' ' ' < "$work/gets")"
[[ $(desc /a/after) == Пълен* && $(desc /a/full) == Пълен* ]] && ok "full text: cached text still applied" || fail "full text: cache not applied"
enr env >/dev/null; enr env >/dev/null
[[ $(gets /a/forbidden) == 3 ]] && ok "full text: a page is given up after 3 failures" || fail "full text: 403 page fetched $(gets /a/forbidden) times"

rm -rf "$work/state"/* "$work/gets"
out=$(enr env MAX_ARTICLES=2); got=$?
[[ $got == 0 && $(wc -l < "$work/gets") == 2 ]] && ok "full text: MAX_ARTICLES=2 caps page fetches" || fail "full text: limit: $(cat "$work/gets")"

rm -rf "$work/state"/* "$work/gets"
out=$(enr env ENRICH=0); got=$?
[[ $got == 0 && ! -e $work/gets ]] && cmp -s "$work/put.body" <(curl -s "$base/enrich") \
    && ok "full text: ENRICH=0 mirrors the feed as is" || fail "full text: ENRICH=0: $out"

rm -f "$work/gets"
out=$(enr env CACHE_DIR=/nonexistent); got=$?
[[ $got == 0 && $out == *"not writable"* ]] && cmp -s "$work/put.body" <(curl -s "$base/enrich") \
    && ok "full text: broken cache dir still uploads the plain feed" || fail "full text: bad cache: exit $got: $out"

FEED_URL=$base/enrich CACHE_DIR=$work/state PAUSE_MS=300 PAUSE_JITTER_MS=0 MAX_ARTICLES=3 ARTICLE_PREFIX=$base/a/ \
    bash -c 'rm -rf "$CACHE_DIR"/*; s=$(date +%s%N); "$0" --dry-run >/dev/null 2>&1; echo $(( ($(date +%s%N) - s) / 1000000 ))' "$script" > "$work/ms"
(( $(cat "$work/ms") >= 600 )) && ok "full text: pause between pages ($(cat "$work/ms") ms for 3)" || fail "full text: no pause: $(cat "$work/ms") ms"
unset ARTICLE_PREFIX PAUSE_MS PAUSE_JITTER_MS

# --- the real feed ---
if [[ ${LIVE:-0} == 1 ]]; then
    run 0 "live: www.burgas.bg validates (dry run)" --dry-run
fi

echo
if (( fails )); then echo "$fails failed"; exit 1; fi
echo "all passed"
