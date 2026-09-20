# CLAUDE.md

**Read `cce-compositor/WORKSPACE.md` before working anywhere in this workspace.**
That is the authoritative guide: layout, the multi-repo rule, the build/install
entry point, the `cce-ui` toolkit, config, and IPC.

This file is only a pointer. The guide lives inside `cce-compositor/`
(alongside `scripts/ccebuild`, which it documents) because that crate is where
the build tooling lives.

This directory **is** now a git repository, but a deliberately narrow one: it
versions only what ties the crates together — `Cargo.toml` (the member list and
the `[patch]` block), `Cargo.lock`, `.cargo/config.toml` and this file. Its
`.gitignore` excludes every subdirectory by glob, so no crate can be swallowed
as an embedded repo and adding a crate needs no change here. It also holds
`bump-revs.sh`: after pushing a shared crate, run it to repoint the git pins in
the crates that depend on it, because a stale pin never fails a build here --
only a standalone build elsewhere.

Three rules are repeated here, and only these three, because acting against any
of them before reading the guide does damage that is annoying to undo:

- **Each crate is its own git repository, and so is this root.** Commit crate
  changes inside the relevant crate — the root repo tracks only the workspace
  files listed above, and its `.gitignore` keeps every crate out. Remember that
  **committing is not publishing** —
  `origin` is a pushable bare repo under `~/git/`, and gitsite mirrors from
  there, so an unpushed commit is not on the site.
- **`ccebuild` is the build/install entry point** (`ccebuild install`,
  `restart`, `status`, `prune`). Do not hand-roll a loop over the crates, and
  never add a binary name to a Makefile — `cargo metadata` already knows it, and
  hand-listing is what left crates shipping incomplete for weeks.
- **Other Claude sessions may be working in sibling crates right now.** Scope
  builds and installs to your crate (`cargo build -p <crate>`,
  `ccebuild install <crate>` — never bare `install` or `restart`, which deploy
  and restart *other sessions'* work too), and read the "Concurrent sessions"
  section of the guide before editing shared crates (`cce-ui`,
  `cce-window-manager`, `cce-icons`) or driving the live session.
