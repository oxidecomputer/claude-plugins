# Reference

## VCS command reference

Check for a `.jj` directory at each repo root: if present, use `jj`; otherwise, use `git`.

| Operation | jj | git |
|---|---|---|
| Fetch upstream | `jj git fetch` | `git fetch origin` |
| Start new work | `jj new main` | `git checkout -b $BRANCH main` |
| Commit | `jj commit -m "..."` | `git commit -am "..."` |
| Push | `jj git push` | `git push -u origin $BRANCH` |
| View diff | `jj diff --git` | `git diff` |

## Oxide repo dependency graph

**This is illustrative only — do not rely on it.** The actual graph changes frequently as repos add or remove dependencies. Always discover the graph dynamically by scanning each repo's `Cargo.toml`. This sketch exists only to give a rough sense of the topology:

- omicron tends to rev-pin its dependencies on crucible, propolis, dendrite, maghemite.
- Most other repos branch-track omicron (and sometimes each other). (But they pin to a rev in their `Cargo.lock` files.)
- Cycles are the norm, not the exception.

## Finding inter-repo git deps

Search each repo's workspace `Cargo.toml` for `git = "https://github.com/oxidecomputer/` to find inter-repo dependencies.

## Finding cross-repo type boundaries

Key search targets by crate:

- **reqwest**: search for `new_with_client` (client injection is the common boundary pattern).
- **dropshot/progenitor**: search for config or type re-exports that cross repo lines.
- **General**: search for `use $CRATE::` and check whether each site involves a type that flows across a repo boundary.
