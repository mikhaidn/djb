# Scheme Browser — Init Brief & MVP Spec

**Purpose:** a from-scratch browser engine where **Scheme replaces JavaScript** as the in-page scripting language. Not a real-web browser — it renders its own s-expression document format. This is a learning/research engine, scoped tight enough to reach a working end-to-end loop fast.

**Audience:** this document is an init brief for the implementing agent. It defines the architecture, the MVP boundary, the binding layer in detail, and a manual driver so the human operator can open, run, and assess the software at every milestone without a GUI stack.

---

## 1. Design decisions (read these first)

Three choices shape everything:

1. **The document format is s-expressions.** A page is a Scheme datum. The "HTML parser" is `read`. The parsed datum, once given mutable node records, *is* the DOM. This deletes an entire hard subsystem.

2. **Scripts mutate; they never draw.** Page scripts get host procedures that read/mutate the live node tree and register event handlers. Mutation sets a **dirty flag**. After a handler returns, the event loop re-runs style → layout → paint → present. Scripts cannot call the renderer directly. This is the "live tree driven by script" model, and it's the core of what makes this feel like a browser.

3. **Scripts run in a sandboxed child interpreter** handed a fixed set of host procedures. DOM nodes are exposed as **integer handles** into a host-owned node table — never as raw host structs. This keeps the sandbox from reaching into engine internals and makes stale-handle detection trivial.

---

## 2. Architecture / pipeline

```
 .sx file
   │  read                 (step 1: "parsing" is free)
   ▼
 raw datum ──► DOM build ──► style ──► layout ──► paint ──► present
                 │            │         │          │          │
              node table   computed   box tree   draw ops   output
              (id→node)     styles    (geometry)            (dump/ascii/img)
                 ▲
                 │  host procedures (get/mutate/on!)
                 │
             script sandbox  ◄──── events (from driver REPL)
```

Subsystems, each independently testable:

- **Loader** — `read` the file into a datum.
- **DOM builder** — convert datum into mutable `node` records with parent pointers; register each in the node table; assign handles.
- **Style** — match stylesheet rules to nodes, compute final style per node (cascade is minimal at MVP; see §9).
- **Layout** — walk the styled tree, produce a box tree with `(x y w h)` per box. Block flow + naive inline only.
- **Paint** — walk box tree, emit draw ops (filled rects, text runs).
- **Present** — draw ops → output tier (§7).
- **Script runtime + binding layer** — §4. The heart of the project.
- **Driver** — §6. How the human runs and inspects everything.

---

## 3. Document & stylesheet format

A page (`page.sx`):

```scheme
(document
  (head (title "Hello"))
  (body
    (div (@ (id "root") (class "container"))
      (p "Hello, world")
      (button (@ (id "btn")) "Click me"))
    (style
      (rule (tag body)   (background-color "white") (padding 10))
      (rule (class container) (background-color "#cceeff") (padding 20) (width 400))
      (rule (id btn)     (background-color "#3366cc") (color "white") (padding 8)))
    (script
      (on! (get-element "btn") "click"
        (lambda (ev)
          (set-text! (get-element "root") "Clicked!"))))))
```

Node grammar: `(tag (@ (attr value) ...) child ...)`. A bare string is a text node. `(@ ...)` is optional and, if present, is always the first child. This is essentially SXML — a well-trodden convention, so the builder can borrow from existing SXML handling.

Stylesheet: a `(style ...)` element containing `(rule (selector) (prop value) ...)`. MVP selectors: `(tag name)`, `(class name)`, `(id name)`. No descendant/combinator selectors at MVP.

Script: a `(script ...)` element whose body is evaluated once in the sandbox after DOM build, with the host procedures in scope. Handlers registered via `on!` fire later.

---

## 4. The binding layer (the meat)

This is the part worth getting right. Host-side, in the engine's own Scheme:

```scheme
;; A live DOM node.
(struct node (tag
              [attrs    #:mutable]   ; alist
              [children #:mutable]   ; list of node
              [parent   #:mutable]
              [text     #:mutable]   ; #f unless a text node
              [style    #:mutable])) ; computed style, filled by §style

;; Indirection table: the sandbox only ever sees the integer keys.
(define node-table (make-hash))          ; integer handle -> node
(define id-index   (make-hash))          ; DOM "id" attr   -> integer handle
(define next-id    (box 0))
(define document-dirty? (box #t))
(define listeners  (make-hash))          ; (handle . event-type) -> (listof proc)

(define (register! n)
  (define h (unbox next-id))
  (hash-set! node-table h n)
  (set-box! next-id (add1 h))
  (let ([id (assoc 'id (node-attrs n))])
    (when id (hash-set! id-index (cdr id) h)))
  h)
```

Host procedures injected into the sandbox. Every mutating one flips the dirty flag — that single line is the repaint trigger:

```scheme
(define (h:get-element id-str)
  (hash-ref id-index id-str #f))              ; -> integer handle or #f

(define (h:text-content h)
  (node-text (hash-ref node-table h)))

(define (h:set-text! h str)
  (set-node-text! (hash-ref node-table h) str)
  (set-box! document-dirty? #t))              ; <── triggers re-render

(define (h:get-attribute h name)
  (cond [(assoc name (node-attrs (hash-ref node-table h))) => cdr]
        [else #f]))

(define (h:set-attribute! h name val)
  (define n (hash-ref node-table h))
  (set-node-attrs! n (cons (cons name val)
                           (remove* (list (assoc name (node-attrs n)))
                                    (node-attrs n))))
  (set-box! document-dirty? #t))

(define (h:create-element tag)
  (register! (node tag '() '() #f #f #f)))    ; returns a fresh handle

(define (h:append-child! parent-h child-h)
  (define p (hash-ref node-table parent-h))
  (define c (hash-ref node-table child-h))
  (set-node-children! p (append (node-children p) (list c)))
  (set-node-parent! c p)
  (set-box! document-dirty? #t))

(define (h:on! h event-type proc)
  (hash-update! listeners (cons h event-type)
                (lambda (ps) (cons proc ps)) '()))
```

Wiring the sandbox (Racket `racket/sandbox`; Guile's `(ice-9 sandbox)` is the analog):

```scheme
(require racket/sandbox)
(define ev
  (make-evaluator 'racket/base
    #:allow-for-load '()          ; no filesystem
    ;; bind host procs into the script's namespace:
    #:namespace-specs (list ...)))
;; Expose get-element, set-text!, on!, create-element, append-child!, etc.
;; as h:* under their public names, then evaluate the page's (script ...) body.
```

The event loop — the other half of the mechanism:

```scheme
(define (dispatch ev-type target-handle)
  (for ([proc (hash-ref listeners (cons target-handle ev-type) '())])
    (proc (make-event ev-type target-handle))))   ; runs page's Scheme handler

(define (tick! ev-type target-handle)
  (dispatch ev-type target-handle)
  (when (unbox document-dirty?)
    (set-box! document-dirty? #f)
    (relayout!) (repaint!) (present!)))            ; the re-render
```

**End-to-end trace** (this is the whole point):
1. DOM build registers `btn`→handle 3, `root`→handle 1.
2. Script runs once: `on!` records a click listener on handle 3.
3. Operator types `(click "btn")` in the driver REPL → `tick! "click" 3`.
4. `dispatch` runs the handler; `set-text!` on handle 1 mutates the node and sets `document-dirty? = #t`.
5. `tick!` sees the flag, re-runs layout+paint+present.
6. Operator sees "Clicked!" in the next render.

MVP repaints the whole document on any dirty. Subtree invalidation is a later optimization — deliberately out of scope.

---

## 5. Script API surface (MVP)

Injected names available to page scripts:

| Procedure | Effect |
|---|---|
| `(get-element id) → handle\|#f` | look up by DOM id |
| `(text-content handle) → str` | read text |
| `(set-text! handle str)` | set text, mark dirty |
| `(get-attribute handle name) → val\|#f` | read attr |
| `(set-attribute! handle name val)` | set attr, mark dirty |
| `(create-element tag) → handle` | new detached node |
| `(append-child! parent child)` | attach, mark dirty |
| `(remove-child! parent child)` | detach, mark dirty |
| `(on! handle event-type proc)` | register listener |

One event type at MVP: `"click"`. `proc` receives an event record `(event type target)`.

---

## 6. Manual driver (open / run / assess)

The operator interface. Two entry points.

**One-shot:**
```
$ scheme-browser run page.sx
```
Loads, renders once to the default output tier, prints it, exits.

**Interactive REPL** (the primary assessment tool):
```
$ scheme-browser repl page.sx
browser> (render)            ; produce/print current output
browser> (dump-dom)          ; pretty-print the live DOM tree
browser> (dump-boxes)        ; box tree with (x y w h) per box
browser> (inspect "root")    ; one node: tag, attrs, computed style, text
browser> (click "btn")       ; synthetic event → dispatch → auto re-render
browser> (set-output 'ascii) ; switch tier: 'dump | 'ascii | 'image
browser> (reload)            ; re-read the file from disk
browser> (quit)
```

Synthetic events replace a windowing/mouse stack entirely — the operator *is* the input device. This is what makes every milestone assessable by hand.

---

## 7. Output tiers

Build in this order; each is a strict superset of assessment power:

1. **`dump`** (do first, zero deps) — `dump-dom` + `dump-boxes`. Text trees. Lets you verify structure, styles, and geometry numerically before any pixels exist.
2. **`ascii`** — scale each box's `(x y w h)` onto a character grid; fill with a per-element glyph (e.g. first letter of tag, or a class-mapped char). Dependency-free, and genuinely shows layout.
3. **`image`** (optional at MVP) — rasterize filled rects to a PPM/PNG. Text starts as filled rectangles of the right width; real font rendering is deferred.

Recommendation: ship `dump` + `ascii` for the MVP. Defer `image` and real fonts.

---

## 8. Milestone ladder (each rung has a manual check)

| # | Deliverable | Operator verifies |
|---|---|---|
| **M0** | Loader + DOM builder + `dump-dom` | `(dump-dom)` prints the tree matching the `.sx` file |
| **M1** | Style matching + compute + `inspect` | `(inspect "btn")` shows the expected computed style |
| **M2** | Block+inline layout + `dump-boxes` | `(dump-boxes)` shows sane non-overlapping geometry |
| **M3** | Paint + `ascii` present | `(render)` draws recognizable boxes in the grid |
| **M4** | Sandbox + binding layer + event loop | `(click "btn")` then auto re-render shows the mutation |
| **M5** | Dynamic DOM (`create`/`append`/`remove`) | a script that adds a node → node appears on re-render |

Reaching **M4** is the real milestone: it's the first moment the thing is a *browser* rather than a static renderer.

---

## 9. MVP scope boundary

**In:**
- Elements: `document head title body div p span button` + text nodes.
- Attributes: `id class`.
- CSS props: `display` (`block`/`inline`/`none`), `width`, `height`, `margin`, `padding`, `background-color`, `color`.
- Selectors: `tag`, `class`, `id`. Last-rule-wins conflict resolution (no specificity math yet).
- Layout: block flow (vertical stacking) + naive inline text runs. Fixed viewport width.
- Script API of §5; one event type (`click`).
- Output: `dump` + `ascii`.

**Explicitly out (deferred, do not build yet):**
- Real networking (load local files only).
- HTML/CSS compatibility, real CSS cascade/specificity, inheritance beyond a hardcoded few.
- Floats, flexbox, grid, positioning, z-index, overflow.
- Real fonts / text shaping / image decoding.
- Subtree-scoped invalidation (whole-doc repaint is fine).
- Multiple event types, bubbling/capture, default actions.
- Any JS. This engine has none, by design.

---

## 10. Tech recommendations

- **Engine language: Racket** for MVP speed — `racket/sandbox` gives you the child-interpreter-with-injected-procedures story for free, plus good structs, hashes, and tooling. **Guile** is the alternative if you want future alignment with Hoot/WebAssembly (its `(ice-9 sandbox)` is the analog). **Chez** if you want minimal and fast and don't mind building the sandbox yourself.
- **Sandbox is not optional polish** — it's the cleanest expression of the binding-layer design. Use the platform's sandbox facility rather than `eval` into the host namespace.
- **Node handles as integers**, not structs, across the sandbox boundary. Validate on every host-proc entry.

---

## 11. Suggested repo layout

```
scheme-browser/
  src/
    loader.rkt      ; read .sx -> datum
    dom.rkt         ; node struct, builder, node-table, handles
    style.rkt       ; rule matching + compute
    layout.rkt      ; box tree + geometry
    paint.rkt       ; box tree -> draw ops
    present.rkt     ; draw ops -> dump | ascii | image
    bindings.rkt    ; host procedures (h:*), dirty flag, listeners
    runtime.rkt     ; sandbox setup, event loop, dispatch
    driver.rkt      ; CLI + REPL (run / repl entry points)
  pages/
    hello.sx        ; the §3 example — first test page
  tests/
    *.rkt
  README.md
```

---

## 12. First-commit instructions for the implementing agent

1. Scaffold the repo layout above.
2. Implement **M0** only: `loader.rkt`, the `node` struct + builder + node-table in `dom.rkt`, and `(dump-dom)` in a minimal `driver.rkt` REPL.
3. Use `pages/hello.sx` (the §3 example) as the fixture.
4. Stop at M0 and report: show the operator the `(dump-dom)` output so they can confirm the tree before layout work begins.

Proceed one milestone at a time; do not skip ahead to painting before `dump-boxes` produces correct geometry. The binding layer (M4) should not be started until M0–M3 give a static render the operator has visually confirmed.
