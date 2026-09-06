# djb — a Scheme browser

A from-scratch browser engine where **Scheme replaces JavaScript** as the
in-page scripting language. Pages are s-expressions (`.sx`), the DOM is the
parsed datum given mutable node records, and page scripts run in a sandbox
that can only touch the tree through integer handles.

Not a real-web browser. A learning/research engine with a tight MVP.
The full design brief is in [`docs/SPEC.md`](docs/SPEC.md).

**Current milestone: M5 + popup window.** The whole pipeline runs end to
end — style, layout, paint, sandboxed scripts, event loop, dynamic DOM —
and there is a real window you can click in. See
[`docs/M1-M5-NOTES.md`](docs/M1-M5-NOTES.md) for what to check and the
decisions worth pushing back on; [`docs/M0-NOTES.md`](docs/M0-NOTES.md)
is the earlier round.

## Quickstart

```sh
brew install --cask racket          # macOS, once; gives you `racket` and `raco`
sudo apt install racket             # Debian/Ubuntu alternative
git clone https://github.com/mikhaidn/djb && cd djb

racket src/driver.rkt gui  pages/hello.sx    # the popup browser: a window you can click in
racket src/driver.rkt run  pages/hello.sx    # one-shot ascii render, exit
racket src/driver.rkt repl pages/hello.sx    # interactive, no window needed
raco test tests/                             # 54 tests, headless
```

Try `pages/counter.sx` and `pages/todo.sx` in the window too. Optional,
makes startup snappier after edits: `raco make src/*.rkt`.

## The popup window

```sh
racket src/driver.rkt gui pages/counter.sx
```

Opens a window titled after the page's `(title ...)`, 800px wide, with a
Reload button, a status line, and the rendered page. A left click in the
page is hit-tested against the layout box tree; the deepest element under
the pointer gets a `"click"` event, its script handlers run in the sandbox,
and if they mutated the DOM the page is re-styled, re-laid-out, and
repainted. The status line says what was hit and whether anything changed.
`r` (or the button) reloads the `.sx` from disk, so edit-save-reload works.

When run from a terminal the REPL below runs alongside the window, so you
can `(dump-boxes)`, `(inspect "btn")`, `(click "btn")` or `(reload)` and
watch the window follow. The window and the REPL share one engine under a
lock. Closing the window leaves the REPL running; `(gui)` reopens it.

Everything else (`run`, `repl`, the tests) never loads `racket/gui`, so it
works on a machine with no display.

## The REPL

```
$ racket src/driver.rkt repl pages/hello.sx
djb — loaded pages/hello.sx
nodes: 12  (elements 7, text 3, style/script 2)
ids:   2
next handle: 12
listeners: 1   boxes: 9   ops: 7
type (help) for commands
browser> (render)
....................................................................................................
.dddHello, worlddddddddddddddddddddddddddddddddddddddddd............................................
.ddddddddddddddddddddddddddddddddddddddddddddddddddddddd............................................
.dddbClick mebdddddddddddddddddddddddddddddddddddddddddd............................................
.dddbbbbbbbbbbdddddddddddddddddddddddddddddddddddddddddd............................................
.ddddddddddddddddddddddddddddddddddddddddddddddddddddddd............................................

browser> (dump-boxes)
#0 document block (0 0 800 112)
  #4 body block (0 0 800 112)
    #5 div block (10 10 440 92)
      #6 p block (30 30 400 18)
        #7 "Hello," (30 30 48 18)
        #7 "world" (86 30 40 18)
      #8 button inline (30 48 80 34)
        #9 "Click" (38 56 40 18)
        #9 "me" (86 56 16 18)
browser> (click "btn")
....................................................................................................
.dddClicked!dddddddddddddddddddddddddddddddddddddddddddd............................................
.ddddddddddddddddddddddddddddddddddddddddddddddddddddddd............................................
.ddddddddddddddddddddddddddddddddddddddddddddddddddddddd............................................

browser> (dump-dom)
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
browser> (reload)
reloaded pages/hello.sx
...
browser> (inspect "btn")
handle:   8
tag:      button
attrs:    ((id . "btn"))
parent:   #5 div
children: #9 text
style:    display=inline width=#f height=#f margin=0 padding=8 background-color=#3366cc color=white
boxes:    (30 48 80 34)
listeners: click
browser> (quit)
```

| Command | Since | Does |
|---|---|---|
| `(render)` | M3 | print the page at the current output tier |
| `(set-output 'dump)` / `'ascii` / `'image` | M3 | switch tier; `image` writes `render.png` |
| `(screenshot "shot.png")` | M3 | rasterize the current page to a PNG (no display needed) |
| `(gui)` | — | open the popup window |
| `(click "id")` / `(click 8)` | M4 | synthetic click → handlers → re-render if the DOM changed |
| `(dump-dom)` | M0 | print the live tree, one node per line, `#handle tag [attrs]` |
| `(dump-boxes)` | M2 | the layout box tree, `(x y w h)` per box, one box per word of text |
| `(inspect "id")` / `(inspect 8)` | M0 | one node: attrs, computed style, boxes, listeners |
| `(ids)` `(stats)` | M0 | the id → handle index; counts |
| `(reload)` | M0 | re-read the page, rebuild, rerun scripts, re-render |
| `(help)` `(quit)` | M0 | |

The REPL is a command dispatcher, not `eval`: only the commands above are
recognised. Edit a `.sx` file in another window, `(reload)`, `(render)`.

`racket src/driver.rkt run page.sx [dump|ascii|image]` does one render at
the given tier and exits (`ascii` by default).

## Page format

```scheme
(document
  (head (title "Hello"))
  (body
    (div (@ (id "root") (class "container"))
      (p "Hello, world")
      (button (@ (id "btn")) "Click me"))
    (style
      (rule (tag body)        (background-color "white") (padding 10))
      (rule (id btn)          (background-color "#3366cc") (color "white")))
    (script
      (on! (get-element "btn") "click"
        (lambda (ev) (set-text! (get-element "root") "Clicked!"))))))
```

- Element: `(tag (@ (attr value) ...) child ...)`. `(@ ...)` is optional and,
  if present, always first.
- Bare string: text node.
- `(style ...)` holds `(rule (selector) (prop value) ...)` forms. Selectors:
  `(tag x)` `(class x)` `(id x)`. Properties: `display` (`block`/`inline`/
  `none`), `width`, `height`, `margin`, `padding` (numbers, px),
  `background-color`, `color` (strings: names or `#rrggbb`). Last matching
  rule wins; only `color` inherits.
- `(script ...)` forms are evaluated once, in order, in a `racket/base`
  sandbox with these host procedures in scope: `get-element`,
  `text-content`, `set-text!`, `get-attribute`, `set-attribute!`,
  `create-element`, `append-child!`, `remove-child!`, `on!`, and
  `event-type` / `event-target` for the record a handler receives. Nodes
  are integer handles. Every mutator marks the document dirty; after a
  handler returns, a dirty document is re-rendered.
- Exactly one top-level form per file, and it must be `(document ...)`.

## Layout

```
src/
  loader.rkt    read .sx -> datum, validate shape                [M0]
  dom.rkt       node struct, builder, handle tables, dump-dom    [M0]
  style.rkt     rule matching + computed style                   [M1]
  layout.rkt    box tree + geometry, hit-testing, dump-boxes     [M2]
  paint.rkt     box tree -> draw ops                             [M3]
  present.rkt   draw ops -> dump | ascii | image; rasterizer     [M3]
  bindings.rkt  host procedures (h:*), dirty flag, listeners     [M4/M5]
  runtime.rkt   sandbox setup, script eval, dispatch, tick!      [M4]
  gui.rkt       the popup window (only module touching racket/gui)
  driver.rkt    CLI (run | repl | gui) + REPL + pipeline glue
pages/          hello.sx (canonical), nested.sx, counter.sx, todo.sx
tests/          rackunit; `raco test tests/` (gui-smoke.rkt is opt-in)
docs/           SPEC.md (design brief), M<n>-NOTES.md per milestone
```

## Milestone ladder

| # | Deliverable | Operator verifies with | Status |
|---|---|---|---|
| M0 | loader + DOM builder + `dump-dom` | `(dump-dom)` matches the `.sx` | **done** |
| M1 | style matching + `inspect` shows computed style | `(inspect "btn")` | **done** |
| M2 | block + inline layout + `dump-boxes` | `(dump-boxes)` geometry is sane | **done** |
| M3 | paint + ascii present | `(render)` draws boxes | **done** (+ image tier) |
| M4 | sandbox + bindings + event loop | `(click "btn")` → auto re-render | **done** |
| M5 | dynamic DOM (`create`/`append`/`remove`) | script adds a node, it appears | **done** (`pages/todo.sx`) |
| — | popup window | `racket src/driver.rkt gui pages/hello.sx`, click the button | **done** |

## License

GPL-3.0 — see `LICENSE`.
