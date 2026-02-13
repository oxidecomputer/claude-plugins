# Execution plan template

This is the template for Part 2 of the plan document (the detailed execution plan for LLMs). When generating the plan, include this content under a `## Execution plan` heading, populated with repo-specific details.

---

## Standing rules

- **NEVER do a bulk `cargo update`.** Always do targeted updates (e.g., `cargo update -p reqwest`), patiently adding as many individual packages as required. A bulk update pulls in unrelated version changes that muddy the diff, risk breakage, and make the PR harder to review.
- **Use the correct VCS per repo.** Check for a `.jj` directory at the repo root: if present, use `jj`; otherwise, use `git`. Every VCS command in the plan must match the repo's tool.

## Phase 1: per-repo isolated upgrade commits

Each repo gets a single, independently-landable commit. The commit upgrades the repo's own code to the new dependency version while preserving compatibility with git deps that still use the old version, by using the cross-version alias trick.

For each repo that needs upgrading, specify a commit that does:

1. **Add the new version** of the dependency to `[workspace.dependencies]`:
   ```toml
   reqwest = { version = "0.13", default-features = false, features = ["json", "query", "stream"] }
   ```

2. **Add a cross-version alias for the old version** if the repo has cross-repo type boundaries (identified in step 4). Example:
   ```toml
   reqwest012 = { package = "reqwest", version = "0.12", default-features = false }
   ```
   Skip this for repos with no cross-repo type boundaries for the upgrading crate.

3. **Update source code** to use the new version for the repo's own code. At cross-repo type boundaries, use the alias instead:
   ```rust
   // Before: passes a reqwest 0.12 Client to a cross-repo generated client.
   let client = reqwest::Client::new();
   nexus_client::Client::new_with_client(url, client);

   // After: use the alias for cross-repo boundary, new version everywhere else.
   let client = reqwest012::Client::new();
   nexus_client::Client::new_with_client(url, client);
   ```
   Specify exact source code changes (file, line, old code, new code).

4. **Feature changes**: any features that must be added/removed for the new version.

5. **Expected compilation fixes**: note any known API changes from the version upgrade.

6. **Verify** with `cargo check`. Because `Cargo.lock` insulates repos from each other, each commit compiles against the git deps' current (old-version) state without needing `[patch]` sections. If `cargo check` fails:
   - **API changes in the new version:** read the crate's changelog or migration guide. Document each required source change in the plan (file, old code, new code).
   - **Trait impl mismatches:** often caused by a type from the old version being passed where the new version is expected, or vice versa. This usually means a cross-repo type boundary was missed — add an alias for it.
   - **Feature flag changes:** some crates rename, split, or remove features across major versions. Compare the old and new `Cargo.toml` of the dependency to identify changes.
   - Include all compilation fixes in the plan so reviewers can see the full scope of source changes.

**Key property:** each commit is self-contained and can be landed in any order. No `[patch]` sections, no temporary branches, no coordination between repos.

## Phase 1.5: optional local validation with patches

This phase is optional and only needed to validate the **clean end state** (all repos on the new version, aliases removed) before landing anything.

For each repo, temporarily add `[patch]` sections pointing inter-repo git deps to local checkouts of the other upgraded repos. Run `cargo check` to verify everything compiles together at the target state. **Do not commit or land these patches.**

## Phase 2: landing

For each repo in the landing order from the strategy section, specify:
- PR title and description.
- Any post-landing steps (e.g., "after landing, downstream repos X and Y can `cargo update` to pick up the change").

## Phase 3: cleanup

**Cleanup landing order:** non-omicron repos first, omicron last. During the initial upgrade (phase 1), each repo's commit is independently landable in any order. But during cleanup, order matters: non-omicron repos must land their cleanup PRs first so that omicron can then bump rev pins to those landed commits.

1. For each non-omicron repo that used version aliases (land these first):
   - **Targeted `cargo update`** to pick up the landed upgrades from upstream repos. Update only the specific packages from those repos, e.g.:
     ```bash
     cargo update -p omicron-common -p nexus-client -p sled-agent-client
     ```
     This may require listing many individual packages. Patiently enumerate all of them; run `cargo check` after each round to see if more are needed.
   - Remove the alias from `[workspace.dependencies]` (e.g., delete the `reqwest012 = ...` line).
   - Change `aliasname::` to `cratename::` in source (e.g., `reqwest012::` back to `reqwest::`).
   - `cargo check` to verify.
   - PR and land.
2. For omicron (or whichever repo uses rev pins) — land last:
   - Bump all rev pins to pick up the landed cleanup commits from step 1.
   - **Targeted `cargo update -p`** for each bumped dependency's packages.
   - Remove any version aliases that are no longer needed.
   - `cargo check` to verify.
   - PR and land.
