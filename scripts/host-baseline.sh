#!/usr/bin/env bash
#
# Host baseline for the consolidated application server.
# Ubuntu 24.04 LTS, registered as a SUSE Manager client with the Ubuntu
# 24.04 channels subscribed.
#
# Idempotent: safe to re-run.
#
# Usage:  sudo ./host-baseline.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

NTP_SERVER="${NTP_SERVER:-ntp.example.com}"

echo "==> Verifying repository access"
if ! apt-get update -qq; then
    cat >&2 <<'MSG'
apt-get update failed.

This host has no outbound internet, so package access depends entirely on
SUSE Manager. Check that:
  - the host is registered (salt-minion bootstrapped),
  - the Ubuntu 24.04 channels are synced on the SUSE Manager side, and
  - /etc/apt/sources.list points at the SUSE Manager host.

Debian-family channel sync is often not in place on installations that
predominantly manage SUSE clients. Confirm this before going further.
MSG
    exit 1
fi

echo "==> Installing packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    nginx \
    postgresql postgresql-client \
    redis-server \
    python3.12 python3.12-venv python3-pip \
    ruby3.2 ruby3.2-dev bundler \
    nodejs npm \
    build-essential libpq-dev libyaml-dev zlib1g-dev pkg-config \
    ufw chrony \
    rsync curl ca-certificates

echo "==> Recording installed versions"
mkdir -p /var/lib/consolidate
{
    echo "# captured $(date -Is)"
    for p in nginx postgresql redis-server python3.12 ruby3.2 nodejs; do
        printf '%-16s %s\n' "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo MISSING)"
    done
} > /var/lib/consolidate/versions.txt
cat /var/lib/consolidate/versions.txt

echo "==> Firewall"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp  comment 'ssh'
ufw allow 80/tcp  comment 'http redirect'
ufw allow 443/tcp comment 'https'
ufw --force enable
ufw status verbose

echo "==> SSH hardening"
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-consolidate.conf <<'SSHEOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
X11Forwarding no
MaxAuthTries 3
SSHEOF
sshd -t && systemctl reload ssh

echo "==> Time synchronisation"
# An isolated host drifts. Clock skew breaks certificate validation and makes
# log correlation across a migration unreliable.
install -d -m 0755 /etc/chrony/conf.d
cat > /etc/chrony/conf.d/10-consolidate.conf <<CHRONYEOF
server ${NTP_SERVER} iburst
CHRONYEOF
systemctl enable --now chrony
systemctl restart chrony

echo "==> Persistent journal"
install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-consolidate.conf <<'JEOF'
[Journal]
Storage=persistent
SystemMaxUse=2G
SystemKeepFree=2G
MaxRetentionSec=90day
Compress=yes
JEOF
systemctl restart systemd-journald

echo "==> Disabling automatic upgrades"
# Patching runs through SUSE Manager channels and actions. unattended-upgrades
# cannot reach the internet and would only produce recurring failures.
# This makes patching a scheduled human action — it needs a named owner.
systemctl disable --now unattended-upgrades 2>/dev/null || true

echo
echo "Baseline complete. Next: scripts/provision-apps.sh"
