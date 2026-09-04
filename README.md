# djb — a Scheme browser

A from-scratch browser engine where **Scheme replaces JavaScript** as the
in-page scripting language. Pages are s-expressions (`.sx`), the DOM is the
parsed datum given mutable node records, and page scripts run in a sandbox
that can only touch the tree through integer handles.

Not a real-web browser. A learning/research engine with a tight MVP.
The full design brief is in [`docs/SPEC.md`](docs/SPEC.md).

**Current milestone: M0** — loader + DOM builder + `dump-dom`.
See [`docs/M0-NOTES.md`](docs/M0-NOTES.md) for what to check and how to
give feedback.

## Quickstart (macOS)

```sh
brew install --cask racket          # once; gives you `racket` and `raco`
git clone https://github.com/mikhaidn/djb && cd djb

racket src/driver.rkt run  pages/hello.sx    # one-shot: print the DOM, exit
racket src/driver.rkt repl pages/hello.sx    # interactive
raco test tests/                             # 13 tests
```

Optional, makes startup snappier after edits: `raco make src/*.rkt`.

## The REPL

```
$ racket src/driver.rkt repl pages/hello.sx
scheme-browser M0 — loaded pages/hello.sx
nodes: 12  (elements 7, text 3, style/script 2)
ids:   2
type (help) for commands
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
browser> (inspect "btn")
handle:   8
tag:      button
attrs:    ((id . "btn"))
parent:   #5 div
children: #9 text
style:    (not computed — M1)
browser> (quit)
```

| Command | Since | Does |
|---|---|---|
| `(dump-dom)` | M0 | print the live tree, one node per line, `#handle tag [attrs]` |
| `(inspect "id")` / `(inspect 8)` | M0 | one node in detail, by id or handle |
| `(ids)` | M0 | the id → handle index |
| `(stats)` | M0 | node counts |
| `(reload)` | M0 | re-read the page file and rebuild |
| `(help)` `(quit)` | M0 | |
| `(render)` `(dump-boxes)` | M2–M3 | not yet |
| `(click "id")` `(set-output 'tier)` | M3–M4 | not yet |

The REPL is a command dispatcher, not `eval`: only the commands above are
recognised. Edit a `.sx` file in another window, `(reload)`, `(dump-dom)`.

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
- `(style ...)` and `(script ...)` bodies are kept verbatim; they are not
  walked as elements. Style is consumed at M1, script at M4.
- Exactly one top-level form per file, and it must be `(document ...)`.

## Layout

```
src/
  loader.rkt    read .sx -> datum, validate shape           [M0]
  dom.rkt       node struct, builder, handle tables, dump    [M0]
  driver.rkt    CLI + REPL                                   [M0]
  style.rkt     rule matching + computed style               [M1, stub]
  layout.rkt    box tree + geometry                          [M2, stub]
  paint.rkt     box tree -> draw ops                         [M3, stub]
  present.rkt   draw ops -> dump | ascii | image             [M3, stub]
  bindings.rkt  host procedures (h:*), dirty flag, listeners [M4, stub]
  runtime.rkt   sandbox setup, event loop, dispatch          [M4, stub]
pages/          fixture pages (hello.sx is the canonical one)
tests/          rackunit; `raco test tests/`
docs/           SPEC.md (design brief), M<n>-NOTES.md per milestone
```

## Milestone ladder

| # | Deliverable | Operator verifies with | Status |
|---|---|---|---|
| M0 | loader + DOM builder + `dump-dom` | `(dump-dom)` matches the `.sx` | **done** |
| M1 | style matching + `inspect` shows computed style | `(inspect "btn")` | |
| M2 | block + inline layout + `dump-boxes` | `(dump-boxes)` geometry is sane | |
| M3 | paint + ascii present | `(render)` draws boxes | |
| M4 | sandbox + bindings + event loop | `(click "btn")` → auto re-render | |
| M5 | dynamic DOM (`create`/`append`/`remove`) | script adds a node, it appears | |

M4 is where it becomes a browser rather than a static renderer.

## License

GPL-3.0 — see `LICENSE`.
