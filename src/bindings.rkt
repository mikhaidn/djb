#lang racket/base
;; bindings.rkt — M4/M5: the host procedures page scripts get.
;;
;; Spec §4/§5. Every procedure takes/returns integer handles, never
;; nodes, and validates the handle on entry. Every mutating procedure
;; sets `document-dirty?` — that single flag is the repaint trigger the
;; event loop (runtime.rkt) watches.
;;
;; Semantics beyond the spec sketch:
;;   * text-content on an element = concatenated descendant text
;;     (like DOM textContent); set-text! on an element replaces all its
;;     children with one fresh text node, so `(set-text! root "Clicked!")`
;;     makes the button disappear, as in a real browser.
;;   * Attribute names may be strings or symbols from scripts; they are
;;     stored as symbols. Setting `id` keeps id-index in sync.
;;   * remove-child! detaches; the node stays in node-table so its
;;     handle remains valid (it can be re-appended). Handles are never
;;     reused within a session.

(require racket/list
         racket/string
         "dom.rkt")

(provide (struct-out event)
         listeners
         reset-bindings!
         host-bindings
         h:get-element h:text-content h:set-text!
         h:get-attribute h:set-attribute!
         h:create-element h:append-child! h:remove-child!
         h:on!)

;; The record a handler receives.
(struct event (type target) #:transparent)

;; (handle . event-type) -> (listof proc), most recently registered first
(define listeners (make-hash))

(define (reset-bindings!)
  (hash-clear! listeners))

(define (dirty!) (set-box! document-dirty? #t))

;; ---------------------------------------------------------------------------
;; Validation

(define (->node who h)
  (unless (exact-nonnegative-integer? h)
    (error who "expected a node handle (integer), got ~s" h))
  (or (lookup-handle h)
      (error who "no node with handle ~a (stale handle?)" h)))

(define (->attr-name who name)
  (cond [(symbol? name) name]
        [(string? name) (string->symbol name)]
        [else (error who "attribute name must be a string or symbol, got ~s" name)]))

(define (->string who v)
  (cond [(string? v) v]
        [(number? v) (number->string v)]
        [(symbol? v) (symbol->string v)]
        [else (error who "expected a string, got ~s" v)]))

;; ---------------------------------------------------------------------------
;; Host procedures

(define (h:get-element id)
  (hash-ref id-index (->string 'get-element id) #f))

(define (h:text-content h)
  (define n (->node 'text-content h))
  (let walk ([n n])
    (cond [(text-node? n) (node-text n)]
          [(raw-node? n) ""]
          [else (string-append* (map walk (node-children n)))])))

(define (h:set-text! h str)
  (define n (->node 'set-text! h))
  (define s (->string 'set-text! str))
  (cond
    [(text-node? n) (set-node-text! n s)]
    [(raw-node? n) (error 'set-text! "cannot set text of a ~a node" (node-tag n))]
    [else
     (for ([c (in-list (node-children n))]) (set-node-parent! c #f))
     (define t (register! 'text '() '() n s))
     (set-node-children! n (list t))])
  (dirty!))

(define (h:get-attribute h name)
  (node-attr (->node 'get-attribute h) (->attr-name 'get-attribute name)))

(define (h:set-attribute! h name val)
  (define n (->node 'set-attribute! h))
  (define k (->attr-name 'set-attribute! name))
  (set-node-attrs! n (cons (cons k val)
                           (filter (lambda (a) (not (eq? (car a) k))) (node-attrs n))))
  (when (eq? k 'id)
    (hash-set! id-index val h))
  (dirty!))

(define (h:create-element tag)
  (define t (cond [(symbol? tag) tag]
                  [(string? tag) (string->symbol tag)]
                  [else (error 'create-element "tag must be a string or symbol, got ~s" tag)]))
  (node-handle (register! t '() '() #f #f)))

(define (h:append-child! parent-h child-h)
  (define p (->node 'append-child! parent-h))
  (define c (->node 'append-child! child-h))
  (when (raw-node? p) (error 'append-child! "cannot append to a ~a node" (node-tag p)))
  (when (text-node? p) (error 'append-child! "cannot append to a text node"))
  (let loop ([a p])                       ; no cycles
    (when a
      (when (eq? a c) (error 'append-child! "node #~a would become its own ancestor" child-h))
      (loop (node-parent a))))
  (define old (node-parent c))            ; move if already attached somewhere
  (when old (set-node-children! old (remq c (node-children old))))
  (set-node-children! p (append (node-children p) (list c)))
  (set-node-parent! c p)
  (dirty!))

(define (h:remove-child! parent-h child-h)
  (define p (->node 'remove-child! parent-h))
  (define c (->node 'remove-child! child-h))
  (unless (memq c (node-children p))
    (error 'remove-child! "node #~a is not a child of #~a" child-h parent-h))
  (set-node-children! p (remq c (node-children p)))
  (set-node-parent! c #f)
  (dirty!))

(define (h:on! h type proc)
  (->node 'on! h)
  (unless (procedure? proc) (error 'on! "handler must be a procedure, got ~s" proc))
  (hash-update! listeners (cons h (->string 'on! type))
                (lambda (ps) (cons proc ps)) '()))

;; The names page scripts see (spec §5) and what they bind to.
(define host-bindings
  (list (cons 'get-element    h:get-element)
        (cons 'text-content   h:text-content)
        (cons 'set-text!      h:set-text!)
        (cons 'get-attribute  h:get-attribute)
        (cons 'set-attribute! h:set-attribute!)
        (cons 'create-element h:create-element)
        (cons 'append-child!  h:append-child!)
        (cons 'remove-child!  h:remove-child!)
        (cons 'on!            h:on!)
        (cons 'event?         event?)
        (cons 'event-type     event-type)
        (cons 'event-target   event-target)))
