#lang racket/base
;; M4/M5 tests: host bindings, sandbox, event loop, dynamic DOM.

(require rackunit
         racket/runtime-path
         racket/string
         racket/port
         "../src/loader.rkt"
         "../src/dom.rkt"
         "../src/bindings.rkt"
         "../src/runtime.rkt")

(define-runtime-path pages-dir "../pages")

(define (boot name)
  (define r (build-dom (load-page (build-path pages-dir name))))
  (start-runtime!)
  (run-scripts! r)
  (set-box! document-dirty? #f)
  r)

(define (boot-datum d)
  (define r (build-dom d))
  (start-runtime!)
  (run-scripts! r)
  (set-box! document-dirty? #f)
  r)

;; --- bindings ---------------------------------------------------------------

(test-case "text-content / set-text! on elements and text nodes"
  (boot "hello.sx")
  (define root (h:get-element "root"))
  (check-equal? root 5)
  (check-false (h:get-element "nope"))
  (check-equal? (h:text-content root) "Hello, worldClick me")
  (check-equal? (h:text-content 9) "Click me")
  (h:set-text! 9 "Go")
  (check-equal? (h:text-content (h:get-element "btn")) "Go")
  (check-true (unbox document-dirty?))
  ;; on an element: children replaced by one text node
  (h:set-text! root "Clicked!")
  (check-equal? (length (node-children (lookup-handle root))) 1)
  (check-equal? (h:text-content root) "Clicked!")
  (check-false (node-parent (lookup-handle 6)))          ; old p detached
  (check-pred node? (lookup-handle 6)))                  ; but its handle is still valid

(test-case "attributes"
  (boot "hello.sx")
  (define btn (h:get-element "btn"))
  (check-equal? (h:get-attribute btn "id") "btn")
  (check-equal? (h:get-attribute btn 'id) "btn")
  (check-false (h:get-attribute btn "class"))
  (set-box! document-dirty? #f)
  (h:set-attribute! btn "class" "primary")
  (check-true (unbox document-dirty?))
  (check-equal? (h:get-attribute btn "class") "primary")
  (h:set-attribute! btn "class" "secondary")
  (check-equal? (node-attrs (lookup-handle btn)) '((class . "secondary") (id . "btn")))
  ;; setting id keeps the index in sync
  (h:set-attribute! btn "id" "go")
  (check-equal? (h:get-element "go") btn))

(test-case "create / append / remove"
  (boot "hello.sx")
  (define root (h:get-element "root"))
  (define p (h:create-element "p"))
  (check-equal? p 12)
  (check-false (node-parent (lookup-handle p)))
  (h:set-text! p "new")
  (h:append-child! root p)
  (check-eq? (node-parent (lookup-handle p)) (lookup-handle root))
  (check-equal? (h:text-content root) "Hello, worldClick menew")
  (check-exn exn:fail? (lambda () (h:append-child! p root)))          ; cycle
  (check-exn exn:fail? (lambda () (h:append-child! 9 p)))             ; text node parent
  (h:remove-child! root p)
  (check-false (node-parent (lookup-handle p)))
  (check-equal? (h:text-content root) "Hello, worldClick me")
  (check-exn exn:fail? (lambda () (h:remove-child! root p))))         ; not a child

(test-case "handle validation"
  (boot "hello.sx")
  (check-exn #rx"stale handle" (lambda () (h:text-content 999)))
  (check-exn #rx"expected a node handle" (lambda () (h:set-text! "btn" "x")))
  (check-exn #rx"handler must be a procedure" (lambda () (h:on! 8 "click" 42))))

;; --- runtime -----------------------------------------------------------------

(test-case "script runs at load and registers a listener"
  (boot "hello.sx")
  (check-equal? (hash-keys listeners) '((8 . "click")))
  (check-true (runtime-running?)))

(test-case "tick!: click -> handler -> dirty -> rerender"
  (define root (boot "hello.sx"))
  (define renders 0)
  (check-true (tick! "click" 8 (lambda () (set! renders (add1 renders)))))
  (check-equal? renders 1)
  (check-equal? (h:text-content 5) "Clicked!")
  (check-false (unbox document-dirty?))
  ;; no listener -> no rerender
  (check-false (tick! "click" 6 (lambda () (set! renders (add1 renders)))))
  (check-equal? renders 1)
  ;; the DOM tree really changed
  (check-true (string-contains? (dump-dom-string root) "\"Clicked!\""))
  (check-false (string-contains? (dump-dom-string root) "button")))

(test-case "handlers receive an event record"
  (boot-datum '(document (body (p (@ (id "p")) "x")
                               (script (on! (get-element "p") "click"
                                            (lambda (ev)
                                              (set-text! (event-target ev) (event-type ev))))))))
  (tick! "click" 2 void)
  (check-equal? (h:text-content 2) "click"))

(test-case "counter.sx: sandbox state persists across events"
  (boot "counter.sx")
  (define inc (h:get-element "inc"))
  (tick! "click" inc void)
  (tick! "click" inc void)
  (tick! "click" inc void)
  (check-equal? (h:text-content (h:get-element "count")) "3")
  (tick! "click" (h:get-element "reset") void)
  (check-equal? (h:text-content (h:get-element "count")) "0"))

(test-case "todo.sx: dynamic DOM through the sandbox"
  (boot "todo.sx")
  (define list-h (h:get-element "list"))
  (define (items) (length (node-children (lookup-handle list-h))))
  (check-equal? (items) 1)
  (check-true (tick! "click" (h:get-element "add") void))
  (check-true (tick! "click" (h:get-element "add") void))
  (check-equal? (items) 3)
  (check-equal? (h:text-content list-h) "write a browseritem 1item 2")
  ;; the created nodes got their class via set-attribute!
  (define created (cadr (node-children (lookup-handle list-h))))
  (check-equal? (node-attr created 'class) "item")
  (check-eq? (node-tag created) 'p)
  (check-true (tick! "click" (h:get-element "clear") void))
  (check-equal? (items) 1)
  (check-false (node-parent created)))

(test-case "script errors are reported, not fatal"
  (define out (open-output-string))
  (parameterize ([current-output-port out])
    (boot-datum '(document (body (p (@ (id "p")) "x")
                                 (script (car '())
                                         (on! (get-element "p") "click" (lambda (ev) (error "boom")))))))
    (check-equal? (hash-count listeners) 1)
    (check-false (tick! "click" 2 void)))
  (define s (get-output-string out))
  (check-true (string-contains? s "script error: car"))
  (check-true (string-contains? s "script error: boom")))

(test-case "sandbox: no filesystem, handlers run under the sandbox too"
  (define out (open-output-string))
  (parameterize ([current-output-port out])
    (boot-datum '(document (body (p (@ (id "p")) "x")
                                 (script (on! (get-element "p") "click"
                                              (lambda (ev) (open-input-file "/etc/hostname")))))))
    (tick! "click" 2 void))
  (check-true (string-contains? (get-output-string out) "access denied")))

(test-case "sandbox: runaway handler is cut off by the time limit"
  (set-box! script-eval-limits '(1 50))
  (define out (open-output-string))
  (parameterize ([current-output-port out])
    (boot-datum '(document (body (p (@ (id "p")) "x")
                                 (script (on! (get-element "p") "click"
                                              (lambda (ev) (let loop () (loop))))))))
    (tick! "click" 2 void))
  (set-box! script-eval-limits '(5 50))
  (check-true (string-contains? (get-output-string out) "script error")))

(test-case "start-runtime! resets listeners (reload semantics)"
  (boot "hello.sx")
  (check-equal? (hash-count listeners) 1)
  (start-runtime!)
  (check-equal? (hash-count listeners) 0)
  (stop-runtime!)
  (check-false (runtime-running?)))
