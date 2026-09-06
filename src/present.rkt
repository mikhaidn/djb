#lang racket/base
;; present.rkt — M3: draw ops -> an output tier.
;;
;;   dump   print the ops, one per line                      (zero deps)
;;   ascii  scale boxes onto a character grid                (zero deps)
;;   image  rasterize to a PNG with racket/draw              (no display needed)
;;   gui    a live window; see gui.rkt (needs a display)
;;
;; `draw-ops!` is the shared rasterizer used by both the image tier and
;; the window: given any dc<%> it draws the ops with the current font.
;; `make-text-measurer` builds a layout.rkt measurer from real font
;; metrics so that image/gui geometry matches what gets drawn.
;;
;; The ascii tier maps px -> cells with the same 8x18 cell that
;; layout.rkt's default measurer assumes, so text lands exactly in its
;; box. Rect ops fill their cells with a glyph per element (first letter
;; of the tag; body '.', document ' '); text ops overwrite with the real
;; characters. Later ops overwrite earlier ones, matching paint order.

(require racket/class
         racket/draw
         racket/string
         "dom.rkt"
         "paint.rkt")

(provide output-tiers
         present-dump
         present-ascii ascii-string
         present-image
         draw-ops!
         make-text-measurer
         default-font
         ascii-cell-w ascii-cell-h)

(define output-tiers '(dump ascii image))

;; ---------------------------------------------------------------------------
;; dump

(define (present-dump ops [out (current-output-port)])
  (dump-ops ops out))

;; ---------------------------------------------------------------------------
;; ascii

(define ascii-cell-w 8)
(define ascii-cell-h 18)

;; glyph : tag -> char
(define (glyph tag)
  (case tag
    [(document) #\space]
    [(body)     #\.]
    [else       (string-ref (symbol->string tag) 0)]))

(define (ascii-string ops #:width [width #f] #:height [height #f])
  (define-values (ew eh) (ops-extent ops))
  (define w (or width  (max 1 (ceiling (/ ew ascii-cell-w)))))
  (define h (or height (max 1 (ceiling (/ eh ascii-cell-h)))))
  (define rows (for/vector ([_ (in-range h)]) (make-string w #\space)))
  (define text-cells (for/vector ([_ (in-range h)]) (make-vector w #f)))
  (define (in-grid? col row) (and (>= row 0) (< row h) (>= col 0) (< col w)))
  (define (put! col row ch)
    (when (in-grid? col row)
      (string-set! (vector-ref rows row) col ch)))
  (define (text-cell? col row)
    (and (in-grid? col row) (vector-ref (vector-ref text-cells row) col)))
  (define (put-text! col row ch)
    (when (in-grid? col row)
      (string-set! (vector-ref rows row) col ch)
      (vector-set! (vector-ref text-cells row) col #t)))
  (for ([op (in-list ops)])
    (case (car op)
      [(rect)
       (define-values (x y bw bh) (values (cadr op) (caddr op) (cadddr op) (car (cddddr op))))
       (when (and (> bw 0) (> bh 0))
         ;; edges snap to the nearest cell boundary; at least one cell
         (define c0 (round (/ x ascii-cell-w)))
         (define c1 (max (add1 c0) (round (/ (+ x bw) ascii-cell-w))))
         (define r0 (round (/ y ascii-cell-h)))
         (define r1 (max (add1 r0) (round (/ (+ y bh) ascii-cell-h))))
         (define ch (glyph (list-ref op 6)))
         (for* ([r (in-range r0 r1)] [c (in-range c0 c1)]) (put! c r ch)))]
      [(text)
       (define col (inexact->exact (round (/ (cadr op) ascii-cell-w))))
       (define row (inexact->exact (floor (/ (caddr op) ascii-cell-h))))
       ;; a one-cell gap between two fragments on a line is a word space:
       ;; blank it instead of leaving the parent's glyph showing through
       (when (and (not (text-cell? (- col 1) row)) (text-cell? (- col 2) row))
         (put-text! (- col 1) row #\space))
       (for ([ch (in-string (list-ref op 5))] [i (in-naturals)])
         (put-text! (+ col i) row ch))]))
  (string-join (for/list ([r (in-vector rows)]) (string-trim r #:left? #f)) "\n"))

(define (present-ascii ops [out (current-output-port)])
  (write-string (ascii-string ops) out)
  (newline out))

;; ---------------------------------------------------------------------------
;; racket/draw rasterizer (image tier + window)

(define default-font (make-font #:size 14 #:family 'default))

;; make-text-measurer : [font] -> (string -> (values w h))
(define (make-text-measurer [font default-font])
  (define dc (new bitmap-dc% [bitmap (make-bitmap 1 1)]))
  (send dc set-font font)
  (lambda (s)
    (define-values (w h _d _a) (send dc get-text-extent s font #t))
    (values w h)))

(define (->color str)
  (or (send the-color-database find-color str)
      (with-handlers ([exn:fail? (lambda (e) #f)])
        (and (regexp-match? #px"^#[0-9a-fA-F]{6}$" str)
             (make-color (string->number (substring str 1 3) 16)
                         (string->number (substring str 3 5) 16)
                         (string->number (substring str 5 7) 16))))
      (make-color 255 0 255)))   ; unknown color: loud magenta

;; draw-ops! : dc ops [font] -> void
(define (draw-ops! dc ops [font default-font])
  (send dc set-font font)
  (send dc set-pen "black" 1 'transparent)
  (send dc set-text-mode 'transparent)
  (for ([op (in-list ops)])
    (case (car op)
      [(rect)
       (send dc set-brush (->color (list-ref op 5)) 'solid)
       (send dc draw-rectangle (cadr op) (caddr op) (cadddr op) (list-ref op 4))]
      [(text)
       (send dc set-text-foreground (->color (list-ref op 6)))
       (send dc draw-text (list-ref op 5) (cadr op) (caddr op) #t)])))

;; present-image : ops path #:width #:height -> path
(define (present-image ops path #:width [width #f] #:height [height #f] #:font [font default-font])
  (define-values (ew eh) (ops-extent ops))
  (define w (max 1 (inexact->exact (ceiling (or width ew)))))
  (define h (max 1 (inexact->exact (ceiling (or height eh)))))
  (define bm (make-bitmap w h))
  (define dc (new bitmap-dc% [bitmap bm]))
  (send dc set-background "white")
  (send dc clear)
  (send dc set-smoothing 'aligned)
  (draw-ops! dc ops font)
  (send bm save-file path 'png)
  path)
