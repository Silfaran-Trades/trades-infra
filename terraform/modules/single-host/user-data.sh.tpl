#!/bin/bash
# Cloud-init user-data — host bootstrap, rebuild-not-repair (IA-009, IA-011; BR-12, BR-39).
#
# Derived from: ai-standards/templates/terraform/aws/modules/single-host/user-data.sh.tpl.template
# Adaptations (spec § Host "User-data"; the KHA lessons of BR-39 checked):
#   (a) a ${swap_gb} GiB swapfile + vm.swappiness=10 — absorbs ClamAV's signature
#       reload spike on the t4g.medium (BR-11); sustained swap or OOM kills are
#       the graduation signal
#   (b) `age` (dump encryption), NO PostgreSQL client — every SQL runs through
#       the postgres container
#   (c) the /srv/trades layout: deploy, secrets (700), backups, log-archive
#   (d) the ECR credential helper for the deploy user (KHA lesson: the IAM grant
#       alone fails with "no basic auth credentials")
#   (e) fetch-secrets.sh exports AWS_PAGER="" and writes through `cat` (KHA
#       lesson: the snap AWS CLI under the SSM agent wrote 0 bytes to a redirect)
#   (f) THREE cron files under /etc/cron.d/: the nightly backup, the 14-day
#       log-archive prune, the 10-minute host sentinel (a cron that lives only
#       in a runbook is pet state — scheduled-jobs.md anti-patterns)
#   (g) two tiny helper scripts for the sentinel (its NOTIFY_CMD publishes to
#       the host-alerts topic; its DLQ_DEPTH_CMD reads the failed queue) — files
#       instead of inline cron commands, so no quoting rides a cron line
#
# Rendered by templatefile() in main.tf — ${project}/${environment}/${region}/
# ${registry_host}/${host_alerts_topic_arn}/${swap_gb} are Terraform template
# variables, NOT shell variables. A shell dollar-brace is escaped as a doubled dollar before the brace; a bare `$VAR` or `$(` is left as is - templatefile interpolates only dollar-brace, and `$$` is NOT an escape (it reaches the host literally).
#
# HARD RULE: no secrets in this file — user-data is readable from the instance
# metadata surface. Secrets are fetched at deploy time from the parameter store
# via the instance profile (fetch-secrets.sh below), landing in the chmod-600
# env files that deployment.md § "Secrets in production" governs.
#
# An edit here plans as an in-place stop/modify/start and never re-runs
# cloud-init on the live host (modules/single-host/main.tf); RUNBOOK.md says so.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
# Distro packages, deliberately not a curl|sh installer. `age` encrypts the
# nightly DB dumps (deploy/backup-postgres.sh). No postgresql-client (adaptation b).
apt-get install -y docker.io docker-compose-v2 git unzip age

systemctl enable --now docker

# Adaptation (a): the swapfile — a spike buffer, not a habit (low swappiness).
if [ ! -f /swapfile ]; then
  fallocate -l ${swap_gb}G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
sysctl -p /etc/sysctl.d/99-swap.conf

# Deploy user owns /srv/${project} (the ONLY repo content on the host is the
# synced deploy/ directory — services arrive as images; BR-26).
useradd --create-home --shell /bin/bash deploy || true
usermod -aG docker deploy

# Adaptation (c): the layout. secrets is 700; the rest 755 under the deploy user.
install -d -o deploy -g deploy /srv/${project}
install -d -o deploy -g deploy /srv/${project}/deploy
install -d -o deploy -g deploy -m 700 /srv/${project}/secrets
install -d -o deploy -g deploy /srv/${project}/backups
install -d -o deploy -g deploy /srv/${project}/log-archive

# AWS CLI for parameter-store reads, the S3 dump copy and the SNS alert, all
# through the instance profile (no keys, SC-012). Snap binaries live in
# /snap/bin — every cron file below puts it on PATH.
snap install aws-cli --classic || apt-get install -y awscli

# Adaptation (d): ECR pull auth. The instance profile GRANTS pull (the inline
# policy in main.tf), but docker only USES it through the credential helper —
# without this, `compose pull` fails with "no basic auth credentials".
# credHelpers is scoped to ONLY this project's registry host.
apt-get install -y amazon-ecr-credential-helper
install -d -o deploy -g deploy -m 700 /home/deploy/.docker
cat > /home/deploy/.docker/config.json <<DOCKERCFG
{ "credHelpers": { "${registry_host}": "ecr-login" } }
DOCKERCFG
chown deploy:deploy /home/deploy/.docker/config.json
chmod 600 /home/deploy/.docker/config.json

# --- Day-2 hygiene (IA-011) — the host must patch, prune, cap and back itself
# up from PROVISIONED config, or a rebuilt host silently loses whatever was
# hand-configured (the pet-state failure IA-009 forbids).

# (1) Unattended SECURITY upgrades — the image's OS-patch layer patches the
# containers; without this the host Ubuntu never patches after first boot.
# Automatic-Reboot stays at its default (false): a co-located database makes
# surprise reboots a data risk — kernel-update reboots are an operator act.
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTAUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APTAUTO

# (2) journald cap — Docker logs are already size-capped by the compose `local`
# driver; journald needs its own ceiling or system logs eat the root volume
# that co-locates Postgres.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/50-cap.conf <<'JOURNALD'
[Journal]
SystemMaxUse=500M
MaxRetentionSec=1month
JOURNALD
systemctl restart systemd-journald

# (3) Weekly image prune — deploy.sh prunes after each successful promotion; a
# weekly sweep covers quiet weeks. Rollback stays safe: ECR keeps the last 10
# SHA tags and deploy.sh re-pulls. (image prune only: never `system prune
# --volumes` — the database, the object store and the captured mail live in volumes.)
cat > /etc/systemd/system/docker-image-prune.service <<'PRUNESVC'
[Unit]
Description=Prune Docker images unused for 7+ days
[Service]
Type=oneshot
ExecStart=/usr/bin/docker image prune -af --filter until=168h
PRUNESVC
cat > /etc/systemd/system/docker-image-prune.timer <<'PRUNETMR'
[Unit]
Description=Weekly Docker image prune
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
PRUNETMR
systemctl enable --now docker-image-prune.timer

# Secrets fetcher — run after the host sync and before the first compose up;
# one env file per parameter under /${project}/${environment}/env/<service>
# (app, media, mercure, postgres, storage).
cat > /srv/${project}/fetch-secrets.sh <<'FETCH'
#!/bin/bash
set -euo pipefail
# Adaptation (e) — snap-packaged awscli under the SSM agent: NEVER redirect aws
# stdout straight to a file — it writes 0 bytes (EBADF on stdout flush at
# interpreter exit) with exit code 0: silent corruption. Pipe through `cat`
# instead, and keep the CLI pager off in automation.
export AWS_PAGER=""
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
PREFIX="/${project}/${environment}/env"
DEST="/srv/${project}/secrets"
aws ssm get-parameters-by-path --region "${region}" --path "$PREFIX" \
  --with-decryption --query 'Parameters[].Name' --output text | tr '\t' '\n' \
| while read -r name; do
  [ -n "$name" ] || continue
  svc="$(basename "$name")"
  aws ssm get-parameter --region "${region}" --name "$name" --with-decryption \
    --query 'Parameter.Value' --output text | cat > "$DEST/$svc.env"
  chmod 600 "$DEST/$svc.env"
  chown deploy:deploy "$DEST/$svc.env"
  echo "→ fetch-secrets: wrote $DEST/$svc.env"
done
FETCH
chmod 750 /srv/${project}/fetch-secrets.sh
chown deploy:deploy /srv/${project}/fetch-secrets.sh

# Adaptation (g): the sentinel's two commands as files (deploy/host-sentinel.sh
# reads the alert on stdin for NOTIFY_CMD and expects a bare integer from
# DLQ_DEPTH_CMD). The topic ARN is this project's own (modules/host-alarms).
cat > /srv/${project}/sentinel-notify.sh <<'NOTIFY'
#!/bin/bash
set -euo pipefail
export AWS_PAGER=""
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
aws sns publish --region "${region}" --topic-arn "${host_alerts_topic_arn}" \
  --subject "[${project} sentinel] host alert" --message "$(cat)" | cat >/dev/null
NOTIFY
cat > /srv/${project}/sentinel-dlq-depth.sh <<'DLQ'
#!/bin/bash
set -euo pipefail
# The app's Messenger table and its dead-letter queue (deploy/host-sentinel.sh header).
docker exec ${project}-prod-postgres-1 sh -c 'psql -U "$POSTGRES_USER" -d ${project}_app -tAc "SELECT count(*) FROM shared.messenger_messages WHERE queue_name = '"'"'failed'"'"'"'
DLQ
chmod 750 /srv/${project}/sentinel-notify.sh /srv/${project}/sentinel-dlq-depth.sh
chown deploy:deploy /srv/${project}/sentinel-notify.sh /srv/${project}/sentinel-dlq-depth.sh

# (4) Adaptation (f): the three schedules, PROVISIONED — never a hand-edited
# crontab a rebuilt host silently loses. The scripts arrive with the first host
# sync (scripts/sync-host-deploy.sh); until then cron logs a loud "No such file"
# — the correct failure direction. All three are UTC (the host clock is UTC).
#
# trades-backup: the nightly encrypted dump + its S3 copy (BR-28). BACKUPS_BUCKET
# is read by the script from /srv/${project}/deploy/.env (host state, never here).
cat > /etc/cron.d/${project}-backup <<'BACKUPCRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
15 3 * * * deploy /srv/${project}/deploy/backup-postgres.sh >> /var/log/${project}-backup.log 2>&1
BACKUPCRON
chmod 644 /etc/cron.d/${project}-backup
touch /var/log/${project}-backup.log
chown deploy:deploy /var/log/${project}-backup.log

# trades-log-archive: the 14-day prune of the pre-recreate log archive — in
# MINUTES (14 × 1440), the same expression deploy.sh and backup-postgres.sh use:
# `find -mtime +14` is a 15-day prune (RUNBOOK.md § "Log archive retention").
cat > /etc/cron.d/${project}-log-archive <<'ARCHIVECRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
15 3 * * * deploy find /srv/${project}/log-archive -maxdepth 1 -name '*.log.gz' -mmin +20160 -delete
ARCHIVECRON
chmod 644 /etc/cron.d/${project}-log-archive

# trades-sentinel: monitoring rung 2 every 10 minutes (DE-006, BR-30a).
cat > /etc/cron.d/${project}-sentinel <<'SENTINELCRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
NOTIFY_CMD=/srv/${project}/sentinel-notify.sh
DLQ_DEPTH_CMD=/srv/${project}/sentinel-dlq-depth.sh
*/10 * * * * deploy /srv/${project}/deploy/host-sentinel.sh >> /var/log/${project}-sentinel.log 2>&1
SENTINELCRON
chmod 644 /etc/cron.d/${project}-sentinel
touch /var/log/${project}-sentinel.log
chown deploy:deploy /var/log/${project}-sentinel.log

# The deploy/ directory is synced by scripts/sync-host-deploy.sh (BR-26) and
# deploy/.env is written by hand (RUNBOOK.md § "First deploy"); nothing
# project-specific is baked into the AMI or this script beyond the layout above.
