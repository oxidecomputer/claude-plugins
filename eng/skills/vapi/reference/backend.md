# v-api backend reference (v0.4.7)

The complete API surface for building a Rust service on v-api, organized as copy-paste steps. All paths are relative to a v-api checkout unless noted. Real usage lives in `rfd-api`, `turnstile`, and `mfg-support`.

## Crate layout

The `v-api` workspace publishes these crates (depend on them by git tag):

| Crate | Purpose |
|---|---|
| `v-api` | The framework: `VContext`/`VContextBuilder`, dropshot endpoint handlers + injection macros, authn (JWT/API-key), OAuth providers, magic link, mappers, config types (`AuthnProviders`, `AsymmetricKey`, `JwtConfig`). |
| `v-model` | Data models (diesel structs), schema, embedded migrations, the `*Store` storage traits, the `PostgresStore` reference impl, and the core `Permission`/`Permissions`/`Caller`/`PermissionStorage` types. Owns the optional `saga` submodule. |
| `v-api-permission-derive` | The `#[v_api(...)]` proc-macro. Generates `PermissionStorage`, `AsScope`, and `From<VPermission>` impls and injects the built-in system-permission variants. |
| `v-api-param` | File-or-inline config values for secrets (`StringParam`), resolved via a param base path. |
| `v-cli-sdk` | Reusable clap commands for a CLI client: `auth login` (OAuth device/code + magic link), `config get/set`, output printer. |
| `dropshot-authorization-header` | Request extractors for `Authorization: Basic`/`Bearer` headers. |

## Step 1: Workspace + dependencies

Pin every v-api crate to the same git tag. In `[workspace.dependencies]`:

```toml
v-api = { git = "https://github.com/oxidecomputer/v-api", tag = "v0.4.7", default-features = false }
v-model = { git = "https://github.com/oxidecomputer/v-api", tag = "v0.4.7" }
v-api-permission-derive = { git = "https://github.com/oxidecomputer/v-api", tag = "v0.4.7" }
v-cli-sdk = { git = "https://github.com/oxidecomputer/v-api", tag = "v0.4.7" }
dropshot-authorization-header = { git = "https://github.com/oxidecomputer/v-api", tag = "v0.4.7" }

# Uncomment to develop against a local v-api checkout:
# [patch."https://github.com/oxidecomputer/v-api"]
# v-api = { path = "../v-api/v-api" }
# v-model = { path = "../v-api/v-model" }
# v-api-permission-derive = { path = "../v-api/v-api-permission-derive" }
# v-cli-sdk = { path = "../v-api/v-cli-sdk" }
```

**Sagas decision (do this now):**
- Sagas OFF (rfd-api, turnstile): `default-features = false` on `v-api` (its default feature set is `["sagas"]`).
- Sagas ON (mfg-support): add `features = ["sagas"]` to `v-api`, `v-model`, and `v-api-permission-derive`.

Expose a `local-dev` passthrough feature so consumers can enable v-api's dev conveniences:
```toml
[features]
local-dev = ["v-api/local-dev"]
```

Recommended crate split (mirrors all three references): a `-model` crate (depends on `v-model` only) for domain models + storage + migrations; a `-api` crate (depends on `v-api`) for context + endpoints + server; optionally a `-cli` crate (depends on `v-cli-sdk`).

## Step 2: Define your permission enum

The derive macro folds v-api's built-in `VPermission` variants (CreateApiUser, Get/ManageApiUser(s), ApiKey*, Group*, ManageGroupMembership*, Mapper*, OAuthClient*, MagicLinkClient*, CreateAccessToken, RetrieveRemoteAccessToken, and — under `sagas` — GetSagasAll/ManageSagasAll) into your enum via `From(VPermission)`.

```rust
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use strum::EnumIter;
use v_api::permissions::VPermission;
use v_api_permission_derive::v_api;

#[v_api(From(VPermission))]
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema, EnumIter)]
pub enum RfdPermission {
    // Per-id read; contributes into the GetRfds bulk variant when stored.
    #[v_api(contract(kind = append, variant = GetRfds), scope(to = "rfd:content:r"))]
    GetRfd(i32),

    // Bulk (set) variant; expands into per-id GetRfd checks at auth time.
    #[v_api(
        contract(kind = extend, variant = GetRfds),
        expand(kind = iter, variant = GetRfd)
        scope(to = "rfd:content:r")
    )]
    GetRfds(BTreeSet<i32>),

    // "Assigned to me" — expands using the caller's own already-known grants.
    #[v_api(
        expand(kind = alias, variant = GetRfd, source = actor),
        scope(to = "rfd:content:r", from = "rfd:content:r")
    )]
    GetRfdsAssigned,

    // Umbrella "all" permission. Use implies(...) to satisfy narrower checks.
    #[v_api(
        implies(variant = GetRfd),
        implies(variant = GetRfds),
        implies(variant = GetRfdsAssigned),
        scope(to = "rfd:content:r", from = "rfd:content:r")
    )]
    GetRfdsAll,

    #[v_api(scope(to = "search", from = "search"))]
    SearchRfds,
}
```

### `#[v_api(...)]` attribute vocabulary

On the **enum**: `From(SourceEnum)` — generate `From<SourceEnum>`, `AsScope`, and `PermissionStorage` impls, and inject the source enum's variants.

Per-**variant** (comma-separated, composable):

- `contract(kind = append|extend|drop|replace, variant = Target)` — how granted permissions are compacted for storage. `append` folds `GetRfd(id)` into a `GetRfds({ids})` collector; `extend` merges two collectors; `drop` discards the concrete value (recomputed via `expand`).
- `expand(kind = alias|iter|replace, variant = Target, source = actor|ext, ext = TypeName, field = id|groups|<field>)` — how a stored permission expands into concrete permissions at auth time.
  - `alias` — pull matching concrete grants from the actor's permission set (`GetRfdsAssigned`).
  - `iter` — emit one concrete variant per element of a set field (e.g. actor's `groups`).
  - `replace` — substitute a single field from `actor` or from a typed request extension (`source = ext, ext = Applicant, field = id` — see "self" permissions below).
- `implies(variant = Target)` — holding this permission satisfies a `can()` check for `Target`. Used mainly on `*All` variants. Positional field comparison when both carry fields, else wildcard. Backs `PermissionStorage::implies`.
- `scope(to = "scope:str", from = "scope1 scope2")` — OAuth scope string mapping for `AsScope`. `"full"` is reserved (all permissions, must be exclusive); `""` means zero permissions.

Register all variants as "additional builtin permissions" at startup (requires `EnumIter`):
```rust
.with_additional_builtin_permissions(RfdPermission::iter().collect())
```
`EnumIter` yields default/empty-payload instances of data-carrying variants — that's fine here; the builder wants the *shape* of each permission, and this set defines what the registration/unauthenticated callers may hold and grant.

### Checking permissions in handlers

`Caller<T>` and `Permissions<T>` (from `v_model::permissions`) offer:
```rust
caller.can(&RfdPermission::GetRfd(id).into())       // held directly OR via implies()
caller.can_grant(&perm)                              // may the caller grant this?
caller.can_grant_all(&new_permissions)               // all-of can_grant — use before granting
caller.any(perms.iter())  /  caller.all(perms.iter())
```
Because of `implies`, prefer a single `caller.can(...)` over `caller.any([narrow, broad])` disjunctions. Before any endpoint that grants permissions or group membership, gate on `caller.can_grant_all(&perms)` — the registration user must itself hold every permission it hands out (pass that full set to the builder).

## Step 3: Storage

**Reuse `PostgresStore`.** It implements every `*Store` trait v-api needs (`ApiUserStore`, `ApiKeyStore`, `AccessTokenStore`, `LoginAttemptStore`, `OAuthClient*Store`, `AccessGroupStore`, `MapperStore`, `MapperEventStore`, `LinkRequestStore`, `MagicLink*Store`, and `Saga*Store` under the sagas feature). The `VApiStorage<T>` supertrait has a blanket impl, so `PostgresStore` satisfies it automatically. Do not reimplement it.

For your **own** domain tables, add a small store trait and implement it against the same pool. Two idioms:

**rfd-api style** — `impl` your traits directly on `PostgresStore`:
```rust
use v_model::storage::postgres::PostgresStore;
#[async_trait] impl RfdStore for PostgresStore { /* diesel queries on self.pool */ }
#[async_trait] impl JobStore for PostgresStore { /* ... */ }
```

**turnstile style** — wrap it in a newtype exposing the pool:
```rust
use v_model::storage::postgres::PostgresStore;
#[derive(Clone)] pub struct Storage(PostgresStore);
impl TurnstileStore for Storage { fn pool(&self) -> &Pool<...> { &self.0.pool } }
impl From<PostgresStore> for Storage { fn from(v: PostgresStore) -> Self { Self(v) } }
```
Only implement `PermissionStorage`/`MapperEventStore`/`VApiStorage` by hand if you are writing a genuinely custom backend (none of the three references do).

## Step 4: App context implementing `ApiContext`

Your dropshot context wraps `Arc<VContext<YourPermission>>` and implements `ApiContext` (from `v_api`, defined in `v-api/src/context/mod.rs`):

```rust
pub trait ApiContext: ServerContext {
    type AppPermissions: VAppPermission;
    fn v_ctx(&self) -> &VContext<Self::AppPermissions>;
}
```

```rust
pub struct RfdContext {
    v_ctx: Arc<VContext<RfdPermission>>,
    pub storage: Arc<dyn RfdStorage>,
    // ... your domain sub-contexts, search clients, etc.
}
impl ApiContext for RfdContext {
    type AppPermissions = RfdPermission;
    fn v_ctx(&self) -> &VContext<RfdPermission> { &self.v_ctx }
}
```
`RequestContext<T: ApiContext>` also implements `ApiContext`, so handlers call `rqctx.v_ctx().get_caller(&rqctx).await?` to get an authenticated, authorized `Caller<RfdPermission>`.

## Step 5: `VContextBuilder` at startup

```rust
let storage = Arc::new(PostgresStore::new(&config.database_url).await?);
let mut builder = VContextBuilder::<RfdPermission>::new()
    .with_public_url(config.public_url.clone())     // REQUIRED
    .with_storage(storage.clone())                   // REQUIRED (xor with_storage_url)
    .with_keys(std::mem::take(&mut config.keys))     // REQUIRED
    .with_jwt_expiration(config.jwt.default_expiration)
    .with_additional_builtin_permissions(RfdPermission::iter().collect());
if let Some(param_path) = param_path.clone() {
    builder = builder.with_param_path(param_path);   // base dir for secret resolution
}
// Sagas ON only:
// builder = builder.with_saga_backend(node_id, None);  // REQUIRED when sagas feature enabled
let mut v_ctx = builder.build().await?;
```

Builder methods: `new`, `with_param_path`, `with_service_name`, `with_jwt_expiration`, `with_public_url`, `with_storage(Arc<dyn VApiStorage<T>>)`, `with_storage_url(String)` (builder constructs `PostgresStore` for you), `with_keys(Vec<AsymmetricKey>)`, `with_mappers(Vec<PresetMapperConfig>)`, `with_saga_backend(node_id, Option<Logger>)` (sagas only), `with_additional_builtin_permissions(Vec<T>)`, `build() -> Result<VContext<T>, _>`.

`build()` errors if: both/neither storage set, no `public_url`, no `keys`, or (sagas on) no saga backend. It resolves keys into JWKS/signers/verifiers, builds all sub-contexts, and converts preset mappers into `Mapper`s with deterministic UUIDv5 ids.

## Step 6: OAuth + magic link (AFTER build, before Arc)

The `VContext` is still mutated after `build()`. Do this before wrapping in `Arc`.

**OAuth providers** — built-in: `GitHub`, `Google`, `Zendesk` (in `v-api/src/endpoints/login/oauth/remote/`). Register a lazy factory:
```rust
use v_api::endpoints::login::oauth::{OAuthProviderName, remote::github::GitHubOAuthProvider};
if let Some(github) = config.authn.oauth.github {
    let cfg = github.resolve(param_path.as_deref())?;   // ResolvedOAuthConfig
    let public_url = config.public_url.clone();
    v_ctx.insert_oauth_provider(OAuthProviderName::GitHub, Box::new(move || {
        Box::new(GitHubOAuthProvider::new(cfg.clone(), public_url.clone(), None))
    }));
}
```
Each provider takes `(ResolvedOAuthConfig, public_url: String, additional_scopes: Option<Vec<String>>)`. Config sub-sections (`web`, `device`, `proxy_web`) are each optional and resolved independently — see config-and-deploy.md for the TOML shape.

**Magic link** — register a message builder + messenger per template (optional; skip entirely to disable):
```rust
v_ctx.magic_link.set_message_builder(target.clone(), MagicLinkMessageBuilder { env });
v_ctx.magic_link.set_messenger(target, ResendMagicLink::new(key, from));
```

**Caller extensions** (for "self" permissions) — turnstile registers a handler that stashes the caller's domain record into request extensions, powering `expand(kind = replace, source = ext, ext = Applicant, field = id)`:
```rust
v_ctx.user.add_extension_handler(Arc::new(CallerAsApplicant { ctx }));
```

**Extra unauthenticated permissions** (e.g. public read):
```rust
v_ctx.add_unauthenticated_caller_permission(RfdPermission::SearchRfds);
```

Then: `let v_ctx = Arc::new(v_ctx);`

## Step 7: Initial data (groups + mappers)

Seed groups and mappers from `mappers.toml` at startup, idempotently (tolerate unique-violation "already exists"). Deserialize into small app structs wrapping v-api's `MappingRulesData<T>`:
```rust
use v_api::mapper::MappingRulesData;
#[derive(Deserialize)]
pub struct InitialMapper {
    pub name: String,
    #[serde(flatten)] pub rule: MappingRulesData<RfdPermission>,  // "email_address" | "email_domain" | ...
    pub max_activations: Option<u32>,
}
```
On init: `ctx.group.create_group(&ctx.builtin_registration_user(), NewAccessGroup { .. })` and `ctx.mapping.add_mapper(&ctx.builtin_registration_user(), &new_mapper)`. See mfg-support/rfd-api `initial_data.rs`.

## Step 8: Endpoints

Inject all of v-api's system endpoints, then register your own, onto one `ApiDescription`:
```rust
use v_api::{inject_endpoints, v_system_endpoints};

v_system_endpoints!(RfdContext, RfdPermission);   // module scope; TWO args (README's 1-arg form is stale)

fn api_description() -> ApiDescription<RfdContext> {
    let mut api = ApiDescription::new().tag_config(/* ... */);
    inject_endpoints!(api);                         // v-api: users, groups, mappers, oauth, magic-link, jwks, .well-known
    api.register(list_rfds).expect("register");     // your endpoints
    api.register(view_rfd).expect("register");
    api
}
// Sagas ON: also v_saga_endpoints!(Ctx, Perm); + inject_v_saga_endpoints!(api);
```
The `v_system_endpoints!` macro must be in the same module as `inject_endpoints!` (it defines the handler fns those register). Built-in endpoint groups: `api_user` (self, users, API keys, group membership, contact email, provider link), `group`, `login/oauth/*`, `login/magic_link/*`, `mappers`, `well_known` (`/.well-known/openid-configuration`, `/.well-known/jwks.json`), and `saga` (sagas only). There is no separate api-key module — key endpoints live in `api_user`.

Your endpoints follow this shape:
```rust
#[endpoint { method = GET, path = "/rfd/{number}" }]
pub async fn view_rfd(
    rqctx: RequestContext<RfdContext>,
    path: Path<RfdPathParams>,
) -> Result<HttpResponseOk<Rfd>, HttpError> {
    let ctx = rqctx.context();
    let caller = ctx.v_ctx().get_caller(&rqctx).await?;
    let num = path.into_inner().number;
    if !caller.can(&RfdPermission::GetRfd(num).into()) {
        return Err(HttpError::for_forbidden(None, "no access".into()));
    }
    Ok(HttpResponseOk(ctx.storage.get_rfd(num).await?))
}
```
Not every endpoint must use v-api auth — rfd-api has an HMAC-verified GitHub webhook on the same `ApiDescription`. Add a test that just calls `api_description()` to catch route/operation-id conflicts at build time.

## Step 9: Migrations

v-api's migrations first, then yours (shared `__diesel_schema_migrations` table):
```rust
use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};
const MIGRATIONS: EmbeddedMigrations = embed_migrations!("migrations");

pub fn run_migrations(url: &str, v_only: bool) {
    v_model::migrations::run_migrations(url);   // v-api core + (sagas) saga migrations, feature-gated
    if !v_only {
        let mut conn = /* connect */;
        conn.run_pending_migrations(MIGRATIONS).unwrap();
    }
}
```
`v_model::migrations::run_migrations(url: &str)` runs core migrations (`v-model/migrations/`) and, when the `sagas` feature is on, saga migrations (`v-model/src/saga/migrations/`). The `--v-only` flag (run only v-api's migrations) is useful for staged rollouts. turnstile instead *validates* pending migrations at startup and fails fast rather than auto-migrating — pick auto-migrate vs. fail-fast consciously.

## Step 10: CLI subcommands

A clap CLI with at least `start`/`run`, `migrate [--v-only]`, `describe` (emit OpenAPI spec — needed for SDK generation), `validate`, `version`. Take config via `--config`/`-c`, not a bare positional (some old deployments do the latter — don't copy that).

## Feature flags

- `v-api`: `default = ["sagas"]`, plus `local-dev` (enables `POST /login/local` mock login) and `sagas` (pulls `slog`/`steno`, saga storage bounds, `VContext::saga`, saga endpoints, saga permission variants).
- `v-model`: `mock` (generates `Mock*Store` via mockall — tests only) and `sagas`.
- `v-api-permission-derive`: `sagas` (whether the macro injects `GetSagasAll`/`ManageSagasAll`).

## Sagas (mfg-support pattern)

If `sagas` is on: define a `SagaType` marker (`type ExecContextType = YourContext`), write steno `Action`s, hold an `Arc<ActionRegistry<YourSaga>>` in your context, and drive `v_ctx.saga.create_saga(...)`/`.start_saga(...)`. mfg-support adds a custom `SagaBackgroundSpawner` (app code, not part of v-api) that polls and self-schedules background sagas, raced against the dropshot server via `tokio::select!`. Note mfg-support added a `saga_idempotency` migration to guard against double-creating background sagas — make background generators idempotent.

## Data model notes for v0.4.7 (from the migration guide)

- Permission checks use **implication** (`can()`), not strict equality. Grant operations enforce `can_grant_all`.
- OAuth: PKCE is mandatory for code flows; device flow is proxied through v-api; scopes are a space-delimited string in the JWT `scp` claim (`""`=none, `"full"`=all). Providers take `ResolvedOAuthConfig` + `public_url`.
- API key `permissions` field is named `permission_boundary` in Rust/JSON (DB column stays `permissions`) — it's an upper bound, not a grant.
- Omitting `scope` yields **zero** permissions (not a default). Use `"full"` for all.
- Preset mappers live in memory (config-driven, deterministic UUIDv5, can't be deleted via API); dynamic mappers are DB-backed via the API.
