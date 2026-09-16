# Consolidated application server — configuration

Configuration for migrating nine applications from two servers onto a single
Ubuntu 24.04 host, run as native systemd services behind nginx on an isolated
network. This implements Option B of the two reviewed plans.

Placeholder application IDs (`flask-1`, `node-2`, …) are used throughout.
Replace them with the real names before deploying — `apps.manifest` is the
single place that defines them, and the scripts read it.

## Storage

Two filesystems, with a clear split:

| Path | Disk | Holds |
|---|---|---|
| `/` | root | OS, packages, `/etc` configuration, journal |
| `/data` | separate | PostgreSQL cluster, all application releases, static sites |

```
/data/postgresql/16/main     PostgreSQL cluster
/data/apps/<app>/            releases/, current -> …, shared/env
/data/www/<app>/             the two static applications
/data/www/landing/           index page
```

Every unit declares `RequiresMountsFor=/data`, including drop-ins for the
packaged nginx and PostgreSQL units. If the disk is not mounted, nothing
starts — which is the behaviour you want. The alternative is nginx serving
404s and PostgreSQL refusing to start against an empty mountpoint, both of
which present as application faults rather than storage ones.

**Do not mount `/data` with `noexec`.** Virtualenv binaries, Node native
addons and Ruby native gems are shared objects mapped with execute
permission, and `noexec` makes them fail at import time with errors that do
not point at the mount options. `nodev` and `nosuid` are fine to keep.
`setup-data-disk.sh` checks for this and refuses to continue.

```
UUID=xxxx-xxxx  /data  ext4  defaults,nodev,nosuid,noatime  0  2
```

## Layout

```
apps.manifest              id, type, path prefix, listener, unix user
nginx/
  snippets/                proxy and TLS behaviour shared by every app
  sites-available/         the one public server block
  apps.d/                  one location block per application
systemd/                   one unit per application, plus apps.target
postgresql/                pg_hba.conf and a conf.d drop-in
redis/                     cache-only overrides for flask-4
scripts/                   provisioning, deployment, backup
www/landing/               index page listing the nine applications
```

## Install order

Run on the target host, as root, in this order:

| # | Command | What it does |
|---|---|---|
| 1 | `scripts/host-baseline.sh` | Packages, firewall, SSH, chrony, journald |
| 2 | `scripts/setup-data-disk.sh --recreate-cluster` | Checks `/data`, builds the PostgreSQL cluster there |
| 3 | `scripts/make-csr.sh` | Key + CSR for the enterprise CA |
| 4 | *(install the issued certificate)* | See the script's output — full chain required |
| 5 | `scripts/provision-apps.sh` | Users, groups, `/data` tree, nginx group access |
| 6 | `scripts/install-configs.sh` | Copies and validates all configuration |
| 7 | `scripts/provision-databases.sh` | Roles, databases, generated passwords |
| 8 | `scripts/deploy.sh <app> <tarball>` | Once per application, in migration order |

`--recreate-cluster` drops the packaged cluster on `/var` and rebuilds it on
`/data` via `pg_createcluster`, so the Debian packaging stays consistent. It
is destructive, asks for confirmation, and is only correct on a fresh host.

**Match the cluster's encoding and collation to the source databases** before
running step 2. A cluster initialised with a different collation sorts text
differently, which changes index ordering and query results after a restore —
silently, and in ways that are painful to trace. Check the old servers first:

```
psql -c "SHOW server_encoding" -c "SHOW lc_collate"
```

then pass the matching values:

```
PG_ENCODING=UTF8 PG_LOCALE=en_US.UTF-8 \
  scripts/setup-data-disk.sh --recreate-cluster
```

Nothing is enabled until you enable it. Migrate one application at a time:

```
systemctl enable --now flask-1
journalctl -u flask-1 -f
```

Once all nine are running: `systemctl enable apps.target`.

`host-baseline.sh` fails early and loudly if apt cannot reach SUSE Manager.
That check is deliberate — Debian-family channel sync is often missing on
SUSE Manager installations that mostly manage SUSE clients, and finding out
at step 1 is much cheaper than finding out at step 7.

## Release tarballs

Built on the build machine (Ubuntu 24.04, same architecture as the target).
Each tarball holds the application at its root plus its offline dependency
bundle:

```
flask   pip wheel -r requirements.txt -w wheelhouse/
rails   bundle cache --all --all-platforms
        RAILS_ENV=production bundle exec rails assets:precompile
node    npm ci --omit=dev          # ship the whole node_modules/ tree
```

Compiled extensions — `psycopg2`, `pg`, `nokogiri`, `bcrypt` — are built
against a specific ABI and architecture. A build machine that drifts ahead of
the target produces bundles that fail at import time on the target, after the
transfer and inside the maintenance window. Keep it matching.

**Archive every bundle that reaches production**, alongside its release. On an
isolated network you cannot re-resolve dependencies on demand, so the archived
bundle is your only route back to a known-good build. A lockfile is not enough
when nothing can be fetched.

## Per-application env files

`/data/apps/<app>/shared/env`, mode 0600, owned by the application user. Not
under `releases/`, so deploys never touch them and a rollback never reverts
them. `provision-databases.sh` writes `DATABASE_URL`; everything else is
added by hand.

```
# every app
DATABASE_URL=postgresql://...        # written by provision-databases.sh

# flask-4 only
REDIS_URL=redis://127.0.0.1:6379/0

# rails only
SECRET_KEY_BASE=...                  # COPY FROM THE OLD SERVER — a new value
                                     # invalidates every existing session
```

## Changes required in the applications

The configuration assumes these. None are optional.

**Path prefix.** Each app must know its own mount point. The units set
`SCRIPT_NAME` (Flask), `RAILS_RELATIVE_URL_ROOT` (Rails) and `BASE_PATH`
(Node). Flask and Rails usually need no code change; Node needs the router
mounted at `process.env.BASE_PATH`, and the static apps need
`<base href="/static-a/">` or the build tool's base option.

**Cookie paths.** All nine applications now share one origin and therefore one
cookie namespace. Two apps both issuing a `session` cookie at `Path=/` will
overwrite each other and produce intermittent logout bugs that are very hard
to trace back to their cause.

```
Flask    SESSION_COOKIE_PATH = '/flask-1'
         SESSION_COOKIE_SECURE = True
         SESSION_COOKIE_SAMESITE = 'Lax'
Rails    config.session_store :cookie_store, key: '_rails_session',
                              path: '/rails', secure: true
Express  cookie: { path: '/node-1', secure: true, sameSite: 'lax' }
Static   prefix localStorage / sessionStorage keys per app
```

**No external references.** Run `scripts/audit-external-urls.sh` against every
source tree on the build machine and resolve every hit. On an isolated network
a CDN link does not fail cleanly — it hangs until timeout, so the page loads
slowly and half-broken and the symptom does not point at the cause. The two
static applications are the likeliest offenders.

## Operations

```
systemctl status apps.target             # all nine at a glance
journalctl -u flask-1 -f                 # one application's logs
systemctl reload flask-1                 # gunicorn: cycle workers, no downtime
systemctl restart rails
systemctl stop apps.target               # everything, for maintenance
systemd-cgtop                            # live resource use per unit
systemd-analyze security flask-1.service # grade one unit's sandboxing

runuser -u postgres -- psql            # database shell (sudo -u will NOT work)
runuser -u postgres -- psql flask1

scripts/deploy.sh flask-1 flask-1-20260912.tar.gz
scripts/rollback.sh flask-1              # symlink flip, seconds
scripts/backup-databases.sh              # set BACKUP_REMOTE first
scripts/restore-test.sh /var/backups/consolidate/…/flask1.dump
```

`deploy.sh` rolls back automatically if the unit fails to come up.

## Notes on specific choices

**Unix sockets for Flask and Rails, TCP for Node.** Gunicorn and Puma support
sockets natively: no port to allocate and nothing bindable from the network by
accident. Socket support in Node web frameworks is more variable, and the
benefit does not justify fighting the application.

**`proxy_pass` without a trailing slash.** This is what forwards the path
prefix through to the application. A trailing slash — or a slash after the
socket's colon — strips it, and every URL the application generates then
points one level too high. The comment at the top of each `apps.d` file
repeats this, because it is the single easiest thing to break here.

**`Type=notify` for Flask, `Type=simple` for Rails and Node.** Gunicorn
implements `sd_notify`; Puma needs a plugin and plain Node does not implement
it at all. A unit claiming `notify` support that never signals readiness hangs
until timeout on every start.

**`MemoryDenyWriteExecute` is off for Rails and Node.** V8 and some Ruby
native extensions need writable-executable memory. It is on for Flask.

**Resource limits are starting points**, sized for a 16 GB host: Flask 768 MB
each, Rails 1.5 GB, Node 512 MB each, PostgreSQL `shared_buffers` 2 GB. Tune
from `systemd-cgtop` after a few weeks. The limits matter more than the totals
— they are what stops one leaking application from taking the host down.

**Account switching uses `runuser`, never `sudo -u` or `su`.** Logins on this
host are governed by `pam_access` (`/etc/security/access.conf`), and the
`postgres` and application accounts are deliberately absent from it. That
makes `sudo -u postgres psql` and `su - postgres` fail, *even from root* —
`pam_access` sits in the account stack those services consult. `runuser` has
a minimal PAM configuration that does not include `pam_access`, which is
exactly its purpose: switching user from root in a script, with no login
taking place. Every script uses an `as_postgres` / `as_app` helper so there is
one place to change if that policy ever moves.

Two consequences worth knowing:

- **Do not add cron jobs for these accounts.** Debian's `/etc/pam.d/cron`
  pulls in `common-account`, so a cron job for an account excluded by
  `pam_access` fails silently with only a terse denial in the auth log. Use
  systemd timers, which do not go through PAM at all.
- **`runuser` execs its argument directly**, so a `VAR=value` prefix would be
  read as a command name. `deploy.sh` uses `env` for this, e.g.
  `as_app env BUNDLE_GEMFILE=… bundle install --local`.

The packaged PostgreSQL tools (`pg_createcluster`, `pg_ctlcluster`) change uid
directly rather than going through PAM, so they are unaffected.

**PostgreSQL's `data_directory` is not set in `conf.d`.** `pg_createcluster`
records it in the main `postgresql.conf`. A second definition in the drop-in
would shadow that and make the real location hard to find later.

**HSTS is commented out.** Certificate renewal is manual, and a cached
`max-age` turns a missed renewal into an outage no server-side change can
undo.

## Still open

- Real application names, to replace the placeholders in `apps.manifest`.
- Which applications actually need a database. `provision-databases.sh`
  currently creates one for all seven non-static apps — remove the ones that
  do not need it.
- Which PostgreSQL versions the source databases run, and whether any two
  applications share one today.
- Whether `flask-4` keeps sessions in Redis as well as cache. If it does, a
  Redis restart logs every user out and `save ""` needs reconsidering.
- Confirmation that the apps run on the repository runtimes: Python 3.12,
  Ruby 3.2, Node 18.19. Node 18.19 is end-of-life and receives no upstream
  security patches — accepted for an isolated network, recorded here as a
  decision rather than an oversight.
