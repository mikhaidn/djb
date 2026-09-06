#lang racket/base
;; M3 tests: draw ops, ascii tier, image tier (headless racket/draw).

(require rackunit
         racket/runtime-path
         racket/list
         racket/string
         racket/file
         "../src/loader.rkt"
         "../src/dom.rkt"
         "../src/style.rkt"
         "../src/layout.rkt"
         "../src/paint.rkt"
         "../src/present.rkt")

(define-runtime-path pages-dir "../pages")

(define (ops-for name)
  (set-box! viewport-width 800)
  (set-box! text-measurer default-text-measurer)
  (define r (build-dom (load-page (build-path pages-dir name))))
  (compute-styles! r)
  (paint (layout-document r)))

(define hello-ops (ops-for "hello.sx"))

(test-case "hello.sx draw ops in paint order"
  (check-equal? hello-ops
                '((rect 0 0 800 112 "white" body)
                  (rect 10 10 440 92 "#cceeff" div)
                  (text 30 30 48 18 "Hello," "black")
                  (text 86 30 40 18 "world" "black")
                  (rect 30 48 80 34 "#3366cc" button)
                  (text 38 56 40 18 "Click" "white")
                  (text 86 56 16 18 "me" "white"))))

(test-case "boxes without a background emit no rect"
  (define ops (ops-for "nested.sx"))
  (check-pred null? (filter op-rect? ops))
  (check-equal? (length (filter op-text? ops)) 9))

(test-case "ops-extent covers rects and text"
  (define-values (w h) (ops-extent hello-ops))
  (check-equal? w 800)
  (check-equal? h 112)
  (define-values (w2 h2) (ops-extent (ops-for "nested.sx")))
  (check-equal? w2 184)
  (check-equal? h2 54))

(test-case "ascii tier: glyph fill, text overlay, word gaps"
  (define s (ascii-string hello-ops))
  (define lines (string-split s "\n" #:trim? #f))
  (check-equal? (length lines) 7)                       ; ceil(112/18)
  (check-equal? (string-length (car lines)) 100)        ; 800/8: body, no trailing trim
  (check-true (string-prefix? (car lines) "...."))
  (check-equal? (substring (list-ref lines 1) 0 16) ".dddHello, world")
  (check-equal? (substring (list-ref lines 2) 0 16) ".ddddddddddddddd")
  (check-equal? (substring (list-ref lines 3) 0 14) ".dddbClick meb")
  (check-equal? (substring (list-ref lines 4) 0 14) ".dddbbbbbbbbbb")
  (check-equal? (list-ref lines 6) ""))                 ; last row: nothing drawn

(test-case "ascii tier: page with no backgrounds is just text"
  (check-equal? (ascii-string (ops-for "nested.sx"))
                "Para with a span inside\nSecond paragraph\nAB"))

(test-case "dump tier prints one op per line"
  (check-equal? (length (string-split (dump-ops-string hello-ops) "\n")) 7))

(test-case "image tier writes a PNG (headless)"
  (define out (make-temporary-file "djb-~a.png"))
  (present-image hello-ops out)
  (define bytes (file->bytes out))
  (check-true (> (bytes-length bytes) 100))
  (check-equal? (subbytes bytes 1 4) #"PNG")
  (delete-file out))

(test-case "real font metrics measurer"
  (define m (make-text-measurer))
  (define-values (w h) (m "Hello"))
  (check-true (> w 0))
  (check-true (> h 0))
  (define-values (w2 _h) (m "Hello, world"))
  (check-true (> w2 w)))
