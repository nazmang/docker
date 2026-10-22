#!/usr/bin/env bash
#
# Mirror of the Burgas municipality news RSS into our public bucket.
#
# Why this exists: www.burgas.bg sits behind Cloudflare, which answers the
# Kubernetes cluster with 403, so n8n cannot read the feed directly. debian01
# is on a home connection that Cloudflare lets through. This host fetches the
# feed and puts it into MinIO; n8n reads the copy from the bucket.
#
# A copy is replaced ONLY by a feed that passed validation: HTTP 200, parses as
# XML, the root is <rss> with a <channel> and at least one <item>. Anything else
# (a Cloudflare challenge page, an empty feed, a 403, a cut connection) leaves the
# last good copy in place, logs why, and exits non-zero so the unit is marked
# failed. A stale copy is fine for n8n; a broken one is not.
#
# Full text: the feed's <description> is a ~400-character teaser. Before upload
# the script fetches each article page once (same curl, same agent, same IP as
# the feed), cuts the text out of <div id="content"> and puts it into that
# item's <description> as plain text, up to MAX_CHARS. The text is cached per
# guid in $STATE_DIRECTORY, so an article costs one GET for its whole life in
# the feed. At most MAX_ARTICLES pages per run, with a 1-2 s pause between them.
# A page that fails or yields less text than the teaser leaves the teaser; a
# 403/429 also stops further page fetches until the next run. A failed page goes
# to the back of the queue and is given up after MAX_FAILS tries. Enrichment never
# breaks the mirror: if anything in it fails, the plain feed goes up.
#
# The S3 key may only PutObject - no HEAD/GET/list with it (those answer 403).
# It comes from systemd LoadCredential= ($CREDENTIALS_DIRECTORY/credentials, two
# lines AWS_ACCESS_KEY_ID=... / AWS_SECRET_ACCESS_KEY=...) and never reaches the
# log or the command line: curl reads it from stdin (-K -).
#
#   burgas-feed.sh               fetch, validate, upload
#   burgas-feed.sh --dry-run     fetch, validate and add full texts, no upload, no credentials needed
#   burgas-feed.sh --check FILE  validate a local file only (tests)
#   burgas-feed.sh --write-metric  write the success timestamp for node_exporter's textfile
#                                collector (the unit runs it as root after a successful run)
#
# Exit codes: 0 ok, 2 fetch failed, 3 feed invalid, 4 upload failed, 5 config error.

set -uo pipefail

FEED_URL="${FEED_URL:-https://www.burgas.bg/bg/rss/news}"
TARGET_URL="${TARGET_URL:-https://bg-coast-assets.srvx.cc/bg-coast-news-assets/feeds/burgas.xml}"
# A browser-like agent: Cloudflare challenges default curl agents more eagerly.
TEXTFILE="${TEXTFILE:-/var/lib/node_exporter/textfile/burgas_feed.prom}"
USER_AGENT="${USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36}"
# Full text. ENRICH=0 mirrors the feed as is. Only links under ARTICLE_PREFIX are
# fetched: the feed decides which URLs we GET, so it must not point us elsewhere.
ENRICH="${ENRICH:-1}"
ARTICLE_PREFIX="${ARTICLE_PREFIX:-https://www.burgas.bg/}"
MAX_ARTICLES="${MAX_ARTICLES:-20}"
MAX_CHARS="${MAX_CHARS:-3500}"
# A page that failed this many times (403, 5xx, timeout) is not fetched again.
export MAX_FAILS="${MAX_FAILS:-3}"
# Pause between page fetches, milliseconds: PAUSE_MS plus up to PAUSE_JITTER_MS.
PAUSE_MS="${PAUSE_MS:-1000}"
PAUSE_JITTER_MS="${PAUSE_JITTER_MS:-1000}"
# Without StateDirectory= (a manual --dry-run) the cache lives only for this run.
CACHE_DIR="${CACHE_DIR:-${STATE_DIRECTORY:-}}"

log() { printf 'burgas-feed: %s\n' "$*" >&2; }

# feedtool list FEED CACHE PREFIX MAX    - print "key<TAB>link" of up to MAX items with no cached text,
#                                          ones that failed before last, ones that failed MAX_FAILS times never
# feedtool extract PAGE                  - print the article text of an HTML page
# feedtool apply FEED CACHE MAXCHARS OUT - write FEED with cached texts as descriptions to OUT,
#                                          print how many items got the full text
feedtool() {
    python3 - "$@" <<'PY'
import hashlib, html, os, re, sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

def key(item):
    ident = (item.findtext("guid") or item.findtext("link") or "").strip()
    return hashlib.sha256(ident.encode()).hexdigest() if ident else None

class Content(HTMLParser):
    """Text of <div id="content">, minus the date/author/share block and scripts."""
    BLOCK = {"p", "div", "li", "ul", "ol", "br", "tr", "table", "blockquote",
             "h1", "h2", "h3", "h4", "h5", "h6"}
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.depth = 0          # <div> nesting inside #content; 0 = outside
        self.skip_at = None     # depth of the div being skipped
        self.raw = 0            # inside <script>/<style>
        self.done = False
        self.out = []
    def handle_starttag(self, tag, attrs):
        if self.done:
            return
        a = dict(attrs)
        if self.depth == 0:
            if tag == "div" and a.get("id") == "content":
                self.depth = 1
            return
        if tag in ("script", "style"):
            self.raw += 1
        if tag == "div":
            self.depth += 1
            if self.skip_at is None and "event-meta" in (a.get("class") or "").split():
                self.skip_at = self.depth
        if tag in self.BLOCK:
            self.out.append("\n")
        if tag == "li" and self.skip_at is None:
            self.out.append("- ")
    def handle_startendtag(self, tag, attrs):
        if self.depth and tag == "br":
            self.out.append("\n")
    def handle_endtag(self, tag):
        if self.done or self.depth == 0:
            return
        if tag in ("script", "style") and self.raw:
            self.raw -= 1
        if tag == "div":
            if self.skip_at == self.depth:
                self.skip_at = None
            self.depth -= 1
            if self.depth == 0:
                self.done = True
        if tag in self.BLOCK:
            self.out.append("\n")
    def handle_data(self, data):
        if self.depth and not self.done and self.skip_at is None and not self.raw:
            self.out.append(data)

def tidy(text):
    lines = [re.sub(r"[ \t\r\f\v\xa0]+", " ", l).strip() for l in text.split("\n")]
    text = "\n".join(lines)
    text = re.sub(r"\n(- *\n)+", "\n", text)        # empty list items
    return re.sub(r"\n{3,}", "\n\n", text).strip()

def plain(teaser):
    return tidy(html.unescape(re.sub(r"<[^>]+>", " ", teaser or "")))

def cut(text, limit):
    if len(text) <= limit:
        return text
    head = text[:limit - 1]
    space = max(head.rfind(" "), head.rfind("\n"))
    return (head[:space] if space > limit // 2 else head).rstrip() + "…"

cmd = sys.argv[1]
if cmd == "list":
    feed, cache, prefix, limit = sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
    todo = []
    for item in ET.parse(feed).getroot().find("channel").findall("item"):
        k, link = key(item), (item.findtext("link") or "").strip()
        if not k or not link.startswith(prefix) or os.path.exists(os.path.join(cache, k)):
            continue
        try:
            fails = int(open(os.path.join(cache, k + ".fail")).read() or 0)
        except (OSError, ValueError):
            fails = 0
        if fails < int(os.environ.get("MAX_FAILS", "3")):
            todo.append((fails, k, link))
    # A page that keeps failing must not stand first in line and starve the rest.
    for fails, k, link in sorted(todo, key=lambda t: t[0])[:limit]:
        print(f"{k}\t{link}")
elif cmd == "extract":
    p = Content()
    p.feed(open(sys.argv[2], encoding="utf-8", errors="replace").read())
    print(tidy("".join(p.out)))
elif cmd == "apply":
    feed, cache, limit, out = sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
    tree = ET.parse(feed)
    n = 0
    for item in tree.getroot().find("channel").findall("item"):
        k = key(item)
        path = os.path.join(cache, k) if k else None
        if not path or not os.path.exists(path):
            continue
        os.utime(path)                     # still in the feed: keep it past the prune
        text = open(path, encoding="utf-8").read().strip()
        desc = item.find("description")
        if len(text) <= len(plain(desc.text if desc is not None else "")):
            continue                       # page gave no more than the teaser: keep the teaser
        if desc is None:
            desc = ET.SubElement(item, "description")
        desc.text = cut(text, limit)
        n += 1
    tree.write(out, encoding="UTF-8", xml_declaration=True)
    print(n)
PY
}

# failed KEY - count a failed page fetch in the cache ($MAX_FAILS of them and the page is left alone)
failed() {
    local f="$cache/$1.fail" n=0
    [[ -r $f ]] && n=$(<"$f")
    printf '%d\n' "$(( ${n:-0} + 1 ))" > "$f"
}

# enrich FEED - replace teasers in FEED with full article texts, in place; never fails the run
enrich() {
    local feed=$1 cache=$CACHE_DIR fetched=0 k link code page text n reason
    if [[ -z "$cache" ]]; then
        cache="$tmpdir/cache"; mkdir -p "$cache"
    fi
    [[ -d "$cache" && -w "$cache" ]] || { log "full text: cache $cache not writable, mirroring teasers"; return 0; }
    # Articles drop out of a 20-item feed within days; apply touches the live ones.
    find "$cache" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null

    page="$tmpdir/page"
    while IFS=$'\t' read -r k link; do
        (( fetched )) && sleep "$(( PAUSE_MS + RANDOM % (PAUSE_JITTER_MS + 1) ))e-3"
        fetched=$((fetched + 1))
        code=$(curl -sS --connect-timeout 10 -m 15 -A "$USER_AGENT" -H 'Accept: text/html' \
                    -o "$page" -w '%{http_code}' "$link") || { log "full text: fetch failed (curl exit $?): $link"; failed "$k"; continue; }
        if [[ $code == 403 || $code == 429 ]]; then
            log "full text: HTTP $code on $link, no more pages this run"
            failed "$k"; break
        fi
        [[ $code == 200 ]] || { log "full text: HTTP $code on $link, keeping the teaser"; failed "$k"; continue; }
        # Cached even when empty: a page with no #content will not grow one, so it is not fetched again.
        text=$(feedtool extract "$page") || { log "full text: cannot parse $link"; continue; }
        printf '%s\n' "$text" > "$cache/$k.tmp" && mv "$cache/$k.tmp" "$cache/$k"
        [[ -n "$text" ]] || log "full text: no text in $link, keeping the teaser"
    done < <(feedtool list "$feed" "$cache" "$ARTICLE_PREFIX" "$MAX_ARTICLES" 2>/dev/null)

    if ! n=$(feedtool apply "$feed" "$cache" "$MAX_CHARS" "$feed.full" 2>/dev/null); then
        log "full text: rewrite failed, mirroring teasers"; return 0
    fi
    if [[ $n == 0 ]]; then
        rm -f "$feed.full"                 # nothing to add: upload the feed byte for byte
        log "full text: 0 items, $fetched pages fetched this run"; return 0
    fi
    if ! reason=$(validate "$feed.full" 2>&1); then
        log "full text: rewritten feed invalid ($reason), mirroring teasers"; return 0
    fi
    mv "$feed.full" "$feed"
    log "full text: $n items, $fetched pages fetched this run"
}

# validate FILE - exit 0 if it is a non-empty RSS 2.0 feed, else print the reason and exit 1
validate() {
    python3 - "$1" <<'PY'
import sys
import xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except ET.ParseError as e:
    sys.exit(f"not XML ({e}) - a Cloudflare challenge or an error page")
if root.tag != "rss":
    sys.exit(f"root is <{root.tag}>, not <rss>")
channel = root.find("channel")
if channel is None:
    sys.exit("no <channel>")
items = channel.findall("item")
if not items:
    sys.exit("no <item> - empty feed")
print(f"{len(items)} items")
PY
}

mode=run
case "${1:-}" in
    --dry-run) mode=dry ;;
    --check)
        [[ -n "${2:-}" ]] || { log "--check needs a file"; exit 5; }
        if reason=$(validate "$2" 2>&1); then log "valid: $reason"; exit 0; else log "invalid: $reason"; exit 3; fi ;;
    --write-metric)
        # Skipped quietly when node_exporter is not installed, like host-health.sh.
        [[ -d "$(dirname "$TEXTFILE")" ]] || exit 0
        printf '%s\n' \
            '# HELP burgas_feed_last_success_timestamp_seconds Last successful mirror of the Burgas RSS.' \
            '# TYPE burgas_feed_last_success_timestamp_seconds gauge' \
            "burgas_feed_last_success_timestamp_seconds $(date +%s)" > "$TEXTFILE.tmp" && mv "$TEXTFILE.tmp" "$TEXTFILE"
        exit ;;
    "") ;;
    *) log "unknown argument: $1"; exit 5 ;;
esac

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
tmp="$tmpdir/feed.xml"

# --- fetch ---------------------------------------------------------------------
code=$(curl -sS --connect-timeout 10 -m 30 -A "$USER_AGENT" -H 'Accept: application/rss+xml, application/xml;q=0.9' \
            -o "$tmp" -w '%{http_code}' "$FEED_URL") || { log "fetch failed (curl exit $?): $FEED_URL"; exit 2; }
if [[ "$code" != 200 ]]; then
    log "fetch got HTTP $code from $FEED_URL, keeping the previous copy"
    exit 2
fi

# --- validate ------------------------------------------------------------------
if ! reason=$(validate "$tmp" 2>&1); then
    log "feed rejected: $reason; keeping the previous copy"
    exit 3
fi
log "feed ok: $reason, $(stat -c %s "$tmp") bytes"

# --- full text -----------------------------------------------------------------
[[ $ENRICH == 1 ]] && enrich "$tmp"

if [[ $mode == dry ]]; then
    log "dry run: no upload"
    exit 0
fi

# --- upload --------------------------------------------------------------------
cred="${CREDENTIALS_DIRECTORY:-}/credentials"
[[ -n "${CREDENTIALS_DIRECTORY:-}" && -r "$cred" ]] || { log "no credentials (LoadCredential=credentials:...)"; exit 5; }
# Parsed, not sourced: the file must not be able to run code.
ak=$(sed -n 's/^AWS_ACCESS_KEY_ID=//p' "$cred" | tail -1)
sk=$(sed -n 's/^AWS_SECRET_ACCESS_KEY=//p' "$cred" | tail -1)
[[ -n "$ak" && -n "$sk" ]] || { log "credentials file lacks AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY"; exit 5; }

# The key goes to curl on stdin as a config line, so it is never in argv (ps) or the log.
code=$(printf 'user = "%s:%s"\n' "$ak" "$sk" |
       curl -sS --connect-timeout 10 -m 60 -K - --aws-sigv4 "aws:amz:us-east-1:s3" \
            -T "$tmp" -H 'Content-Type: application/rss+xml' -o /dev/null -w '%{http_code}' "$TARGET_URL") \
    || { log "upload failed (curl exit $?)"; exit 4; }
unset ak sk
if [[ "$code" != 200 ]]; then
    log "upload got HTTP $code from the bucket"
    exit 4
fi
log "uploaded to $TARGET_URL"
