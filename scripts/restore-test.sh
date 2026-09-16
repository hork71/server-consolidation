#!/usr/bin/env bash
#
# Restores one dump into a scratch database and reports what arrived.
# Run this BEFORE cutover, not after. An untested backup is an assumption.
#
# Usage:  sudo ./restore-test.sh <path/to/app.dump>

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
[[ $# -eq 1 ]] || { sed -n '2,8p' "$0"; exit 1; }

DUMP=$1
SCRATCH="restore_test_$(date +%s)"

[[ -f $DUMP ]] || { echo "no such dump: $DUMP" >&2; exit 1; }

cleanup() { as_postgres dropdb --if-exists "$SCRATCH"; }
trap cleanup EXIT

echo "==> restoring $(basename "$DUMP") into ${SCRATCH}"
as_postgres createdb "$SCRATCH"
# Fed on stdin rather than by path: the backup directory is 0700 and
# root-owned, so the postgres account cannot open the file itself.
as_postgres pg_restore -d "$SCRATCH" --no-owner --no-privileges < "$DUMP"

echo
echo "==> tables and row counts"
as_postgres psql -X "$SCRATCH" -c "
    SELECT schemaname, relname, n_live_tup AS approx_rows
    FROM pg_stat_user_tables
    ORDER BY n_live_tup DESC
    LIMIT 40;"

echo
echo "==> size"
as_postgres psql -qtAX -c \
    "SELECT pg_size_pretty(pg_database_size('${SCRATCH}'))"

echo
echo "Restore succeeded. Scratch database is being dropped."
