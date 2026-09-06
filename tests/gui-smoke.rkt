#lang racket/base
;; GUI smoke test: opens the popup, clicks the button in it, checks the
;; DOM changed, closes it. Needs a display, so it is opt-in:
;;
;;   DJB_GUI_TEST=1 raco test tests/gui-smoke.rkt
;;   xvfb-run -a env DJB_GUI_TEST=1 raco test tests/gui-smoke.rkt   (headless Linux)
;;
;; Without DJB_GUI_TEST it reports one skipped check and passes.

(require rackunit
         racket/runtime-path
         "../src/dom.rkt"
         "../src/layout.rkt"
         "../src/bindings.rkt"
         "../src/driver.rkt")

(define-runtime-path hello "../pages/hello.sx")
(define-runtime-path gui-module "../src/gui.rkt")

(cond
  [(not (getenv "DJB_GUI_TEST"))
   (displayln "gui-smoke: skipped (set DJB_GUI_TEST=1 and have a display to run it)")]
  [else
   (load-and-build hello)
   (define w (open-gui!))
   (define window-click! (dynamic-require gui-module 'window-click!))
   (define window-shown? (dynamic-require gui-module 'window-shown?))
   (check-true (window-shown? w))
   ;; real font metrics are now in use; find the button's box
   (define btn (lookup-id "btn"))
   (define bx (let walk ([b (session-boxes)])
                (if (eq? (lbox-node b) btn)
                    b
                    (for/or ([c (in-list (lbox-children b))]) (walk c)))))
   (check-pred lbox? bx)
   ;; a click somewhere in empty body space does nothing
   (window-click! w 700 5)
   (check-equal? (h:text-content (hash-ref id-index "root")) "Hello, worldClick me")
   ;; a click in the middle of the button fires the page's handler
   (window-click! w (+ (lbox-x bx) (/ (lbox-w bx) 2)) (+ (lbox-y bx) (/ (lbox-h bx) 2)))
   (check-equal? (h:text-content (hash-ref id-index "root")) "Clicked!")
   ;; and the button is gone from the box tree
   (check-false (let walk ([b (session-boxes)])
                  (or (eq? (lbox-node b) btn)
                      (for/or ([c (in-list (lbox-children b))]) (walk c)))))
   (close-gui!)
   (check-false (gui-open?))
   (displayln "gui-smoke: ok")])
