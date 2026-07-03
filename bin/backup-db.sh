#!/usr/bin/env bash

set -euo pipefail

#
# Database backup to S3 (e.g. Hetzner Object Storage).
#
# Dumps the database to a temporary local file, uploads it to the backup bucket
# under the "database" subfolder, then removes the local file. Old backups beyond
# DB_BACKUPS_TO_KEEP are pruned from the bucket automatically.
#
# All configuration is read straight from the container environment (injected by
# Coolify / docker `env_file`). Required environment variables:
#
#   DATABASE_URL                - Shopware DSN (mysql://user:pass@host:port/db)
#   S3_BACKUP_ACCESS_KEY_ID     - Backup bucket credentials
#   S3_BACKUP_SECRET_ACCESS_KEY
#   S3_BACKUP_REGION            - e.g. "fsn1"
#   S3_BACKUP_DOMAIN            - e.g. "https://fsn1.your-objectstorage.com"
#   S3_BACKUP_BUCKET            - Bucket name
#   S3_BACKUP_PATH              - Path prefix inside bucket (default: "")
#   DB_BACKUPS_TO_KEEP          - Number of backups to retain (default: 60)
#   APP_ENV                     - Used in the dump filename (default: "prod")
#

CWD="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Defaults
DB_BACKUPS_TO_KEEP="${DB_BACKUPS_TO_KEEP:-60}"
S3_BACKUP_PATH="${S3_BACKUP_PATH:-}"
S3_BACKUP_PATH="${S3_BACKUP_PATH%/}"
APP_ENV="${APP_ENV:-prod}"

# Validate required variables
for var in DATABASE_URL S3_BACKUP_ACCESS_KEY_ID S3_BACKUP_SECRET_ACCESS_KEY \
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

# Configure rclone remote via environment
export RCLONE_CONFIG_BACKUP_TYPE="s3"
export RCLONE_CONFIG_BACKUP_PROVIDER="Other"
export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="${S3_BACKUP_ACCESS_KEY_ID}"
export RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="${S3_BACKUP_SECRET_ACCESS_KEY}"
export RCLONE_CONFIG_BACKUP_REGION="${S3_BACKUP_REGION}"
export RCLONE_CONFIG_BACKUP_ENDPOINT="${S3_BACKUP_DOMAIN}"
export RCLONE_CONFIG_BACKUP_FORCE_PATH_STYLE="true"
export RCLONE_CONFIG_BACKUP_ACL="private"

# Build remote path: bucket/[path]/database
if [[ -n "${S3_BACKUP_PATH}" ]]; then
    REMOTE_DIR="${S3_BACKUP_BUCKET}/${S3_BACKUP_PATH}/database"
else
    REMOTE_DIR="${S3_BACKUP_BUCKET}/database"
fi

DATE=$(date +%Y%m%d_%H%M%S)
FILENAME="${APP_ENV}_${DATE}.sql.gz"
LOCAL_TMP="/tmp/${FILENAME}"

# Dump database to temporary local file
${CWD}/dump-db.sh "${LOCAL_TMP}"

# Upload to S3
echo "Uploading ${FILENAME} to s3://${REMOTE_DIR}/ ..."
rclone copyto "${LOCAL_TMP}" "backup:${REMOTE_DIR}/${FILENAME}" --log-level INFO

# Remove local temp file
rm -f "${LOCAL_TMP}"
echo "Local temp file removed."

# Prune old backups: list all .sql.gz files, sorted oldest first, remove excess
REMOTE_FILES=$(rclone lsf "backup:${REMOTE_DIR}/" --include "*.sql.gz" | sort)
BACKUP_COUNT=$(echo "${REMOTE_FILES}" | grep -c . || true)

if [ "${BACKUP_COUNT}" -gt "${DB_BACKUPS_TO_KEEP}" ]; then
    TO_DELETE=$((BACKUP_COUNT - DB_BACKUPS_TO_KEEP))
    echo "Pruning ${TO_DELETE} old backup(s) (keeping ${DB_BACKUPS_TO_KEEP})..."
    echo "${REMOTE_FILES}" | head -n "${TO_DELETE}" | while read -r file; do
        echo "  Deleting: ${file}"
        rclone deletefile "backup:${REMOTE_DIR}/${file}"
    done
fi

echo "Database backup completed: ${FILENAME}"
