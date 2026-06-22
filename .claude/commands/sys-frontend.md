---
name: sys-frontend
description: The single canonical frontend ruleset — one global path-based reactive store, stable contract, our own state model
argument-hint: [frontend feature or state concern to apply the ruleset to]
allowed-tools: Read, Grep, Glob, Write
---

# FRONTEND RULESET

Apply this ruleset when designing or building any frontend state. It is the **single source of truth** for HOW frontend state is modeled. Read it before touching state; conform to it. Unlike backend critical concerns (which adopt mature external libraries — see `/sys-rules`), the frontend state layer is **our own model**, and its contract is **stable**: depend only on the public surface, never on internals, and never introduce a competing state mechanism.

Input: **$ARGUMENTS**

---

## GOAL

Single global state graph with path-based access, deterministic derivation, strict mutation boundaries, and isolated side effects.

---

## PRIORITY

1. State consistency
2. Mutation boundaries
3. Determinism
4. Side-effect isolation
5. Composition

---

## STATE MANAGEMENT — OUR MODEL, STABLE CONTRACT

State management is the **one deliberate exception** to "adopt a mature external library for critical concerns." The frontend state layer MUST be **our own model** — the path-based reactive store contract defined below. We do NOT swap in, wrap, or shadow an external state-management framework for it.

- **One model only.** All application state MUST flow through this store. No parallel or competing state mechanism (ad-hoc globals, component-local stores of record, a second library) is allowed to hold canonical state.
- **The contract is stable — treat it as frozen.** The store's public surface (the uniform path-addressed verbs — `get` / `set` / `update` / `delete` / `subscribe` / `compute` / `effect` / collection verbs / resource + handle APIs) is a long-lived contract. Features depend ONLY on this contract, never on internals.
- **Change is rare, deliberate, and backward-compatible.** Additive evolution is allowed; breaking the existing contract is a defect. A breaking change requires re-evaluating this ruleset first, then a versioned, migration-backed transition — never an in-place silent break.
- **Internals are free, the surface is not.** The implementation behind the contract MAY be refactored or optimized freely, as long as the observable contract and its semantics (path notifications, batching, determinism, dirty/draft/save behavior) are preserved exactly.
- **Stability beats convenience.** Do not add a new verb or option to solve a one-off; compose existing verbs. The contract grows only when a capability is genuinely missing and broadly needed.

### Concrete binding

- Prefer **`nanostores`** as the implementation of this model whenever it fits.
- In **Preact / React**, use **signals** when `nanostores` is not a good fit.
- Whichever is chosen, it MUST be used **through this store contract** — the surface and semantics above stay identical; the choice is an internal detail, never leaked to features.

---

## STATE MODEL

- ONE global state graph
- State accessed only by path

````ts
/**
 * Shared types for the path-based reactive store.
 *
 * Every value in the store is addressed by a dot-delimited {@link Path}
 * (e.g. `"user.first_name"`). These types are the common vocabulary shared by
 * every module, so they live in one place to keep the rest of the codebase DRY.
 */
/** A dot-delimited string addressing a node, e.g. `"user.first_name"`. */
type Path = string;
/** Called with the current value at a path whenever that path changes. */
type Listener<T = unknown> = (value: T) => void;
/** Returned by subscriptions/effects; call it to stop listening. */
type Unsubscribe = () => void;
/** Functional update: receives the current value, returns the next one. */
type Updater<T = unknown> = (current: T) => T;
/** Predicate used by collection helpers (`remove`). */
type Predicate<T = unknown> = (item: T) => boolean;
/** Mapper used by collection helpers (`map`). */
type Mapper<T = unknown, R = unknown> = (item: T) => R;
/** An immutable capture of the whole store state. */
interface Snapshot {
  state: Record<string, unknown>;
}
/**
 * The low-level reactive engine every feature module is built on.
 *
 * Feature modules (collections, reactive, resources, …) receive a `StoreCore`
 * and never touch global state directly — this is the single contract that
 * keeps the modules decoupled and independently testable.
 */
interface StoreCore {
  /** Read the value at `path` (`undefined` if absent). */
  get(path: Path): unknown;
  /** Write `value` at `path`, creating intermediate objects as needed. */
  set(path: Path, value: unknown): void;
  /** Functionally update the value at `path`. */
  update(path: Path, fn: Updater): void;
  /** Remove the value at `path`. */
  delete(path: Path): void;
  /**
   * Listen for changes at `path`. The listener fires after the value changes
   * (not immediately on subscribe). Changes to ancestors or descendants of
   * `path` also notify `path`, so subscribing to `"user"` reacts to
   * `"user.first_name"` edits and vice-versa.
   */
  subscribe(path: Path, fn: Listener): Unsubscribe;
  /** Coalesce all notifications produced inside `fn` into one flush. */
  batch(fn: () => void): void;
  /** Raw root state object (live reference — treat as read-mostly). */
  getState(): Record<string, unknown>;
  /** Replace the entire root state and notify every known path. */
  replaceState(state: Record<string, unknown>): void;
}
/** Resource status flags, surfaced under `<resource>.*` paths. */
interface ResourceStatus {
  loading: boolean;
  saving: boolean;
  error: unknown;
  dirty: boolean;
}
/** Configuration passed to `store.resource(path, config)`. */
interface ResourceConfig<T = unknown> {
  /** Fetch canonical state from the server. */
  load: () => Promise<T> | T;
  /** Persist the minimal change set. */
  save?: (changes: Partial<T>) => Promise<unknown> | unknown;
}

/**
 * Path handles — the optional ergonomic layer (spec §5).
 *
 * A handle binds a single path to an object exposing the uniform verbs, so you
 * don't repeat the path string. It's a thin delegator over the composed store:
 * it owns no state, only the bound path.
 */

/** The subset of the store a handle delegates to. */
interface HandleHost {
  get(path: Path): unknown;
  set(path: Path, value: unknown): void;
  update(path: Path, fn: Updater): void;
  delete(path: Path): void;
  subscribe(path: Path, fn: Listener): Unsubscribe;
  push(path: Path, value: unknown): void;
  remove(path: Path, predicate: Predicate): void;
  map(path: Path, mapper: Mapper): void;
  clear(path: Path): void;
  is_dirty(path: Path): boolean;
}
/** An object bound to one path, exposing the uniform API without the string. */
interface Handle {
  /** The path this handle is bound to. */
  readonly path: Path;
  get(): unknown;
  set(value: unknown): void;
  update(fn: Updater): void;
  delete(): void;
  subscribe(fn: Listener): Unsubscribe;
  push(value: unknown): void;
  remove(predicate: Predicate): void;
  map(mapper: Mapper): void;
  clear(): void;
  is_dirty(): boolean;
}
/** Bind `path` on `host`, returning a {@link Handle}. */
declare function create_handle(host: HandleHost, path: Path): Handle;

/**
 * Path-Based Reactive Store — public entry point.
 *
 * Implements the design in `nanostore.md`: one uniform, path-addressed API over
 * a reactive core, plus a resource layer with draft/dirty/save semantics.
 *
 * Composition wires two cores together:
 *  - `base`    — the reactive engine (state + subscriptions + batching).
 *  - `tracked` — `base` decorated with global undo/redo capture.
 *
 * User-facing mutations (`set`/`update`/`delete` and collection verbs) flow
 * through `tracked` so they're undoable. Derived and internal writes (computed
 * outputs, resource status flags) use `base` directly so global history records
 * intentful edits, not bookkeeping. Subscriptions all live on the shared base
 * registry, so everything reacts uniformly regardless of which core wrote.
 *
 * @example
 * ```ts
 * const store = create_store({ users: [], user: {} });
 * store.push("users", { id: 1 });
 * store.set("user.first_name", "john");
 * store.compute("user.full_name",
 *   ["user.first_name", "user.last_name"],
 *   (first, last) => `${first} ${last}`);
 * ```
 */

/** A value derivation dependency: a path string or a bound {@link Handle}. */
type Dep = Path | Handle;
/** The composed store returned by {@link create_store}. */
interface Store {
  get(path: Path): unknown;
  set(path: Path, value: unknown): void;
  update(path: Path, fn: Updater): void;
  delete(path: Path): void;
  subscribe(path: Path, fn: Listener): Unsubscribe;
  compute(
    path: Path,
    deps: Path[],
    fn: (...values: unknown[]) => unknown,
  ): Handle;
  compute(deps: Dep[], fn: (...values: unknown[]) => unknown): Handle;
  effect(deps: Path[], fn: (...values: unknown[]) => void): Unsubscribe;
  push(path: Path, value: unknown): void;
  remove(path: Path, predicate: Predicate): void;
  map(path: Path, mapper: Mapper): void;
  clear(path: Path): void;
  batch(fn: () => void): void;
  snapshot(): Snapshot;
  undo(path?: Path): void;
  redo(): void;
  schema(shape: Record<string, unknown>): void;
  path(path: Path): Handle;
  resource(path: Path, config: ResourceConfig): void;
  refresh(path: Path): Promise<void>;
  save(path: Path): Promise<void>;
  revert(path: Path): void;
  is_dirty(path: Path): boolean;
}
/** Create a store, optionally seeded with initial top-level values. */
declare function create_store(initial?: Record<string, unknown>): Store;

export {
  type Dep,
  type Handle,
  type HandleHost,
  type Listener,
  type Mapper,
  type Path,
  type Predicate,
  type ResourceConfig,
  type ResourceStatus,
  type Snapshot,
  type Store,
  type StoreCore,
  type Unsubscribe,
  type Updater,
  create_handle,
  create_store,
  create_store as default,
};
````
