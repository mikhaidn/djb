#lang racket/base
;; style.rkt — M1: rule matching + computed style.
;;
;; Input: the live DOM (dom.rkt). Rules come from every (style ...) raw
;; node in the tree, in document order. Output: every node's `style`
;; field is set to an immutable hasheq of property -> value.
;;
;; Rule grammar (spec §3):
;;   (rule (selector) (prop value) ...)
;;   selector: (tag name) | (class name) | (id name)
;; Names may be written as symbols or strings; they are compared as
;; strings, so (id btn) and (id "btn") both match (@ (id "btn")).
;;
;; Cascade (spec §9): last matching rule wins, no specificity. The only
;; inherited property is `color`. Everything else falls back to the
;; defaults below.
;;
;; Properties and value shapes:
;;   display          'block | 'inline | 'none
;;   width height     number (px) | #f (auto)
;;   margin padding   number (px), applied to all four sides
;;   background-color string | #f (transparent)
;;   color            string (default "black")

(require racket/list
         racket/string
         "dom.rkt")

(provide compute-styles!
         collect-rules
         rule-matches?
         style-ref
         default-display
         style-properties)

(define style-properties
  '(display width height margin padding background-color color))

;; ---------------------------------------------------------------------------
;; Defaults

(define (default-display tag)
  (case tag
    [(document body div p)        'block]
    [(head title style script)    'none]
    [(span button text)           'inline]
    [else                         'inline]))

(define (->name-string x)
  (cond [(string? x) x]
        [(symbol? x) (symbol->string x)]
        [else (format "~a" x)]))

;; ---------------------------------------------------------------------------
;; Rules

;; collect-rules : node -> (listof rule-form)
;; Every (rule ...) form from every (style ...) node, in document order.
(define (collect-rules root)
  (let walk ([n root])
    (cond
      [(and (raw-node? n) (eq? (node-tag n) 'style))
       (for/list ([r (in-list (node-text n))])
         (unless (and (pair? r) (eq? (car r) 'rule) (pair? (cdr r)) (pair? (cadr r)))
           (error 'style "malformed rule ~s (expected (rule (selector) (prop value) ...))" r))
         r)]
      [else
       (append* (for/list ([c (in-list (node-children n))]) (walk c)))])))

;; rule-matches? : rule-form node -> boolean
(define (rule-matches? rule n)
  (define sel (cadr rule))
  (define kind (car sel))
  (define name (->name-string (cadr sel)))
  (case kind
    [(tag)   (equal? name (symbol->string (node-tag n)))]
    [(id)    (let ([v (node-attr n 'id)]) (and v (equal? name (->name-string v))))]
    [(class) (let ([v (node-attr n 'class)])
               (and v (member name (string-split (->name-string v))) #t))]
    [else (error 'style "unknown selector ~s (expected tag, class, or id)" sel)]))

;; ---------------------------------------------------------------------------
;; Value normalisation

(define (normalize-value prop val)
  (case prop
    [(display)
     (define d (if (string? val) (string->symbol val) val))
     (unless (memq d '(block inline none))
       (error 'style "display must be block, inline, or none; got ~s" val))
     d]
    [(width height margin padding)
     (unless (real? val)
       (error 'style "~a must be a number (px); got ~s" prop val))
     val]
    [(background-color color)
     (->name-string val)]
    [else
     (error 'style "unknown property ~s (supported: ~a)" prop style-properties)]))

;; ---------------------------------------------------------------------------
;; Compute

;; compute-styles! : node -> void
;; Walks the tree, fills `node-style` for every node.
(define (compute-styles! root)
  (define rules (collect-rules root))
  (let walk ([n root] [parent-style #f])
    (define s (compute-one n rules parent-style))
    (set-node-style! n s)
    (for ([c (in-list (node-children n))])
      (walk c s))))

(define (compute-one n rules parent-style)
  (define inherited-color (if parent-style (hash-ref parent-style 'color) "black"))
  (define base
    (hasheq 'display          (default-display (node-tag n))
            'width            #f
            'height           #f
            'margin           0
            'padding          0
            'background-color #f
            'color            inherited-color))
  (cond
    [(element? n)
     (for*/fold ([s base])
                ([r (in-list rules)]
                 #:when (rule-matches? r n)
                 [decl (in-list (cddr r))])
       (unless (and (pair? decl) (symbol? (car decl)) (pair? (cdr decl)) (null? (cddr decl)))
         (error 'style "malformed declaration ~s in ~s (expected (prop value))" decl r))
       (hash-set s (car decl) (normalize-value (car decl) (cadr decl))))]
    [else base]))

;; style-ref : node prop [default] -> value
(define (style-ref n prop [default #f])
  (define s (node-style n))
  (if s (hash-ref s prop default) default))
