---
name: effective-rust
description: Apply Oxide's "Effective Rust" patterns (RFD 643) to push runtime errors into compile-time errors and make remaining runtime errors explicit. Use whenever writing, reviewing, or refactoring Rust — especially when you see newtype-able primitives (raw u32/u64/String/Uuid for domain values), enums with shared variant data, `Option<T>` or `bool` fields with implicit semantics, builder-style APIs, manual SQL/serialization that names struct fields, `as` casts, subscripting (`vec[i]`, `map[k]`), bare `unwrap()`/`expect()`, or runtime validation that could be encoded in types. Use proactively on Rust review and authoring; do not wait for the user to name the RFD.
---

# Effective Rust (RFD 643)

The goal is to use Rust's type system to make invalid program states either unrepresentable or, when they must exist, explicit at the point of failure. A constraint enforced by the type system is checked at every call site at compile time; a constraint enforced by a runtime check is only checked for the cases a test happens to cover.

When reviewing or writing Rust, ask continuously:

- Which runtime error paths could be checked at compile time instead?
- What application-level invariants does this code assume, and how could those be encoded in types?
- How could a future caller misuse this abstraction, and what guard rail prevents that?

Suggest changes that move checks earlier (compile time > construction time > use site). Don't suggest changes that just move code around without changing what the compiler can prove.

## When to engage

Engage when reading or writing Rust and you spot any of the patterns below. Frame suggestions as "this could push X into the type system" with the concrete refactor. Be concise — pattern-match, name the pattern from this skill, show the diff shape, explain *why* the new shape is harder to misuse.

Don't carpet-bomb: pick the highest-leverage suggestions. A function with five small issues gets one comment about the most impactful one, not five.

## Compile-time invariant patterns

### Newtypes

Wrap primitives that carry domain meaning. Look for:

- Raw `u64`/`usize` byte/time/count values → wrap so units can't be confused (`ByteCount`, `Mib`, `DurationMs`).
- Raw `Uuid` for things with a kind (instance id, sled id, project id) → use `newtype-uuid` (`TypedUuid<InstanceKind>` etc.). The Oxide convention is one kind per id type.
- Raw `String` for names, tags, identifiers → newtype with a validating constructor.

The objection "but it's obvious from the parameter name" is wrong at scale: it's not about *this* call site, it's about every call site in every code path, including ones added later.

### Parse, don't validate

When data crosses a boundary (network, disk, env, CLI), parse it once into a type whose existence proves the invariants hold. Don't re-check the invariants downstream. Concretely:

- Define a strict type whose constructor (or `Deserialize` impl, often via a "raw" type → `TryFrom`) validates.
- Downstream code accepts the strict type and assumes the invariants.
- Look for existing functions that take loose types and do `if x.is_empty()` / `if x.len() > N` / `if !x.contains('@')` checks — those are candidates to push into a type.

### Typestates

When one struct has methods that are only valid in some "mode" or "state," split into multiple types with explicit transitions. Builder pattern is one instance: `ServerBuilder::start(self) -> HttpServer` is better than `Server` with methods that error after start.

Smell: methods documented as "only valid before/after X" or returning `Err` for "wrong state."

### Named structs as enum variant data

Prefer

```rust
enum SiloUser {
    ApiOnly(SiloUserApiOnly),
    Jit(SiloUserJit),
    Scim(SiloUserScim),
}
```

over inline `enum Foo { Variant { fields... } }` *when* code needs to operate on a specific variant. The named struct lets functions accept `SiloUserJit` directly, eliminating runtime "wrong variant" checks. If no code ever specializes on a variant, inline fields are fine — don't introduce structs gratuitously.

### Token values for cross-cutting checks

When a precondition must be checked once and then carried through (auth check, `--destructive` flag, feature-flag enabled), encode it as a zero-sized token type whose constructor lives in a private module. Example: `DestructiveOperationToken(())` returned only by `Omdb::check_allow_destructive`. Functions that need the precondition take the token by value. Mark it `#[must_use]`.

This doesn't force callers to use the token, but if they do, the compiler enforces the precondition was checked.

### `#[must_use]`

Apply to:

- Tokens (above).
- Builder types where dropping mid-build is almost always a bug.
- Result-like wrappers that aren't `Result`.
- Newtypes where ignoring the value loses important computation.

### Full-struct destructuring as a compile barrier

When code names individual fields of a struct (custom serialization, manual SQL `bind`, hand-written hash, manual `Debug`), destructure the *whole* struct first and use the local bindings:

```rust
// Adding a field to Foo will fail to compile here, prompting an update.
let Foo { a, b, c } = *foo;
do_thing(a);
do_thing(b);
do_thing(c);
```

Add a brief comment explaining the destructure exists as a compile barrier. This is one of the highest-leverage patterns to suggest during review of serialization/DB code — a missed field there is a silent data-corruption bug.

### Const generics for type-level constants

When several values share a type but differ by a fixed constant (subnet prefix length, buffer size, version), parametrize with `const N: ...` so `Ipv6Subnet<48>` and `Ipv6Subnet<64>` cannot be confused.

## Making runtime errors explicit

These don't add static checks but eliminate silent failure modes.

### Avoid `as`

`as` performs silent lossy conversions. Prefer `From`/`Into` for lossless, `TryFrom`/`try_into` for fallible. The clippy lints `cast_lossless`, `cast_possible_truncation`, `cast_sign_loss` cover this.

Exception: bit-level casts in low-level code where the lossiness is the point — comment why.

### Avoid subscripting `Vec`/`HashMap`/`BTreeMap`

`vec[i]` and `map[k]` panic on miss. Prefer `.get(...)` returning `Option`. If you do unwrap, the unwrap site documents the assumption. Iterate with iterators (`.iter()`, `.iter().nth(i)`) rather than index loops.

### Document `unsafe`

Every `unsafe` block needs a `// SAFETY:` comment stating the invariant that makes it sound. The `clippy::missing_safety_doc` lint enforces this for `unsafe fn`.

### Document `unwrap`/`expect`

When unwrapping is justified, leave a comment naming the invariant that makes `None`/`Err` impossible. Format:

```rust
// unwrap: <reason this can't be None/Err>
```

Prefer `expect("reason")` over `unwrap()` when convenient — the message survives in panics. Avoid `unwrap()` for cases that can come up in production; return an error instead.

### Explicit enums over `Option<T>` and `bool`

`Option<T>` is right when "absent" has no further semantics (`first(&self) -> Option<&T>`). When `None` would mean something domain-specific (no policy = allow all? deny all? error?), use a named enum:

```rust
enum AccessPolicy {
    AllowAll,
    DenyAll,
    Restricted(IamPolicy),
}
```

Same for `bool` parameters and fields: `Verbosity::{Quiet, Verbose}` beats `verbose: bool` because the call site reads `Verbosity::Verbose` instead of `true`.

## How to deliver suggestions

When reviewing existing code, structure feedback as:

1. The pattern from this skill (e.g., "newtype opportunity").
2. The specific code location.
3. The concrete refactor (sketch the new type or signature).
4. *Why* the new shape is harder to misuse — what bug class it eliminates.

Don't quote this skill back at the user. Don't lecture. One or two sentences per suggestion is usually enough.

When writing new code, apply the patterns silently as the default. Mention them only if the user might reasonably have wanted the simpler shape (e.g., "I made this a newtype rather than a raw `u64` so callers can't mix it up with X — happy to inline if you'd rather").

## What this skill is not

- Not a general Rust style guide. Idiomatic-Rust questions (clippy lints, borrow checker, async patterns) are out of scope; only invoke this skill when the issue is about pushing invariants into the type system or making runtime errors explicit.
- Not a refactor-everything mandate. The patterns have costs (more types, more files, more imports). Apply where the leverage is high: boundaries, shared abstractions, code likely to be modified by people unfamiliar with the invariants. Inside a 20-line internal helper, raw types are fine.
