#lang racket/base
;; gui.rkt — the popup window (the `gui` output tier).
;;
;; This is the only module that touches racket/gui, and driver.rkt loads
;; it lazily (dynamic-require) so `run`, `repl`, and the tests work on a
;; machine with no display.
;;
;; The window knows nothing about the engine. It is handed callbacks:
;;   #:paint           (dc -> void)      draw the current page onto a dc
;;   #:content-height  (-> real)         document height, for the scrollbar
;;   #:on-click        (x y -> void)     left click at page coordinates
;;   #:on-reload       (-> void)         the Reload button / the `r` key
;;   #:on-close        (-> void)         the window was closed
;;
;; It runs in its own eventspace, so the caller's thread (the REPL) is
;; not blocked and can keep issuing commands; both sides poke the same
;; engine, so the caller serialises with a lock. The callbacks run on
;; the window's handler thread.

(require racket/class
         racket/gui/base)

(provide open-window
         window?
         window-refresh!
         window-set-status!
         window-set-title!
         window-close!
         window-shown?
         window-click!
         window-wait)

(struct window (eventspace frame canvas status paint content-height))

(define page-canvas%
  (class canvas%
    (init-field on-click on-key)
    (define/override (on-event e)
      (when (eq? (send e get-event-type) 'left-down)
        (define-values (vx vy) (send this get-view-start))
        (on-click (+ (send e get-x) vx) (+ (send e get-y) vy))))
    (define/override (on-char e)
      (on-key (send e get-key-code)))
    (super-new)))

(define page-frame%
  (class frame%
    (init-field on-close-cb)
    (define/augment (on-close) (on-close-cb))
    (super-new)))

;; open-window : ... -> window
(define (open-window #:title title
                     #:width width
                     #:height height
                     #:paint paint
                     #:content-height content-height
                     #:on-click on-click
                     #:on-reload on-reload
                     #:on-close on-close)
  (define es (make-eventspace))
  (define result-ch (make-channel))
  (parameterize ([current-eventspace es])
    (queue-callback
     (lambda ()
       (define frame (new page-frame% [label title] [on-close-cb on-close]))
       (define bar (new horizontal-panel% [parent frame] [stretchable-height #f]
                        [alignment '(left center)]))
       (new button% [parent bar] [label "Reload"]
            [callback (lambda (b e) (on-reload))])
       (define status (new message% [parent bar] [label ""] [auto-resize #t]))
       (define canvas
         (new page-canvas% [parent frame]
              [style '(vscroll)]
              [min-width width] [min-height height]
              [on-click on-click]
              [on-key (lambda (k) (when (memv k '(#\r #\R)) (on-reload)))]
              [paint-callback
               (lambda (c dc)
                 (send dc set-background "white")
                 (send dc clear)
                 (send dc set-smoothing 'aligned)
                 (paint dc))]))
       (define w (window es frame canvas status paint content-height))
       (update-scrollbars! w)
       (send frame show #t)
       (send canvas focus)
       (channel-put result-ch w))))
  (channel-get result-ch))

(define (update-scrollbars! w)
  (define c (window-canvas w))
  (define-values (cw ch) (send c get-client-size))
  (define doc-h (inexact->exact (ceiling ((window-content-height w)))))
  (send c init-auto-scrollbars #f (max ch doc-h) 0.0 0.0))

;; Run thunk on the window's handler thread. `wait?` blocks until done.
(define (in-window w thunk #:wait? [wait? #f])
  (define done (make-semaphore 0))
  (parameterize ([current-eventspace (window-eventspace w)])
    (queue-callback (lambda () (thunk) (semaphore-post done))))
  (when wait? (semaphore-wait done)))

(define (window-refresh! w)
  (in-window w (lambda ()
                 (update-scrollbars! w)
                 (send (window-canvas w) refresh))))

(define (window-set-status! w text)
  (in-window w (lambda () (send (window-status w) set-label text))))

(define (window-set-title! w text)
  (in-window w (lambda () (send (window-frame w) set-label text))))

(define (window-close! w)
  (in-window w (lambda () (send (window-frame w) show #f)) #:wait? #t))

(define (window-shown? w)
  (send (window-frame w) is-shown?))

;; window-click! : window x y -> void
;; Synthesize a left click at page coordinates (x y) and wait for the
;; on-click callback to finish. Used by the GUI smoke test.
(define (window-click! w x y)
  (in-window w
             (lambda ()
               (define c (window-canvas w))
               (define-values (vx vy) (send c get-view-start))
               (send c on-event (new mouse-event% [event-type 'left-down]
                                     [x (- x vx)] [y (- y vy)] [left-down #t])))
             #:wait? #t))

;; window-wait : window -> void   block the calling thread until closed
(define (window-wait w)
  (let loop ()
    (when (window-shown? w)
      (sleep 0.1)
      (loop))))
