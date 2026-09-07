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
exit $rc
