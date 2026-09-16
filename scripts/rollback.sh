#!/usr/bin/env bash
#
# Points an application back at its previous release and restarts it.
# Takes seconds: the old release and its dependencies are still on disk.
#
# Usage:  sudo ./rollback.sh <app-id> [release-id]
#
# With no release-id, rolls back to the most recent release that is not the
# current one. List available releases with:
#
#   ls -1t /data/apps/<app>/releases

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ $# -ge 1 ]] || { sed -n '2,14p' "$0"; exit 1; }

APP=$1
ROOT="/data/apps/${APP}"
[[ -d $ROOT ]] || { echo "unknown app: $APP" >&2; exit 1; }

CURRENT="$(basename "$(readlink -f "${ROOT}/current")")"

if [[ ${2:-} ]]; then
    TARGET=$2
else
    TARGET="$(cd "${ROOT}/releases" && ls -1dt */ | sed 's#/##' \
              | grep -v "^${CURRENT}$" | head -1)"
fi

[[ -n ${TARGET:-} ]] || { echo "no previous release to roll back to" >&2; exit 1; }
[[ -d ${ROOT}/releases/${TARGET} ]] || { echo "no such release: $TARGET" >&2; exit 1; }

echo "==> ${APP}: ${CURRENT} -> ${TARGET}"
ln -sfn "${ROOT}/releases/${TARGET}" "${ROOT}/current"
systemctl restart "$APP"

sleep 2
if systemctl is-active --quiet "$APP"; then
    echo "    ${APP} active on release ${TARGET}"
else
    echo "    ${APP} still failing on ${TARGET} — investigate:" >&2
    echo "    journalctl -u ${APP} -n 50 --no-pager" >&2
    exit 1
fi
