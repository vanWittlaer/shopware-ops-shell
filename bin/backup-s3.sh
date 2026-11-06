#!/usr/bin/env bash

set -euo pipefail

#
# Mirror public and private S3 buckets to a backup bucket at a different location.
#
# Protection against accidental deletions:
#   - Files removed or overwritten in the source are NOT immediately deleted from the backup.
#     Instead they are moved to a timestamped "soft-delete" directory inside the backup bucket.
#   - Soft-delete directories older than S3_BACKUP_RETAIN_DAYS are pruned automatically.
#   - Additionally, enable Object Versioning on the backup bucket at the storage level for an
#     extra safety net.
#
# All configuration is read straight from the container environment (injected by Coolify /
# docker `env_file`). Required environment variables:
#
#   S3_ACCESS_KEY_ID          - Source bucket credentials (reused from Shopware config)
#   S3_SECRET_ACCESS_KEY
#   S3_REGION                 - Source region, e.g. "nbg1"
#   S3_DOMAIN                 - Source endpoint, e.g. "https://nbg1.your-objectstorage.com"
#   S3_BUCKET_PUBLIC          - Source public bucket name
#   S3_BUCKET_PRIVATE         - Source private bucket name
#   S3_SOURCE_PATH            - Path prefix inside the source buckets (default: "").
#                              Set this when a single bucket is shared across
#                              environments (e.g. "production" / "staging"): only
#                              <bucket>/<S3_SOURCE_PATH> is mirrored, not the whole bucket.
#
#   S3_BACKUP_ACCESS_KEY_ID     - Backup bucket credentials (can be same or different)
#   S3_BACKUP_SECRET_ACCESS_KEY
#   S3_BACKUP_REGION            - Backup region, e.g. "fsn1"
#   S3_BACKUP_DOMAIN            - Backup endpoint, e.g. "https://fsn1.your-objectstorage.com"
#   S3_BACKUP_BUCKET            - Backup bucket name
#   S3_BACKUP_PATH              - Path prefix inside bucket (default: "")
#
#   S3_BACKUP_RETAIN_DAYS       - Days to keep soft-deleted files (default: 30)
#

# Defaults
S3_BACKUP_RETAIN_DAYS="${S3_BACKUP_RETAIN_DAYS:-30}"
S3_BACKUP_PATH="${S3_BACKUP_PATH:-}"
S3_BACKUP_PATH="${S3_BACKUP_PATH%/}"
S3_SOURCE_PATH="${S3_SOURCE_PATH:-}"
S3_SOURCE_PATH="${S3_SOURCE_PATH#/}"
S3_SOURCE_PATH="${S3_SOURCE_PATH%/}"

# Throughput tuning for the throttled Hetzner NBG cluster.
# Hetzner has imposed temporary limits in NBG on upload speed AND the number of
# concurrent requests; exceeding them returns HTTP 503 (SlowDown), which trips
# retry backoff and makes the whole sync slower. Their guidance is "moderate
# parallel requests", not bursts — so we keep concurrency low and cap the
# request rate to stay *under* the limit, rather than hammering it.
#
# Dial these in by watching the log for "503"/"SlowDown":
#   - seeing them  -> lower S3_BACKUP_TPSLIMIT / S3_BACKUP_TRANSFERS
#   - log is clean but still slow -> raise them gradually
S3_BACKUP_TRANSFERS="${S3_BACKUP_TRANSFERS:-8}"
S3_BACKUP_CHECKERS="${S3_BACKUP_CHECKERS:-16}"
S3_BACKUP_TPSLIMIT="${S3_BACKUP_TPSLIMIT:-10}"
S3_BACKUP_UPLOAD_CONCURRENCY="${S3_BACKUP_UPLOAD_CONCURRENCY:-4}"

# Validate required variables
for var in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_REGION S3_DOMAIN \
           S3_BUCKET_PUBLIC S3_BUCKET_PRIVATE \
           S3_BACKUP_ACCESS_KEY_ID S3_BACKUP_SECRET_ACCESS_KEY \
           S3_BACKUP_REGION S3_BACKUP_DOMAIN S3_BACKUP_BUCKET; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required environment variable ${var} is not set." >&2
        exit 1
    fi
done

# Check rclone is available
if ! command -v rclone &>/dev/null; then
    echo "ERROR: rclone is not installed." >&2
    exit 1
fi

DATE=$(date +%Y%m%d_%H%M%S)

# Build remote base path
if [[ -n "${S3_BACKUP_PATH}" ]]; then
    REMOTE_BASE="${S3_BACKUP_BUCKET}/${S3_BACKUP_PATH}"
else
    REMOTE_BASE="${S3_BACKUP_BUCKET}"
fi

# Build rclone config on the fly (no config file needed)
SOURCE_REMOTE="source"
BACKUP_REMOTE="backup"

export RCLONE_CONFIG_SOURCE_TYPE="s3"
export RCLONE_CONFIG_SOURCE_PROVIDER="Other"
export RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}"
export RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_SOURCE_REGION="${S3_REGION}"
export RCLONE_CONFIG_SOURCE_ENDPOINT="${S3_DOMAIN}"
export RCLONE_CONFIG_SOURCE_FORCE_PATH_STYLE="true"
export RCLONE_CONFIG_SOURCE_ACL="private"

export RCLONE_CONFIG_BACKUP_TYPE="s3"
export RCLONE_CONFIG_BACKUP_PROVIDER="Other"
export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="${S3_BACKUP_ACCESS_KEY_ID}"
export RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="${S3_BACKUP_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_BACKUP_REGION="${S3_BACKUP_REGION}"
export RCLONE_CONFIG_BACKUP_ENDPOINT="${S3_BACKUP_DOMAIN}"
export RCLONE_CONFIG_BACKUP_FORCE_PATH_STYLE="true"
export RCLONE_CONFIG_BACKUP_ACL="private"

# Folder-marker objects in the source (keys ending in "/", created by some S3 UIs or
# clients) are listed by rclone as files with an empty name; reading them fails with a
# nameless "GetObject ... NoSuchKey" and aborts the sync. Only called after a failed
# sync, so the extra listing costs nothing on healthy runs.
report_source_markers() {
    local src_path="$1"
    local markers
    markers=$(rclone lsf "${SOURCE_REMOTE}:${src_path}/" -R --files-only --fast-list --format sp 2>/dev/null \
        | awk -F';' '$2 == "" || $2 ~ /\/$/' || true)

    if [[ -n "${markers}" ]]; then
        echo "ERROR: folder-marker objects found in ${src_path} (size;path, empty path = '${src_path}/' itself):" >&2
        echo "${markers}" | sed 's/^/  /' >&2
        echo "  Delete each one by exact key (ending in '/'); this removes only the marker object:" >&2
        local path
        while IFS=';' read -r _ path; do
            echo "  curl -s -o /dev/null -w '%{http_code}\\n' -X DELETE --aws-sigv4 \"aws:amz:\${S3_REGION}:s3\" --user \"\${S3_ACCESS_KEY_ID}:\${S3_SECRET_ACCESS_KEY}\" \"\${S3_DOMAIN}/${src_path}/${path}\"" >&2
        done <<< "${markers}"
    fi
}

sync_bucket() {
    local src_bucket="$1"
    local label="$2"

    # Scope the source read to a sub-path when a bucket is shared across
    # environments; otherwise mirror the whole bucket.
    local src_path="${src_bucket}"
    if [[ -n "${S3_SOURCE_PATH}" ]]; then
        src_path="${src_bucket}/${S3_SOURCE_PATH}"
    fi

    echo "=== Syncing ${label}: ${src_path} -> ${REMOTE_BASE}/${label} ==="

    if ! rclone sync \
        "${SOURCE_REMOTE}:${src_path}" \
        "${BACKUP_REMOTE}:${REMOTE_BASE}/${label}/current" \
        --backup-dir "${BACKUP_REMOTE}:${REMOTE_BASE}/${label}/_soft-deleted/${DATE}" \
        --transfers "${S3_BACKUP_TRANSFERS}" \
        --checkers "${S3_BACKUP_CHECKERS}" \
        --tpslimit "${S3_BACKUP_TPSLIMIT}" \
        --tpslimit-burst "${S3_BACKUP_TPSLIMIT}" \
        --checksum \
        --s3-upload-concurrency "${S3_BACKUP_UPLOAD_CONCURRENCY}" \
        --s3-upload-cutoff 100M \
        --s3-chunk-size 64M \
        --s3-no-check-bucket \
        --retries 5 \
        --low-level-retries 20 \
        --exclude "public/theme/**" \
        --exclude "public/sitemap/**" \
        --exclude "public/thumbnail/**" \
        --fast-list \
        --stats-one-line \
        --stats 30s \
        --log-level INFO; then
        report_source_markers "${src_path}"
        return 1
    fi

    echo "=== Done syncing ${label} ==="
}

cleanup_soft_deletes() {
    local label="$1"
    local cutoff_date
    local cutoff_epoch
    cutoff_epoch=$(( $(date +%s) - S3_BACKUP_RETAIN_DAYS * 86400 ))
    cutoff_date=$(date -d "@${cutoff_epoch}" +%Y%m%d)

    echo "=== Cleaning soft-deletes older than ${S3_BACKUP_RETAIN_DAYS} days in ${label} ==="

    rclone lsd "${BACKUP_REMOTE}:${REMOTE_BASE}/${label}/_soft-deleted/" 2>/dev/null | while read -r _ _ _ dirname; do
        dir_date="${dirname%%_*}"
        if [[ "${dir_date}" < "${cutoff_date}" ]]; then
            echo "  Removing old soft-delete: ${dirname}"
            rclone purge "${BACKUP_REMOTE}:${REMOTE_BASE}/${label}/_soft-deleted/${dirname}"
        fi
    done

    echo "=== Done cleaning ${label} ==="
}

echo "Starting S3 backup at ${DATE}"
echo "Source: ${S3_DOMAIN} (${S3_REGION})${S3_SOURCE_PATH:+ path=${S3_SOURCE_PATH}}"
echo "Backup: ${S3_BACKUP_DOMAIN} (${S3_BACKUP_REGION}) -> ${REMOTE_BASE}"
echo ""

# Sync both buckets
sync_bucket "${S3_BUCKET_PUBLIC}" "public"
sync_bucket "${S3_BUCKET_PRIVATE}" "private"

# Clean up old soft-deletes
cleanup_soft_deletes "public"
cleanup_soft_deletes "private"

echo ""
echo "S3 backup completed successfully at $(date +%Y%m%d_%H%M%S)"
