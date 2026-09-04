#lang racket/base
;; loader.rkt — step 1 of the pipeline: `read` a .sx file into a datum.
;;
;; "Parsing is free": the page format is s-expressions, so the whole
;; parser is `read`. This module only adds two things on top:
;;   * a single-datum guarantee (one top-level form per file), and
;;   * a shape check that the form is (document ...).
;;
;; Everything else about the datum (attrs, text nodes, style, script)
;; is interpreted by dom.rkt.

(require racket/port)

(provide load-page
         (struct-out exn:fail:page))

;; Raised for any load-time problem the operator should see as a
;; page error rather than a Racket stack trace.
(struct exn:fail:page exn:fail (path) #:transparent)

(define (page-error path fmt . args)
  (raise (exn:fail:page (string-append (path->string (if (path? path) path (string->path path)))
                                       ": "
                                       (apply format fmt args))
                        (current-continuation-marks)
                        path)))

;; load-page : path-string -> datum
;; Returns the (document ...) form. Raises exn:fail:page on:
;;   - unreadable file / read error
;;   - zero or more-than-one top-level datum
;;   - top-level datum that is not (document ...)
(define (load-page path)
  (unless (file-exists? path)
    (page-error path "file not found"))
  (define forms
    (with-handlers ([exn:fail:read?
                     (lambda (e)
                       (page-error path "read error: ~a" (exn-message e)))])
      (call-with-input-file path
        (lambda (in)
          (port-count-lines! in)
          (let loop ([acc '()])
            (define d (read in))
            (if (eof-object? d)
                (reverse acc)
                (loop (cons d acc))))))))
  (cond
    [(null? forms)
     (page-error path "file contains no s-expression")]
    [(pair? (cdr forms))
     (page-error path "expected exactly one top-level form, found ~a" (length forms))]
    [else
     (define doc (car forms))
     (unless (and (pair? doc) (eq? (car doc) 'document))
       (page-error path "top-level form must be (document ...), got ~s"
                   (if (pair? doc) (car doc) doc)))
     doc]))
