#lang racket/base
;; layout.rkt — M2: styled tree -> box tree with absolute (x y w h).
;;
;; Block flow + naive inline, per spec §2/§9:
;;   * A block box stacks its block children vertically. Consecutive
;;     inline/text children form an "inline run" laid out on lines
;;     directly inside the block (no anonymous boxes are created).
;;   * Text is split on whitespace into word fragments; each fragment
;;     is its own 'text box. Lines wrap greedily at the block's content
;;     width. An inline element's box is the union of its fragments,
;;     expanded by its padding.
;;   * `width`/`height` are content-box sizes (padding is added outside,
;;     like CSS). `margin` and `padding` are single numbers for all sides.
;;   * Inline elements honour horizontal padding/margin only; width and
;;     height on inline elements are ignored. A block inside an inline
;;     element is laid out as if inline.
;;   * display none: the subtree produces no boxes.
;;   * Margins do not collapse. Fixed viewport width (`viewport-width`).
;;
;; Text measurement is pluggable: `text-measurer` is a box holding a
;; (string -> (values width height)) procedure. The default is a
;; deterministic monospace estimate (8px per char, 18px line) so tests
;; and the ascii tier are stable. The image/gui tiers install real font
;; metrics via present.rkt.

(require racket/list
         racket/string
         racket/base
         "dom.rkt"
         "style.rkt")

(provide (struct-out lbox)
         layout-document
         viewport-width
         text-measurer default-text-measurer
         box-at
         lbox-right lbox-bottom
         dump-boxes dump-boxes-string
         box-count)

;; ---------------------------------------------------------------------------
;; Box record (named lbox so it does not shadow racket's `box`)
;;
;; kind: 'block | 'inline | 'text
;; node: the DOM node this box belongs to (a text box's node is the text node;
;;       one text node may produce many text boxes, one per word fragment)
;; text: the fragment string for 'text boxes, else #f

(struct lbox (node kind [x #:mutable] [y #:mutable] [w #:mutable] [h #:mutable]
                  [children #:mutable] text)
  #:property prop:custom-write
  (lambda (b port mode)
    (fprintf port "#<box #~a ~a ~a>" (node-handle (lbox-node b)) (lbox-kind b)
             (list (lbox-x b) (lbox-y b) (lbox-w b) (lbox-h b)))))

(define (lbox-right b)  (+ (lbox-x b) (lbox-w b)))
(define (lbox-bottom b) (+ (lbox-y b) (lbox-h b)))

;; ---------------------------------------------------------------------------
;; Parameters (plain boxes, not Racket parameters, so a value set in one
;; thread — the REPL — is seen by another — the GUI eventspace).

(define viewport-width (box 800))

(define (default-text-measurer s)
  (values (* 8 (string-length s)) 18))

(define text-measurer (box default-text-measurer))

(define (measure s) ((unbox text-measurer) s))

;; ---------------------------------------------------------------------------
;; Entry

;; layout-document : node -> box
;; Requires compute-styles! to have run. Root box is at (0 0).
(define (layout-document root)
  (layout-block root 0 0 (unbox viewport-width)))

(define (display-of n) (style-ref n 'display 'block))
(define (visible? n)   (not (eq? (display-of n) 'none)))
(define (inline-level? n) (or (text-node? n) (eq? (display-of n) 'inline)))

;; ---------------------------------------------------------------------------
;; Block layout
;;
;; layout-block : node x0 y0 avail-w -> box
;; (x0 y0) is the top-left of the margin edge; avail-w is the width
;; available for margin+border box. Returns the box with children laid out.

(define (layout-block n x0 y0 avail-w)
  (define m (style-ref n 'margin 0))
  (define p (style-ref n 'padding 0))
  (define width  (style-ref n 'width #f))
  (define height (style-ref n 'height #f))
  (define x (+ x0 m))
  (define y (+ y0 m))
  (define w (if width (+ width (* 2 p)) (max 0 (- avail-w (* 2 m)))))
  (define cx (+ x p))
  (define cw (max 0 (- w (* 2 p))))
  (define b (lbox n 'block x y w 0 '() #f))
  ;; children: group into block items and inline runs
  (define cursor (+ y p))
  (define kids '())
  (let loop ([cs (filter visible? (node-children n))])
    (cond
      [(null? cs) (void)]
      [(inline-level? (car cs))
       (define-values (run rest) (splitf-at cs inline-level?))
       (define-values (boxes run-h) (layout-inline-run run cx cursor cw))
       (set! kids (append kids boxes))
       (set! cursor (+ cursor run-h))
       (loop rest)]
      [else
       (define cb (layout-block (car cs) cx cursor cw))
       (define cm (style-ref (car cs) 'margin 0))
       (set! kids (append kids (list cb)))
       (set! cursor (+ cursor (lbox-h cb) (* 2 cm)))
       (loop (cdr cs))]))
  (set-lbox-children! b kids)
  (set-lbox-h! b (if height (+ height (* 2 p)) (+ (- cursor y) p)))
  b)

;; ---------------------------------------------------------------------------
;; Inline layout
;;
;; A line builder holds the current line's pending fragments. Fragments
;; are placed with a final x immediately; y is assigned when the line
;; closes (the line height is the max fragment height incl. inline
;; padding). Each fragment is a 'text box; inline element boxes are
;; built afterwards as unions of their descendants.

(struct lb (left right x y pending space? total-h any?) #:mutable)

;; pending entries: (vector box pad-v)
(define (lb-line-empty? L) (null? (lb-pending L)))

(define (lb-close-line! L)
  (unless (lb-line-empty? L)
    (define line-h
      (for/fold ([h 0]) ([e (in-list (lb-pending L))])
        (max h (+ (lbox-h (vector-ref e 0)) (* 2 (vector-ref e 1))))))
    (for ([e (in-list (lb-pending L))])
      (set-lbox-y! (vector-ref e 0) (+ (lb-y L) (vector-ref e 1))))
    (set-lb-y! L (+ (lb-y L) line-h))
    (set-lb-total-h! L (+ (lb-total-h L) line-h))
    (set-lb-pending! L '()))
  (set-lb-x! L (lb-left L))
  (set-lb-space?! L #f))

;; Place one word fragment for text node n.
(define (lb-word! L n word pad-v)
  (define-values (w h) (measure word))
  (define-values (sw _sh) (measure " "))
  (define advance-space (if (and (lb-space? L) (not (lb-line-empty? L))) sw 0))
  (when (and (not (lb-line-empty? L))
             (> (+ (lb-x L) advance-space w) (lb-right L)))
    (lb-close-line! L)
    (set! advance-space 0))
  (define fx (+ (lb-x L) advance-space))
  (define b (lbox n 'text fx (lb-y L) w h '() word))
  (set-lb-pending! L (cons (vector b pad-v) (lb-pending L)))
  (set-lb-x! L (+ fx w))
  (set-lb-space?! L #t)      ; words of one text node are whitespace-separated
  (set-lb-any?! L #t)
  b)

;; layout-inline-run : (listof node) x y avail-w -> (values (listof box) height)
(define (layout-inline-run nodes x y avail-w)
  (define L (lb x (+ x avail-w) x y '() #f 0 #f))
  (define boxes
    (append*
     (for/list ([n (in-list nodes)])
       (place-inline n L 0))))
  (lb-close-line! L)
  ;; every fragment now has its final y; size the inline element boxes
  (for ([b (in-list boxes)]) (union-inline! b))
  (values boxes (lb-total-h L)))

;; place-inline : node lb pad-v -> (listof box)
;; Text nodes return one box per word fragment; elements return a
;; single-element list with their (not yet sized) box.
(define (place-inline n L pad-v)
  (cond
    [(text-node? n)
     (define s (node-text n))
     (define words (string-split s))
     (when (and (positive? (string-length s))
                (char-whitespace? (string-ref s 0)))
       (set-lb-space?! L #t))
     (define frags (for/list ([w (in-list words)]) (lb-word! L n w pad-v)))
     ;; after the node, a space is pending only if it ended in whitespace
     (unless (null? words)
       (set-lb-space?! L (char-whitespace? (string-ref s (sub1 (string-length s))))))
     frags]
    [(not (visible? n)) '()]
    [else
     (define p (style-ref n 'padding 0))
     (define m (style-ref n 'margin 0))
     (set-lb-x! L (+ (lb-x L) m p))
     (define start-x (lb-x L))
     (define start-y (lb-y L))          ; top of the current line
     (define kids (append* (for/list ([c (in-list (node-children n))])
                             (place-inline c L (+ pad-v p)))))
     (set-lb-x! L (+ (lb-x L) p m))
     (list (lbox n 'inline start-x start-y 0 0 kids #f))]))

;; union-inline! : box -> void
;; Sizes an inline element box to the union of its children (recursively),
;; expanded by its own padding. An empty inline element is a padding-only
;; box at the point where it was placed.
(define (union-inline! b)
  (when (eq? (lbox-kind b) 'inline)
    (for ([c (in-list (lbox-children b))]) (union-inline! c))
    (define p (style-ref (lbox-node b) 'padding 0))
    (define kids (lbox-children b))
    (cond
      [(null? kids)
       (set-lbox-x! b (- (lbox-x b) p))
       (set-lbox-y! b (lbox-y b))
       (set-lbox-w! b (* 2 p))
       (set-lbox-h! b (* 2 p))]
      [else
       (define x0 (apply min (map lbox-x kids)))
       (define y0 (apply min (map lbox-y kids)))
       (define x1 (apply max (map lbox-right kids)))
       (define y1 (apply max (map lbox-bottom kids)))
       (set-lbox-x! b (- x0 p))
       (set-lbox-y! b (- y0 p))
       (set-lbox-w! b (+ (- x1 x0) (* 2 p)))
       (set-lbox-h! b (+ (- y1 y0) (* 2 p)))])))

;; ---------------------------------------------------------------------------
;; Hit testing

;; box-at : box x y -> box | #f
;; Deepest box containing the point (later siblings win on overlap).
(define (box-at b px py)
  (define (inside? bb)
    (and (>= px (lbox-x bb)) (< px (lbox-right bb))
         (>= py (lbox-y bb)) (< py (lbox-bottom bb))))
  (and (inside? b)
       (or (for/or ([c (in-list (reverse (lbox-children b)))])
             (box-at c px py))
           b)))

;; ---------------------------------------------------------------------------
;; dump-boxes

(define (fmt-num v) (if (integer? v) (inexact->exact v) (/ (round (* v 10)) 10.0)))

(define (format-box b)
  (define n (lbox-node b))
  (define geom (format "(~a ~a ~a ~a)" (fmt-num (lbox-x b)) (fmt-num (lbox-y b))
                       (fmt-num (lbox-w b)) (fmt-num (lbox-h b))))
  (case (lbox-kind b)
    [(text) (format "#~a ~s ~a" (node-handle n) (lbox-text b) geom)]
    [else   (format "#~a ~a ~a ~a" (node-handle n) (node-tag n) (lbox-kind b) geom)]))

(define (dump-boxes root [out (current-output-port)])
  (let walk ([b root] [depth 0])
    (write-string (make-string (* 2 depth) #\space) out)
    (write-string (format-box b) out)
    (newline out)
    (for ([c (in-list (lbox-children b))]) (walk c (add1 depth)))))

(define (dump-boxes-string root)
  (define o (open-output-string))
  (dump-boxes root o)
  (get-output-string o))

(define (box-count root)
  (add1 (for/sum ([c (in-list (lbox-children root))]) (box-count c))))
