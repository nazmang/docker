#!/usr/bin/env bash
#
# Tests for burgas-feed.sh, no root and no real bucket needed:
#   bash debian01/burgas-feed.test.sh          local cases only
#   LIVE=1 bash debian01/burgas-feed.test.sh   plus the real www.burgas.bg feed (dry run)
#
# A tiny local HTTP server plays both the feed (a good feed, an empty one, a
# Cloudflare-style HTML challenge, a 403, a cut connection) and the bucket (it
# records the PUT so the test can check the signature header, the content type
# and that the secret never shows up in the script's output).

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

# --- the real feed ---
if [[ ${LIVE:-0} == 1 ]]; then
    run 0 "live: www.burgas.bg validates (dry run)" --dry-run
fi

echo
if (( fails )); then echo "$fails failed"; exit 1; fi
echo "all passed"
