#!/usr/bin/env bash
#
# Creates the system user, group and directory tree for each application,
# and grants nginx access to the application sockets.
#
# Idempotent: safe to re-run.
#
# Usage:  sudo ./provision-apps.sh

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${HERE}/../apps.manifest"

[[ -f $MANIFEST ]] || { echo "missing $MANIFEST" >&2; exit 1; }

# Everything below lives on the separate /data disk. Writing to the bare
# mountpoint on the root filesystem would appear to succeed and then vanish
# under the real disk at the next mount.
if ! mountpoint -q /data; then
    echo "/data is not mounted — run scripts/setup-data-disk.sh first" >&2
    exit 1
fi

install -d -m 0755 /data/apps /data/www

while read -r id type prefix listener user; do
    [[ $id == \#* || -z $id ]] && continue

    if [[ $type == static ]]; then
        echo "==> ${id}: static, document root only"
        install -d -m 0755 -o root -g root "/data/www/${id}"
        continue
    fi

    echo "==> ${id}: user ${user}"
    if ! getent group "$user" >/dev/null; then
        groupadd --system "$user"
    fi
    if ! id "$user" >/dev/null 2>&1; then
        useradd --system --gid "$user" --no-create-home \
                --home-dir "/data/apps/${id}" \
                --shell /usr/sbin/nologin "$user"
    fi

    # nginx must reach the application socket. Adding www-data to each
    # application's group keeps the applications isolated from each other;
    # running the applications AS www-data would not.
    usermod -aG "$user" www-data

    install -d -m 0755 -o root  -g root  "/data/apps/${id}"
    install -d -m 0755 -o "$user" -g "$user" "/data/apps/${id}/releases"
    install -d -m 0750 -o "$user" -g "$user" "/data/apps/${id}/shared"

    # Rails needs writable log/ and tmp/; the deploy script symlinks the
    # release's copies here so exactly one path needs ReadWritePaths=.
    if [[ $type == rails ]]; then
        install -d -m 0750 -o "$user" -g "$user" "/data/apps/${id}/shared/log"
        install -d -m 0750 -o "$user" -g "$user" "/data/apps/${id}/shared/tmp"
    fi

    # Secrets file. Created empty and locked down; populated by
    # provision-databases.sh and by hand for app-specific values.
    if [[ ! -f /data/apps/${id}/shared/env ]]; then
        install -m 0600 -o "$user" -g "$user" /dev/null "/data/apps/${id}/shared/env"
        echo "# ${id} — secrets and environment. Mode 0600." \
            > "/data/apps/${id}/shared/env"
        chown "$user:$user" "/data/apps/${id}/shared/env"
        chmod 0600 "/data/apps/${id}/shared/env"
    fi
done < "$MANIFEST"

install -d -m 0755 /data/www/landing

echo
echo "Reloading nginx so its new group memberships take effect."
systemctl restart nginx 2>/dev/null || true

echo "Done. Next: scripts/provision-databases.sh"
