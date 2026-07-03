# shopware-ops-shell

A small, env-agnostic **ops/maintenance sidecar image for self-hosted Shopware 6**.

The official Shopware container image intentionally ships no shell, no `mysqldump`, and
no object-storage client — great for a lean web/worker runtime, awkward the moment you
need to run a backup or a one-off maintenance task. This image fills that gap: a tiny
[Wolfi](https://github.com/wolfi-dev) base with just enough tooling to dump the database
and mirror your media buckets offsite, plus the backup scripts themselves.

It is deliberately **application-agnostic**: it carries no Shopware source, reads all of
its configuration from the environment, and is designed to run *idle* so a scheduler
(Coolify Scheduled Tasks, `docker exec`, a cron container, …) can exec the scripts into
it on a schedule.

## What's in the image

| Tool | Why |
|---|---|
| `bash` | runs the scripts (the Shopware base image has none) and splits `DATABASE_URL` into connection parts |
| [`shopware-cli`](https://github.com/FriendsOfShopware/shopware-cli) | `project dump` — the database dump (a native Go dumper, so no `mysqldump` binary is needed) |
| [`rclone`](https://rclone.org/) | every S3 transfer (dump upload, bucket mirror, pruning) |

Base: `cgr.dev/chainguard/wolfi-base`. Entry point: `tail -f /dev/null` (idle). No PHP,
no `mysqldump` — the DSN is parsed in pure bash and `shopware-cli` dumps natively.

## Scripts

| Script | Does |
|---|---|
| `bin/backup-db.sh` | Dumps the DB (`shopware-cli project dump`) → uploads to the backup bucket under `database/` → prunes to `DB_BACKUPS_TO_KEEP`. |
| `bin/backup-s3.sh` | Mirrors the public + private media buckets to an offsite backup bucket, with timestamped **soft-deletes** (kept `S3_BACKUP_RETAIN_DAYS`) instead of hard deletes. |
| `bin/dump-db.sh` | Low-level DB dump helper used by `backup-db.sh` (also usable standalone: `dump-db.sh out.sql.gz`). |

All configuration is read **straight from the container environment** — no `.env` files,
no dotenv loader. Inject the variables however your platform does (Coolify service env,
docker `env_file`, `-e` flags, …).

### Environment variables

**Database backup** (`backup-db.sh`)

| Var | Required | Default | Notes |
|---|---|---|---|
| `DATABASE_URL` | ✓ | | Shopware DSN `mysql://user:pass@host:port/db` |
| `S3_BACKUP_ACCESS_KEY_ID` / `S3_BACKUP_SECRET_ACCESS_KEY` | ✓ | | Backup-bucket credentials |
| `S3_BACKUP_REGION` | ✓ | | e.g. `fsn1` |
| `S3_BACKUP_DOMAIN` | ✓ | | e.g. `https://fsn1.your-objectstorage.com` |
| `S3_BACKUP_BUCKET` | ✓ | | Backup bucket name |
| `S3_BACKUP_PATH` | | `""` | In-bucket prefix, e.g. `production` |
| `DB_BACKUPS_TO_KEEP` | | `60` | Retained dumps before pruning |
| `APP_ENV` | | `prod` | Used in the dump filename |

**S3 media mirror** (`backup-s3.sh`) — the above `S3_BACKUP_*` **plus** the source buckets:

| Var | Required | Default | Notes |
|---|---|---|---|
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | ✓ | | Source-bucket credentials (your Shopware S3 config) |
| `S3_REGION` | ✓ | | Source region, e.g. `nbg1` |
| `S3_DOMAIN` | ✓ | | Source endpoint |
| `S3_BUCKET_PUBLIC` / `S3_BUCKET_PRIVATE` | ✓ | | Source media buckets |
| `S3_BACKUP_RETAIN_DAYS` | | `30` | Days to keep soft-deleted files |
| `S3_BACKUP_TRANSFERS` / `S3_BACKUP_CHECKERS` / `S3_BACKUP_TPSLIMIT` / `S3_BACKUP_UPLOAD_CONCURRENCY` | | `8` / `16` / `10` / `4` | rclone throughput tuning (lower if you see `503 SlowDown`) |

> **Use a different location for the backup bucket** than the source buckets — the whole
> point is offsite. Optionally enable Object Versioning on it for a storage-level safety net.

## Usage

Run the image idle, then exec a script into it on a schedule.

**Coolify** — deploy the image as a service (it stays up on `tail -f /dev/null`), then add
two **Scheduled Tasks** pointing at it:

```
/var/www/html/bin/backup-db.sh    #  e.g.  0 2 * * *
/var/www/html/bin/backup-s3.sh    #  e.g. 30 2 * * *
```

**Plain docker**

```bash
docker run -d --name ops-shell --env-file backup.env ghcr.io/vanwittlaer/shopware-ops-shell:latest
docker exec ops-shell /var/www/html/bin/backup-db.sh
docker exec ops-shell /var/www/html/bin/backup-s3.sh
```

## Extending the image

Need your own maintenance tasks (a sanitized dump, a media re-import, an extra CLI)?
Use this image as a base and drop your scripts into `bin/` — they land next to the
built-in ones and are scheduled/exec'd exactly the same way. Add any extra tooling from
the Wolfi/Alpine package repos.

```dockerfile
# Pin a released tag rather than :latest for reproducible builds.
FROM ghcr.io/vanwittlaer/shopware-ops-shell:v1.0.0

# Your own scripts (they can source nothing but env vars, like the built-ins).
COPY bin/ /var/www/html/bin/
RUN chmod +x /var/www/html/bin/*.sh

# Optional: extra tooling. The base runs as root, so apk works directly.
RUN apk add --no-cache mariadb-client aws-cli

# Keep the idle entrypoint so a scheduler can exec your scripts in.
# (Inherited from the base — only set CMD if you need a different idle/entry behavior.)
```

Then schedule your script the same way, e.g. a Coolify Scheduled Task running
`/var/www/html/bin/my-task.sh`. Because everything reads its config from the container
environment, your scripts get the same `DATABASE_URL` / `S3_*` vars with no extra wiring.

## Image tags

Published to `ghcr.io/vanwittlaer/shopware-ops-shell`:

- `latest` — built from `main` on every push
- `<short-sha>` — every `main` build, immutable
- `vX.Y.Z` — cut from a git tag; **pin one of these in production** rather than `latest`

## License

MIT — see [LICENSE](LICENSE).
