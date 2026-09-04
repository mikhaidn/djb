#lang racket/base
;; M0 tests: loader + DOM builder + handle tables + dump-dom.
;; Run:  raco test tests/

(require rackunit
         racket/runtime-path
         racket/string
         "../src/loader.rkt"
         "../src/dom.rkt")

(define-runtime-path pages-dir "../pages")
(define (page name) (build-path pages-dir name))

;; --- loader ----------------------------------------------------------------

(test-case "loader: hello.sx reads to a (document ...) datum"
  (define d (load-page (page "hello.sx")))
  (check-pred pair? d)
  (check-eq? (car d) 'document))

(test-case "loader: rejects non-document top-level form"
  (check-exn exn:fail:page? (lambda () (load-page (page "bad-not-document.sx")))))

(test-case "loader: rejects missing file"
  (check-exn exn:fail:page? (lambda () (load-page (page "does-not-exist.sx")))))

;; --- builder ---------------------------------------------------------------

(define root (build-dom (load-page (page "hello.sx"))))

(test-case "root is document with handle 0 and no parent"
  (check-eq? (node-tag root) 'document)
  (check-equal? (node-handle root) 0)
  (check-false (node-parent root)))

(test-case "handles are dense pre-order integers"
  (define-values (total _e _t _r) (dom-stats))
  (check-equal? total 12)
  (check-equal? (unbox next-id) 12)
  (for ([h (in-range 12)])
    (check-pred node? (lookup-handle h) (format "handle ~a" h))
    (check-equal? (node-handle (lookup-handle h)) h)))

(test-case "id-index maps id attr values to handles"
  (check-equal? (hash-ref id-index "root") 5)
  (check-equal? (hash-ref id-index "btn") 8)
  (check-eq? (node-tag (lookup-id "btn")) 'button)
  (check-false (lookup-id "nope")))

(test-case "attrs parsed as (symbol . value) alist"
  (define div (lookup-id "root"))
  (check-equal? (node-attrs div) '((id . "root") (class . "container")))
  (check-equal? (node-attr div 'class) "container")
  (check-false (node-attr div 'href)))

(test-case "parent pointers are consistent with children lists"
  (let walk ([n root])
    (for ([c (in-list (node-children n))])
      (check-eq? (node-parent c) n)
      (walk c))))

(test-case "text nodes"
  (define btn (lookup-id "btn"))
  (define t (car (node-children btn)))
  (check-true (text-node? t))
  (check-equal? (node-text t) "Click me")
  (check-pred null? (node-children t)))

(test-case "style and script bodies kept raw, not walked"
  (define body (lookup-handle 4))
  (check-eq? (node-tag body) 'body)
  (define style  (lookup-handle 10))
  (define script (lookup-handle 11))
  (check-true (raw-node? style))
  (check-true (raw-node? script))
  (check-pred null? (node-children style))
  (check-equal? (length (node-text style)) 3)
  (check-eq? (car (car (node-text style))) 'rule)
  (check-equal? (length (node-text script)) 1)
  (check-eq? (car (car (node-text script))) 'on!))

(test-case "build-dom resets tables (reload semantics)"
  (build-dom (load-page (page "nested.sx")))
  (check-equal? (hash-ref id-index "outer") 5)
  (check-false (hash-ref id-index "btn" #f))
  (define-values (total _e _t _r) (dom-stats))
  (check-equal? total 18)
  ;; rebuild hello so later tests (if any) see it
  (void (build-dom (load-page (page "hello.sx")))))

;; --- dump-dom --------------------------------------------------------------

(test-case "dump-dom output shape"
  (define s (dump-dom-string (build-dom (load-page (page "hello.sx")))))
  (define lines (string-split s "\n"))
  (check-equal? (length lines) 12)
  (check-equal? (car lines) "#0 document")
  (check-true (string-contains? s "#5 div [id=\"root\" class=\"container\"]"))
  (check-true (string-contains? s "#10 style (3 rules)"))
  (check-true (string-contains? s "#11 script (1 form)")))

(test-case "builder rejects malformed attribute"
  (check-exn exn:fail? (lambda () (build-dom '(document (div (@ (id)) "x"))))))
