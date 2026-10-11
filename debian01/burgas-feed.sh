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
# The S3 key may only PutObject - no HEAD/GET/list with it (those answer 403).
# It comes from systemd LoadCredential= ($CREDENTIALS_DIRECTORY/credentials, two
# lines AWS_ACCESS_KEY_ID=... / AWS_SECRET_ACCESS_KEY=...) and never reaches the
# log or the command line: curl reads it from stdin (-K -).
#
#   burgas-feed.sh               fetch, validate, upload
#   burgas-feed.sh --dry-run     fetch and validate, no upload, no credentials needed
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

log() { printf 'burgas-feed: %s\n' "$*" >&2; }

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

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

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
