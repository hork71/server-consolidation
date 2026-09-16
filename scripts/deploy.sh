#!/usr/bin/env bash
#
# Deploys one application from a release tarball prepared on the build
# machine.
#
# Usage:  sudo ./deploy.sh <app-id> <release.tar.gz>
#
# The tarball must contain the application at its root, plus the offline
# dependency bundle for its runtime:
#
#   flask  →  wheelhouse/   (built with: pip wheel -r requirements.txt -w wheelhouse/)
#   rails  →  vendor/cache/ (built with: bundle cache --all --all-platforms)
#             public/assets/ precompiled on the build machine
#   node   →  node_modules/ (built with: npm ci --omit=dev)
#
# Everything must be built on Ubuntu 24.04 matching this host's architecture.
# Compiled extensions (psycopg2, pg, nokogiri, bcrypt) are ABI-specific and
# fail at import time on a mismatch — after the transfer, during the window.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

# Account switching goes through runuser, never `sudo -u` or `su`.
#
# pam_access (/etc/security/access.conf) governs logins on this host, and the
# application accounts are deliberately not listed there — so sudo and su are
# denied for them, even from root. runuser's PAM stack does not consult
# pam_access, which is precisely what it is for.
#
# Note `env`: runuser execs its argument directly, so a VAR=value prefix would
# be treated as a command name rather than an assignment.
as_app() { runuser -u "$user" -- "$@"; }
[[ $# -eq 2 ]] || { sed -n '2,25p' "$0"; exit 1; }

APP=$1
TARBALL=$2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${HERE}/../apps.manifest"

[[ -f $TARBALL ]] || { echo "no such tarball: $TARBALL" >&2; exit 1; }

# Everything below lives on the separate /data disk. Writing to the bare
# mountpoint on the root filesystem would appear to succeed and then vanish
# under the real disk at the next mount.
if ! mountpoint -q /data; then
    echo "/data is not mounted — run scripts/setup-data-disk.sh first" >&2
    exit 1
fi

read -r id type prefix listener user < <(awk -v a="$APP" '$1==a' "$MANIFEST") || true
[[ -n ${id:-} ]] || { echo "unknown app: $APP" >&2; exit 1; }

if [[ $type == static ]]; then
    echo "==> ${APP}: static — unpacking into /data/www/${APP}"
    tmp="$(mktemp -d)"
    tar -xzf "$TARBALL" -C "$tmp"
    rsync -a --delete "$tmp"/ "/data/www/${APP}/"
    rm -rf "$tmp"
    chown -R root:root "/data/www/${APP}"
    find "/data/www/${APP}" -type d -exec chmod 0755 {} +
    find "/data/www/${APP}" -type f -exec chmod 0644 {} +
    echo "    done (no service to restart)"
    exit 0
fi

REL="$(date +%Y%m%dT%H%M%S)"
ROOT="/data/apps/${APP}"
DIR="${ROOT}/releases/${REL}"

echo "==> ${APP}: unpacking release ${REL}"
install -d -m 0755 -o "$user" -g "$user" "$DIR"
tar -xzf "$TARBALL" -C "$DIR"
# Ownership must be correct BEFORE the per-runtime step: `bundle` runs as the
# application user and writes .bundle/config into the release directory.
chown -R "${user}:${user}" "$DIR"

case $type in
flask)
    [[ -d ${DIR}/wheelhouse ]] || { echo "tarball has no wheelhouse/" >&2; exit 1; }
    echo "==> building virtualenv from the offline wheelhouse"
    python3.12 -m venv "${DIR}/venv"
    "${DIR}/venv/bin/pip" install --quiet --upgrade pip
    "${DIR}/venv/bin/pip" install \
        --no-index --find-links="${DIR}/wheelhouse" \
        -r "${DIR}/requirements.txt"
    ;;
rails)
    [[ -d ${DIR}/vendor/cache ]] || { echo "tarball has no vendor/cache/" >&2; exit 1; }
    echo "==> installing gems from vendor/cache"
    # log/ and tmp/ must survive a rollback and must be the only writable
    # path the unit grants, so point them at shared/.
    rm -rf "${DIR}/log" "${DIR}/tmp"
    ln -sfn "${ROOT}/shared/log" "${DIR}/log"
    ln -sfn "${ROOT}/shared/tmp" "${DIR}/tmp"
    ( cd "$DIR"
      as_app env BUNDLE_GEMFILE="${DIR}/Gemfile" \
          bundle config set --local deployment true
      as_app env BUNDLE_GEMFILE="${DIR}/Gemfile" \
          bundle config set --local without 'development test'
      as_app env BUNDLE_GEMFILE="${DIR}/Gemfile" \
          bundle install --local )
    if [[ ! -d ${DIR}/public/assets ]]; then
        echo "WARNING: public/assets/ is missing. Assets must be precompiled" >&2
        echo "on the build machine — compiling here will fail without network." >&2
    fi
    ;;
node)
    [[ -d ${DIR}/node_modules ]] || { echo "tarball has no node_modules/" >&2; exit 1; }
    echo "==> node_modules shipped with the release, nothing to install"
    ;;
esac

# Again, because the venv was created as root.
chown -R "${user}:${user}" "$DIR"

echo "==> switching ${APP} to release ${REL}"
# -n matters: without it, if current/ already points at a directory the new
# link is created INSIDE the old target instead of replacing it.
ln -sfn "$DIR" "${ROOT}/current"

if [[ $type == flask ]]; then
    # HUP cycles gunicorn workers without dropping the listening socket.
    systemctl reload "$APP" 2>/dev/null || systemctl restart "$APP"
else
    systemctl restart "$APP"
fi

sleep 2
systemctl is-active --quiet "$APP" \
    && echo "    ${APP} active on release ${REL}" \
    || { echo "    ${APP} FAILED to start — rolling back" >&2
         "${HERE}/rollback.sh" "$APP"
         exit 1; }

echo "==> pruning old releases (keeping 3)"
( cd "${ROOT}/releases" && ls -1dt */ 2>/dev/null | tail -n +4 | xargs -r rm -rf )

echo "Done."
