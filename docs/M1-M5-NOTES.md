# M1–M5 + popup window

**Status:** done. 54 tests pass (`raco test tests/`), plus an opt-in GUI
smoke test. **Spec reference:** `docs/SPEC.md` §2, §4–§9.

The ask was "a working popup browser". Getting there meant finishing the
static pipeline (M1–M3), the script/event loop (M4), dynamic DOM (M5), and
then a window on top. Each rung is still assessable without the window.

## What exists

| File | Role |
|---|---|
| `src/style.rkt` | `compute-styles!`: collects `(rule ...)` forms from every `(style ...)`, matches `tag`/`class`/`id`, last rule wins, `color` inherits. Every node gets an immutable hasheq. |
| `src/layout.rkt` | `layout-document`: block flow + inline runs → `lbox` tree with absolute `(x y w h)`. `box-at` hit-tests. `dump-boxes`. Pluggable `text-measurer`. |
| `src/paint.rkt` | `paint`: box tree → `(rect x y w h color tag)` / `(text x y w h str color)` ops in paint order. |
| `src/present.rkt` | tiers `dump`, `ascii`, `image`; `draw-ops!` (shared by image tier and window); `make-text-measurer` from real font metrics. |
| `src/bindings.rkt` | the `h:*` host procedures, `listeners`, `event` struct. Handles validated on every entry; every mutator sets `document-dirty?`. |
| `src/runtime.rkt` | `racket/sandbox` evaluator with the host procs spliced in as definitions; `run-scripts!`, `dispatch!`, `tick!`. |
| `src/gui.rkt` | `open-window`: frame + Reload button + status line + scrolling canvas, in its own eventspace. Engine-agnostic: gets `paint`/`on-click`/`on-reload` callbacks. |
| `src/driver.rkt` | `run` / `repl` / `gui` entry points, `render-pipeline!`, the REPL commands, the click → tick → re-render → refresh glue. |
| `pages/counter.sx` | sandbox state across events (`set!` on a closed-over counter) |
| `pages/todo.sx` | M5: `create-element` / `set-attribute!` / `append-child!` / `remove-child!` |

## How to verify

```sh
racket src/driver.rkt gui pages/hello.sx      # click the button: "Clicked!", button gone
racket src/driver.rkt gui pages/counter.sx    # +1 / reset
racket src/driver.rkt gui pages/todo.sx       # Add / Clear; scrollbar appears when the list grows
```

Headless equivalents: `racket src/driver.rkt run pages/todo.sx` (ascii),
then in `repl`: `(click "add")` `(click "add")` `(dump-boxes)` `(inspect 17)`.
`(screenshot "x.png")` rasterizes without a display.

GUI smoke test (needs a display; on Linux CI use xvfb):

```sh
DJB_GUI_TEST=1 raco test tests/gui-smoke.rkt
xvfb-run -a env DJB_GUI_TEST=1 raco test tests/gui-smoke.rkt
```

## Decisions & deviations — flag any you disagree with

1. **`set-text!` on an element replaces its children with one text node**
   (DOM `textContent` semantics). The spec sketch set `node-text` on the
   element, which our DOM has no meaning for (`text` is `#f` on elements).
   Consequence: hello.sx's handler makes the button disappear, as it would
   in a real browser. The old children stay in `node-table` (handles are
   never reused), just detached.

2. **Handlers run through `call-in-sandbox-context`.** A handler is a
   closure created inside the sandbox; calling it directly from the host
   would run it under the *host's* security guard. Routing it through the
   evaluator keeps the filesystem ban and the time/memory limit (`5s / 50MB`
   per evaluation, `script-eval-limits`) in force at event time too. There's
   a test for each.

3. **Host procs are spliced into the sandbox as literal values**
   (`(ev `(define set-text! ,h:set-text!))`). No module path, nothing for
   the sandbox to `require`, nothing to whitelist. The sandbox language is
   plain `racket/base`, so scripts have `define`, `set!`, `for-each`,
   strings, lists.

4. **Sizes are content-box.** `width 400` + `padding 20` → an outer box 440
   wide, like CSS. `margin`/`padding` are single numbers for all sides; no
   shorthand lists yet. Margins don't collapse.

5. **One text box per word.** Text is split on whitespace; each word is a
   `'text` lbox with its own `(x y w h)`, so `dump-boxes` shows exactly
   where each word landed and hit-testing a word is exact. Whitespace
   between fragments is a pending-space flag (leading/trailing whitespace
   of a text node matters, as in HTML), so `"Para " (span ...) " inside"`
   spaces correctly and `(button "A") (button "B")` don't.

6. **Inline boxes are unions.** An inline element's box is the union of its
   fragments plus its padding, even across a wrap (then it's a rectangle
   spanning both lines and may start 1×padding left of the content edge).
   Continuation lines start at the content edge without repeating the
   padding, as CSS does. Inline `width`/`height` are ignored; a block
   inside an inline is laid out as inline.

7. **Text measurement is pluggable, and the window switches it.** The
   default measurer is 8px/char × 18px/line, so `dump-boxes`, `ascii`, and
   the tests are deterministic. Opening the window, `(screenshot ...)`, or
   the `image` tier installs `make-text-measurer` over the real font and
   re-renders, so what you click is what was laid out. It's one-way for the
   session: after `(gui)`, `dump-boxes`/`ascii` use real metrics too, so
   their numbers differ from a fresh `run`.

8. **ascii tier: rects fill with a glyph per tag** (`.` for body, space
   for document, first letter otherwise), text overwrites, and a one-cell
   gap between two fragments on a line is blanked so words read
   normally. Rect edges snap to the nearest cell.

9. **Draw ops carry a little more than the spec sketch**: rects carry the
   tag (for the ascii glyph), texts carry `w h` (so the extent and the
   scrollbar work on pages with no backgrounds).

10. **Clicks resolve to the deepest element.** `box-at` returns the deepest
    box (a word fragment, usually); the driver maps a text node to its
    parent element and dispatches on that handle only. No bubbling (spec
    §9). So a click on the padding of `#btn` and on the word "Click" both
    hit `#btn`; a click on the `p` text does nothing unless `p` has a
    listener.

11. **Window in its own eventspace; one engine lock.** The REPL keeps the
    main thread. Every REPL command and every window click runs under
    `engine-lock`, so they can't interleave mid-pipeline. `gui` mode with
    no terminal on stdin (e.g. launched from a script) just waits for the
    window to close.

12. **`racket/gui` is loaded lazily** (`dynamic-require` in `driver.rkt`),
    so `run`, `repl`, and `raco test tests/` never need a display.
    `racket/draw` (image tier, font metrics) works headless.

13. **`get-element` coerces its argument to a string**, so `(get-element 'btn)`
    works; `id-index` is still keyed by the value as written in the page
    (M0 decision 5 stands: write ids as strings).

## Known limits (deliberately, spec §9)

- One event type, `"click"`. No keyboard events to scripts, no bubbling.
- Whole-document re-render on any dirty flag.
- No inline wrapping of *elements* beyond the union rule; no vertical
  alignment; text is top-aligned in its line.
- Colors: named colors racket/draw knows, or `#rrggbb`. Anything else
  paints magenta so you notice.
- The window is fixed at the viewport width (800); vertical scroll only.

## Feedback wanted

1. Decision 1 (`set-text!` on elements) — keep DOM semantics, or the
   spec's literal "set the text field"?
2. Decision 7 — should `run`/`ascii` also use real font metrics (then
   `dump-boxes` numbers depend on the installed font)?
3. Whether clicks should bubble to ancestors with listeners. It's a
   five-line change in `runtime.rkt`; the spec says no for MVP.
