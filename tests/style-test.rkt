#lang racket/base
;; M1 tests: rule collection, selector matching, computed style.

(require rackunit
         racket/runtime-path
         "../src/loader.rkt"
         "../src/dom.rkt"
         "../src/style.rkt")

(define-runtime-path pages-dir "../pages")
(define (load name)
  (define r (build-dom (load-page (build-path pages-dir name))))
  (compute-styles! r)
  r)

(test-case "rules are collected from (style ...) in document order"
  (define rules (collect-rules (load "hello.sx")))
  (check-equal? (length rules) 3)
  (check-equal? (map cadr rules) '((tag body) (class container) (id btn))))

(test-case "selectors: tag, class, id; symbol or string names"
  (load "hello.sx")
  (define btn (lookup-id "btn"))
  (define div (lookup-id "root"))
  (check-true  (rule-matches? '(rule (id btn)) btn))
  (check-true  (rule-matches? '(rule (id "btn")) btn))
  (check-false (rule-matches? '(rule (id btn)) div))
  (check-true  (rule-matches? '(rule (class container)) div))
  (check-true  (rule-matches? '(rule (tag button)) btn))
  (check-false (rule-matches? '(rule (tag button)) div))
  (check-exn exn:fail? (lambda () (rule-matches? '(rule (descendant x)) btn))))

(test-case "class matching handles space-separated class lists"
  (define r (build-dom '(document (body (div (@ (class "a b c")) "x")))))
  (define d (car (node-children (car (node-children r)))))
  (check-true (rule-matches? '(rule (class b)) d))
  (check-false (rule-matches? '(rule (class ab)) d)))

(test-case "computed style: declared props, defaults, last rule wins"
  (load "hello.sx")
  (define btn (lookup-id "btn"))
  (check-equal? (style-ref btn 'background-color) "#3366cc")
  (check-equal? (style-ref btn 'color) "white")
  (check-equal? (style-ref btn 'padding) 8)
  (check-equal? (style-ref btn 'margin) 0)
  (check-equal? (style-ref btn 'display) 'inline)
  (check-false  (style-ref btn 'width))
  (define div (lookup-id "root"))
  (check-equal? (style-ref div 'width) 400)
  (check-equal? (style-ref div 'display) 'block))

(test-case "last matching rule wins (no specificity)"
  (define r (build-dom '(document
                         (body (p (@ (id "x") (class "c")) "t")
                               (style (rule (id x) (color "red"))
                                      (rule (class c) (color "blue")))))))
  (compute-styles! r)
  (check-equal? (style-ref (lookup-id "x") 'color) "blue"))

(test-case "color inherits; text nodes get the parent's color"
  (load "hello.sx")
  (define btn (lookup-id "btn"))
  (define t (car (node-children btn)))
  (check-equal? (style-ref t 'color) "white")
  (check-equal? (style-ref (lookup-id "root") 'color) "black")
  (check-equal? (style-ref (car (node-children (lookup-handle 6))) 'color) "black"))

(test-case "default display per tag"
  (load "hello.sx")
  (check-equal? (style-ref (lookup-handle 1) 'display) 'none)   ; head
  (check-equal? (style-ref (lookup-handle 10) 'display) 'none)  ; style
  (check-equal? (style-ref (lookup-handle 11) 'display) 'none)  ; script
  (check-equal? (style-ref (lookup-handle 4) 'display) 'block)  ; body
  (check-equal? (default-display 'span) 'inline)
  (check-equal? (default-display 'p) 'block))

(test-case "display can be overridden and is normalised"
  (define r (build-dom '(document (body (span (@ (id "s")) "t")
                                        (style (rule (id s) (display "block")))))))
  (compute-styles! r)
  (check-equal? (style-ref (lookup-id "s") 'display) 'block))

(test-case "bad values are errors"
  (define (bad style)
    (define r (build-dom `(document (body (p (@ (id "p")) "t") (style ,@style)))))
    (check-exn exn:fail? (lambda () (compute-styles! r))))
  (bad '((rule (id p) (display sideways))))
  (bad '((rule (id p) (padding "8"))))
  (bad '((rule (id p) (float left))))
  (bad '((rule (id p) padding))))
