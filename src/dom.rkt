#lang racket/base
;; dom.rkt — the live node tree, the handle table, and dump-dom.
;;
;; The parsed datum from loader.rkt is turned into mutable `node`
;; records with parent pointers. Every node is registered in
;; `node-table` under an integer handle; that handle is the ONLY thing
;; the script sandbox will ever see (M4). Elements with an `id` attr
;; are additionally indexed in `id-index` for get-element.
;;
;; Node grammar (SXML-style):
;;   (tag (@ (attr value) ...) child ...)   element; (@ ...) optional, first
;;   "string"                               text node
;;   (style rule ...) / (script form ...)   raw bodies, not walked
;;
;; Deviations from the spec's struct sketch, all deliberate:
;;   * `handle` is stored on the node (immutable) so node->handle is O(1)
;;     without a reverse table. The spec's struct had no such field.
;;   * Text nodes use tag 'text (not an element in the MVP element set,
;;     so no collision) with the string in `text`.
;;   * (style ...) and (script ...) are NOT walked as element children.
;;     Their bodies are kept verbatim in the `text` field as a list of
;;     forms, so `text` is: #f for elements, a string for text nodes,
;;     a list for style/script. style.rkt (M1) and runtime.rkt (M4)
;;     read them from there.
;;   * Attribute names are symbols, attribute values are kept as written
;;     (strings in all fixtures). id-index is keyed by the value as
;;     written, so `(get-element "btn")` matches `(id "btn")`.

(require racket/list
         racket/string
         racket/format)

(provide (struct-out node)
         ;; tables (exported so bindings.rkt/runtime.rkt can share them)
         node-table id-index next-id document-dirty?
         reset-dom!
         register!
         ;; build
         build-dom
         ;; lookup
         lookup-handle lookup-id
         ;; predicates / helpers
         element? text-node? raw-node?
         node-attr node-id
         dom-stats
         ;; output
         dump-dom
         dump-dom-string)

;; ---------------------------------------------------------------------------
;; Node record

(struct node (handle                 ; exact-nonnegative-integer, fixed at register!
              tag                    ; symbol; 'text for text nodes
              [attrs    #:mutable]   ; alist (symbol . value)
              [children #:mutable]   ; list of node
              [parent   #:mutable]   ; node or #f
              [text     #:mutable]   ; #f | string (text node) | list (style/script body)
              [style    #:mutable])  ; computed style, filled in by style.rkt (M1)
  ;; Opaque with a short printer: the tree is cyclic (parent pointers),
  ;; so a transparent struct would print as a #0=... graph blob.
  #:property prop:custom-write
  (lambda (n port mode)
    (fprintf port "#<node #~a ~a>" (node-handle n) (node-tag n))))

;; ---------------------------------------------------------------------------
;; Tables

(define node-table      (make-hasheqv))  ; handle -> node
(define id-index        (make-hash))     ; id attr value -> handle
(define next-id         (box 0))
(define document-dirty? (box #t))

;; Wipe all tables. Called before every build (reload, tests).
(define (reset-dom!)
  (hash-clear! node-table)
  (hash-clear! id-index)
  (set-box! next-id 0)
  (set-box! document-dirty? #t))

;; register! : symbol alist list node/#f text -> node
;; Allocates the next handle, constructs the node, records it in
;; node-table and (if it has an id attr) id-index. Returns the node.
;; This is the single choke point where handles are minted; M4's
;; create-element goes through here too.
(define (register! tag attrs children parent text)
  (define h (unbox next-id))
  (set-box! next-id (add1 h))
  (define n (node h tag attrs children parent text #f))
  (hash-set! node-table h n)
  (define id (assq 'id attrs))
  (when id
    (hash-set! id-index (cdr id) h))
  n)

;; ---------------------------------------------------------------------------
;; Building

(define raw-tags '(style script))

(define (attr-form? x)
  (and (pair? x) (eq? (car x) '@)))

;; parse-attrs : (@ (name value) ...) -> alist
(define (parse-attrs form)
  (for/list ([a (in-list (cdr form))])
    (unless (and (pair? a) (symbol? (car a)) (pair? (cdr a)) (null? (cddr a)))
      (error 'build-dom "malformed attribute ~s (expected (name value))" a))
    (cons (car a) (cadr a))))

;; build-dom : datum -> node
;; Resets the tables and builds a fresh tree rooted at the datum.
;; Handles are assigned in pre-order, so the document root is always 0.
(define (build-dom datum)
  (reset-dom!)
  (build-node datum #f))

(define (build-node datum parent)
  (cond
    ;; text node
    [(string? datum)
     (register! 'text '() '() parent datum)]

    ;; element
    [(and (pair? datum) (symbol? (car datum)))
     (define tag (car datum))
     (define rest (cdr datum))
     (define-values (attrs body)
       (if (and (pair? rest) (attr-form? (car rest)))
           (values (parse-attrs (car rest)) (cdr rest))
           (values '() rest)))
     (cond
       ;; style / script: keep body verbatim, don't walk
       [(memq tag raw-tags)
        (register! tag attrs '() parent body)]
       [else
        ;; Register the parent BEFORE children so pre-order handles hold.
        (define n (register! tag attrs '() parent #f))
        (set-node-children! n (for/list ([c (in-list body)])
                                (build-node c n)))
        n])]

    [else
     (error 'build-dom "cannot build node from ~s (expected element list or string)" datum)]))

;; ---------------------------------------------------------------------------
;; Lookup & helpers

;; lookup-handle : integer -> node | #f
(define (lookup-handle h) (hash-ref node-table h #f))

;; lookup-id : id-value -> node | #f
(define (lookup-id id)
  (define h (hash-ref id-index id #f))
  (and h (lookup-handle h)))

(define (text-node? n) (eq? (node-tag n) 'text))
(define (raw-node? n)  (and (memq (node-tag n) raw-tags) #t))
(define (element? n)   (not (or (text-node? n) (raw-node? n))))

(define (node-attr n name) (cond [(assq name (node-attrs n)) => cdr] [else #f]))
(define (node-id n) (node-attr n 'id))

;; dom-stats : -> (values total elements text-nodes raw-nodes)
(define (dom-stats)
  (define ns (hash-values node-table))
  (values (length ns)
          (count element? ns)
          (count text-node? ns)
          (count raw-node? ns)))

;; ---------------------------------------------------------------------------
;; dump-dom
;;
;; One line per node, indented by depth:
;;   #<handle> <tag> [attrs] | text / body summary
;; e.g.
;;   #0 document
;;     #1 head
;;       #2 title
;;         #3 "Hello"
;;   ...
;;       #10 style (3 rules)
;;       #11 script (1 form)

(define (format-attrs attrs)
  (if (null? attrs)
      ""
      (string-append
       " ["
       (string-join (for/list ([a (in-list attrs)])
                      (format "~a=~s" (car a) (cdr a)))
                    " ")
       "]")))

(define (format-node n)
  (cond
    [(text-node? n)
     (format "#~a ~s" (node-handle n) (node-text n))]
    [(raw-node? n)
     (define body (node-text n))
     (define k (length body))
     (define unit (if (eq? (node-tag n) 'style) "rule" "form"))
     (format "#~a ~a~a (~a ~a~a)"
             (node-handle n) (node-tag n) (format-attrs (node-attrs n))
             k unit (if (= k 1) "" "s"))]
    [else
     (format "#~a ~a~a" (node-handle n) (node-tag n) (format-attrs (node-attrs n)))]))

;; dump-dom : node [output-port] -> void
(define (dump-dom root [out (current-output-port)])
  (let walk ([n root] [depth 0])
    (write-string (make-string (* 2 depth) #\space) out)
    (write-string (format-node n) out)
    (newline out)
    (for ([c (in-list (node-children n))])
      (walk c (add1 depth)))))

;; dump-dom-string : node -> string   (handy for tests)
(define (dump-dom-string root)
  (define o (open-output-string))
  (dump-dom root o)
  (get-output-string o))
