# v-api config & deployment reference

Runtime configuration and deployment for a v-api service. Real examples are from `corp-services/services/{rfd-api,mfg-support,turnstile}/` (secrets redacted). Each service keeps **two** config files plus a systemd unit and a Caddyfile.

## The runtime config contract

Every v-api service shares this core, deserialized into an `AppConfig` struct that embeds v-api's own config types (`v_api::config::{AuthnProviders, AsymmetricKey, JwtConfig, ServerLogFormat}`). Config is loaded with the `config` crate (file + `Environment` overlay); a `--config` path overrides the default search locations.

```toml
log_format = "json"                       # json | pretty
log_directory = "/var/log/<svc>"
public_url = "https://<svc>.shared.oxide.computer"
server_port = 8080
database_url = ""                         # full Postgres URL (secret)
initial_mappers = "/etc/<svc>/mappers.toml"

[jwt]
default_expiration = 604800               # seconds (rfd-api 2wk, mfg/turnstile 1wk)

# --- Signing keys: one signer + one verifier. KMS in prod, local PEM in dev. ---
[[keys]]
kind = "ckms_signer"                      # GCP Cloud KMS
kid = "<svc>-api-1"
version = 1
key = "<kms-key-name>"
keyring = "<kms-keyring>"
location = "us-west1"
project = "<gcp-project>"

[[keys]]
kind = "ckms_verifier"
kid = "<svc>-api-1"
version = 1
key = "<kms-key-name>"
keyring = "<kms-keyring>"
location = "us-west1"
project = "<gcp-project>"

# Local dev alternative (also works alongside KMS, as mfg-support does for a local verifier):
# [[keys]]
# kind = "local_signer"
# kid = "local"
# private = "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
# [[keys]]
# kind = "local_verifier"
# kid = "local"
# public = "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----\n"
```

### OAuth providers

Under `[authn.oauth.<provider>]` where provider is `google`, `github`, or `zendesk`. Each of `device`, `web`, `proxy_web` is **optional** and independent. Credential fields are `remote_client_id`/`remote_client_secret` (the upstream provider's app credentials); `client_id` (where present) is the **internal v-api OAuthClient UUID**.

```toml
# Device flow — proxied through v-api; needs an internal client id.
[authn.oauth.google.device]
client_id = "<v-api OAuthClient UUID>"
remote_client_id = "<...>.apps.googleusercontent.com"
remote_client_secret = ""                 # secret; or { path = "/run/parameters/..." }

# Web (authorization code) flow — redirect_uri is derived from public_url, not configured.
[authn.oauth.google.web]
remote_client_id = "<...>.apps.googleusercontent.com"
remote_client_secret = ""

# PKCE-only public client (e.g. a CLI callback).
[authn.oauth.google.proxy_web]
client_id = "<v-api OAuthClient UUID>"
redirect_uri = "http://localhost:PORT/callback"
proxy_port = 8910
```

`remote_client_secret` is a `StringParam` — an inline string or `{ path = "..." }` resolved against the `param_path`.

### Magic link

```toml
[magic_link.email_service.resend]
key = ""                                  # Resend API key (secret)

[[magic_link.templates]]
medium = "email"
channel = "login"                         # channel name your client sends to
from = "noreply@oxidecomputer.com"
subject = "Complete your authentication - Oxide"
text = "Use this link to finish authentication: {{ url }}"     # {{ url }} for browser, {{ token }} for CLI
html = """<a href="{{ url }}">Sign in</a>"""
```

Multiple templates per service are allowed (mfg-support has `frontend` + `cli` channels; turnstile has `apply`). Empty `templates` = magic link disabled.

## The `mappers.toml` bootstrap file

Loaded separately (path from `initial_mappers`) into groups + preset mappers, applied idempotently at startup. This is how a service grants initial admin access and domain-based default access without seeding the DB by hand.

```toml
[[groups]]
name = "admin"
permissions = [
  "GetApiUsersAll", "CreateApiUser", "ManageApiUsersAll",
  "GetGroupsAll", "CreateGroup", "ManageGroupMembershipsAll", "ManageGroupsAll",
  "GetMappersAll", "CreateMapper", "ManageMappersAll",
  "CreateOAuthClient", "GetOAuthClientsAll", "ManageOAuthClientsAll",
  "CreateMagicLinkClient", "GetMagicLinkClientsAll", "ManageMagicLinkClientsAll",
  # ... plus your app-specific *All permissions
]

[[groups]]
name = "default"
permissions = ["GetApiUserSelf", "GetGroupsJoined"]

# Grant a single named human admin (repeat per person, as mfg-support does 6x).
[[mappers]]
name = "Initial admin"
rule = "email_address"
email = "you@oxidecomputer.com"
groups = ["admin"]

# Grant everyone in a domain a role.
[[mappers]]
name = "Oxide users"
rule = "email_domain"
domain = "oxidecomputer.com"
groups = ["oxide-employee"]

# Catch-all for unmapped users.
[[mappers]]
name = "default"
rule = "default"
groups = ["default"]        # turnstile maps default -> "oxide-applicant" instead
```

Mapper rule kinds: `email_address`, `email_domain`, `github_username`, `default`. The permission strings must exactly match your permission enum's variant names (including injected v-api ones).

## Deployment

### systemd unit

```ini
[Unit]
Description=<Service>
After=network.target network-online.target
Requires=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=exec
User=<svc>
Group=<svc>
Environment=RUST_LOG=info
Environment=GOOGLE_APPLICATION_CREDENTIALS=/etc/<svc>/gcp.json
ExecStart=/usr/bin/<svc>-api start --config /etc/<svc>/settings.toml
Restart=always
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
```

`<svc>-api start --config <path>`

### Secrets

Kept out of the TOML (empty-string placeholders);
injected via `Environment=GOOGLE_APPLICATION_CREDENTIALS=...` (GCP creds for KMS)
other `Environment=` vars, or filled in post-deploy.
Keep the config file as _shape_, secrets separate.

### Migrations

**Not automated in any current deployment** — no `ExecStartPre`, no init container. Each binary has a `migrate` subcommand run manually against `database_url`:

```
<svc>-server migrate --config /etc/<svc>/settings.toml        # or --database-url ...
<svc>-server migrate --v-only ...                              # only v-api's migrations
```

Recommendation for a new service: wire this as `ExecStartPre=` or a one-shot systemd unit rather than leaving it fully manual.

### Reverse proxy (Caddy)

TLS-terminating reverse proxy to `127.0.0.1:8080` with gzip/zstd and file access logging. mfg-support runs two site blocks (API on `:8080`, Next.js frontend on `:3000`).

### Operational gotcha

turnstile's deploy note bumps Postgres `max_connections` from 100 → 200 — `PostgresStore`'s pool is `max_size = 50`, so a couple of service instances plus tooling can exhaust the default. Size Postgres connections against the pool.
