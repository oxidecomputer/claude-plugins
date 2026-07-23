# v-api TypeScript client reference

How a TypeScript frontend authenticates against and calls a v-api service.
Reference clients: `rfd-site` (→ rfd-api), `careers` and `oxide-computer` (→ turnstile).
All three are **React Router v7** (framework mode, SSR) on Vercel, and all integration is **server-side** — the browser never talks to the API directly and never sees the access token.

Two npm packages, both generated/published from the **backend** repo, do the work:
- `@oxide/<svc>.ts` — the generated OpenAPI client (`@oxide/rfd.ts`, `@oxide/turnstile.ts`).
- `@oxide/remix-auth-<svc>` — `remix-auth` strategies wrapping v-api's OAuth + magic-link endpoints.

## 1. Generating the SDK (in the backend repo)

The backend is self-describing. A `cargo xtask generate` chains:
1. `cargo run -p <svc>-api -- describe` → writes `<svc>-api-spec.json` (the OpenAPI spec, straight from the server).
2. Rust SDK + CLI via **progenitor**.
3. TypeScript SDK via **`npx @oxide/openapi-gen-ts@<ver> <svc>-api-spec.json <svc>-ts/src --features zod[,msw]`** (Oxide's own generator, same one used for `oxide.ts`).

The generated package lives in the backend repo (`rfd-api/rfd-ts/`, `turnstile/turnstile-ts/`), is built with `tsup` to CJS+ESM, and published to npm.
A `--check` mode detects drift in CI. Frontends depend on the published package — they do **not** vendor or regenerate it.
Add a new endpoint on the backend → regenerate → bump the frontend's dependency.

Package subpath exports:
- `/client` — the `Api` class, `ApiResult`, and all generated types (including `RfdPermission` / `*_for_TurnstilePermission` — the TS projection of the backend permission enum).
- `/client-retry` — `ApiWithRetry` (retries once on `ECONNRESET`).
- `/validation` — generated Zod schemas.
- `/msw-handlers` — `makeHandlers` for contract-checked mocks (see §5).

## 2. The client factory + error mapping

Wrap the generated client in a `client(token?)` factory (host from env, optional Bearer token). Every call returns a discriminated `ApiResult`:

```ts
import { ApiWithRetry } from '@oxide/rfd.ts/client-retry'

export function client(token?: string): Api {
  return new ApiWithRetry({
    host: process.env.RFD_API!,
    token,                                   // SDK adds `Authorization: Bearer <token>`
    baseParams: { headers: { Connection: 'keep-alive' } },
  })
}

// ApiResult<T> = { type: 'success', data } | { type: 'error', data: ErrorBody } | { type: 'client_error', error }
// ErrorBody mirrors v-api's Error schema: { errorCode?, message, requestId }
export function handleApiResponse<T>(res: ApiResult<T>): T {
  if (res.type === 'success') return res.data
  if (res.response?.status === 401) throw new AuthenticationError()
  if (res.response?.status === 403) throw new AuthorizationError()
  throw new ApiError(res)
}
```
Calls are method-based: `client(token).methods.getSelf({})`, `.listListings({}, {})`, `.magicLinkSend({ path, body })`. Anonymous access = pass no token (v-api's unauthenticated caller applies).

## 3. Auth flows (via `remix-auth`)

Register strategies with a `remix-auth` `Authenticator`. Both flows end the same way: fetch the user, store `{ token, permissions, groups, expiresAt }` in a session cookie.

### OAuth authorization-code flow (careers, rfd-site)

`RfdOAuthStrategy`/`TurnstileOAuthStrategy` extend `remix-auth-oauth2` and point at v-api endpoints:
```
authorizationEndpoint: `${host}/login/oauth/${remoteProvider}/code/authorize`
tokenEndpoint:         `${host}/login/oauth/${remoteProvider}/code/token`
userInfoUrl:           `${host}/self`
```
```ts
auth.use(new RfdOAuthStrategy({
  host: process.env.RFD_API!,
  clientId: process.env.RFD_API_CLIENT_ID!,
  clientSecret: process.env.RFD_API_CLIENT_SECRET!,
  redirectURI: process.env.RFD_API_GOOGLE_CALLBACK_URL!,
  remoteProvider: 'google',                 // strategy name becomes `rfd-google`
  scopes: ['group:info:r', 'rfd:content:r', 'search', 'user:info:r'],
}, verify))
```
Route wiring: a login form POSTs to `/auth/google` → its action calls `auth.authenticate('rfd-google', request)` (redirects to v-api's authorize endpoint; PKCE + state handled by `remix-auth-oauth2`) → provider redirects to `/auth/google/callback` → that loader runs `auth.authenticate` again (exchanges code for token), runs `verify`, stores the user, redirects to `returnTo`.

### Magic-link flow (oxide-computer, rfd-site)

`RfdMagicLinkStrategy`/`TurnstileMagicLinkStrategy`, two phases by HTTP method:
- **POST** (login form submits email): `client().methods.magicLinkSend({ path: { channel: 'login' }, body: { medium: 'email', recipient: email, redirectUri: '<origin>/auth/magic/callback', secret: MLINK_SECRET, scope: scopes.join(' '), expiresIn } })`. Store `attemptId` + `email` in session, tell the user to check email.
- **GET** (emailed link hits the callback with `?code=`): `client().methods.magicLinkExchange({ path: { channel: 'login' }, body: { attemptId, recipient: email, secret: code } })` → returns the access token.

### The `verify` callback

After either flow yields a token, build the user:
```ts
async function verify({ token }): Promise<User> {
  const api = client(token)
  const self = handleApiResponse(await api.methods.getSelf({}))     // v-api /self
  const groups = handleApiResponse(await api.methods.getGroups({})) // resolve group UUIDs → names
  const { exp } = decodeJwt(token)   // decode ONLY to read exp for session expiry — do NOT verify (server enforces)
  return {
    id: self.info.id, token,
    permissions: getUserPermissions(self, groups),   // union direct + each group's permissions
    groups: self.info.groups, expiresAt: exp * 1000,
  }
}
```

## 4. Token & session handling

- **Storage:** the whole `User` (including `token`) goes into an **httpOnly, signed, `sameSite: 'lax'` session cookie** (`createCookieSessionStorage`, signed with `SESSION_SECRET`, `secure` in prod). Never localStorage; never exposed to client JS.
- **Attaching:** each loader/action reads `user` from the session and passes `user.token` into `client()`.
- **Expiry:** set the cookie's `expires` to the JWT `exp`. **No refresh** — when it expires the user re-authenticates. A 401 → `AuthenticationError` → redirect to login.
- **Scopes:** requested at login time (the `scopes` array / space-joined `scope`). The set must be a subset of what the user's permissions allow server-side.

## 5. Permission gating in the UI

The server always enforces authorization; the frontend replicates v-api's implication rules only to *show/hide* UI. rfd-site's `app/utils/permission.ts` implements `can(allPermissions, permission)`:
- `{GetRfd: n}` is satisfied by `{GetRfds: [n]}` or `GetRfdsAll` (mirrors the backend `implies`/`expand`).
- Object/tuple permission variants (`{GetRfd: number}`, `{ManageGroup: uuid}`) vs. string variants (`GetRfdsAll`, `SearchRfds`) come straight from the generated `RfdPermission` union.

Do not treat this as a security boundary — it's cosmetic. Enforcement is the backend's `caller.can(...)`.

## 6. Environment variables

No `.env.example` in these repos; the README + an env-check script are canonical. Typical set (rfd-site / careers naming):
- `<SVC>_API` / `<SVC>_HOST` — backend base URL (SDK host + OAuth host).
- `<SVC>_CLIENT_ID` / `<SVC>_CLIENT_SECRET` — OAuth client credentials (created via the API).
- `<SVC>_*_CALLBACK_URL` / `<SVC>_REDIRECT_URL` — OAuth callback URIs (`https://{host}/auth/{provider}/callback`).
- `<SVC>_MLINK_SECRET` / `TURNSTILE_SECRET` — magic-link client secret.
- `SESSION_SECRET` / `AUTH_COOKIE_SECRET` — cookie signing.
- Dev shortcuts: `LOCAL_RFD_REPO` (rfd-site reads local files, bypassing the API), `MOCK_API=1` (careers).

Local real-API dev pattern (careers README): authenticate with the CLI, then
`export TURNSTILE_API=$(turnstile-cli config get host)` and
`export TURNSTILE_API_TOKEN=$(turnstile-cli config get token)`.

## 7. Contract-checked mocks

The generated package ships MSW handler types.
careers mounts `makeHandlers(handlers)` from `@oxide/turnstile.ts/msw-handlers` at a route; a stub file 501s every endpoint by default, so a newly-added backend endpoint surfaces as a **TypeScript error** in the mock until implemented.
Strong pattern for keeping the frontend honest against the SDK.

## "Copy this" checklist for a new v-api TS client

1. Backend: `xtask generate` → `<svc> describe` (OpenAPI) → progenitor (Rust) + `@oxide/openapi-gen-ts` (TS); publish the TS package.
2. Frontend: `client(token?)` factory wrapping `ApiWithRetry` + a `handleApiResponse` mapping `ApiResult` → typed 401/403/5xx.
3. `remix-auth` + the v-api strategy pair: OAuth2 at `/login/oauth/{provider}/code/{authorize,token}` and/or magic link (`magicLinkSend`/`magicLinkExchange`).
4. On success: `getSelf` + `getGroups`, store `{token, permissions, groups, expiresAt}` in an httpOnly signed cookie, cookie expiry = JWT `exp`.
5. A small `can()` for UI gating; rely on the server for real enforcement.
