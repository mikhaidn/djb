#lang racket/base
;; paint.rkt — M3: box tree -> draw ops.
;;
;; Draw ops are plain lists, in paint order (a box's background before
;; its children, children in document order):
;;   (rect x y w h color tag)  filled rectangle, for boxes with a background-color;
;;                             `tag` is the element's tag (the ascii tier keys glyphs on it)
;;   (text x y w h string color) a text fragment; (x y) is the top-left of its glyph box
;;
;; Colors are the strings written in the stylesheet ("white", "#3366cc").
;; present.rkt decides what to do with them per output tier.

(require "dom.rkt"
         "style.rkt"
         "layout.rkt")

(provide paint
         op-rect? op-text?
         ops-extent
         dump-ops dump-ops-string)

;; paint : box -> (listof op)
(define (paint root)
  (define acc '())
  (define (emit! op) (set! acc (cons op acc)))
  (let walk ([b root])
    (define n (lbox-node b))
    (case (lbox-kind b)
      [(text)
       (emit! (list 'text (lbox-x b) (lbox-y b) (lbox-w b) (lbox-h b)
                    (lbox-text b) (style-ref n 'color "black")))]
      [else
       (define bg (style-ref n 'background-color #f))
       (when bg
         (emit! (list 'rect (lbox-x b) (lbox-y b) (lbox-w b) (lbox-h b) bg (node-tag n))))])
    (for ([c (in-list (lbox-children b))]) (walk c)))
  (reverse acc))

(define (op-rect? op) (eq? (car op) 'rect))
(define (op-text? op) (eq? (car op) 'text))

;; ops-extent : (listof op) -> (values width height)
;; Bounding size of all ops. Used by the ascii/image tiers to size the canvas.
(define (ops-extent ops)
  (for/fold ([w 0] [h 0]) ([op (in-list ops)])
    (values (max w (+ (list-ref op 1) (list-ref op 3)))
            (max h (+ (list-ref op 2) (list-ref op 4))))))

(define (dump-ops ops [out (current-output-port)])
  (for ([op (in-list ops)])
    (write op out)
    (newline out)))

(define (dump-ops-string ops)
  (define o (open-output-string))
  (dump-ops ops o)
  (get-output-string o))
