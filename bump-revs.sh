#!/bin/sh
# Bump the pinned revs that let a single crate be installed on its own.
#
# Each app declares its workspace-internal dependencies as git dependencies on
# GitHub (the crates' origin), pinned to an exact rev, while the workspace root patches those
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
# WHAT IT PINS TO: the head of the dependency's branch on its `origin` remote
# (GitHub, since 2026-09-20 -- the bare repos under ~/git are gone) -- not the
# work tree's HEAD. A rev that exists only in a work tree is fetchable by
# nobody, so pinning it would write manifests that resolve on this machine and
# nowhere else. If the dependency's work tree has uncommitted changes or
# commits not yet on origin, that is reported and the run fails rather than
# pinning something stale; push it first (the post-commit hook normally has).
# An origin ahead of the work tree is fine and is pinned as-is -- it is what
# others can actually fetch.
#
# The pins name GitHub directly (since 2026-09-21; before that git.lucas.co,
# which only mirrors GitHub hourly, so a fresh pin was unfetchable for up to an
# hour), so a rev pinned right after a push resolves at once.
#
# A manifest that should have changed but did not fails the run. Silently
# skipping is what let 21 repos sit unpushed for a day; the same rule applies
# here.
#
# THE LOCKFILE MOVES WITH THE PIN. A crate that commits its Cargo.lock gets it
# re-resolved against the new pin and committed alongside it. Inside the
# workspace cargo never reads a member's own lock (the root lock and the
# [patch] block win), so a stale one rots exactly as a stale pin does, and
# surfaces only as a standalone build rewriting it silently. Until 2026-09-25
# this script touched Cargo.toml only, and all ten tracked locks with git deps
# had drifted -- two still resolving cce-ui as a PATH dependency. The refresh
# is `cargo metadata` in a copy of the crate outside the workspace: a minimal
# update, the one a standalone build would make, moving nothing from
# crates.io that the new pin does not require. A crate whose lock does not
# resolve fails the run before anything is committed.
#
# A PIN MAY CARRY EXTRA KEYS AFTER `rev` (features, optional, ...); the bump
# rewrites the rev alone and keeps them. Until 2026-10-01 the pattern demanded
# nothing after the rev, so cce-notes' and cce-grid's `features = [...]` pins
# of cce-ui and cce-ui's `optional = true` pin of cce-vault were invisible:
# not bumped, not reported, because the drift check only looked at manifests
# the pattern had already matched. Now every `git = "https://github.com/
# lsgalante/..."` line the pattern does not match is reported, and one naming
# a dependency being bumped fails the run before anything is written.
#
# A REPIN TOUCHES ONLY THE REPIN. A crate whose Cargo.toml or Cargo.lock
# already has uncommitted changes blocks the run before anything is written,
# and --commit commits exactly those two paths, leaving anything else staged
# where it was. Until 2026-10-01 it ran `git add` then a bare `git commit`, so
# whatever another session had staged, or half-edited in the manifest, went
# out in the "Repin" commit and was pushed with it. A commit that fails now
# fails the run.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DRY=""
COMMIT=""
WANT=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --commit)  COMMIT=1 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed '/^$/d; s/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)  WANT="$WANT $arg" ;;
    esac
done

[ -f "$ROOT/Cargo.toml" ] || { echo "no Cargo.toml beside $0" >&2; exit 1; }
grep -q '^\[workspace\]' "$ROOT/Cargo.toml" || {
    echo "$ROOT/Cargo.toml is not a workspace root" >&2; exit 1; }

say() { printf '%s\n' "$*"; }

# Scratch space for the whole run, removed however the run ends -- an early
# `exit 1` included, which used to leave a predictable /tmp/bump-revs.$$
# behind.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# Every git pin in the workspace, as "crate dep rev". A pin is
#   dep = { git = "https://github.com/lsgalante/dep.git", rev = "<sha>"[, more] }
# -- the git URL and rev first, then any other keys (features, optional, ...),
# which the bump leaves exactly as they are.
PIN_RE='^\([a-z0-9-]*\) = { git = "https://github\.com/lsgalante/\1\.git", rev = "\([0-9a-f]\{40\}\)"\(, [^}]*\)\{0,1\} }$'
pins() {
    for m in "$ROOT"/*/Cargo.toml; do
        crate=$(basename "$(dirname "$m")")
        sed -n "s|$PIN_RE|$crate \\1 \\2|p" "$m"
    done
}

# Every line that points a dependency at one of our GitHub repos but is not a
# pin in the shape above, as "crate:line: text". These are what used to vanish
# silently -- a pin the pattern cannot see is a pin nobody bumps.
strays() {
    for m in "$ROOT"/*/Cargo.toml; do
        crate=$(basename "$(dirname "$m")")
        grep -n 'git = "https://github\.com/lsgalante/' "$m" \
            | grep -v '^[0-9]*:[[:space:]]*#' \
            | grep -v "^[0-9]*:$(printf '%s' "$PIN_RE" | sed 's/^\^//')" \
            | sed "s|^|$crate:|"
    done
}

ALL_PINS=$(pins)
STRAYS=$(strays)
if [ -n "$STRAYS" ]; then
    say "!! not in pin shape -- this script cannot see or bump these:"
    printf '%s\n' "$STRAYS" | sed 's/^/     /'
    say "   put each in the shape above (extra keys after rev are fine)"
fi
[ -n "$ALL_PINS" ] || [ -n "$STRAYS" ] || { say "no git pins found under $ROOT"; exit 0; }

DEPS=$(printf '%s\n' "$ALL_PINS" | awk '{print $2}' | sort -u)
if [ -n "$WANT" ]; then
    for w in $WANT; do
        printf '%s\n' "$DEPS" | grep -qx "$w" || {
            echo "$w is not pinned by any crate here" >&2; exit 1; }
    done
    DEPS=$(printf '%s' "$WANT" | tr ' ' '\n' | sed '/^$/d')
fi

# A stray naming a dependency this run bumps is a dependent that would be
# left behind, so it stops the run; with no dependency named, every one of
# our repos counts. Strays naming other dependencies were reported above.
if [ -n "$STRAYS" ]; then
    if [ -n "$WANT" ]; then
        hit=""
        for dep in $DEPS; do
            printf '%s\n' "$STRAYS" | grep -q "lsgalante/$dep\(\.git\)\{0,1\}\"" && hit="$hit $dep"
        done
    else
        hit=" every dependency"
    fi
    if [ -n "$hit" ]; then
        say ""
        say "blocked: a pin above is out of shape, bumping$hit would leave it behind"
        say "-- nothing written"
        exit 1
    fi
fi

[ -n "$DRY" ] && say "DRY RUN -- nothing will be written"

# Resolve each dependency to the rev that others can actually fetch, refusing
# to pin anything that is only local. Collected first, so a blocked dependency
# stops the run before any manifest is touched.
TARGETS=""
BLOCKED=""
for dep in $DEPS; do
    wt="$ROOT/$dep"
    # -e, not -d: a checkout made with `git worktree add` has a .git FILE.
    [ -e "$wt/.git" ] || { say "!! $dep: no work tree at $wt"; BLOCKED="$BLOCKED $dep"; continue; }
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) || {
        say "!! $dep: detached HEAD -- check out its branch first"; BLOCKED="$BLOCKED $dep"; continue; }
    url=$(git -C "$wt" remote get-url origin 2>/dev/null) || {
        say "!! $dep: no origin remote"; BLOCKED="$BLOCKED $dep"; continue; }
    # Asked of the remote itself, not a possibly stale remote-tracking ref:
    # what others can fetch is what origin has right now.
    new=$(git -C "$wt" ls-remote --quiet "$url" "refs/heads/$branch" 2>/dev/null | cut -f1)
    [ -n "$new" ] || {
        say "!! $dep: origin ($url) has no branch $branch -- push it first"; BLOCKED="$BLOCKED $dep"; continue; }

    if [ -n "$(git -C "$wt" status --porcelain --untracked-files=no)" ]; then
        say "!! $dep: uncommitted changes -- commit and push before pinning"
        BLOCKED="$BLOCKED $dep"; continue
    fi
    wt_head=$(git -C "$wt" rev-parse HEAD)
    if [ "$wt_head" != "$new" ]; then
        # Make sure the local history knows the remote rev before comparing;
        # a fetch is cheap and the ancestor test is meaningless without it.
        git -C "$wt" fetch --quiet "$url" "refs/heads/$branch" 2>/dev/null || true
        if git -C "$wt" merge-base --is-ancestor "$new" "$wt_head" 2>/dev/null; then
            ahead=$(git -C "$wt" rev-list --count "$new..$wt_head")
            say "!! $dep: work tree is $ahead commit(s) ahead of origin/$branch"
            say "     push it first, or the pin misses that work:"
            say "     git -C $wt push origin $branch"
            BLOCKED="$BLOCKED $dep"; continue
        elif ! git -C "$wt" merge-base --is-ancestor "$wt_head" "$new" 2>/dev/null; then
            say "!! $dep: work tree and origin/$branch have diverged -- reconcile first"
            BLOCKED="$BLOCKED $dep"; continue
        fi
    fi
    TARGETS="$TARGETS $dep=$new"
done

if [ -n "$BLOCKED" ]; then
    say ""
    say "blocked:$BLOCKED -- nothing written"
    # One blocked name per line: grep reads each line as its own pattern.
    # (`tr -d ' '` used to glue two blocked names into one pattern that
    # matched nothing, so the hint suggested re-running with them included.)
    rest=$(printf '%s\n' "$DEPS" \
        | grep -vxF "$(printf '%s' "$BLOCKED" | tr ' ' '\n' | sed '/^$/d')" \
        | tr '\n' ' ' | sed 's/ $//')
    if [ -n "$rest" ]; then
        say "name the other dependencies explicitly to bump them anyway, e.g."
        say "    $(basename "$0") $rest"
    fi
    exit 1
fi

# A crate this run would repin must not already have uncommitted changes in
# its manifest or lock: the repin would be committed on top of them -- often
# another session's work in progress -- and pushed with it, and the lock
# refresh would resolve against them too. Checked before anything is written.
DIRTY=""
for t in $TARGETS; do
    dep=${t%%=*}
    new=${t#*=}
    for crate in $(printf '%s\n' "$ALL_PINS" | awk -v d="$dep" -v n="$new" '$2 == d && $3 != n { print $1 }'); do
        case " $DIRTY " in *" $crate "*) continue ;; esac
        if [ -n "$(git -C "$ROOT/$crate" status --porcelain --untracked-files=no -- Cargo.toml Cargo.lock 2>&1)" ]; then
            say "!! $crate: Cargo.toml or Cargo.lock has uncommitted changes -- commit or stash them first"
            DIRTY="$DIRTY $crate"
        fi
    done
done
if [ -n "$DIRTY" ]; then
    say ""
    say "blocked: would repin on top of uncommitted changes in$DIRTY -- nothing written"
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
    done > "$SCRATCH/plan"

    while read -r verb crate old; do
        case "$verb" in
            SAME) UNCHANGED=$((UNCHANGED + 1)) ;;
            EDIT)
                m="$ROOT/$crate/Cargo.toml"
                say "    $crate"
                if [ -z "$DRY" ]; then
                    # The rev alone is rewritten; keys after it are kept.
                    head="$dep = { git = \"https://github\\.com/lsgalante/$dep\\.git\", rev = \""
                    sed -i "s|^\($head\)$old\"|\1$new\"|" "$m"
                    grep -q "^$head$new\"" "$m" || {
                        say "!! $crate: manifest did not change -- pin format drifted?"; exit 1; }
                else
                    printf '    would: %s %s -> %s\n' "$crate" "$(printf '%.8s' "$old")" "$(printf '%.8s' "$new")"
                fi
                CHANGED="$CHANGED $crate"
                ;;
        esac
    done < "$SCRATCH/plan"
done

CHANGED=$(printf '%s' "$CHANGED" | tr ' ' '\n' | sed '/^$/d' | sort -u)
COUNT=$(printf '%s' "$CHANGED" | grep -c . || true)

# Whether a crate commits its Cargo.lock. An untracked (or absent) lock has
# nothing published to go stale, so it is left to whoever builds there.
lock_tracked() {
    git -C "$ROOT/$1" ls-files --error-unmatch Cargo.lock >/dev/null 2>&1
}

# Re-resolve one crate's Cargo.lock against its edited manifest, the way a
# standalone clone would: the committed tree plus the work tree's manifest and
# lock, in a directory outside the workspace (inside it cargo would find the
# root and ignore this lock entirely).
WORK="$SCRATCH/locks"
refresh_lock() {
    crate=$1
    mkdir -p "$WORK"
    case "$WORK" in "$ROOT"/*)
        say "!! temp dir $WORK is inside the workspace -- set TMPDIR elsewhere"; return 1 ;;
    esac
    copy="$WORK/$crate"
    rm -rf "$copy" && mkdir -p "$copy"
    git -C "$ROOT/$crate" archive HEAD | tar -x -C "$copy"
    cp "$ROOT/$crate/Cargo.toml" "$ROOT/$crate/Cargo.lock" "$copy/"
    if ! ( cd "$copy" && cargo metadata --quiet --format-version 1 >/dev/null 2>"$WORK/$crate.err" ); then
        say "!! $crate: Cargo.lock does not resolve standalone:"
        tail -n 5 "$WORK/$crate.err" | sed 's/^/     /'
        return 1
    fi
    if cmp -s "$copy/Cargo.lock" "$ROOT/$crate/Cargo.lock"; then
        say "    $crate (already current)"
    else
        cp "$copy/Cargo.lock" "$ROOT/$crate/Cargo.lock"
        say "    $crate"
    fi
}

if [ "$COUNT" != 0 ]; then
    say ""
    if [ -n "$DRY" ]; then
        for crate in $CHANGED; do
            lock_tracked "$crate" && say "    would refresh: $crate/Cargo.lock"
        done
    else
        say "refreshing lockfiles:"
        LOCK_FAILED=""
        for crate in $CHANGED; do
            lock_tracked "$crate" || continue
            refresh_lock "$crate" || LOCK_FAILED="$LOCK_FAILED $crate"
        done
        if [ -n "$LOCK_FAILED" ]; then
            say ""
            say "lock refresh failed:$LOCK_FAILED -- nothing committed; the"
            say "manifests are edited in place, so fix the resolve and re-run"
            exit 1
        fi
    fi
fi

say ""
if [ "$COUNT" = 0 ]; then
    say "every pin already current ($UNCHANGED) -- nothing to do"
    exit 0
fi
if [ -n "$DRY" ]; then
    repinned="would be repinned"
else
    repinned="repinned"
fi
if [ "$UNCHANGED" -gt 0 ]; then
    say "$COUNT crate(s) $repinned, $UNCHANGED already current"
else
    say "$COUNT crate(s) $repinned"
fi

if [ -n "$DRY" ]; then
    say "re-run without --dry-run to write them"
elif [ -n "$COMMIT" ]; then
    say ""
    say "committing:"
    FAILED=""
    for crate in $CHANGED; do
        files="Cargo.toml"
        lock_tracked "$crate" && files="$files Cargo.lock"
        # The paths after `--` are the whole commit: anything else already
        # staged in the crate stays staged and out of it. A failure is
        # counted, not swallowed -- `( ... ) && say` here once let a failed
        # commit pass under set -e and still print "committed".
        if git -C "$ROOT/$crate" commit --quiet -m "Repin workspace dependencies to their published revs

The pinned revs only affect builds outside this workspace, where an app is
cloned on its own, so a stale pin never fails a build here. Bumped by
bump-revs.sh after the dependency was pushed; Cargo.lock (when committed)
is re-resolved to match." -- $files; then
            say "    $crate"
        else
            say "!! $crate: commit failed"
            FAILED="$FAILED $crate"
        fi
    done
    if [ -n "$FAILED" ]; then
        say ""
        say "not committed:$FAILED -- their manifests are edited in place; commit them by hand"
        exit 1
    fi
    say ""
    say "committed -- each crate's post-commit hook pushes it to origin (GitHub);"
    say "a crate without the hook still needs: git -C <crate> push origin <branch>"
else
    say "review, then commit in each crate (or re-run with --commit)"
fi
