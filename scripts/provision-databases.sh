#!/usr/bin/env bash
#
# Creates one PostgreSQL role and one database per application, generates a
# password for each, and writes DATABASE_URL into the application's env file.
#
# Idempotent: an existing role keeps its password unless --rotate is given.
#
# Usage:  sudo ./provision-databases.sh [--rotate] [app ...]
#
# With no app arguments, provisions every non-static application in the
# manifest. Remove any application that does not actually need a database —
# confirm which do before running this.

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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${HERE}/../apps.manifest"

ROTATE=0
if [[ ${1:-} == --rotate ]]; then ROTATE=1; shift; fi
TARGETS=("$@")

psql_q() { as_postgres psql -qtAX -c "$1"; }

# Alphanumeric only: the password goes into a URL, and this avoids every
# percent-encoding question.
gen_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

wanted() {
    [[ ${#TARGETS[@]} -eq 0 ]] && return 0
    local t; for t in "${TARGETS[@]}"; do [[ $t == "$1" ]] && return 0; done
    return 1
}

while read -r id type prefix listener user; do
    [[ $id == \#* || -z $id ]] && continue
    [[ $type == static ]] && continue
    wanted "$id" || continue

    db="${user}"
    role="${user}"

    echo "==> ${id}: role ${role}, database ${db}"

    exists=$(psql_q "SELECT 1 FROM pg_roles WHERE rolname = '${role}'")
    if [[ $exists == 1 && $ROTATE -eq 0 ]]; then
        echo "    role exists, password unchanged (use --rotate to replace)"
        continue
    fi

    password="$(gen_password)"

    if [[ $exists == 1 ]]; then
        psql_q "ALTER ROLE ${role} WITH LOGIN PASSWORD '${password}'" >/dev/null
        echo "    password rotated"
    else
        psql_q "CREATE ROLE ${role} WITH LOGIN PASSWORD '${password}'" >/dev/null
        echo "    role created"
    fi

    dbexists=$(psql_q "SELECT 1 FROM pg_database WHERE datname = '${db}'")
    if [[ $dbexists != 1 ]]; then
        as_postgres createdb -O "${role}" "${db}"
        echo "    database created"
    fi

    # No rights on anything beyond its own database.
    psql_q "REVOKE ALL ON DATABASE ${db} FROM PUBLIC" >/dev/null
    psql_q "GRANT CONNECT, TEMPORARY ON DATABASE ${db} TO ${role}" >/dev/null

    envfile="/data/apps/${id}/shared/env"
    url="postgresql://${role}:${password}@127.0.0.1:5432/${db}"

    touch "$envfile"
    # Replace an existing DATABASE_URL rather than appending a second one.
    if grep -q '^DATABASE_URL=' "$envfile"; then
        sed -i "s|^DATABASE_URL=.*|DATABASE_URL=${url}|" "$envfile"
    else
        echo "DATABASE_URL=${url}" >> "$envfile"
    fi
    chown "${user}:${user}" "$envfile"
    chmod 0600 "$envfile"
    echo "    DATABASE_URL written to ${envfile}"
done < "$MANIFEST"

echo
echo "Passwords exist only in the per-application env files (mode 0600)."
echo "They are not printed here and not stored anywhere else."
