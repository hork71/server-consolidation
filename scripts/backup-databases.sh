#!/usr/bin/env bash
#
# Nightly backup. With no user-uploaded files, the surface is small: every
# database, plus the configuration needed to rebuild the host.
#
# Install as a systemd timer or a root cron entry:
#   15 2 * * *  /data/consolidate/scripts/backup-databases.sh
#
# Usage:  sudo ./backup-databases.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

# Account switching goes through runuser, never `sudo -u` or `su`.
#
# pam_access (/etc/security/access.conf) governs logins on this host, and the
# postgres and application accounts are deliberately not listed there — so
# sudo and su are denied for them, even from root. runuser's PAM stack does
# not consult pam_access, which is precisely what it is for: switching user
# from root inside a script, with no login taking place.
as_postgres() { runuser -u postgres -- "$@"; }

DEST="${BACKUP_DEST:-/var/backups/consolidate}"
REMOTE="${BACKUP_REMOTE:-}"          # e.g. backup@backuphost:/backups/servername
KEEP_DAYS="${KEEP_DAYS:-14}"
STAMP="$(date +%Y%m%dT%H%M%S)"
OUT="${DEST}/${STAMP}"

install -d -m 0700 "$OUT"

echo "==> databases"
# Custom format (-Fc): compressed, and restorable selectively with pg_restore.
for db in $(as_postgres psql -qtAX \
            -c "SELECT datname FROM pg_database
                WHERE datistemplate = false AND datname <> 'postgres'"); do
    echo "    ${db}"
    # The redirect runs in this (root) shell, so the dump file is owned
    # by root in a 0700 directory rather than by postgres.
    as_postgres pg_dump -Fc "$db" > "${OUT}/${db}.dump"
done

echo "==> configuration"
tar -czf "${OUT}/config.tar.gz" \
    --ignore-failed-read \
    /etc/nginx \
    /etc/systemd/system/apps.target \
    /etc/systemd/system/*.service \
    /etc/postgresql \
    /etc/redis \
    /data/apps/*/shared/env \
    /var/lib/consolidate/versions.txt 2>/dev/null || true
chmod 0600 "${OUT}/config.tar.gz"   # contains the env files

echo "==> manifest"
{
    echo "created   $(date -Is)"
    echo "host      $(hostname -f)"
    echo "pg        $(as_postgres psql -qtAX -c 'SHOW server_version')"
    echo
    echo "releases in service:"
    for a in /data/apps/*/; do
        [[ -L ${a}current ]] || continue
        printf '  %-12s %s\n' "$(basename "$a")" \
               "$(basename "$(readlink -f "${a}current")")"
    done
} > "${OUT}/MANIFEST.txt"

echo "==> retention (${KEEP_DAYS} days)"
find "$DEST" -maxdepth 1 -type d -name '20*' -mtime "+${KEEP_DAYS}" \
     -exec rm -rf {} + 2>/dev/null || true

if [[ -n $REMOTE ]]; then
    echo "==> off-host copy to ${REMOTE}"
    # A backup that only exists on the host it protects is not a backup.
    rsync -a --delete "${DEST}/" "${REMOTE}/"
else
    cat >&2 <<'MSG'

WARNING: BACKUP_REMOTE is not set, so this backup exists only on the host it
is meant to protect. Set BACKUP_REMOTE to an off-host destination before
relying on this.
MSG
fi

echo "Done: ${OUT}"
