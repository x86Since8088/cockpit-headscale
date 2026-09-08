#!/usr/bin/env bash
#
# install.sh - in-place install of cockpit-headscale, BY SYMLINK.
#
#   sudo ./install.sh                 install from wherever this script is
#   sudo ./install.sh --with-units    also render the systemd unit (dev only)
#   sudo ./install.sh --uninstall     remove the links and the units
#   sudo DESTDIR=/tmp/x ./install.sh  stage every destination under /tmp/x
#
# THE ONE IDEA
#   This script does not copy the payload. It links the payload's files into the
#   places Cockpit and the shell expect, FROM WHEREVER IT IS BEING RUN. Run it
#   from the dev checkout and the Cockpit page is a set of symlinks into the
#   checkout, so editing wgclient.js changes what the browser loads on the next
#   reload. Run the identical script from /opt/cockpit-headscale/payload and the
#   links point at a tree with no relationship to the share. The script is the
#   same; only where it is run from differs. Nothing below branches on which of
#   the two it is in order to decide WHAT to link - it branches only to RECORD
#   which it did, in /etc/cockpit-headscale/install.conf.
#
#   deploy.sh is the other half: it is the only thing that copies, it seeds the
#   .env, and it is the only thing that enables a unit.
#
# WHAT IT TOUCHES
#   /usr/share/cockpit/headscale/*        symlinks, one per PAGE entry
#   /usr/local/sbin/{hs-admin,hs-policy}  symlinks, one per HELPERS entry
#   the two policy files named by .env    seeded MISSING-ONLY, never clobbered
#   /etc/systemd/system/hs-policy-watch.service  rendered from systemd/*.in
#   /etc/cockpit-headscale/install.conf   what this run did, for the next reader
#
#   The --user mode the previous version had is gone. It installed into
#   ~/.local/share/cockpit, which cannot hold a /usr/local/sbin helper, so the
#   page it produced had no backend - the same defect this rewrite exists to
#   fix, in a different disguise. A dev install is now the way to get a
#   live-editing install: run this script from the checkout.
#
#   It never restarts cockpit.socket. Cockpit is live at https://localhost:9090
#   and rescans its package directory when a session starts; a page reload is
#   enough, a logout/login only for a changed menu entry.
#
# Normative reference: cockpit-secrets/source/docs/DEPLOY-CONTRACT.md.

set -Eeuo pipefail

# BEGIN-MANIFEST
# The ONE declaration. deploy.sh sources this exact block out of this file
# rather than restating it, because two lists that can disagree is the failure
# mode this whole gate exists to design out. See DEPLOY-CONTRACT.md section 7.1.
PROJECT=cockpit-headscale
PAGE_NAME=headscale

# -> /usr/share/cockpit/$PAGE_NAME/ , one symlink each, and the sweep below
#    removes anything in that directory that is not on this line.
PAGE=(manifest.json index.html headscale.js headscale.css)

# -> /usr/local/sbin/ , one symlink each.
#
# hs-admin    THE root entry point for this plugin, and the reason this array
#             exists. It was installed on this host by hand and referenced ZERO
#             times by this project's own installer, so a fresh clone produced a
#             page with nothing behind it. headscale.js now pins it in one
#             top-of-file constant (var HS_ADMIN = "/usr/local/sbin/hs-admin")
#             and asks it where headscale lives, which check 3 below can see.
#             Every headscale query needs root - the control socket sits in a
#             drwx------ root root directory - so there is no unprivileged path
#             that could substitute for it.
# hs-policy   the subnet-router reconciler. Operator-run (`hs-policy check`) and
#             run in a loop by hs-policy-watch.service.
#
# There is no hs-policy-watch executable: the watch unit runs hs-policy in a
# shell loop, so the loop is visible in the unit rather than hidden in a script.
# That is a deliberate difference from cockpit-wireguard, whose watcher has real
# work to do between ticks (tracking handshakes to attribute a repair).
HELPERS=(hs-admin hs-policy)

# -> /usr/local/lib/$PROJECT/ . Both helpers are single self-contained bash
#    scripts; there is no library root to install.
LIBS=()

# -> $UNITDIR, rendered from systemd/<name>.in with at-sign substitution.
UNITS=(hs-policy-watch.service)

# Seed data: <path under the payload>=<the .env KEY naming its destination>.
# Copied MISSING-ONLY - both are operator-edited content, and the ACL policy in
# particular decides which routes are auto-approved, so overwriting one on a
# re-install would silently change who can reach what.
#
# Naming the destination by .env key rather than by literal is what lets the ACL
# policy live inside the snap's writable area on this host (snap confinement
# means the daemon cannot read /etc) and somewhere else on a host that installed
# headscale from a tarball, with nothing to keep in step by hand.
SEEDS=(etcdefaults/routing-policy.json=HS_POLICY_FILE
       etcdefaults/acl-policy.hujson=HS_ACL_POLICY_FILE)

ENVDEFAULT=.envdefault

# Keys that must be present and non-empty in .env before anything is written.
# HEADSCALE_BIN and HEADSCALE_CONFIG are required, not optional with a fallback,
# because headscale is packaged by no distribution: there is no layout to fall
# back to, only a decision somebody made and has to record.
REQUIRED_ENV=(HEADSCALE_BIN HEADSCALE_CONFIG HS_POLICY_FILE HS_ACL_POLICY_FILE HS_POLICY_INTERVAL)

# Shipped by deploy.sh but neither linked nor swept.
EXTRA=(VERSION LICENSE README.md)

# Where rendered units go. Recorded in install.conf so an --uninstall run by a
# different version still finds them (DEPLOY-CONTRACT.md JC-11).
UNITDIR=/etc/systemd/system
# END-MANIFEST

# --------------------------------------------------------------- self-location

# readlink -f FIRST, then dirname. Without the readlink, an install.sh invoked
# through a symlink resolves its payload relative to the LINK's directory and
# links a tree that is not the one it was run from. This installer used to have
# that bug.
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SRC="$(cd -- "$(dirname -- "$SELF")" && pwd)"

# WHICH KIND OF INSTALL IS THIS? Decided by LAYOUT, never by a path prefix.
# Recorded and warned about only - never used to decide what gets linked.
#
# deploy.sh writes <install path>/payload-<version>/ and points a sibling
# `payload` symlink at it; swapping that symlink IS an upgrade or rollback, so
# this is a DEPLOYED payload exactly when our own directory is what that
# symlink resolves to. A checkout has no such symlink.
#
# This replaces an older `$SRC == $DEV_ROOT/*` test that named the share
# literally and got a checkout ANYWHERE ELSE wrong: it called itself
# `deployed`, skipping the group-writable warning, recording
# INSTALL_KIND=deployed for a host that was not self-sustaining, and dropping
# "the checkout is NOT touched" from --uninstall. Layout cannot drift when a
# tree moves, and it leaves no dev-root literal here - which is why check 9
# now scans this installer too, with no carve-out.
# NB: computed from $SRC, never from $ROOT - in some of these installers ROOT
# is derived FROM KIND, so reading it here would be a use-before-assignment
# that silently classified every deployed payload as `dev`.
# Two ways to be a deployed payload. The first is the normal one: the `payload`
# alias points at us. The second covers a PREVIOUS payload being run directly -
# a rollback done without swapping the alias first - which is still a deployed
# tree, not a checkout, and must not be told to go and create a test .env.
if [[ "$(readlink -f -- "$SRC/../payload" 2>/dev/null)" == "$SRC" ]] \
   || { [[ "${SRC##*/}" == payload-* ]] && [[ -L "$SRC/../payload" ]]; }
then KIND=deployed
else KIND=dev
fi

# The install path is the payload's parent, and the .env is its sibling. In a
# dev checkout that would put .env outside the repo, which is wrong: a dev .env
# is a test fixture and belongs beside the tests. So:
#   deployed  ->  /opt/cockpit-headscale/.env      (sibling of payload/)
#   dev       ->  <checkout>/.env                  (gitignored, TESTS ONLY)
# This is a RECORDING difference, per DEPLOY-CONTRACT.md section 3.2. It changes
# no link.
if [[ $KIND == deployed ]]; then
    ROOT="$(cd -- "$SRC/.." && pwd)"
    ENV_FILE="$ROOT/.env"
else
    ROOT="$SRC"
    ENV_FILE="$SRC/.env"
fi
ROOT_REAL="$(readlink -f -- "$ROOT")"

# Link through the stable `payload` alias when one exists and points at us. An
# upgrade is then a single rename of that symlink and every link on the host
# follows it atomically; a rollback needs no re-link at all, and no link can be
# left pointing into a payload-<old> that the next deploy deletes. When there is
# no such alias - every dev install, and a --install-to layout that keeps a plain
# payload/ - this is just $SRC.
LINK_SRC="$SRC"
if [[ -L "$ROOT/payload" && "$(readlink -f -- "$ROOT/payload")" == "$SRC" ]]; then
    LINK_SRC="$ROOT/payload"
fi

# The one allowed asymmetry (DEPLOY-CONTRACT.md JC-5), expressed ONCE: a payload
# keeps its executables in bin/, a dev checkout keeps them at the root. Units
# reference @BIN@ rather than a hardcoded bin/ so the same template renders
# correctly in both, and so nothing else in this script has to know.
if [[ -d "$SRC/bin" ]]; then BIN_DIR="$LINK_SRC/bin"; else BIN_DIR="$LINK_SRC"; fi

DESTDIR="${DESTDIR:-}"
PKGDIR="$DESTDIR/usr/share/cockpit/$PAGE_NAME"
SBINDIR="$DESTDIR/usr/local/sbin"
CONFDIR="$DESTDIR/etc/$PROJECT"
UNITDEST="$DESTDIR$UNITDIR"

WITH_UNITS=0
ACTION=install

# ------------------------------------------------------------------ utilities

say()  { printf '  %s\n' "$*"; }
warn() { printf 'install.sh: warning: %s\n' "$*" >&2; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# Print the whole leading comment block, whatever length it happens to be. A
# fixed line range is a comment that silently starts lying the moment somebody
# adds a paragraph - which both of these already had.
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SELF"; }

# Where a helper lives in this payload. DEPLOY-CONTRACT.md JC-5: the payload has
# bin/, a dev checkout keeps its helpers at the root, and this three-line
# function is the ONLY place the two layouts are allowed to differ.
helper_path() { if [[ -f "$SRC/bin/$1" ]]; then printf '%s/bin/%s\n' "$SRC" "$1"; else printf '%s/%s\n' "$SRC" "$1"; fi; }
helper_link_target() { if [[ -f "$SRC/bin/$1" ]]; then printf '%s/bin/%s\n' "$LINK_SRC" "$1"; else printf '%s/%s\n' "$LINK_SRC" "$1"; fi; }

# Remove one thing we installed. Never follows a symlink, never recurses.
remove_link() {
    local p=$1
    if [[ -L "$p" ]]; then
        rm -f -- "$p"
        say "unlinked $p"
    elif [[ -e "$p" ]]; then
        warn "$p is not a symlink - left in place, remove it by hand if you meant to"
    fi
}

# A rendered unit is a real file, not a link. Same containment discipline.
remove_file() {
    local p=$1
    if [[ -L "$p" ]]; then rm -f -- "$p"; say "unlinked $p"
    elif [[ -f "$p" ]]; then rm -f -- "$p"; say "removed $p"
    elif [[ -e "$p" ]]; then warn "$p is not a regular file - left in place"
    fi
}

# Remove a directory we created, ONLY if we emptied it.
remove_dir_if_empty() {
    local p=$1
    [[ -d "$p" && ! -L "$p" ]] || return 0
    rmdir -- "$p" 2>/dev/null && say "removed empty $p" \
        || say "kept $p (not empty - something else lives there)"
}

# There is NO rm -r anywhere in this script. Not with a trailing slash, not with
# a glob. `rm -rf "$PKGDIR"` - which this installer did until now - is correct
# only while $PKGDIR is a real directory, and the entire point of this rewrite is
# that /usr/share/cockpit/headscale is now full of links into a tree somebody
# cares about. One trailing slash is the whole distance between a routine
# uninstall and deleting the dev checkout. Removing the deployed payload is
# deploy.sh --remove, a different verb in a different script.

# 0 = we may replace it; nonzero = refuse and print why.
owned_by_us() {
    local link=$1 cur
    [[ -e "$link" || -L "$link" ]] || return 0
    [[ -L "$link" ]] || { warn "$link exists and is NOT a symlink"; return 1; }
    cur=$(readlink -f -- "$link") || return 1
    [[ "$cur" == "$SRC"/* || "$cur" == "$ROOT_REAL"/* ]] \
        || { warn "$link -> $cur, which is not under $ROOT_REAL"; return 1; }
    return 0
}

# The section 4.1 grammar, in bash. Prints KEY=VALUE lines; refuses anything the
# python and systemd parsers would read differently.
env_parse() {
    local file=$1 n=0 line k v
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        [[ "$line" == *=* ]] || die "$file:$n: not KEY=VALUE"
        k="${line%%=*}"; v="${line#*=}"
        k="${k%"${k##*[![:space:]]}"}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "$file:$n: bad key '$k'"
        if [[ ${#v} -ge 2 && "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then v="${v:1:-1}"; fi
        [[ "$v" == *'$'* || "$v" == *'`'* ]] \
            && die "$file:$n: $k contains \$ or \` - interpolation is not supported (DEPLOY-CONTRACT.md section 4.1)"
        printf '%s=%s\n' "$k" "$v"
    done < "$file"
}

env_value() { env_parse "$1" | awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/,""); v=$0} END {print v}'; }
env_keys()  { env_parse "$1" | cut -d= -f1 | sort -u; }

# ----------------------------------------------------------------------- args

while (($#)); do
    case "$1" in
        --uninstall)  ACTION=uninstall; shift ;;
        --with-units) WITH_UNITS=1; shift ;;
        --with-policy)
            # The old flag. Helpers are no longer opt-in - the page cannot work
            # without hs-admin - so all this ever meant was "render the unit".
            WITH_UNITS=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must be run as root (try: sudo $0)"

# =============================================================== uninstall ===

if [[ $ACTION == uninstall ]]; then
    echo "Uninstalling $PROJECT"
    say "payload: $SRC  ($KIND install)"

    # The sentence the operator needs in order to not panic.
    # Ask the LINK TARGET's layout, not this script's: an operator may be
    # running the deployed installer to tear down links a dev install made.
    t="$(readlink -f -- "$PKGDIR/index.html" 2>/dev/null || true)"
    if [[ -n "$t" && "$(readlink -f -- "${t%/*}/../payload" 2>/dev/null)" != "${t%/*}" ]]; then
        echo
        echo "  *** This is a DEV install. Only symlinks will be removed."
        echo "  *** The checkout at $SRC is NOT touched."
        echo
    fi

    for u in "${UNITS[@]}"; do
        if [[ -z "$DESTDIR" ]]; then
            systemctl stop    "$u" 2>/dev/null || true
            systemctl disable "$u" 2>/dev/null || true
        fi
        remove_file "$UNITDEST/$u"
    done
    if [[ -z "$DESTDIR" ]] && ((${#UNITS[@]})); then
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed  2>/dev/null || true
    fi

    for h in "${HELPERS[@]}"; do remove_link "$SBINDIR/$h"; done
    for f in "${PAGE[@]}";    do remove_link "$PKGDIR/$f";  done
    remove_dir_if_empty "$PKGDIR"

    remove_file "$CONFDIR/install.conf"
    remove_dir_if_empty "$CONFDIR"

    echo
    echo "Removed the software. DATA WAS LEFT ALONE, deliberately:"
    echo "  $ENV_FILE                      your settings"
    echo "  $(env_value "$ENV_FILE" HS_POLICY_FILE 2>/dev/null || echo /etc/headscale/routing-policy.json)   your subnet-router policy"
    echo "  $(env_value "$ENV_FILE" HS_ACL_POLICY_FILE 2>/dev/null || echo '<HS_ACL_POLICY_FILE>')   your ACL policy"
    echo "  headscale's own database, config and control socket - untouched throughout."
    echo "Removing those is a separate, deliberate action. cockpit.socket was not touched."
    exit 0
fi

# =============================================================== pre-flight ===
#
# Nine checks. Every one refuses. NOTHING is written until all of them pass.

echo "Installing $PROJECT"
say "from:  $SRC   ($KIND install)"
say "links: $LINK_SRC"
say "to:    $PKGDIR, $SBINDIR"
say "env:   $ENV_FILE"
echo
echo "Pre-flight"

# --- 1. payload present ------------------------------------------------------
missing=()
for f in "${PAGE[@]}";  do [[ -f "$SRC/$f" ]] || missing+=("$f"); done
for h in "${HELPERS[@]}"; do
    p="$(helper_path "$h")"
    [[ -f "$p" ]] || missing+=("$h (looked in $SRC/bin/ and $SRC/)")
    [[ -f "$p" && ! -x "$p" ]] && missing+=("$h (present but not executable)")
done
for l in "${LIBS[@]}";  do [[ -e "$SRC/$l" ]] || missing+=("$l"); done
for u in "${UNITS[@]}"; do
    [[ -f "$SRC/systemd/$u.in" || -f "$SRC/systemd/$u" ]] || missing+=("systemd/$u.in")
done
for s in "${SEEDS[@]}"; do [[ -f "$SRC/${s%%=*}" ]] || missing+=("${s%%=*}"); done
[[ -f "$SRC/$ENVDEFAULT" ]] || missing+=("$ENVDEFAULT")
((${#missing[@]} == 0)) || die "payload is incomplete:$(printf '\n    %s' "${missing[@]}")"
say "1. payload complete (${#PAGE[@]} page files, ${#HELPERS[@]} helpers, ${#UNITS[@]} unit)"

# --- 2. the page asks only for what is shipped -------------------------------
# Parsed, not grepped: a regex over HTML is how you miss the one attribute that
# is spelled differently. An unshipped reference is not a 404 - Cockpit answers
# with an HTML error page and the browser then refuses to execute it on a MIME
# mismatch, which is a permanent console error on every load.
command -v python3 >/dev/null 2>&1 || die "python3 is required for the pre-flight"
python3 - "$SRC/index.html" "${PAGE[@]}" <<'PY' || die "index.html references a file PAGE does not ship (above). Nothing was changed."
import html.parser, sys
path, ship = sys.argv[1], set(sys.argv[2:])
refs = []


class Refs(html.parser.HTMLParser):
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("script", "img", "iframe", "audio", "video", "source",
                   "embed", "track") and a.get("src"):
            refs.append((tag, a["src"]))
        elif tag == "link" and a.get("href"):
            refs.append((tag, a["href"]))
        elif tag == "object" and a.get("data"):
            refs.append((tag, a["data"]))


try:
    Refs().feed(open(path, encoding="utf-8").read())
except Exception as e:
    sys.exit("  index.html could not be parsed: %s" % type(e).__name__)

local, bad = [], []
for tag, raw in refs:
    u = raw.split("#")[0].split("?")[0].strip()
    if not u:
        continue
    low = u.lower()
    # A scheme, an authority, an absolute path or a parent segment names
    # something outside this package directory. ../base1/cockpit.js is
    # Cockpit's own file and is deliberately not ours to install.
    if "://" in low or low.startswith(("//", "/", "data:", "mailto:", "../")):
        continue
    if "/" in u:
        bad.append("%s (<%s>: the Cockpit payload is flat)" % (u, tag))
        continue
    local.append(u)
    if u not in ship:
        bad.append("%s (<%s>)" % (u, tag))

if bad:
    sys.exit("  index.html references %s, which install.sh's PAGE array does not\n"
             "  ship - so the stale-file sweep DELETES it on every run and Cockpit\n"
             "  answers the browser with an HTML error page. Add it to PAGE, or make\n"
             "  the page stop asking for it." % ", ".join(sorted(set(bad))))
print("  2. index.html: %d package-local reference(s), all shipped (%s)"
      % (len(local), ", ".join(local)))
PY

# --- 3. every helper the page names is shipped and will be linked ------------
# THE CATCH THIS GATE EXISTS FOR. hs-admin was installed on this host by hand and
# named ZERO times by this project's installer; headscale.js now pins it in one
# top-of-file constant, which is what makes it visible here.
# Comments count: bias to declaring. A false positive costs one word in an array;
# a false negative ships a UI with no backend.
named=$(grep -oh '/usr/local/sbin/[A-Za-z0-9_-]\+' "${PAGE[@]/#/$SRC/}" 2>/dev/null | sed 's#.*/##' | sort -u || true)
for h in $named; do
    printf '%s\n' "${HELPERS[@]}" | grep -qx -- "$h" \
        || die "the page calls /usr/local/sbin/$h, which HELPERS does not install.
    Add it to HELPERS, or stop the page calling it."
done
say "3. every helper the page names is declared ($(echo "$named" | tr '\n' ' '))"

# --- 4. a declared helper nothing calls is fine ------------------------------
# hs-policy is run by an operator (`hs-policy check`) and by the watch unit, not
# by the page. Under-declaring is the bug; over-declaring is not, so this check
# reports and does not refuse.
undeclared=""
for h in "${HELPERS[@]}"; do
    printf '%s\n' $named | grep -qx -- "$h" || undeclared+=" $h"
done
[[ -z "$undeclared" ]] || say "4. declared but not named by the page (fine):$undeclared"

# --- 5. every unit renders clean ---------------------------------------------
# Deferred to render_unit(), which refuses on a surviving placeholder. What is
# checked here is the half that must be true before anything is written: the
# ExecStart the template will produce names a file this payload actually ships.
realbin="$( [[ -d "$SRC/bin" ]] && echo "$SRC/bin" || echo "$SRC" )"
for u in "${UNITS[@]}"; do
    tin="$SRC/systemd/$u.in"; [[ -f "$tin" ]] || tin="$SRC/systemd/$u"
    # Every payload-local executable the unit names, wherever it appears. The
    # first word after ExecStart= is not enough here: this unit's ExecStart is
    # /bin/sh -c '...', and the thing that must exist is inside the quotes.
    while read -r ref; do
        ref="${ref//@BIN@/$realbin}"
        ref="${ref//@PAYLOAD@/$SRC}"
        [[ -x "$ref" ]] || die "$u: names $ref, which this payload does not ship"
    done < <(grep -o '@BIN@/[A-Za-z0-9_.-]\+\|@PAYLOAD@/[A-Za-z0-9_./-]\+' "$tin" | sort -u)
done
say "5. unit templates present, every payload-local ExecStart exists"

# --- 6. .envdefault parses, and defines every required key -------------------
env_parse "$SRC/$ENVDEFAULT" >/dev/null
for k in "${REQUIRED_ENV[@]}"; do
    env_keys "$SRC/$ENVDEFAULT" | grep -qx -- "$k" \
        || die "$ENVDEFAULT does not define REQUIRED_ENV key $k"
done
say "6. $ENVDEFAULT parses and defines all ${#REQUIRED_ENV[@]} required keys"

# --- 7. .env exists and defines every required key, non-empty ----------------
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ $KIND == dev ]]; then
        die "no $ENV_FILE.
    A dev install needs one for the tests. Create it and edit it:
        cp $SRC/$ENVDEFAULT $ENV_FILE
    It is gitignored. A DEPLOYED .env is created by deploy.sh, never by hand."
    else
        die "no $ENV_FILE.
    Run deploy.sh, which seeds it from $ENVDEFAULT, missing-only."
    fi
fi
env_parse "$ENV_FILE" >/dev/null
unset_keys=()
for k in "${REQUIRED_ENV[@]}"; do
    [[ -n "$(env_value "$ENV_FILE" "$k")" ]] || unset_keys+=("$k")
done
((${#unset_keys[@]} == 0)) || die "$ENV_FILE is missing or empties:$(printf '\n    %s' "${unset_keys[@]}")
    A version that adds a key cannot add it to an existing .env - seeding is
    missing-only by design - so this is where that is caught. Copy the key and
    its comment out of $SRC/$ENVDEFAULT."
say "7. $ENV_FILE defines all ${#REQUIRED_ENV[@]} required keys"

# --- 8. nothing declared collides with another project ----------------------
for h in "${HELPERS[@]}"; do
    owned_by_us "$SBINDIR/$h" \
        || die "$SBINDIR/$h belongs to something else (see the warning above).
    Two projects fighting over one helper name must surface now, not as an
    intermittent wrong-verb error in six months."
done
for f in "${PAGE[@]}"; do
    owned_by_us "$PKGDIR/$f" || die "$PKGDIR/$f belongs to something else"
done
for u in "${UNITS[@]}"; do
    if [[ -e "$UNITDEST/$u" ]] && [[ -z "$DESTDIR" ]]; then
        grep -q "^# rendered by $PROJECT install.sh" "$UNITDEST/$u" 2>/dev/null \
            || die "$UNITDEST/$u exists and was not rendered by this project.
    Move it aside if you mean to take it over."
    fi
done
say "8. no collision in $SBINDIR, $PKGDIR or $UNITDEST"

# --- 9. no dev root and no retired path in anything being shipped -----------
shipped=("${PAGE[@]/#/$SRC/}")
for h in "${HELPERS[@]}"; do shipped+=("$(helper_path "$h")"); done
for s in "${SEEDS[@]}";  do shipped+=("$SRC/${s%%=*}"); done
shipped+=("$SRC/$ENVDEFAULT")
if [[ -d "$SRC/systemd" ]]; then
    while IFS= read -r f; do shipped+=("$f"); done < <(find "$SRC/systemd" -type f)
fi
# $SELF is scanned too, with NO carve-out - the classifier above is layout-
# based, so this file carries no dev-root literal any more. Both patterns are
# split so this grep line cannot match itself; that weakens nothing, since the
# concatenation searched for is unchanged and every other file is matched in
# full. It only stops the audit reporting itself.
shipped+=("$SELF")
if grep -RIn -e "/opt/sc""/git" -e "/srv/smb/share/sc/ai-orchestrator""-group" -- "${shipped[@]}"; then
    die "a shipped file hardcodes a dev or retired path (above). It belongs in .env."
fi
say "9. no retired-checkout path and no dev-root literal in any shipped file"

echo "Pre-flight passed. Writing."
echo

# ============================================================== the install ===

install -d -o root -g root -m 0755 "$PKGDIR" "$SBINDIR" "$CONFDIR"

# --- the Cockpit page: a real directory of per-file symlinks -----------------
# NOT one directory symlink. This same script runs in a dev install, where the
# directory it would link is the checkout - and /usr/share/cockpit/<name> is a
# web root, so that would serve .git/, tests/ and docs/ over HTTPS to any
# authenticated Cockpit session.
for f in "${PAGE[@]}"; do
    ln -sfn -- "$LINK_SRC/$f" "$PKGDIR/$f"
    say "link $PKGDIR/$f -> $LINK_SRC/$f"
done

# The sweep is what makes PAGE the description of the installed state rather
# than a hopeful comment. remove_link only ever removes a link.
shopt -s nullglob dotglob
for existing in "$PKGDIR"/*; do
    name="${existing##*/}"; keep=0
    for f in "${PAGE[@]}"; do [[ "$name" == "$f" ]] && keep=1; done
    ((keep)) || { say "stale: $name"; remove_link "$existing"; }
done
shopt -u nullglob dotglob

# --- the helpers ------------------------------------------------------------
for h in "${HELPERS[@]}"; do
    t="$(helper_link_target "$h")"
    ln -sfn -- "$t" "$SBINDIR/$h"
    say "link $SBINDIR/$h -> $t"
done

# --- seed data, MISSING-ONLY ------------------------------------------------
# Never clobbered. These are what the operator decided the host and the tailnet
# should look like; overwriting one on a re-install would silently change what
# the reconciler enforces and which routes headscale auto-approves.
for s in "${SEEDS[@]}"; do
    src="$SRC/${s%%=*}"; key="${s##*=}"
    dest="$DESTDIR$(env_value "$ENV_FILE" "$key")"
    [[ -n "${dest#$DESTDIR}" ]] || die "SEEDS names .env key $key, which is empty"
    if [[ -e "$dest" ]]; then
        say "kept existing $dest (not overwritten)"
    else
        install -D -o root -g root -m 0644 -- "$src" "$dest"
        say "seeded $dest from ${s%%=*}"
    fi
done

# --- units: rendered and placed, never enabled ------------------------------
render_unit() {
    local name=$1 in="$SRC/systemd/$1.in" out="$UNITDEST/$1"
    [[ -f "$in" ]] || in="$SRC/systemd/$1"
    [[ -f "$in" ]] || die "missing unit template for $name"
    install -d -o root -g root -m 0755 "$UNITDEST"
    {
        printf '# rendered by %s install.sh from systemd/%s.in on %s\n' \
               "$PROJECT" "$name" "$(date -u +%FT%TZ)"
        printf '# Do not edit here - edit the template and re-run install.sh.\n'
        sed -e "s|@BIN@|$BIN_DIR|g" \
            -e "s|@PAYLOAD@|$LINK_SRC|g" \
            -e "s|@INSTALL_PATH@|$ROOT|g" \
            -e "s|@ENV_FILE@|$ENV_FILE|g" \
            -e "s|@SBIN@|/usr/local/sbin|g" "$in"
    } > "$out.new"
    if grep -q '@[A-Z_]\+@' "$out.new"; then
        local left; left=$(grep -o '@[A-Z_]*@' "$out.new" | sort -u | tr '\n' ' ')
        rm -f -- "$out.new"
        die "unrendered placeholder(s) in $name: $left"
    fi
    chmod 0644 "$out.new"; chown root:root "$out.new"
    mv -f -- "$out.new" "$out"
    say "rendered $out"
}

if ((${#UNITS[@]})); then
    if [[ $KIND == dev && $WITH_UNITS -eq 0 ]]; then
        say "units NOT rendered: this is a dev install and --with-units was not given."
        say "  A dev install must not put a system unit on a host that may already"
        say "  have a deployed one - two hs-policy-watch daemons reconciling the same"
        say "  host against two policy files is a genuinely confusing outage."
    else
        for u in "${UNITS[@]}"; do render_unit "$u"; done
        if [[ -z "$DESTDIR" ]]; then
            systemctl daemon-reload
            say "daemon-reload done. NOT enabled and NOT started - that is deploy.sh's"
            say "  job, behind --with-policy. To do it by hand:"
            say "    systemctl enable --now ${UNITS[0]}"
        fi
    fi
fi

# --- the marker file --------------------------------------------------------
# .env is the operator's; install.conf is the machine's. Nothing good comes of
# one file being both. Every helper resolves its .env through THIS file and has
# no "look beside me" fallback, which is what stops a deployed helper reading a
# checkout's test .env.
cat > "$CONFDIR/install.conf" <<EOF
# Written by install.sh. Do not edit; re-run install.sh instead.
INSTALL_KIND=$KIND
INSTALL_PATH=$ROOT
PAYLOAD=$LINK_SRC
ENV_FILE=$ENV_FILE
UNITDIR=$UNITDIR
VERSION=$( [[ -f "$SRC/VERSION" ]] && tr -d '\n' < "$SRC/VERSION" || echo unknown )
INSTALLED_AT=$(date -u +%FT%TZ)
INSTALLED_BY=install.sh
EOF
chmod 0644 "$CONFDIR/install.conf"; chown root:root "$CONFDIR/install.conf"
say "wrote $CONFDIR/install.conf"

# ========================================================== post-install ======
#
# Separate from the pre-flight on purpose: a script that only checked its
# intentions would report the mode it meant to set.

echo
echo "Asserting what was produced"

shopt -s nullglob dotglob
found=(); for e in "$PKGDIR"/*; do found+=("${e##*/}"); done
shopt -u nullglob dotglob
want=$(printf '%s\n' "${PAGE[@]}" | sort)
have=$(printf '%s\n' "${found[@]}" | sort)
[[ "$want" == "$have" ]] || die "$PKGDIR contains something other than PAGE:
$(diff <(echo "$want") <(echo "$have") || true)"

for f in "${PAGE[@]}"; do
    [[ -L "$PKGDIR/$f" ]] || die "$PKGDIR/$f is not a symlink"
    t=$(readlink -f -- "$PKGDIR/$f") || die "$PKGDIR/$f does not resolve"
    [[ "$t" == "$SRC"/* ]] || die "$PKGDIR/$f resolves to $t, outside $SRC"
    [[ -f "$t" ]] || die "$PKGDIR/$f resolves to $t, which does not exist"
done
say "page: ${#PAGE[@]} symlinks, every target resolving under $SRC"

for h in "${HELPERS[@]}"; do
    [[ -L "$SBINDIR/$h" ]] || die "$SBINDIR/$h is not a symlink"
    t=$(readlink -f -- "$SBINDIR/$h") || die "$SBINDIR/$h does not resolve"
    [[ "$t" == "$SRC"/* ]] || die "$SBINDIR/$h resolves to $t, outside $SRC"
    [[ -x "$t" ]] || die "$SBINDIR/$h resolves to $t, which is not executable"
done
say "helpers: ${#HELPERS[@]} symlinks, every target executable under $SRC"

t=$(readlink -f -- "$CONFDIR/install.conf")
[[ -f "$t" ]] || die "install.conf was not written"
say "install.conf: PAYLOAD=$LINK_SRC ENV_FILE=$ENV_FILE"

# THE SELF-SUSTAINING ASSERTION, stated positively and proved on what was
# actually produced. After a deployment, unmounting the share must leave the
# plugin working. This is now stated as "everything resolves INSIDE the install
# path" rather than "nothing resolves into the dev share": it needs no path
# literal, and it is strictly stronger, because a link into any OTHER foreign
# tree - a second checkout, someone's home directory, a scratch dir - fails it
# too. A dev install is deliberately the opposite: it IS the checkout, so the
# assertion runs only for the kind of install that has to survive.
if [[ $KIND == deployed ]]; then
    for f in "${PAGE[@]}"; do
        t=$(readlink -f -- "$PKGDIR/$f")
        [[ "$t" == "$ROOT_REAL"/* ]] || die "$PKGDIR/$f resolves to $t, which is OUTSIDE $ROOT_REAL.
    A deployed host must keep working with the development share unmounted."
    done
    for h in "${HELPERS[@]}"; do
        t=$(readlink -f -- "$SBINDIR/$h")
        [[ "$t" == "$ROOT_REAL"/* ]] || die "$SBINDIR/$h resolves to $t, which is OUTSIDE $ROOT_REAL"
    done
    # Units may legitimately name a system interpreter (`ExecStart=/bin/sh -c
    # '... @BIN@/hs-policy ...'`), so the rule is not "everything under the
    # payload". It is: EVERY absolute path anywhere on the line must be either
    # inside the install path or on an FHS system prefix that is part of the
    # host itself. A path under /srv, /home, /mnt, /media or /tmp - which is
    # where a development checkout lives - fails, and it fails without this
    # file having to name any particular checkout.
    for u in "${UNITS[@]}"; do
        [[ -f "$UNITDEST/$u" ]] || continue
        while IFS= read -r tok; do
            [[ "$tok" == "$ROOT_REAL" || "$tok" == "$ROOT_REAL"/* ]] && continue
            case "$tok" in
                /usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*|/etc/*|/var/*|/run/*) continue ;;
            esac
            die "$UNITDEST/$u names $tok, which is neither inside $ROOT_REAL nor on a system prefix.
    A deployed host must keep working with the development share unmounted."
        done < <(grep -o '/[A-Za-z0-9_./@%+-]*' <(grep '^ExecStart=' "$UNITDEST/$u") || true)
    done
    say "self-sustaining: every link resolves inside $ROOT_REAL; every unit path is inside it or on a system prefix"
fi

echo
echo "Done. $KIND install of $PROJECT."
echo "  Reload the Cockpit page; log out and back in for a changed menu entry."
echo "  cockpit.socket was NOT restarted; headscale was not stopped, started or"
echo "  reconfigured, and no route was approved or revoked."
if [[ $KIND == dev ]]; then
    echo
    echo "  This is a DEV install: the page is symlinked into $SRC."
    echo "  Unmount the share and it stops working. That is the point of it."
fi
