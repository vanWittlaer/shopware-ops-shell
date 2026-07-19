FROM cgr.dev/chainguard/wolfi-base:latest

# shopware-cli provides `project dump` (a native Go dumper — no mysqldump needed);
# rclone drives every S3 transfer; bash runs the scripts and splits DATABASE_URL. The
# Shopware base image ships none of these, which is why this sidecar exists.
COPY --from=shopware/shopware-cli:bin-0.16.7 /shopware-cli /usr/local/bin/shopware-cli

RUN apk add --no-cache \
    bash \
    libstdc++ \
    rclone

COPY bin/ /var/www/html/bin/
RUN chmod +x /var/www/html/bin/*.sh
WORKDIR /var/www/html

# Idle so a scheduler (Coolify Scheduled Tasks, `docker exec`, cron, …) can exec the
# backup scripts into a long-running container.
CMD ["tail", "-f", "/dev/null"]
