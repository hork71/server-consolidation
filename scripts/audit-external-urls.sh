#!/usr/bin/env bash
#
# Finds outbound references in the application source trees.
#
# On an isolated network these do not fail cleanly — they hang until timeout,
# so pages load slowly and half-broken and the cause is not obvious from the
# symptom. The two static HTML/JavaScript applications are the likeliest
# offenders (CDN script tags, Google Fonts, a Bootstrap link).
#
# Run this against the source trees on the BUILD machine, before migrating.
# Resolve every hit: vendor the asset locally, or remove it.
#
# Usage:  ./audit-external-urls.sh <dir> [dir ...]

set -euo pipefail

[[ $# -ge 1 ]] || { sed -n '2,15p' "$0"; exit 1; }

EXCLUDE_DIRS=(.git node_modules vendor .bundle venv __pycache__ dist build coverage)
EX_ARGS=()
for d in "${EXCLUDE_DIRS[@]}"; do EX_ARGS+=(--exclude-dir="$d"); done

# Hosts that are local and therefore fine to reference. "unix:" covers
# nginx proxy_pass to a unix socket, which is not a network reference at all.
LOCAL_RE='(unix:|localhost|127\.0\.0\.1|0\.0\.0\.0|::1|example\.com|servername)'

total=0
for target in "$@"; do
    echo "════ ${target}"
    hits=$(grep -rInE "${EX_ARGS[@]}" \
              -e 'https?://[A-Za-z0-9]' \
              "$target" 2>/dev/null \
           | grep -vE "https?://${LOCAL_RE}" \
           | grep -vE '^\s*$' || true)

    if [[ -z $hits ]]; then
        echo "  no external references found"
    else
        n=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
        total=$(( total + n ))
        printf '%s\n' "$hits" | sed 's/^/  /'
        echo
        echo "  ── ${n} reference(s) to resolve"
    fi
    echo
done

echo "════ total: ${total} reference(s) across $# tree(s)"
if (( total > 0 )); then
    cat <<'MSG'

Each one needs a decision before migration:
  · asset (script, stylesheet, font, image)  → vendor it into the app
  · API call                                 → point at an internal endpoint,
                                                or remove the feature
  · analytics / error reporting              → remove it
  · comment or documentation string          → harmless, ignore
MSG
    exit 1
fi
