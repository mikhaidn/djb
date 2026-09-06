#lang racket/base
;; driver.rkt — the operator interface (CLI + REPL + popup window).
;;
;;   racket src/driver.rkt run  pages/hello.sx [tier]  ; render once to a tier, exit
;;   racket src/driver.rkt repl pages/hello.sx         ; interactive
;;   racket src/driver.rkt gui  pages/hello.sx         ; popup window (+ REPL if on a tty)
;;
;; The REPL reads one s-expression per line and dispatches on its head.
;; It is NOT an eval into the engine namespace: only the commands listed
;; in (help) work, mirroring the sandbox stance of the spec (§4).
;;
;; The window and the REPL share one engine; every command and every
;; click runs under `engine-lock` so the two never interleave.

(require racket/list
         racket/string
         racket/format
         racket/runtime-path
         "loader.rkt"
         "dom.rkt"
         "style.rkt"
         "layout.rkt"
         "paint.rkt"
         "present.rkt"
         "bindings.rkt"
         "runtime.rkt")

(provide main
         load-and-build
         run-command
         render-pipeline!
         session-root session-boxes session-ops
         open-gui! close-gui! gui-open?
         call-with-engine-lock)

(define-runtime-path gui-module "gui.rkt")

;; ---------------------------------------------------------------------------
;; Session state

(define current-page-path (box #f))
(define current-root      (box #f))
(define current-boxes     (box #f))
(define current-ops       (box '()))
(define current-tier      (box 'ascii))
(define current-window    (box #f))
(define image-path        (box "render.png"))

(define (session-root)  (unbox current-root))
(define (session-boxes) (unbox current-boxes))
(define (session-ops)   (unbox current-ops))
(define (gui-open?)     (and (unbox current-window) #t))

(define engine-lock (make-semaphore 1))
(define (call-with-engine-lock thunk)
  (call-with-semaphore engine-lock thunk))

;; ---------------------------------------------------------------------------
;; Pipeline

;; render-pipeline! : -> ops
;; style -> layout -> paint over the live DOM; caches boxes and ops and
;; refreshes the window if one is open. Clears the dirty flag.
(define (render-pipeline!)
  (define root (unbox current-root))
  (compute-styles! root)
  (define bx (layout-document root))
  (define ops (paint bx))
  (set-box! current-boxes bx)
  (set-box! current-ops ops)
  (set-box! document-dirty? #f)
  (let ([w (unbox current-window)])
    (when w (gui-call 'window-refresh! w)))
  ops)

;; load-and-build : path -> node
;; The whole load: read, build DOM, fresh sandbox, run scripts, render.
(define (load-and-build path)
  (define datum (load-page path))
  (define root (build-dom datum))
  (set-box! current-page-path path)
  (set-box! current-root root)
  (start-runtime!)
  (run-scripts! root)
  (render-pipeline!)
  (let ([w (unbox current-window)])
    (when w (gui-call 'window-set-title! w (window-title))))
  root)

(define (page-title)
  (define t (let walk ([n (unbox current-root)])
              (if (eq? (node-tag n) 'title)
                  n
                  (for/or ([c (in-list (node-children n))]) (walk c)))))
  (and t (pair? (node-children t)) (node-text (car (node-children t)))))

(define (window-title)
  (format "~a — djb" (or (page-title) (unbox current-page-path))))

;; ---------------------------------------------------------------------------
;; Output

(define (present-current! [out (current-output-port)])
  (case (unbox current-tier)
    [(dump)
     (dump-boxes (unbox current-boxes) out)
     (present-dump (unbox current-ops) out)]
    [(ascii)
     (present-ascii (unbox current-ops) out)]
    [(image)
     (ensure-real-metrics!)
     (present-image (unbox current-ops) (unbox image-path))
     (fprintf out "wrote ~a\n" (unbox image-path))]))

;; The image tier and the window draw with a real font, so they lay out
;; with its metrics too. Switching is one-way for the session: after
;; this, dump/ascii geometry follows the font as well.
(define real-metrics? (box #f))
(define (ensure-real-metrics!)
  (unless (unbox real-metrics?)
    (set-box! real-metrics? #t)
    (set-box! text-measurer (make-text-measurer default-font))
    (render-pipeline!)))

;; ---------------------------------------------------------------------------
;; Events

(define (resolve-handle key who)
  (cond [(exact-nonnegative-integer? key) (and (lookup-handle key) key)]
        [(string? key) (hash-ref id-index key #f)]
        [(symbol? key) (hash-ref id-index (symbol->string key) #f)]
        [else #f]))

;; click-handle! : handle (-> void) -> boolean
(define (click-handle! h after-render)
  (define n (lookup-handle h))
  (define listened? (hash-has-key? listeners (cons h "click")))
  (define rendered?
    (tick! "click" h (lambda () (render-pipeline!) (after-render))))
  (values listened? rendered?))

;; element-at : x y -> node | #f   (text boxes resolve to their element)
(define (element-at x y)
  (define bx (unbox current-boxes))
  (define b (and bx (box-at bx x y)))
  (and b
       (let ([n (lbox-node b)])
         (if (text-node? n) (node-parent n) n))))

;; ---------------------------------------------------------------------------
;; GUI (lazy: racket/gui is only loaded when a window is asked for)

(define (gui-call name . args)
  (apply (dynamic-require gui-module name) args))

(define (open-gui! #:width [width (unbox viewport-width)] #:height [height 600])
  (cond
    [(unbox current-window) => values]
    [else
     (ensure-real-metrics!)          ; WYSIWYG: lay out with the font we draw with
     (define open-window (dynamic-require gui-module 'open-window))
     (define w
       (open-window #:title (window-title)
                 #:width width
                 #:height height
                 #:paint (lambda (dc) (draw-ops! dc (unbox current-ops) default-font))
                 #:content-height (lambda () (lbox-h (unbox current-boxes)))
                 #:on-click gui-click
                 #:on-reload (lambda ()
                               (call-with-engine-lock
                                (lambda ()
                                  (with-handlers ([exn:fail? (lambda (e) (status! (format "error: ~a" (exn-message e))))])
                                    (load-and-build (unbox current-page-path))
                                    (status! "reloaded")))))
                 #:on-close (lambda () (set-box! current-window #f))))
     (set-box! current-window w)
     w]))

(define (close-gui!)
  (define w (unbox current-window))
  (when w
    (gui-call 'window-close! w)
    (set-box! current-window #f)))

(define (status! text)
  (define w (unbox current-window))
  (when w (gui-call 'window-set-status! w text)))

;; Runs on the window's handler thread.
(define (gui-click x y)
  (call-with-engine-lock
   (lambda ()
     (define n (element-at x y))
     (cond
       [(not n) (status! (format "click (~a ~a): nothing there" (round x) (round y)))]
       [else
        (define h (node-handle n))
        (define-values (listened? rendered?) (click-handle! h void))
        (status! (format "click #~a ~a~a~a"
                         h (node-tag n)
                         (let ([id (node-id n)]) (if id (format " #~a" id) ""))
                         (cond [rendered? " → re-rendered"]
                               [listened? " (handler ran, no change)"]
                               [else " (no listeners)"])))]))))

;; ---------------------------------------------------------------------------
;; Commands

(define (cmd-help)
  (displayln
   (string-join
    '("Commands:"
      "  (render)            print the page at the current output tier"
      "  (set-output 'tier)  dump | ascii | image     (image writes render.png)"
      "  (screenshot \"f.png\") rasterize the current page to a PNG file"
      "  (gui)               open the popup window (clicks in it fire page handlers)"
      "  (click \"id\")        synthetic click on an element by id (or handle) → re-render if dirty"
      "  (dump-dom)          the live DOM tree with handles"
      "  (dump-boxes)        the layout box tree, (x y w h) per box"
      "  (inspect \"id\")      one node: attrs, computed style, boxes; also (inspect 3)"
      "  (ids)               id -> handle index"
      "  (stats)             node counts"
      "  (reload)            re-read the page, rebuild, rerun scripts, re-render"
      "  (help)  (quit)")
    "\n")))

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
                                (if p (format "#~a ~a" (node-handle p) (node-tag p)) "none (root or detached)")))
     (printf "children: ~a\n" (string-join
                               (for/list ([c (in-list (node-children n))])
                                 (format "#~a ~a" (node-handle c) (node-tag c)))
                               " "))
     (cond
       [(text-node? n) (printf "text:     ~s\n" (node-text n))]
       [(raw-node? n)  (printf "body:     ~a form(s)\n" (length (node-text n)))
                       (for ([f (in-list (node-text n))]) (printf "          ~s\n" f))])
     (define s (node-style n))
     (cond
       [(not s) (printf "style:    (not computed)\n")]
       [else
        (printf "style:    ~a\n"
                (string-join (for/list ([p (in-list style-properties)])
                               (format "~a=~a" p (hash-ref s p)))
                             " "))])
     (define bs (boxes-for n))
     (printf "boxes:    ~a\n"
             (if (null? bs)
                 "none (display none, or not in the box tree)"
                 (string-join (for/list ([b (in-list bs)])
                                (format "(~a ~a ~a ~a)" (lbox-x b) (lbox-y b) (lbox-w b) (lbox-h b)))
                              " ")))
     (define ls (for/list ([k (in-hash-keys listeners)] #:when (equal? (car k) (node-handle n))) (cdr k)))
     (unless (null? ls) (printf "listeners: ~a\n" (string-join ls " ")))]))

(define (boxes-for n)
  (define root (unbox current-boxes))
  (if root
      (let walk ([b root])
        (append (if (eq? (lbox-node b) n) (list b) '())
                (append* (map walk (lbox-children b)))))
      '()))

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
  (printf "next handle: ~a\n" (unbox next-id))
  (printf "listeners: ~a   boxes: ~a   ops: ~a\n"
          (hash-count listeners)
          (if (unbox current-boxes) (box-count (unbox current-boxes)) 0)
          (length (unbox current-ops))))

(define (cmd-reload)
  (load-and-build (unbox current-page-path))
  (printf "reloaded ~a\n" (unbox current-page-path))
  (cmd-stats))

(define (cmd-click key)
  (define h (resolve-handle key 'click))
  (cond
    [(not h) (printf "no node for ~s\n" key)]
    [else
     (define n (lookup-handle h))
     (define-values (listened? rendered?)
       (click-handle! h (lambda () (present-current!))))
     (cond [rendered? (void)]
           [listened? (printf "click #~a ~a: handler ran, document unchanged\n" h (node-tag n))]
           [else (printf "click #~a ~a: no listeners\n" h (node-tag n))])]))

(define (cmd-set-output tier)
  (define t (cond [(symbol? tier) tier] [(string? tier) (string->symbol tier)] [else #f]))
  (cond
    [(memq t output-tiers) (set-box! current-tier t) (printf "output: ~a\n" t)]
    [(eq? t 'gui) (open-gui!) (displayln "window open")]
    [else (printf "unknown tier ~s; one of ~a, or gui\n" tier output-tiers)]))

(define (cmd-screenshot path)
  (define p (if (path-string? path) path (format "~a" path)))
  (ensure-real-metrics!)
  (present-image (unbox current-ops) p)
  (printf "wrote ~a\n" p))

;; run-command : datum -> 'quit | void
(define (run-command form)
  (define head (and (pair? form) (car form)))
  (define args (if (pair? form) (cdr form) '()))
  (case head
    [(help ?)            (cmd-help)]
    [(render)            (present-current!)]
    [(dump-dom dom)      (dump-dom (unbox current-root))]
    [(dump-boxes boxes)  (dump-boxes (unbox current-boxes))]
    [(inspect)           (if (= (length args) 1)
                             (cmd-inspect (car args))
                             (displayln "usage: (inspect \"id\") or (inspect handle)"))]
    [(click)             (if (= (length args) 1)
                             (cmd-click (car args))
                             (displayln "usage: (click \"id\") or (click handle)"))]
    [(set-output output) (if (= (length args) 1)
                             (cmd-set-output (let ([a (car args)])
                                               (if (and (pair? a) (eq? (car a) 'quote)) (cadr a) a)))
                             (printf "usage: (set-output 'tier)  tiers: ~a gui\n" output-tiers))]
    [(screenshot)        (cmd-screenshot (if (pair? args) (car args) (unbox image-path)))]
    [(gui window)        (open-gui!) (displayln "window open")]
    [(ids)               (cmd-ids)]
    [(stats)             (cmd-stats)]
    [(reload)            (cmd-reload)]
    [(quit exit q)       'quit]
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
           (call-with-engine-lock (lambda () (run-command form)))))
       (unless (eq? result 'quit) (loop))])))

;; ---------------------------------------------------------------------------
;; CLI

(define (usage)
  (displayln "usage: racket src/driver.rkt run  page.sx [dump|ascii|image]")
  (displayln "       racket src/driver.rkt repl page.sx")
  (displayln "       racket src/driver.rkt gui  page.sx")
  (exit 2))

(define (boot path)
  (with-handlers ([exn:fail:page?
                   (lambda (e) (printf "page error: ~a\n" (exn-message e)) (exit 1))]
                  [exn:fail?
                   (lambda (e) (printf "build error: ~a\n" (exn-message e)) (exit 1))])
    (load-and-build path)))

(define (banner path)
  (printf "djb — loaded ~a\n" path)
  (cmd-stats)
  (displayln "type (help) for commands"))

(define (main . argv)
  (define mode (and (pair? argv) (car argv)))
  (define path (and (pair? argv) (pair? (cdr argv)) (cadr argv)))
  (cond
    [(and (equal? mode "run") path (<= (length argv) 3))
     (when (= (length argv) 3)
       (define t (string->symbol (caddr argv)))
       (unless (memq t output-tiers) (usage))
       (set-box! current-tier t))
     (boot path)
     (present-current!)]
    [(and (equal? mode "repl") path (= (length argv) 2))
     (boot path)
     (banner path)
     (repl)]
    [(and (equal? mode "gui") path (= (length argv) 2))
     (boot path)
     (open-gui!)
     (cond
       [(terminal-port? (current-input-port))
        (banner path)
        (displayln "window open — click in it, or drive it from here")
        (repl)]
       [else
        (gui-call 'window-wait (unbox current-window))])
     (exit 0)]
    [else (usage)]))

(module+ main
  (apply main (vector->list (current-command-line-arguments))))
