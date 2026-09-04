#lang racket/base
;; driver.rkt — the operator interface (CLI + REPL).
;;
;;   racket src/driver.rkt run  pages/hello.sx   ; load, dump-dom, exit
;;   racket src/driver.rkt repl pages/hello.sx   ; interactive
;;
;; The REPL reads one s-expression per line and dispatches on its head.
;; It is NOT an eval into the engine namespace: only the commands listed
;; in (help) work. That keeps the driver honest about what each milestone
;; actually provides, and mirrors the sandbox stance of the spec (§4).
;;
;; M0 commands: (dump-dom) (inspect id) (ids) (stats) (reload) (help) (quit)
;; Later milestones add (render) (dump-boxes) (click id) (set-output tier).

(require racket/list
         racket/string
         racket/format
         "loader.rkt"
         "dom.rkt")

(provide main
         load-and-build
         run-command)

;; ---------------------------------------------------------------------------
;; Session state

(define current-page-path (box #f))
(define current-root      (box #f))

;; load-and-build : path -> node
(define (load-and-build path)
  (define datum (load-page path))
  (define root (build-dom datum))
  (set-box! current-page-path path)
  (set-box! current-root root)
  root)

;; ---------------------------------------------------------------------------
;; Commands

(define (cmd-help)
  (displayln
   (string-join
    '("Commands (M0):"
      "  (dump-dom)        pretty-print the live DOM tree with handles"
      "  (inspect \"id\")    show one element by DOM id: handle, tag, attrs, text, parent"
      "  (inspect 3)       same, by integer handle"
      "  (ids)             list all id -> handle entries"
      "  (stats)           node counts"
      "  (reload)          re-read the page from disk and rebuild"
      "  (help)            this message"
      "  (quit)            exit"
      ""
      "Not yet available: (render) (dump-boxes) (click ...) (set-output ...)  -> M1..M4")
    "\n")))

(define (cmd-dump-dom)
  (dump-dom (unbox current-root)))

(define (cmd-inspect key)
  (define n
    (cond [(exact-nonnegative-integer? key) (lookup-handle key)]
          [(string? key) (lookup-id key)]
          [(symbol? key) (lookup-id (symbol->string key))]
          [else #f]))
  (cond
    [(not n)
     (printf "no node for ~s\n" key)]
    [else
     (printf "handle:   ~a\n" (node-handle n))
     (printf "tag:      ~a\n" (node-tag n))
     (printf "attrs:    ~s\n" (node-attrs n))
     (printf "parent:   ~a\n" (let ([p (node-parent n)])
                                (if p (format "#~a ~a" (node-handle p) (node-tag p)) "none (root)")))
     (printf "children: ~a\n" (string-join
                               (for/list ([c (in-list (node-children n))])
                                 (format "#~a ~a" (node-handle c) (node-tag c)))
                               " "))
     (cond
       [(text-node? n) (printf "text:     ~s\n" (node-text n))]
       [(raw-node? n)  (printf "body:     ~a form(s)\n" (length (node-text n)))
                       (for ([f (in-list (node-text n))]) (printf "          ~s\n" f))])
     (printf "style:    ~a\n" (or (node-style n) "(not computed — M1)"))]))

(define (cmd-ids)
  (define entries (sort (hash->list id-index) < #:key cdr))
  (if (null? entries)
      (displayln "(no ids)")
      (for ([e (in-list entries)])
        (printf "~s -> #~a\n" (car e) (cdr e)))))

(define (cmd-stats)
  (define-values (total els texts raws) (dom-stats))
  (printf "nodes: ~a  (elements ~a, text ~a, style/script ~a)\n" total els texts raws)
  (printf "ids:   ~a\n" (hash-count id-index))
  (printf "next handle: ~a\n" (unbox next-id)))

(define (cmd-reload)
  (load-and-build (unbox current-page-path))
  (printf "reloaded ~a\n" (unbox current-page-path))
  (cmd-stats))

;; run-command : datum -> 'quit | void
(define (run-command form)
  (define head (and (pair? form) (car form)))
  (define args (if (pair? form) (cdr form) '()))
  (case head
    [(help ?)            (cmd-help)]
    [(dump-dom dom)      (cmd-dump-dom)]
    [(inspect)           (if (= (length args) 1)
                             (cmd-inspect (car args))
                             (displayln "usage: (inspect \"id\") or (inspect handle)"))]
    [(ids)               (cmd-ids)]
    [(stats)             (cmd-stats)]
    [(reload)            (cmd-reload)]
    [(quit exit q)       'quit]
    [(render dump-boxes click set-output)
     (printf "~a is not implemented yet (see milestone ladder in README)\n" head)]
    [else
     (printf "unknown command ~s — try (help)\n" form)]))

;; ---------------------------------------------------------------------------
;; REPL

(define (repl)
  (let loop ()
    (display "browser> ")
    (flush-output)
    (define form
      (with-handlers ([exn:fail:read?
                       (lambda (e) (printf "read error: ~a\n" (exn-message e)) 'retry)])
        (read)))
    (cond
      [(eof-object? form) (newline)]
      [(eq? form 'retry) (loop)]
      [else
       (define result
         (with-handlers ([exn:fail:page?
                          (lambda (e) (printf "page error: ~a\n" (exn-message e)))]
                         [exn:fail?
                          (lambda (e) (printf "error: ~a\n" (exn-message e)))])
           (run-command form)))
       (unless (eq? result 'quit) (loop))])))

;; ---------------------------------------------------------------------------
;; CLI

(define (usage)
  (displayln "usage: racket src/driver.rkt (run | repl) page.sx")
  (exit 2))

(define (main . argv)
  (define (boot path)
    (with-handlers ([exn:fail:page?
                     (lambda (e) (printf "page error: ~a\n" (exn-message e)) (exit 1))]
                    [exn:fail?
                     (lambda (e) (printf "build error: ~a\n" (exn-message e)) (exit 1))])
      (load-and-build path)))
  (cond
    [(and (= (length argv) 2) (equal? (car argv) "run"))
     (boot (cadr argv))
     (cmd-dump-dom)]
    [(and (= (length argv) 2) (equal? (car argv) "repl"))
     (boot (cadr argv))
     (printf "scheme-browser M0 — loaded ~a\n" (cadr argv))
     (cmd-stats)
     (displayln "type (help) for commands")
     (repl)]
    [else (usage)]))

(module+ main
  (apply main (vector->list (current-command-line-arguments))))
