#!/bin/sh
# Bump the pinned revs that let a single crate be installed on its own.
#
# Each app declares its workspace-internal dependencies as git dependencies on
# git.lucas.co, pinned to an exact rev, while the workspace root patches those
# sources back to the local crates. That split is what lets one app be cloned
# and built alone -- and it is also exactly why the pins rot silently: inside
# this workspace the [patch] block always wins, so a stale rev never fails a
# build here. It surfaces only as a standalone build of an app quietly
# compiling an old copy of the toolkit. Nothing warns you. Hence this script.
#
# Run it after pushing a shared crate (cce-ui, cce-window-manager).
#
#   bump-revs.sh [--dry-run] [--commit] [dep...]
#
# With no dep named, every dependency that appears in a git pin is considered.
#
# WHAT IT PINS TO: the BARE repo's HEAD under ~/git -- not the work tree's. A
# rev that exists only in a work tree is fetchable by nobody, so pinning it
# would write manifests that resolve on this machine and nowhere else. If a
# dependency has unpushed commits or uncommitted changes, that is reported and
# the run fails rather than pinning something stale; push it first. A bare repo
# ahead of its work tree is fine and is pinned as-is -- it is what others can
# actually fetch.
#
# git.lucas.co lags the bare repos by up to an hour (gitsite.timer), so a rev
# pinned immediately after a push is correct but not yet fetchable from the
# site. That resolves itself and is not an error.
#
# A manifest that should have changed but did not fails the run. Silently
# skipping is what let 21 repos sit unpushed for a day; the same rule applies
# here.
#
#   env: GIT_BARE_ROOT (default ~/git)

set -eu

BARE_ROOT="${GIT_BARE_ROOT:-$HOME/git}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DRY=""
COMMIT=""
WANT=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --commit)  COMMIT=1 ;;
        -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)  WANT="$WANT $arg" ;;
    esac
done

[ -f "$ROOT/Cargo.toml" ] || { echo "no Cargo.toml beside $0" >&2; exit 1; }
grep -q '^\[workspace\]' "$ROOT/Cargo.toml" || {
    echo "$ROOT/Cargo.toml is not a workspace root" >&2; exit 1; }

say() { printf '%s\n' "$*"; }

# Every git pin in the workspace, as "crate dep rev". The manifests are written
# by this script and by hand in one uniform shape, so one pattern covers them;
# a line that drifts out of that shape stops matching and is reported below as
# a manifest that did not change, rather than being quietly left behind.
pins() {
    for m in "$ROOT"/*/Cargo.toml; do
        crate=$(basename "$(dirname "$m")")
        sed -n 's|^\([a-z0-9-]*\) = { git = "https://git\.lucas\.co/\1\.git", rev = "\([0-9a-f]\{40\}\)" }$|'"$crate"' \1 \2|p' "$m"
    done
}

ALL_PINS=$(pins)
[ -n "$ALL_PINS" ] || { say "no git pins found under $ROOT"; exit 0; }

DEPS=$(printf '%s\n' "$ALL_PINS" | awk '{print $2}' | sort -u)
if [ -n "$WANT" ]; then
    for w in $WANT; do
        printf '%s\n' "$DEPS" | grep -qx "$w" || {
            echo "$w is not pinned by any crate here" >&2; exit 1; }
    done
    DEPS=$(printf '%s' "$WANT" | tr ' ' '\n' | sed '/^$/d')
fi

[ -n "$DRY" ] && say "DRY RUN -- nothing will be written"

# Resolve each dependency to the rev that others can actually fetch, refusing
# to pin anything that is only local. Collected first, so a blocked dependency
# stops the run before any manifest is touched.
TARGETS=""
BLOCKED=""
for dep in $DEPS; do
    bare="$BARE_ROOT/$dep.git"
    [ -d "$bare" ] || { say "!! $dep: no bare repo at $bare"; BLOCKED="$BLOCKED $dep"; continue; }
    new=$(git -C "$bare" rev-parse HEAD 2>/dev/null) || {
        say "!! $dep: bare repo has no HEAD commit"; BLOCKED="$BLOCKED $dep"; continue; }

    wt="$ROOT/$dep"
    if [ -d "$wt/.git" ]; then
        if [ -n "$(git -C "$wt" status --porcelain)" ]; then
            say "!! $dep: uncommitted changes -- commit and push before pinning"
            BLOCKED="$BLOCKED $dep"; continue
        fi
        wt_head=$(git -C "$wt" rev-parse HEAD)
        if [ "$wt_head" != "$new" ] && git -C "$wt" merge-base --is-ancestor "$new" "$wt_head" 2>/dev/null; then
            ahead=$(git -C "$wt" rev-list --count "$new..$wt_head")
            say "!! $dep: work tree is $ahead commit(s) ahead of $bare"
            say "     push it first, or the pin misses that work:"
            say "     git -C $wt push origin \$(git -C $wt symbolic-ref --short HEAD)"
            BLOCKED="$BLOCKED $dep"; continue
        fi
    fi
    TARGETS="$TARGETS $dep=$new"
done

if [ -n "$BLOCKED" ]; then
    say ""
    say "blocked:$BLOCKED -- nothing written"
    say "name the other dependencies explicitly to bump them anyway, e.g."
    say "    $(basename "$0")$(printf '%s\n' "$DEPS" | grep -vx "$(printf '%s' "$BLOCKED" | tr -d ' ')" | tr '\n' ' ' | sed 's/ $//' | sed 's/^/ /')"
    exit 1
fi

# Apply. A crate already at the target rev is left alone and reported as such,
# so the output distinguishes "nothing to do" from "did nothing".
CHANGED=""
UNCHANGED=0
for t in $TARGETS; do
    dep=${t%%=*}
    new=${t#*=}
    say "$dep -> $(printf '%.8s' "$new")"
    printf '%s\n' "$ALL_PINS" | while read -r crate d old; do
        [ "$d" = "$dep" ] || continue
        [ "$old" = "$new" ] && { echo "SAME $crate"; continue; }
        echo "EDIT $crate $old"
    done > "${TMPDIR:-/tmp}/bump-revs.$$"

    while read -r verb crate old; do
        case "$verb" in
            SAME) UNCHANGED=$((UNCHANGED + 1)) ;;
            EDIT)
                m="$ROOT/$crate/Cargo.toml"
                say "    $crate"
                if [ -z "$DRY" ]; then
                    sed -i "s|^$dep = { git = \"https://git.lucas.co/$dep.git\", rev = \"$old\" }$|$dep = { git = \"https://git.lucas.co/$dep.git\", rev = \"$new\" }|" "$m"
                    grep -q "rev = \"$new\"" "$m" || {
                        say "!! $crate: manifest did not change -- pin format drifted?"; exit 1; }
                else
                    printf '    would: %s %s -> %s\n' "$crate" "$(printf '%.8s' "$old")" "$(printf '%.8s' "$new")"
                fi
                CHANGED="$CHANGED $crate"
                ;;
        esac
    done < "${TMPDIR:-/tmp}/bump-revs.$$"
    rm -f "${TMPDIR:-/tmp}/bump-revs.$$"
done

CHANGED=$(printf '%s' "$CHANGED" | tr ' ' '\n' | sed '/^$/d' | sort -u)
COUNT=$(printf '%s' "$CHANGED" | grep -c . || true)

say ""
if [ "$COUNT" = 0 ]; then
    say "every pin already current ($UNCHANGED) -- nothing to do"
    exit 0
fi
if [ "$UNCHANGED" -gt 0 ]; then
    say "$COUNT crate(s) repinned, $UNCHANGED already current"
else
    say "$COUNT crate(s) repinned"
fi

if [ -n "$COMMIT" ] && [ -z "$DRY" ]; then
    say ""
    say "committing:"
    for crate in $CHANGED; do
        ( cd "$ROOT/$crate" && git add Cargo.toml && git commit --quiet -m "Repin workspace dependencies to their published revs

The pinned revs only affect builds outside this workspace, where an app is
cloned on its own, so a stale pin never fails a build here. Bumped by
bump-revs.sh after the dependency was pushed." ) && say "    $crate"
    done
    say ""
    say "committed, not published -- push when ready:"
    say "    git-bare-sync.sh"
else
    say "review, then commit in each crate (or re-run with --commit)"
fi
