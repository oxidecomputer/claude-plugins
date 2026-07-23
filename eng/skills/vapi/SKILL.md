---
name: vapi
description: Build, extend, configure, or deploy an Oxide service on the v-api framework (v0.4.7) — the Rust framework behind rfd-api, mfg-support, and turnstile that provides OAuth/magic-link auth, API users, groups, permissions, mappers, API keys, and optional sagas on top of dropshot + diesel + Postgres. Also covers building the TypeScript frontend client (generated SDK + remix-auth) that authenticates against a v-api service. Use when creating a new v-api service, adding endpoints/permissions to an existing one, wiring OAuth providers or magic link, writing runtime config (config.toml/mappers.toml), deploying (systemd/Caddy), or building a React/Remix client for one.
---

# Building services on v-api

`v-api` is Oxide's framework for permissioned HTTP API services. It provides the "boring but load-bearing" parts — OAuth + magic-link authentication, JWT issuance, API users, access groups, a rich permission model, attribute-driven mappers, API keys, and optional sagas — so a service only has to write its own domain endpoints and tables. It sits on top of **dropshot** (HTTP), **diesel** (ORM), and **Postgres**.

This skill targets **v-api v0.4.7** (the current release). Do not reference APIs from older versions. The three reference services this skill is built from all pin `tag = "v0.4.7"`.

## When to use this skill

- Creating a **new** service on v-api.
- Adding endpoints, permissions, OAuth providers, mappers, or magic-link support to an **existing** v-api service (rfd-api, mfg-support, turnstile, or a new one).
- Writing or debugging a service's runtime config (`config.toml`/`settings.toml` + `mappers.toml`) or deployment (systemd/Caddy).
- Building or maintaining a **TypeScript frontend** that authenticates against and calls a v-api service.
- Upgrading a service to a new v-api version (pair this with the migration guide at `v-api/docs/migration/`).

## Reference services (read these for real, working patterns)

Four repos are the ground truth. When in doubt, copy from whichever is the closest match to the task:

| Repo | Role | Notable traits |
|---|---|---|
| `rfd-api` | RFD document API | **Simplest backend.** Sagas OFF. Google + GitHub OAuth + magic link. Its own storage traits are `impl`'d directly on v-api's `PostgresStore`. |
| `turnstile` | Applicant tracking (careers) | Sagas OFF (uses a bespoke `JobRunner` instead). Wraps `PostgresStore` in a `Storage` newtype. Full `v-cli-sdk` CLI. `CallerExtension` for "self" permissions. |
| `mfg-support` | Manufacturing support | **Heaviest.** Sagas ON with a custom background spawner. Richest permission enum. Separate model + parallel domain storage layer. |
| Their configs | `corp-services/services/{rfd-api,mfg-support,turnstile}/` | Real `config.toml`/`settings.toml`, `mappers.toml`, systemd units, Caddyfiles. |

TypeScript clients (all React Router v7 / SSR on Vercel, all consume a generated `@oxide/<svc>.ts` SDK + `@oxide/remix-auth-<svc>` strategy package published from the backend repo):

| Client | Backend | Auth method used |
|---|---|---|
| `rfd-site` | rfd-api | OAuth code (Google + GitHub) **and** magic link |
| `careers` | turnstile | OAuth code (Google) |
| `oxide-computer` | turnstile | magic link (email) — only its `/careers` area |

## The mental model

A v-api service is three layers:

1. **`VContext<YourPermission>`** — the framework core, built once at startup by `VContextBuilder`. It owns auth, users, groups, mappers, oauth, magic-link, (optional) sagas, and storage. Exposed as sub-contexts: `v_ctx.user`, `v_ctx.group`, `v_ctx.oauth`, `v_ctx.mapping`, `v_ctx.magic_link`, `v_ctx.login`, `v_ctx.link`, and `v_ctx.saga` (sagas feature only).
2. **Your app context** (e.g. `RfdContext`) — a dropshot `ServerContext` that wraps `Arc<VContext<YourPermission>>` as one field alongside your own domain sub-contexts and storage. It implements the **`ApiContext`** trait, which is the single load-bearing hook: `fn v_ctx(&self) -> &VContext<Self::AppPermissions>`. This is what lets any handler call `rqctx.v_ctx().get_caller(&rqctx)`.
3. **Storage** — one Postgres connection pool serving both v-api's tables and yours. Reuse v-api's `PostgresStore` (`v_model::storage::postgres::PostgresStore`); do **not** implement `VApiStorage` yourself.

The permission enum is the spine. You define `YourPermission` with the `#[v_api(From(VPermission))]` derive macro, which folds v-api's built-in system permissions (user/group/mapper/oauth/api-key management) into your enum and generates all the scope/implication/expansion machinery. Every endpoint extracts a `Caller<YourPermission>` and checks `caller.can(&YourPermission::Something.into())`.

## Building a new service — workflow

Copy this checklist:

```
- [ ] Step 1: Workspace + dependencies (pin tag = "vX.Y.Z")
- [ ] Step 2: Define YourPermission enum
- [ ] Step 3: Storage — reuse PostgresStore, add your own domain Store traits
- [ ] Step 4: App context implementing ApiContext
- [ ] Step 5: VContextBuilder wiring at startup
- [ ] Step 6: OAuth providers + magic link (post-build)
- [ ] Step 7: Initial data (groups + mappers) from mappers.toml
- [ ] Step 8: Endpoints — inject v-api's, register your own
- [ ] Step 9: Migrations (v-api first, then yours)
- [ ] Step 10: CLI subcommands (start / migrate / describe / validate)
- [ ] Step 11: Runtime config (config.toml)
- [ ] Step 12: TypeScript SDK generation + client (if needed)
- [ ] Step 13: Deployment (systemd + Caddy)
```

The three steps that trip people up, in brief (full detail in the reference files):

- **Step 5 → 6 ordering.** `VContextBuilder::build()` requires storage, `public_url`, and `keys` (and `with_saga_backend` if the `sagas` feature is on). OAuth providers, magic-link messengers, caller extensions, and extra unauthenticated permissions are added **after** `build()` by mutating the `VContext`, *before* you wrap it in `Arc`. This is easy to miss because it's not on the builder.
- **Step 8 macros.** `v_system_endpoints!(YourContext, YourPermission)` at module scope + `inject_endpoints!(api)` inside your `api_description()` fn. Both take **two** identifiers now — the v-api README's single-arg example is stale.
- **Step 9 ordering.** Always run `v_model::migrations::run_migrations(url)` (v-api's tables) *before* your own embedded migrations. They share the `__diesel_schema_migrations` table.

The reference services diverge deliberately — start from the one closest to your needs rather than assembling from scratch:
- Minimal, no sagas → **rfd-api**
- Has a CLI, wraps storage in a newtype → **turnstile**
- Needs sagas / background work → **mfg-support**

## Detailed references

Load the reference file that matches what you're doing:

- **[reference/backend.md](reference/backend.md)** — the full v-api API surface: crate layout, `VContextBuilder` (every method, required vs optional), storage traits & `PostgresStore`, the permission system and `#[v_api(...)]` derive attributes in depth, OAuth provider trait & flows, mappers (preset vs dynamic), the endpoint-injection macros, `ApiContext`, migrations, and Cargo feature flags. Includes copy-paste code for each of the 10 build steps.

- **[reference/config-and-deploy.md](reference/config-and-deploy.md)** — the runtime config contract (`config.toml`/`settings.toml`), the `mappers.toml` bootstrap format (groups + preset mappers), KMS vs local signing keys, per-service config differences, and deployment (systemd units, Caddy, migrations as an operational step). Includes real redacted examples and known gotchas (e.g. stale `ExecStart` subcommands in some units).

- **[reference/typescript-client.md](reference/typescript-client.md)** — building the frontend: generating the TS SDK from the backend's OpenAPI spec (`cargo xtask generate` → `@oxide/openapi-gen-ts`), the `client(token?)` factory + `ApiResult` error mapping, `remix-auth` OAuth-code and magic-link strategies against v-api endpoints, storing the token in an httpOnly session cookie, and reimplementing permission checks for UI gating.

## Guardrails

- **Never implement `VApiStorage` from scratch.** Reuse `PostgresStore`. Add only your own domain `*Store` traits, `impl`'d on `PostgresStore` (rfd-api style) or on a `Storage` newtype wrapping it (turnstile style), against the same pool.
- **Never omit the v-api migrations.** Your service's migrations layer on top of v-api's in a shared migrations table; run v-api's first.
- **Pin to a v-api git tag** (`tag = "v0.4.7"`), not a floating branch. Keep a commented-out `[patch."https://github.com/oxidecomputer/v-api"]` block for local co-development.
- **Decide sagas up front.** `sagas` is a default feature; opt out with `default-features = false` (rfd-api, turnstile) or keep it and add `with_saga_backend` + the saga migrations (mfg-support). Switching later is disruptive.
- **Keep two config files.** Runtime config (`config.toml`) and bootstrap data (`mappers.toml`) are separate and loaded separately. Don't merge them.
- **Verify `ExecStart` against the binary's actual `--help`.** Some committed systemd units in corp-services are stale (missing the `start` subcommand).
