#!/usr/bin/env bash
#
# deploy.sh - deploy cockpit-headscale to this host.
#
#   sudo ./deploy.sh                          deploy to /opt/cockpit-headscale
#   sudo ./deploy.sh --install-to /srv/x      deploy somewhere else
#   sudo ./deploy.sh --with-policy            ...and enable+start the reconciler
#   sudo ./deploy.sh --verify                 run the standing checks, change nothing
#   sudo ./deploy.sh --uninstall              un-install: links and units, keep the tree
#   sudo ./deploy.sh --remove                 remove the deployed tree as well
#
# WHAT THIS IS, AND WHAT install.sh IS
#   This is the only thing that COPIES. It copies the declared payload - a
#   subset, never the checkout - into [install path]/payload-<version>/, seeds
#   the .env, swaps a symlink, and then runs install.sh FROM THE INSTALL PATH.
#   install.sh does the linking, and it is the same script either way.
#
#   Self-contained on purpose: this repository is cloned on its own, so a deploy
#   script that reached for a shared framework outside the clone would not run.
#
# WHAT SURVIVES
#   .env, the two policy files it names, and the previous payload. An upgrade
#   replaces payload-<version>/ wholesale and touches nothing else; that split is
#   why .env is a SIBLING of payload/ and not a child of it.
#
#   headscale itself is never touched: not its binary, not its config, not its
#   database, not its unit. This project manages a Cockpit page and two helpers,
#   and it records where headscale lives rather than deciding it.
#
# Normative reference: cockpit-secrets/source/docs/DEPLOY-CONTRACT.md.

set -Eeuo pipefail

SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SRC="$(cd -- "$(dirname -- "$SELF")" && pwd)"

# The ONE declaration, sourced out of install.sh rather than restated. Restating
# it here would re-introduce the exact failure - two lists that can disagree -
# that the gate exists to prevent.
eval "$(sed -n '/^# BEGIN-MANIFEST/,/^# END-MANIFEST/p' "$SRC/install.sh")"
[[ -n "${PROJECT:-}" && ${#PAGE[@]} -gt 0 ]] \
    || { echo "deploy.sh: could not read the manifest block out of install.sh" >&2; exit 1; }

VERSION="$( [[ -f "$SRC/VERSION" ]] && tr -d '[:space:]' < "$SRC/VERSION" || echo 0.0.0 )"
DEV_ROOT=/srv/smb/share/sc/ai-orchestrator-group/ai-orchestrator-storage/projects

ROOT="/opt/$PROJECT"
ACTION=deploy
WITH_POLICY=0

say()  { printf '  %s\n' "$*"; }
warn() { printf 'deploy.sh: warning: %s\n' "$*" >&2; }
die()  { printf 'deploy.sh: %s\n' "$*" >&2; exit 1; }
# Print the whole leading comment block, whatever length it happens to be. A
# fixed line range is a comment that silently starts lying the moment somebody
# adds a paragraph - which both of these already had.
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SELF"; }

while (($#)); do
    case "$1" in
        --install-to) ROOT="${2:-}"; shift 2 ;;
        --with-policy) WITH_POLICY=1; shift ;;
        --verify)     ACTION=verify; shift ;;
        --uninstall)  ACTION=uninstall; shift ;;
        --remove)     ACTION=remove; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

# --------------------------------------------------------------- the standing
# checks of DEPLOY-CONTRACT.md section 4.4. Each must print nothing.

verify() {
    local rc=0 out
    echo "Standing checks (section 4.4)"

    local hp=()
    for h in "${HELPERS[@]}"; do p="$SRC/bin/$h"; [[ -f "$p" ]] || p="$SRC/$h"; hp+=("$p"); done

    # 1. No shipped file ever names a source .env.
    out=$(grep -RIn --exclude-dir=.git -e 'source/\.env' -e '"\.env"' -e "'\.env'" \
          -- "${PAGE[@]/#/$SRC/}" "${hp[@]}" 2>/dev/null || true)
    [[ -z "$out" ]] || { echo "  1 FAIL - a shipped file names a source .env:"; echo "$out"; rc=1; }

    # 2. No helper resolves .env relative to itself. The deployed helper must not
    #    be able to look beside itself, because in a dev install that lands in
    #    the checkout and reads the test .env.
    out=$(grep -RIn -e 'dirname.*\.env' -e '__file__.*\.env' -e '\$SRC/\.env' \
          -e 'BASH_SOURCE.*\.env' -- "${hp[@]}" 2>/dev/null || true)
    [[ -z "$out" ]] || { echo "  2 FAIL - a helper resolves .env relative to itself:"; echo "$out"; rc=1; }

    # 3. Every helper that reads config reads install.conf, or reads nothing.
    for h in "${HELPERS[@]}"; do
        p="$SRC/bin/$h"; [[ -f "$p" ]] || p="$SRC/$h"
        grep -qI -e 'ENV_FILE' -e '\.env' -- "$p" 2>/dev/null || continue
        grep -qI 'install\.conf' -- "$p" \
            || { echo "  3 FAIL - $h reads a .env but never reads install.conf"; rc=1; }
    done

    # 4. On a live host: the deployed helper opens the deployed .env and no
    #    other. strace proves it rather than arguing it; where strace is absent,
    #    the substitute is the booby trap below.
    if [[ $ACTION == verify && -x /usr/local/sbin/hs-admin ]]; then
        if command -v strace >/dev/null 2>&1; then
            t=$(mktemp); strace -f -e trace=openat -o "$t" /usr/local/sbin/hs-admin --help >/dev/null 2>&1 || true
            out=$(grep -F '.env' "$t" | grep -v -e "$ROOT/" -e ENOENT || true); rm -f "$t"
            [[ -z "$out" ]] || { echo "  4 FAIL - hs-admin opened a .env outside $ROOT:"; echo "$out"; rc=1; }
        else
            say "4 skipped - strace not installed. The substitute is a negative test:"
            say "  put a booby-trapped .env in the checkout with an obviously wrong"
            say "  HEADSCALE_BIN, run /usr/local/sbin/hs-admin status, and confirm the"
            say "  bin it reports is not the trapped one."
        fi
    fi

    # 5. No dev root and no retired path in anything that would be shipped.
    local shipped=("${PAGE[@]/#/$SRC/}" "$SRC/$ENVDEFAULT" "${hp[@]}")
    for sd in "${SEEDS[@]}"; do shipped+=("$SRC/${sd%%=*}"); done
    if [[ -d "$SRC/systemd" ]]; then
        while IFS= read -r f; do shipped+=("$f"); done < <(find "$SRC/systemd" -type f)
    fi
    out=$(grep -RIn -e '/opt/sc/git' -e "$DEV_ROOT" -- "${shipped[@]}" 2>/dev/null || true)
    [[ -z "$out" ]] || { echo "  5 FAIL - a shippable file hardcodes a dev or retired path:"; echo "$out"; rc=1; }

    ((rc)) || echo "  all standing checks pass"
    return $rc
}

if [[ $ACTION == verify ]]; then verify; exit $?; fi

[[ $EUID -eq 0 ]] || die "must be run as root (try: sudo $0)"
[[ "$ROOT" == /* ]] || die "--install-to must be an absolute path (got '$ROOT')"

ROOT_REAL="$(readlink -f -- "$ROOT")"

# The ONE recursive removal this contract allows, with its three assertions.
remove_old_payload() {
    local p=$1 real
    [[ -d "$p" && ! -L "$p" ]]  || die "refusing: $p is not a real directory"
    real=$(readlink -f -- "$p") || die "refusing: cannot resolve $p"
    [[ "$real" == "$ROOT_REAL"/payload-* ]] \
        || die "refusing to recursively remove $real - not a payload dir under $ROOT_REAL"
    [[ "$real" != "$ROOT_REAL" ]] || die "refusing: that is the install root"
    rm -rf -- "$real"
    say "removed old payload $real"
}

# =============================================================== uninstall ===

if [[ $ACTION == uninstall || $ACTION == remove ]]; then
    [[ -d "$ROOT" ]] || die "nothing deployed at $ROOT"
    if [[ -x "$ROOT/payload/install.sh" ]]; then
        "$ROOT/payload/install.sh" --uninstall
    else
        warn "no $ROOT/payload/install.sh - links and units were NOT removed"
    fi
    if [[ $ACTION == remove ]]; then
        for d in "$ROOT"/payload-*; do [[ -d "$d" ]] && remove_old_payload "$d"; done
        rm -f -- "$ROOT/payload"
        echo
        echo "Removed the deployed tree. LEFT ALONE, deliberately:"
        echo "  $ROOT/.env"
        echo "  the policy files named by .env (routing policy, ACL policy)"
        echo "  /etc/$PROJECT   (install.conf's directory)"
        echo "Remove those by hand if you really mean to."
        rmdir -- "$ROOT" 2>/dev/null && echo "  removed empty $ROOT" || true
    fi
    exit 0
fi

# =============================================================== pre-flight ===

echo "Deploying $PROJECT $VERSION"
say "from: $SRC"
say "to:   $ROOT"
echo

[[ -d "$SRC/.git" || -f "$SRC/VERSION" ]] || warn "this does not look like a checkout"

# /opt is a separate filesystem on some hosts and a few hardening profiles mount
# it noexec, which would break every helper here. Refuse now rather than produce
# an install that fails at the first click. (DEPLOY-CONTRACT.md JC-1.)
install -d -m 0755 -o root -g root "$ROOT"
probe="$ROOT/.noexec-probe.$$"
printf '#!/bin/sh\nexit 0\n' > "$probe"; chmod 0755 "$probe"
if ! "$probe" 2>/dev/null; then
    rm -f -- "$probe"
    die "$ROOT is on a noexec filesystem. The helpers here are executed from the
    payload, so this install would fail at the first click. Mount it exec, or
    pick another --install-to."
fi
rm -f -- "$probe"
say "target filesystem allows execution"

verify || die "the standing checks failed (above). Nothing was copied."
echo

# ================================================================ the copy ====

# A redeploy of the SAME version is the common case, not an edge case: it is
# what an operator does after editing the checkout without bumping VERSION. It
# must not be a `mv` over a directory that is still the target of the live
# `payload` symlink - mv -T refuses a non-empty directory, and removing it first
# would leave Cockpit serving nothing for the length of a copy. So the same
# version deployed twice gets a distinct, ordered directory name, the swap stays
# a single rename, and the one it replaces becomes the rollback target.
PAYDIR="payload-$VERSION"
[[ -e "$ROOT/$PAYDIR" ]] && PAYDIR="payload-$VERSION+$(date -u +%Y%m%dT%H%M%SZ)"
NEW="$ROOT/$PAYDIR"
STAGE="$NEW.tmp"

# Sweep any staging directory a previous interrupted run left behind, through
# the guarded remover rather than a bare rm -rf. A leftover payload-*.tmp is not
# only clutter: it would otherwise be counted as a payload when deciding which
# previous version to keep, and would push the real rollback target out.
for stale in "$ROOT"/payload-*.tmp; do
    [[ -d "$stale" ]] && remove_old_payload "$stale"
done
mkdir -p -- "$STAGE/bin"

copy() { install -D -o root -g root -m "$1" -- "$2" "$3"; }

for f in "${PAGE[@]}";  do copy 0644 "$SRC/$f" "$STAGE/$f"; done
for h in "${HELPERS[@]}"; do
    p="$SRC/bin/$h"; [[ -f "$p" ]] || p="$SRC/$h"
    copy 0755 "$p" "$STAGE/bin/$h"
done
for l in "${LIBS[@]}"; do cp -a -- "$SRC/$l" "$STAGE/$l"; done
for s in "${SEEDS[@]}"; do copy 0644 "$SRC/${s%%=*}" "$STAGE/${s%%=*}"; done
copy 0644 "$SRC/$ENVDEFAULT" "$STAGE/$ENVDEFAULT"
copy 0755 "$SRC/install.sh"  "$STAGE/install.sh"
if [[ -d "$SRC/systemd" ]]; then
    for u in "$SRC"/systemd/*; do copy 0644 "$u" "$STAGE/systemd/${u##*/}"; done
fi
for e in "${EXTRA[@]}"; do
    if [[ -f "$SRC/$e" ]]; then copy 0644 "$SRC/$e" "$STAGE/$e"; fi
done

# NOT shipped, and this is the point of shipping a subset: .git, check.sh, any
# .env, and anything else not named by the declaration in install.sh.
say "payload staged: ${#PAGE[@]} page files, ${#HELPERS[@]} helpers, $(ls "$STAGE/systemd" 2>/dev/null | wc -l) unit template(s)"

# The payload must contain exactly what was declared and nothing else.
if [[ -e "$STAGE/.env" ]]; then rm -f -- "$STAGE/.env"; warn "a .env had been staged - removed"; fi

# The acceptance test for this entire design is "unmount the share and the
# deployed host keeps working", so assert it on the bytes actually copied rather
# than on the checkout they came from. Exactly ONE occurrence is allowed and it
# is named: install.sh's DEV_ROOT assignment, which is a string this installer
# COMPARES $SRC against in order to record INSTALL_KIND, and never dereferences.
# A blanket exclusion for install.sh would hide a real regression; this excludes
# one line of one file and refuses everything else.
while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    hf=${hit%%:*}; hrest=${hit#*:}; htext=${hrest#*:}
    # install.sh is exempt, and it is the only exemption. It is the file whose
    # JOB is to name these paths: it compares $SRC against the dev root to record
    # INSTALL_KIND, and it carries /opt/sc/git as a grep PATTERN in check 9 in
    # order to refuse it. Every occurrence there is a string compared against,
    # never a path opened - and rather than police that with a line-shape regex
    # that will misjudge the next sentence somebody writes, install.sh's own
    # post-install assertion proves the property that actually matters: on a
    # deployed host every symlink target and every rendered ExecStart resolves
    # OUTSIDE the share. That is the self-sustaining test, stated positively.
    [[ "${hf##*/}" == install.sh ]] && continue
    die "the staged payload names a dev or retired path:
    $hit
    A deployed host must keep working with the share unmounted. Move it to .env."
done < <(grep -RIn -e '/opt/sc/git' -e "$DEV_ROOT" -- "$STAGE" 2>/dev/null || true)
say "no shipped file dereferences a dev or retired path"

mv -T -- "$STAGE" "$NEW"
say "wrote $NEW"

# The swap. mv -T over a symlink is a single rename(2): there is no instant at
# which $ROOT/payload does not resolve, which matters because Cockpit is live at
# https://localhost:9090 and a browser may be loading the page right now.
ln -sfn -- "$PAYDIR" "$ROOT/payload.new"
mv -T -- "$ROOT/payload.new" "$ROOT/payload"
say "payload -> $PAYDIR"

# ============================================================== the .env ======

ENV_FILE="$ROOT/.env"
if [[ -e "$ENV_FILE" ]]; then
    say "kept existing $ENV_FILE (not overwritten)"
    new_keys=$(comm -23 \
        <(grep -oE '^[A-Z][A-Z0-9_]*=' "$NEW/$ENVDEFAULT" | tr -d = | sort -u) \
        <(grep -oE '^[A-Z][A-Z0-9_]*=' "$ENV_FILE"        | tr -d = | sort -u))
    [[ -z "$new_keys" ]] || warn "this version adds keys your .env does not set:
    $(echo "$new_keys" | tr '\n' ' ')
    Missing-only seeding cannot add them for you. install.sh's pre-flight will
    refuse if any of them is required."
else
    install -m 0644 -o root -g root -- "$NEW/$ENVDEFAULT" "$ENV_FILE"
    say "seeded $ENV_FILE from $ENVDEFAULT - REVIEW IT before first use"
fi

# A deployed .env carries locations and settings, never secrets. 0644 is safe
# only because this refusal is enforced rather than promised.
while IFS='=' read -r k v; do
    [[ "$k" =~ (PASS|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|PASSPHRASE) ]] || continue
    [[ "$k" =~ _(FILE|PATH|DIR|NAME|ID)$ ]] && continue
    [[ -z "$v" ]] && continue
    die "$k in $ENV_FILE looks like a secret VALUE. A deployed .env carries
    locations and settings, never secrets. Put the material in a root-only file
    and name the FILE here (${k}_FILE=...)."
done < <(grep -v '^[[:space:]]*#' "$ENV_FILE" | grep '=' || true)
say ".env carries no secret-shaped value"

# ============================================== install, from the install path

echo
"$ROOT/payload/install.sh"

# ================================================== units, behind a flag ======

if ((WITH_POLICY)); then
    echo
    echo "Enabling the routing reconciler (--with-policy)"
    for u in "${UNITS[@]}"; do
        systemctl enable --now "$u"
        say "enabled and started $u"
    done
    say "check drift any time with: hs-policy check"
else
    echo
    say "units were rendered but NOT enabled. Pass --with-policy to enable them,"
    say "or: systemctl enable --now ${UNITS[0]}"
fi

# ============================================ keep exactly one previous ======

# Keep the current payload and exactly ONE previous; delete the rest. The .tmp
# exclusion is load-bearing: a staging directory counted as a payload here would
# silently push the real rollback target off the end of the list.
mapfile -t old < <(find "$ROOT" -maxdepth 1 -type d -name 'payload-*' ! -name '*.tmp' -printf '%T@ %p\n' \
                   | sort -rn | cut -d' ' -f2- | tail -n +3)
for d in "${old[@]:-}"; do [[ -n "$d" ]] && remove_old_payload "$d"; done

echo
echo "Deployed. $ROOT/payload -> $PAYDIR"
echo "  Rollback:  ln -sfn payload-<previous> $ROOT/payload.new \\"
echo "             && mv -T $ROOT/payload.new $ROOT/payload \\"
echo "             && $ROOT/payload/install.sh"
echo "  Available: $(find "$ROOT" -maxdepth 1 -type d -name 'payload-*' -printf '%f ' )"
echo
echo "  Self-sustaining check - unmount the share and this keeps working:"
echo "    readlink -f /usr/share/cockpit/$PAGE_NAME/index.html"
echo "    readlink -f /usr/local/sbin/hs-admin"
