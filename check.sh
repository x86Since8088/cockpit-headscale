#!/bin/bash
# Syntax-check the plugin before installing. There is no build step for Cockpit
# plugins, so a stray paren ships straight to the browser and the panel renders
# blank with only a console error. gjs parses the file inside a never-called
# wrapper: parse errors surface, missing browser globals do not.
set -u
cd "$(dirname "$0")" || exit 1
rc=0
for f in *.js; do
    python3 -c "
import sys
src = open('$f').read()
open('/tmp/.syn-$f','w').write('function __never(cockpit, document, window){\n'+src+'\n}')
"
    if gjs /tmp/".syn-$f" 2>/tmp/.syn-err; then
        printf '  %-20s syntax OK\n' "$f"
    else
        printf '  %-20s SYNTAX ERROR\n' "$f"
        sed 's/^/      /' /tmp/.syn-err
        rc=1
    fi
    rm -f /tmp/".syn-$f" /tmp/.syn-err
done

# --- shell syntax, for the helpers and the two scripts ----------------------
for f in hs-admin hs-policy install.sh deploy.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/tmp/.syn-err; then
        printf '  %-20s syntax OK\n' "$f"
    else
        printf '  %-20s SYNTAX ERROR\n' "$f"; sed 's/^/      /' /tmp/.syn-err; rc=1
    fi
    rm -f /tmp/.syn-err
done

# --- the standing greps (DEPLOY-CONTRACT.md section 4.4) ---------------------
# Each must print nothing. They live here, in the thing a developer already
# runs, because the mistake they catch is made while editing.
check_grep() {
    label=$1; shift
    out=$("$@" 2>/dev/null) || true
    if [ -n "$out" ]; then
        printf '  %-20s FAIL\n' "$label"; printf '%s\n' "$out" | sed 's/^/      /'; rc=1
    else
        printf '  %-20s clean\n' "$label"
    fi
}

HELPERS="hs-admin hs-policy"
PAGEF="manifest.json index.html headscale.js headscale.css"

# 1. No shipped file ever names a source .env.
check_grep "grep 1 source/.env" grep -In -e 'source/\.env' -e '"\.env"' -e "'\.env'" -- $PAGEF $HELPERS

# 2. No helper resolves .env relative to itself. A deployed helper that could
#    look beside itself would read the dev checkout's test .env on a dev install.
check_grep "grep 2 self-relative" grep -In -e 'dirname.*\.env' -e '__file__.*\.env' -e 'BASH_SOURCE.*\.env' -- $HELPERS

# 3. Every helper that reads config reads install.conf, or reads nothing.
for h in $HELPERS; do
    grep -qI 'CFG\[' "$h" 2>/dev/null || continue
    grep -qI 'install\.conf' "$h" || { printf '  %-20s FAIL: reads a config but never install.conf\n' "$h"; rc=1; }
done

# 9. No dev root and no retired path in anything shipped.
check_grep "grep 9 dev/retired" grep -In -e '/opt/sc/git' \
    -e '/srv/smb/share/sc/ai-orchestrator-group' \
    -- $PAGEF $HELPERS .envdefault etcdefaults/routing-policy.json \
       etcdefaults/acl-policy.hujson systemd/hs-policy-watch.service.in

# THE REGRESSION THIS PROJECT EXISTS TO CLOSE: every /usr/local/sbin helper the
# page names must be in install.sh's HELPERS array. hs-admin was installed on
# this host and named zero times by this installer.
for h in $(grep -oh '/usr/local/sbin/[A-Za-z0-9_-]*' $PAGEF 2>/dev/null | sed 's#.*/##' | sort -u); do
    if grep -q "^HELPERS=(.*\b$h\b" install.sh; then
        printf '  %-20s declared in HELPERS\n' "$h"
    else
        printf '  %-20s FAIL: the page calls it, install.sh does not install it\n' "$h"; rc=1
    fi
done

# The page must not read the deployed configuration ITSELF. Naming a .env key in
# a diagnosis is right and required - that is how an operator learns which key to
# set instead of watching the plugin vanish. Opening the file is a different
# thing: it is hs-admin's job, and a second parser in JavaScript is a second
# thing to keep in step with the grammar.
# Match an actual READ, not a mention: cockpit.file() on either config file.
# An earlier, blunter version of this check flagged the comment that explains
# the design and the diagnostic that tells the operator which key to set - both
# of which are the point, not the problem.
check_grep "page reads no config" grep -In \
    -e 'cockpit\.file([^)]*install\.conf' \
    -e 'cockpit\.file([^)]*\.env' \
    -e 'readFile([^)]*install\.conf' -- headscale.js

exit $rc
