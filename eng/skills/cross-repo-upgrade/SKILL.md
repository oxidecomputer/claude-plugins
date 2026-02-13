---
name: cross-repo-upgrade
description: Generates a plan to coordinate a dependency upgrade across multiple Oxide repos with cyclic dependencies. Triggered when upgrading a shared dependency (like progenitor, reqwest, dropshot) that must be synchronized across omicron, crucible, propolis, dendrite, maghemite, lldp, or other repos. Produces a reviewable plan document rather than executing directly.
---

# Cross-repo coordinated dependency upgrade

This skill generates a concrete plan for upgrading a shared dependency across multiple Oxide repos that have cyclic inter-repo dependencies. The plan is written to a file for human review before any execution begins.

## When to use this skill

- Upgrading a dependency (progenitor, reqwest, dropshot, etc.) that appears in multiple Oxide repos.
- The repos have inter-repo git dependencies forming cycles.
- Landing the upgrade requires coordinating across repo boundaries.

## Core principles

### Cargo.lock provides insulation

All Oxide repos commit their `Cargo.lock`. Tracking `branch = "main"` does NOT automatically break when the dep's main changes. Repos only see new dep versions when they explicitly `cargo update` or change the dep specification. This means:

- **No breakage windows.** Landing any repo's upgrade never breaks other repos.
- **No branch stepping stones needed.** Each repo can land independently whenever it's ready.
- **Landing order is driven by convenience**, not by fear of breaking consumers. The ordering consideration is: which repos are ready first, and which landings unblock the most downstream work (by letting downstream repos update their Cargo.lock to pick up the upgrade)?

### Version aliasing for isolated, independently-landable commits

The cross-version alias trick is the primary upgrade strategy. Each repo's upgrade commit adds the new version of the dependency and aliases the old version for cross-repo type boundaries. This makes each commit independently landable without any coordination.

```toml
# New version, used by this repo's own code.
reqwest = { version = "0.13", default-features = false, features = ["json", "query", "stream"] }
# Old version, aliased for cross-repo type boundaries only.
reqwest012 = { package = "reqwest", version = "0.12", default-features = false }
```

**Naming convention:** `{crate}{major}{minor}` (e.g., `reqwest012`, `dropshot015`).

The alias is only needed at **cross-repo type boundaries** where a type from the crate is explicitly passed to a generated client from another repo (e.g., `new_with_client()`). Repos that only use `Client::new(url)` (no custom client) don't need the alias.

### Local path patches for optional end-state validation

`[patch]` sections can optionally validate the clean end state (all repos upgraded, aliases removed) by pointing git deps to local checkouts. Never land these patches.

---

## Prerequisites

- **Detect VCS per repo.** Some Oxide repos use [Jujutsu](https://martinvonz.github.io/jj/) (`jj`), others use `git`. Check for a `.jj` directory at the repo root: if present, use `jj` commands; otherwise, use `git`. Apply this check independently per repo — don't assume they all use the same tool.
- **Update all repos to main/master first.** Before starting, update every in-scope repo so the working copy reflects the latest upstream state. This avoids discovering stale conflicts mid-upgrade.
  - **jj:** `jj git fetch` then `jj new main` (or `jj new master`).
  - **git:** `git fetch origin` then `git checkout main && git pull` (or `master`).

For VCS command equivalents (fetch, commit, push, diff), see [REFERENCE.md](REFERENCE.md).

---

## Workflow: generating the plan

Copy this checklist and check off items as you complete them:

```
Plan generation progress:
- [ ] Step 1: Inputs gathered (dependency, version, repos, paths)
- [ ] Step 2: Current state discovered per repo
- [ ] Step 3: Dependency graph built
- [ ] Step 4: Cross-repo type boundaries identified
- [ ] Step 5: Breaking changes documented
- [ ] Step 6: Upgrade scope determined
- [ ] Step 7: Plan document written
- [ ] Step 8: Plan presented for review
```

### Step 1: gather inputs

Ask the user:

1. **Which dependency** is being upgraded and **to what version**? (e.g., "progenitor 0.12, reqwest 0.13")
2. **Which repos** are in scope? Default: omicron, crucible, propolis, dendrite, maghemite, lldp.
3. **Where** are the repos checked out locally? Default: check in subdirectories of the current directory.

### Step 2: discover current state

For each repo, scan the workspace `Cargo.toml`:

- **Current version** of the target dependency (in `[workspace.dependencies]`).
- **Inter-repo git deps**: URL, branch/rev, crate names. Classify each as:
  - **Rev-pinned** (`rev = "abc123"`): consumer is insulated; must bump rev to pick up changes.
  - **Branch-tracking** (`branch = "main"` or default): consumer's `Cargo.lock` pins a commit; explicit `cargo update` needed to pick up changes.
  - **Unpinned** (no branch/rev): same as branch-tracking.
- **Existing `[patch]` sections** (commented or active).
- **Whether `Cargo.lock` is committed** (it should be; flag if not).

See [REFERENCE.md](REFERENCE.md) for commands to find inter-repo git deps.

### Step 3: build dependency graph

Map inter-repo dependencies as a directed graph. For each edge, record:

- Source repo and crate.
- Target repo and crate(s).
- Pin type (rev, branch, unpinned).

Identify cycles. These are expected and handled by the alias strategy.

### Step 4: identify cross-repo type boundaries

A *cross-repo type boundary* exists wherever a type from the upgrading crate is constructed in one repo and passed to code generated from another repo. The alias trick is only needed at these boundaries.

**How to find them:** look for places where a type from the upgrading crate appears in function signatures that cross repo boundaries. Common patterns:

- **Client injection:** a repo constructs a client (e.g., `reqwest::Client`) and passes it to a generated client from another repo via `new_with_client()` or similar.
- **Shared types in APIs:** a type from the crate (e.g., a `dropshot::ConfigDropshot`) is used in a trait or function defined in one repo but implemented/called in another.
- **Re-exported types:** one repo re-exports a type from the crate in its public API, and another repo consumes it.

For each match, determine:

- Whether the type originates from the upgrading crate.
- Whether it crosses a repo boundary (flows into a generated client, a trait defined in another repo, etc.).
- Which repo is on the other side of the boundary.

These locations need version aliases during the transition period. Locations where the crate is used purely within a single repo do not.

See [REFERENCE.md](REFERENCE.md) for search patterns to find cross-repo type boundaries.

### Step 5: document breaking changes

Read the changelog or migration guide for each dependency being upgraded. For each breaking change, document:

- **What changed** (renamed feature, removed API, changed type signature).
- **Which repos are affected** and which files need updates.
- **The fix** (old code → new code, old feature name → new feature name).

This feeds directly into the per-repo upgrade instructions in the execution plan. Missing a breaking change here means discovering it during `cargo check` later — better to find them upfront.

### Step 6: determine what needs upgrading

Compare current versions to target. For each repo, categorize:

- **Needs upgrade**: current version < target version.
- **Already upgraded**: current version >= target version (skip).
- **Partially upgraded**: some deps upgraded, others not. Note what remains and factor it into the plan.

### Step 7: generate the plan document

The plan document has two parts: a **strategy** section written for humans, and a **detailed execution plan** written for LLMs. Both go in the same file.

---

#### Part 1: strategy (for human review)

This section is what the human reads and approves. It should be concise — ideally fits on one screen. It covers the key decisions and risks without mechanical details.

Write this section at the top of the document under a `## Strategy` heading. It must include:

1. **Scope summary.** One-liner: what's being upgraded, from what version to what version, across which repos.

2. **Per-repo assessment.** A table with one row per repo:

   | Repo | Current version | Needs alias? | Why / boundary notes |
   |---|---|---|---|
   | crucible | 0.12 | Yes | `new_with_client` in `sled-agent` integration |
   | propolis | 0.12 | No | No cross-repo type boundaries |
   | omicron | 0.12 | Yes | Multiple client injection sites |

   "Needs alias?" is the key decision per repo — see "version aliasing" in core principles above. The "why" column is where the human can sanity-check the boundary analysis.

3. **Landing order.** A numbered list with brief rationale:
   1. crucible — fewest changes, unblocks propolis.
   2. propolis — depends on crucible landing first only for cleanup, not for initial upgrade.
   3. omicron — largest change set, land last.

4. **Cleanup order.** Non-omicron repos first, omicron last (because omicron needs to bump rev pins to the landed cleanup commits).

5. **Risks and open questions.** Anything the human should weigh in on: known API breakage, repos with uncommitted work, timing constraints, repos where the boundary analysis is uncertain.

6. **Progress checklist.** A markdown checklist tracking every actionable step across all phases. This is the resumable record of what's done and what remains, updated as work progresses.

   Generate the checklist with checkboxes (`- [ ]`) grouped by phase. For example:

   ```markdown
   ### Phase 1: isolated upgrade commits
   - [ ] crucible: upgrade commit created and pushed
   - [ ] propolis: upgrade commit created and pushed
   - [ ] omicron: upgrade commit created and pushed

   ### Phase 2: landing
   - [ ] crucible: PR created → PR landed
   - [ ] propolis: PR created → PR landed
   - [ ] omicron: PR created → PR landed

   ### Phase 3: cleanup (non-omicron first, omicron last)
   - [ ] crucible: targeted cargo update, alias removed, PR landed
   - [ ] propolis: targeted cargo update, alias removed, PR landed
   - [ ] omicron: rev pins bumped, aliases removed, PR landed
   ```

   Populate with the actual repos and steps from the plan.

---

#### Part 2: detailed execution plan (for LLMs)

This section is the mechanical reference an LLM follows during execution. It goes below the strategy under a `## Execution plan` heading. Humans can skip it; LLMs read it when doing the work.

See [EXECUTION-TEMPLATE.md](EXECUTION-TEMPLATE.md) for the full execution plan template covering phases 1 through 3.

---

### Step 8: present plan for review

Write the plan to a file (e.g., `upgrade-plan-{dep}-{version}.md` in the current directory) and present it to the user. Summarize the strategy section in the conversation so the human can review it without opening the file. Do NOT begin execution until the user approves the strategy.

---

## Guardrails

- **NEVER execute the upgrade without presenting the plan first.** The plan must be reviewed by a human.
- **NEVER assume the dependency graph is static.** Always scan `Cargo.toml` files dynamically.
- **NEVER do a bulk `cargo update`.** Always do targeted updates (e.g., `cargo update -p reqwest`), patiently adding as many individual packages as required.
