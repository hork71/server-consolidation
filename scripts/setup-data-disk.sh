#!/usr/bin/env bash
#
# Prepares /data — the separate disk holding the PostgreSQL cluster and the
# Flask, Node, Rails and static application trees.
#
# Run AFTER host-baseline.sh and BEFORE provision-apps.sh.
#
# Usage:  sudo ./setup-data-disk.sh [--recreate-cluster]
#
# --recreate-cluster drops the default PostgreSQL cluster on /var and builds a
# new one on /data. That is DESTRUCTIVE and is only correct on a fresh host,
# before any data has been loaded. It asks for confirmation.

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

PGVER="${PGVER:-16}"
DATA=/data
PGDATA="${DATA}/postgresql/${PGVER}/main"

# Must match the source databases. A cluster initialised with a different
# collation sorts text differently, which changes index ordering and query
# results after a restore — silently, and in ways that are painful to trace.
# Check the old servers first:
#     psql -c "SHOW lc_collate" -c "SHOW server_encoding"
PG_ENCODING="${PG_ENCODING:-UTF8}"
PG_LOCALE="${PG_LOCALE:-en_US.UTF-8}"

RECREATE=0
[[ ${1:-} == --recreate-cluster ]] && RECREATE=1

# ---------------------------------------------------------------- checks ---
echo "==> Checking ${DATA}"

if ! mountpoint -q "$DATA"; then
    cat >&2 <<MSG
${DATA} is not a mountpoint.

Mount the disk before running this. Add it to /etc/fstab so it comes back
after a reboot — the systemd units all declare RequiresMountsFor=/data and
will refuse to start without it, which is the intended behaviour.

Suggested fstab entry (adjust the UUID and filesystem):

  UUID=xxxx-xxxx  /data  ext4  defaults,nodev,nosuid,noatime  0  2

MSG
    exit 1
fi

echo "    mounted: $(findmnt -no SOURCE,FSTYPE,OPTIONS "$DATA")"

# noexec would break everything here: Python C extensions, Node native addons
# and Ruby native gems are all shared objects mapped with PROT_EXEC, and that
# fails on a noexec mount. The failure surfaces as an unrelated-looking import
# error at runtime, so check for it now.
if findmnt -no OPTIONS "$DATA" | tr ',' '\n' | grep -qx noexec; then
    cat >&2 <<'MSG'

ERROR: /data is mounted noexec.

Virtualenv binaries, Node native addons and Ruby native extensions are all
loaded with execute permission from this disk. noexec makes them fail at
import time with errors that do not obviously point at the mount options.

Remount without noexec (nodev and nosuid are fine to keep):

  mount -o remount,exec /data

and correct the entry in /etc/fstab.

MSG
    exit 1
fi

avail=$(df -BG --output=avail "$DATA" | tail -1 | tr -dc '0-9')
echo "    available: ${avail}G"
(( avail >= 20 )) || echo "    WARNING: less than 20G free" >&2

# ------------------------------------------------------------ directories ---
echo "==> Creating directory tree"
install -d -m 0755 "${DATA}/apps"
install -d -m 0755 "${DATA}/www"
install -d -m 0755 "${DATA}/www/landing"
install -d -m 0750 -o postgres -g postgres "${DATA}/postgresql"
echo "    ${DATA}/apps  ${DATA}/www  ${DATA}/postgresql"

# --------------------------------------------------------- pg relocation ---
current_pgdata=$(as_postgres psql -qtAX -c 'SHOW data_directory' 2>/dev/null || echo "")

if [[ $current_pgdata == "$PGDATA" ]]; then
    echo "==> PostgreSQL cluster already on ${PGDATA}"
    exit 0
fi

if [[ $RECREATE -eq 0 ]]; then
    cat <<MSG

==> PostgreSQL cluster is NOT on ${DATA}
    current data_directory: ${current_pgdata:-<not running>}

To move it, re-run with --recreate-cluster. On a fresh host that is the clean
option: it drops the packaged cluster and initialises a new one on ${DATA}
through pg_createcluster, so the packaging stays consistent.

If this host ALREADY holds data you care about, do not use that flag. Instead:

    systemctl stop postgresql
    rsync -aHAX /var/lib/postgresql/${PGVER}/main/ ${PGDATA}/
    # then set data_directory in /etc/postgresql/${PGVER}/main/postgresql.conf
    systemctl start postgresql

MSG
    exit 0
fi

echo
echo "==> --recreate-cluster: this DESTROYS the existing cluster on /var"
echo "    encoding=${PG_ENCODING}  locale=${PG_LOCALE}"
read -rp "    Type 'yes' to continue: " confirm
[[ $confirm == yes ]] || { echo "    aborted"; exit 1; }

# pg_dropcluster and pg_createcluster change uid directly rather than going
# through PAM, so pam_access does not apply to them and they run fine as root.
if pg_lsclusters -h | awk '{print $1,$2}' | grep -qx "${PGVER} main"; then
    pg_dropcluster "${PGVER}" main --stop
    echo "    dropped old cluster"
fi

pg_createcluster "${PGVER}" main \
    -d "$PGDATA" \
    --start \
    -- --encoding="$PG_ENCODING" --locale="$PG_LOCALE"

echo
echo "==> Verifying"
as_postgres psql -qtAX \
    -c 'SHOW data_directory' \
    -c 'SHOW server_encoding' \
    -c 'SHOW lc_collate'

cat <<'MSG'

Cluster is on /data. Next:

    scripts/provision-apps.sh
    scripts/install-configs.sh     (installs the conf.d drop-in and pg_hba)

install-configs.sh does NOT set data_directory — pg_createcluster records it
in postgresql.conf, and a second definition in conf.d would shadow it and make
the real location hard to find later.
MSG
