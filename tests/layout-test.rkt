#lang racket/base
;; M2 tests: block flow, inline runs, wrapping, hit-testing, dump-boxes.
;; All with the default monospace measurer (8px/char, 18px line) and an
;; 800px viewport unless stated.

(require rackunit
         racket/runtime-path
         racket/list
         racket/string
         "../src/loader.rkt"
         "../src/dom.rkt"
         "../src/style.rkt"
         "../src/layout.rkt")

(define-runtime-path pages-dir "../pages")

(define (layout-page name #:width [w 800])
  (set-box! viewport-width w)
  (define r (build-dom (load-page (build-path pages-dir name))))
  (compute-styles! r)
  (layout-document r))

(define (layout-datum d #:width [w 800])
  (set-box! viewport-width w)
  (define r (build-dom d))
  (compute-styles! r)
  (layout-document r))

(define (all-boxes b) (cons b (append-map all-boxes (lbox-children b))))
(define (boxes-of root n) (filter (lambda (b) (eq? (lbox-node b) n)) (all-boxes root)))
(define (geom b) (list (lbox-x b) (lbox-y b) (lbox-w b) (lbox-h b)))

(define hello (layout-page "hello.sx"))

(test-case "hello.sx geometry"
  (check-equal? (geom hello) '(0 0 800 112))
  (define body (car (lbox-children hello)))
  (check-eq? (node-tag (lbox-node body)) 'body)
  (check-equal? (geom body) '(0 0 800 112))
  ;; container: body padding 10 => x 10; width 400 + 2*20 padding
  (define div (car (boxes-of hello (lookup-id "root"))))
  (check-equal? (geom div) '(10 10 440 92))
  ;; p: inside container content box
  (define p (car (boxes-of hello (lookup-handle 6))))
  (check-equal? (geom p) '(30 30 400 18))
  ;; text fragments: one box per word, space between
  (define frags (boxes-of hello (lookup-handle 7)))
  (check-equal? (map lbox-text frags) '("Hello," "world"))
  (check-equal? (map geom frags) '((30 30 48 18) (86 30 40 18)))
  ;; button: inline, padding 8 around "Click me"
  (define btn (car (boxes-of hello (lookup-id "btn"))))
  (check-eq? (lbox-kind btn) 'inline)
  (check-equal? (geom btn) '(30 48 80 34))
  (check-equal? (map geom (boxes-of hello (lookup-handle 9)))
                '((38 56 40 18) (86 56 16 18))))

(test-case "display:none subtrees produce no boxes"
  (check-pred null? (boxes-of hello (lookup-handle 1)))    ; head
  (check-pred null? (boxes-of hello (lookup-handle 3)))    ; title text
  (check-pred null? (boxes-of hello (lookup-handle 10)))   ; style
  (check-equal? (box-count hello) 9))

(test-case "children are contained in parents; siblings do not overlap"
  (define (contained? c p)
    (and (>= (lbox-x c) (lbox-x p)) (>= (lbox-y c) (lbox-y p))
         (<= (lbox-right c) (lbox-right p)) (<= (lbox-bottom c) (lbox-bottom p))))
  (define (overlap? a b)
    (and (< (lbox-x a) (lbox-right b)) (< (lbox-x b) (lbox-right a))
         (< (lbox-y a) (lbox-bottom b)) (< (lbox-y b) (lbox-bottom a))))
  (for ([root (list hello (layout-page "nested.sx") (layout-page "counter.sx") (layout-page "todo.sx"))])
    (let walk ([b root])
      (for ([c (in-list (lbox-children b))])
        (check-true (contained? c b) (format "~a in ~a" c b))
        (walk c))
      (for* ([pair (in-combinations (lbox-children b) 2)])
        (check-false (overlap? (car pair) (cadr pair)) (format "~a vs ~a" (car pair) (cadr pair)))))))

(test-case "nested.sx: inline span inside a paragraph, adjacent buttons"
  (define r (layout-page "nested.sx"))
  (define span (car (boxes-of r (lookup-id "inner"))))
  (void span)
  (define sp (car (filter (lambda (b) (eq? (node-tag (lbox-node b)) 'span)) (all-boxes r))))
  (check-equal? (geom sp) '(40 0 88 18))          ; after "Para " (32px + space); "with a span" = 32+8+8+8+32
  (define after (car (boxes-of r (lookup-handle 11))))
  (check-equal? (lbox-x after) 136)                ; " inside" gets its leading space
  (define a (car (boxes-of r (lookup-id "a"))))
  (define b (car (boxes-of r (lookup-id "b"))))
  (check-equal? (geom a) '(0 36 8 18))
  (check-equal? (geom b) '(8 36 8 18)))            ; no whitespace between them

(test-case "wrapping: words move to the next line at the content edge"
  (define r (layout-datum '(document (body (p "one two three four"))) #:width 100))
  (define p (car (lbox-children (car (lbox-children r)))))
  (define frags (lbox-children p))
  (check-equal? (map lbox-text frags) '("one" "two" "three" "four"))
  ;; "one two" = 24+8+24 = 56 fits; "three" (40) would end at 104 > 100 -> wraps
  (check-equal? (map geom frags)
                '((0 0 24 18) (32 0 24 18) (0 18 40 18) (48 18 32 18)))
  (check-equal? (lbox-h p) 36)
  (check-equal? (lbox-h r) 36))

(test-case "an inline element spanning a wrap is the union of its fragments"
  (define r (layout-datum '(document (body (p "aa " (span (@ (id "s")) "bbb ccc") " dd")
                                            (style (rule (id s) (padding 2)))))
                          #:width 80))
  (define sp (car (boxes-of r (lookup-id "s"))))
  ;; "aa" 0..16, space, span pad 2 -> "bbb" at 26..50 (y 2: top padding).
  ;; line 1 is 22 tall (18 + 2*2), so "ccc" wraps to y 22+2 at the content
  ;; edge (padding is not repeated on continuation lines, as in CSS).
  (define frags (boxes-of r (car (node-children (lookup-id "s")))))
  (check-equal? (map geom frags) '((26 2 24 18) (0 24 24 18)))
  ;; the span box is the union of its fragments, padded on all sides
  (check-equal? (geom sp) '(-2 0 54 44)))

(test-case "explicit height and margins (no collapsing)"
  (define r (layout-datum '(document (body (div (@ (id "a")) "x") (div (@ (id "b")) "y")
                                            (style (rule (tag div) (height 30) (margin 5) (padding 1)))))))
  (define a (car (boxes-of r (lookup-id "a"))))
  (define b (car (boxes-of r (lookup-id "b"))))
  (check-equal? (geom a) '(5 5 790 32))
  (check-equal? (geom b) '(5 47 790 32))
  (check-equal? (lbox-h r) 84))

(test-case "empty inline element is a padding-only box"
  (define r (layout-datum '(document (body (button (@ (id "e"))) "after")
                                            (style (rule (id e) (padding 5))))))
  (define e (car (boxes-of r (lookup-id "e"))))
  (check-equal? (geom e) '(0 0 10 10))
  (define after (car (boxes-of r (lookup-handle 3))))
  (check-equal? (lbox-x after) 10))

(test-case "box-at finds the deepest box; misses outside"
  (define hello (layout-page "hello.sx"))   ; fresh tables: lookups below must match
  (check-eq? (lbox-node (box-at hello 40 60)) (lookup-handle 9))   ; "Click" text
  (check-eq? (lbox-node (box-at hello 32 50)) (lookup-id "btn"))   ; button padding
  (check-eq? (lbox-node (box-at hello 300 60)) (lookup-id "root")) ; container bg
  (check-eq? (lbox-node (box-at hello 700 5)) (lookup-handle 4))   ; body
  (check-false (box-at hello 900 5))
  (check-false (box-at hello 5 500)))

(test-case "dump-boxes format"
  (define s (dump-boxes-string hello))
  (define lines (string-split s "\n"))
  (check-equal? (length lines) 9)
  (check-equal? (car lines) "#0 document block (0 0 800 112)")
  (check-true (string-contains? s "      #8 button inline (30 48 80 34)"))
  (check-true (string-contains? s "        #7 \"Hello,\" (30 30 48 18)")))

(test-case "text-measurer is pluggable"
  (set-box! text-measurer (lambda (s) (values (* 10 (string-length s)) 20)))
  (define r (layout-datum '(document (body (p "ab cd")))))
  (define p (car (lbox-children (car (lbox-children r)))))
  (check-equal? (map geom (lbox-children p)) '((0 0 20 20) (30 0 20 20)))
  (set-box! text-measurer default-text-measurer))
