# M0 — Loader + DOM builder + `dump-dom`

**Status:** done. 13 tests pass (`raco test tests/`).
**Spec reference:** `docs/SPEC.md` §2 (Loader, DOM builder), §3, §12.

## What exists

| File | Lines | Role |
|---|---|---|
| `src/loader.rkt` | ~60 | `load-page : path -> datum`. `read`s the file, requires exactly one top-level `(document ...)` form. Raises `exn:fail:page` with a readable message otherwise. |
| `src/dom.rkt` | ~200 | `node` struct, `register!`, `build-dom`, `node-table` / `id-index` / `next-id` / `document-dirty?`, lookups, `dump-dom`. |
| `src/driver.rkt` | ~170 | `run` / `repl` entry points; commands `dump-dom inspect ids stats reload help quit`. |
| `pages/hello.sx` | | the §3 fixture, canonical |
| `pages/nested.sx` | | deeper nesting, mixed text/element children, inline `span` |
| `pages/bad-not-document.sx` | | negative fixture for the loader |
| `tests/dom-test.rkt` | | rackunit coverage of all the above |

`style.rkt layout.rkt paint.rkt present.rkt bindings.rkt runtime.rkt` are
empty stubs so the §11 layout exists.

## Decisions & deviations from the spec sketch

Each of these is cheap to reverse now and expensive later — flag any you
disagree with.

1. **`handle` is a field on `node`.** The spec's struct had no handle field
   and `register!` returned the handle. Storing it on the node makes
   node→handle O(1) (needed constantly by `dump-dom`, `inspect`, and later
   by every host procedure that returns a handle) without a reverse table.
   `register!` therefore returns the *node*; callers read `node-handle`.

2. **Handles are dense pre-order integers, root = 0.** The spec's trace uses
   `root→1, btn→3` illustratively; actual numbering is whatever
   `register!` hands out. Pre-order means you can read `dump-dom` top to
   bottom and the handles count up, which is nice for the operator. M4's
   `create-element` will continue from `next-id`, so handles are never
   reused within a session.

3. **`(style …)` and `(script …)` are not walked.** Their bodies are kept
   verbatim as a list of forms in the node's `text` field. Rationale:
   `(rule (tag body) …)` is not an element and must not be turned into
   `rule` / `tag` nodes; same for `(on! …)` / `(lambda …)`. `dump-dom`
   summarises them as `style (3 rules)` / `script (1 form)`; `inspect`
   shows the raw forms.

   Consequence: the `text` field is now `#f | string | list`. If that
   overload bothers you, the alternative is a separate `body` field.

4. **Text nodes have tag `'text`.** Not in the MVP element set, so no
   collision. Alternative was a distinct struct; one struct keeps the
   handle table homogeneous.

5. **Attribute names are symbols, values kept as written.** `(id "root")`
   → `(id . "root")`. `id-index` is keyed by the value as written, so
   scripts will call `(get-element "root")` with a string, matching the
   spec's `h:get-element id-str`. If a page writes `(id root)` (a symbol),
   it will be indexed under the symbol and `(get-element "root")` will
   miss. Decide: coerce to string at build time, or leave strict?

6. **REPL is a command dispatcher, not `eval`.** Unknown commands say so;
   known-but-not-yet-implemented commands (`render`, `click`, …) say which
   milestone they belong to. This keeps every REPL transcript an honest
   record of what the build can do.

7. **`build-dom` resets all tables.** So `(reload)` is `load-page` +
   `build-dom`; no incremental rebuild. Correct for M0–M3; M4 needs to
   also clear `listeners` and tear down the sandbox — noted for then.

## How to verify (the §8 check)

```sh
racket src/driver.rkt run pages/hello.sx
```

Expected:

```
#0 document
  #1 head
    #2 title
      #3 "Hello"
  #4 body
    #5 div [id="root" class="container"]
      #6 p
        #7 "Hello, world"
      #8 button [id="btn"]
        #9 "Click me"
    #10 style (3 rules)
    #11 script (1 form)
```

Then, in the REPL:

- `(inspect "btn")` — parent should be `#5 div`, one text child `#9`.
- `(inspect 10)` — should print the three `rule` forms verbatim.
- Edit `pages/hello.sx` (e.g. add a second `p`), `(reload)`, `(dump-dom)` —
  handles after the insertion point should shift by one.
- `racket src/driver.rkt run pages/bad-not-document.sx` — should print a
  one-line page error, exit code 1, no stack trace.

## Things to try / break

- A page with `(@ …)` not in first position — currently builds it as a
  child element named `@`. Should that be an error?
- Nested `(style …)` inside a `div` — currently allowed anywhere, kept raw.
  M1 will have to decide whether to collect rules from anywhere or only
  from `body`/`head`.
- Duplicate ids — last one wins in `id-index` silently. Warn?
- Non-string, non-list children, e.g. `(p 42)` — build error. Coerce numbers
  to text?
- Empty file, two top-level forms, unbalanced parens — all should give a
  `page error:` line, never a Racket backtrace.

## Feedback wanted before M1

1. Any of the seven decisions above you want reversed.
2. Whether the `dump-dom` format is what you want to be reading for the
   next four milestones (it's the primary debugging surface until ascii
   render lands). Alternatives: SXML-style `(div (@ …) …)` echo, or a
   `tag#handle` compact form.
3. Whether `(@ …)`-out-of-position and duplicate ids should be errors,
   warnings, or ignored.
