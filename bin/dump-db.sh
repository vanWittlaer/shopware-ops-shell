#!/usr/bin/env bash
#
# Usage: bin/dump-db.sh <dump-file>
# Full database dump (no sanitization) via `shopware-cli project dump`.
#
# shopware-cli takes discrete --host/--port/--username/--password/--database flags and
# does NOT read DATABASE_URL (it silently falls back to 127.0.0.1), so we split the
# Shopware DSN ourselves. Pure bash — no php, no external tools.

set -euo pipefail

TARGET=${1:-dump.sql.gz}

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "ERROR: DATABASE_URL is not set." >&2
    exit 1
fi

# Decode %XX percent-escapes (Shopware percent-encodes reserved chars in user/pass).
# rawurldecode semantics: '+' stays a literal '+' (it is not a space in URL userinfo).
urldecode() { printf '%b' "${1//%/\\x}"; }

# Parse mysql://user:pass@host:port/dbname?params by splitting on the structural
# delimiters. Percent-encoding guarantees the real :/@/ separators are unambiguous.
dsn="${DATABASE_URL#*://}"       # drop scheme
userinfo="${dsn%%@*}"            # user[:pass]
hostinfo="${dsn#*@}"             # host[:port]/db[?params]

if [[ "$userinfo" == *:* ]]; then
    DB_USER="$(urldecode "${userinfo%%:*}")"
    DB_PWD="$(urldecode "${userinfo#*:}")"
else
    DB_USER="$(urldecode "$userinfo")"
    DB_PWD=""
fi

if [[ "$hostinfo" == */* ]]; then
    hostport="${hostinfo%%/*}"
    dbpath="${hostinfo#*/}"
    DATABASE="${dbpath%%\?*}"     # strip ?params
else
    hostport="$hostinfo"
    DATABASE=""
fi

DB_HOST="${hostport%%:*}"
if [[ "$hostport" == *:* ]]; then
    DB_PORT="${hostport##*:}"
else
    DB_PORT="3306"
fi

shopware-cli project dump \
    --skip-lock-tables \
    --database "$DATABASE" \
    --username "$DB_USER" \
    --password "$DB_PWD" \
    --host "$DB_HOST" \
    --port "$DB_PORT" \
    --output "${TARGET%.gz}" \
    --compression gzip
