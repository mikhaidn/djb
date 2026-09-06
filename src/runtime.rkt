#lang racket/base
;; runtime.rkt — M4: the script sandbox and the event loop.
;;
;; Page scripts run in a racket/sandbox child evaluator over racket/base.
;; The host procedures from bindings.rkt are injected as definitions,
;; so a script sees plain names: (on! (get-element "btn") "click" ...).
;; The sandbox has no filesystem access and a per-evaluation time and
;; memory limit; a script that misbehaves prints a `script error:` line
;; and the engine carries on.
;;
;; Handlers registered with on! are sandbox closures. They are always
;; invoked through `call-in-sandbox-context` so the sandbox's guards and
;; limits apply while they run, not just when they were defined.
;;
;; Event loop (spec §4):
;;   (dispatch! type handle)          run the listeners for (handle . type)
;;   (tick! type handle rerender)     dispatch, then if the document is
;;                                    dirty clear the flag and call rerender.
;;                                    Returns #t if it re-rendered.

(require racket/sandbox
         "dom.rkt"
         "bindings.rkt")

(provide start-runtime!
         stop-runtime!
         runtime-running?
         run-scripts!
         dispatch!
         tick!
         script-eval-limits)

(define current-evaluator #f)

;; (seconds megabytes) per evaluation / handler invocation
(define script-eval-limits (box '(5 50)))

(define (runtime-running?) (and current-evaluator #t))

(define (report-script-error e)
  (printf "script error: ~a\n" (exn-message e))
  (flush-output))

;; start-runtime! : -> void
;; Tear down any previous sandbox, clear listeners, build a fresh
;; evaluator with the host bindings defined.
(define (start-runtime!)
  (stop-runtime!)
  (reset-bindings!)
  (define ev
    (parameterize ([sandbox-output       (current-output-port)]
                   [sandbox-error-output (current-error-port)]
                   [sandbox-eval-limits  (unbox script-eval-limits)]
                   [sandbox-propagate-exceptions #t])
      (make-evaluator 'racket/base)))
  (for ([b (in-list host-bindings)])
    ;; the procedure is spliced in as a literal value: no module path,
    ;; nothing for the sandbox to `require`.
    (ev `(define ,(car b) ,(cdr b))))
  (set! current-evaluator ev))

(define (stop-runtime!)
  (when current-evaluator
    (kill-evaluator current-evaluator)
    (set! current-evaluator #f)))

;; run-scripts! : node -> void
;; Evaluate every (script ...) body in document order, form by form.
(define (run-scripts! root)
  (unless current-evaluator (start-runtime!))
  (let walk ([n root])
    (when (and (raw-node? n) (eq? (node-tag n) 'script))
      (for ([form (in-list (node-text n))])
        (with-handlers ([exn:fail? report-script-error])
          (current-evaluator form))))
    (for ([c (in-list (node-children n))]) (walk c))))

;; dispatch! : string handle -> void
(define (dispatch! type handle)
  (define procs (reverse (hash-ref listeners (cons handle type) '())))
  (define e (event type handle))
  (for ([proc (in-list procs)])
    (with-handlers ([exn:fail? report-script-error])
      (if current-evaluator
          (call-in-sandbox-context current-evaluator (lambda () (proc e)))
          (proc e)))))

;; tick! : string handle (-> any) -> boolean
(define (tick! type handle rerender)
  (dispatch! type handle)
  (cond
    [(unbox document-dirty?)
     (set-box! document-dirty? #f)
     (rerender)
     #t]
    [else #f]))
