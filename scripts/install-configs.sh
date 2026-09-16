#!/usr/bin/env bash
#
# Copies the nginx, systemd, PostgreSQL and Redis configuration from this
# repository onto the host, validating before anything is activated.
#
# Idempotent: safe to re-run. Originals are backed up once, on first run.
#
# Usage:  sudo ./install-configs.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
PGVER="${PGVER:-16}"
PGDIR="/etc/postgresql/${PGVER}/main"

backup_once() {
    local f=$1
    [[ -f $f && ! -f ${f}.orig ]] && cp -a "$f" "${f}.orig"
    return 0
}

echo "==> nginx"
install -d -m 0755 /etc/nginx/snippets /etc/nginx/apps.d /etc/nginx/sites-available
install -m 0644 "${REPO}"/nginx/snippets/*.conf        /etc/nginx/snippets/
install -m 0644 "${REPO}"/nginx/apps.d/*.conf          /etc/nginx/apps.d/
install -m 0644 "${REPO}"/nginx/sites-available/*.conf /etc/nginx/sites-available/

ln -sfn /etc/nginx/sites-available/servername.conf \
        /etc/nginx/sites-enabled/servername.conf
rm -f /etc/nginx/sites-enabled/default

# Validate before reloading. A bad config that is never loaded is harmless;
# one that is loaded takes all nine applications down.
if nginx -t; then
    systemctl reload nginx
    echo "    nginx reloaded"
else
    echo "    nginx config INVALID — not reloaded" >&2
    exit 1
fi

echo "==> systemd units"
install -m 0644 "${REPO}"/systemd/*.service "${REPO}"/systemd/apps.target \
        /etc/systemd/system/

# Drop-ins that make the packaged nginx and PostgreSQL units wait for /data.
for d in "${REPO}"/systemd/*.service.d; do
    [[ -d $d ]] || continue
    target="/etc/systemd/system/$(basename "$d")"
    install -d -m 0755 "$target"
    install -m 0644 "$d"/*.conf "$target/"
    echo "    drop-in: $(basename "$d")"
done

systemctl daemon-reload

for u in "${REPO}"/systemd/*.service; do
    name="$(basename "$u")"
    out="$(systemd-analyze verify "/etc/systemd/system/${name}" 2>&1 || true)"
    if [[ -z $out ]]; then
        echo "    ${name}: ok"
    else
        echo "    ${name}: warnings —"
        printf '%s\n' "$out" | sed 's/^/        /'
    fi
done

echo "==> PostgreSQL"
if [[ -d $PGDIR ]]; then
    install -d -m 0755 "${PGDIR}/conf.d"
    install -m 0644 -o postgres -g postgres \
        "${REPO}/postgresql/10-consolidate.conf" "${PGDIR}/conf.d/"
    backup_once "${PGDIR}/pg_hba.conf"
    install -m 0640 -o postgres -g postgres \
        "${REPO}/postgresql/pg_hba.conf" "${PGDIR}/pg_hba.conf"
    # Debian keeps config in /etc and data in /var, so `postgres -C` cannot
    # validate from the data directory. Restart and check readiness instead,
    # reverting pg_hba.conf if the server refuses to come back.
    if systemctl restart postgresql && pg_isready -q -h 127.0.0.1; then
        echo "    postgresql restarted and accepting connections"
    else
        echo "    postgresql failed to restart — reverting pg_hba.conf" >&2
        [[ -f ${PGDIR}/pg_hba.conf.orig ]] && \
            install -m 0640 -o postgres -g postgres \
                "${PGDIR}/pg_hba.conf.orig" "${PGDIR}/pg_hba.conf"
        systemctl restart postgresql || true
        journalctl -u postgresql -n 30 --no-pager >&2
        exit 1
    fi
else
    echo "    ${PGDIR} not found; is postgresql-${PGVER} installed?" >&2
    exit 1
fi

echo "==> Redis"
install -m 0640 -o redis -g redis "${REPO}/redis/consolidate.conf" /etc/redis/
backup_once /etc/redis/redis.conf
# The include must be last so these settings override the packaged defaults.
if ! grep -q '^include /etc/redis/consolidate.conf' /etc/redis/redis.conf; then
    printf '\n# consolidated host overrides — must remain the last line\ninclude /etc/redis/consolidate.conf\n' \
        >> /etc/redis/redis.conf
fi
systemctl restart redis-server
redis-cli ping

echo "==> Landing page"
install -d -m 0755 /data/www/landing
install -m 0644 "${REPO}/www/landing/index.html" /data/www/landing/

echo
echo "Configuration installed. Units are not enabled yet — do that per"
echo "application as you migrate it:"
echo
echo "    systemctl enable --now flask-1"
echo
echo "And once all nine are in place:  systemctl enable apps.target"
