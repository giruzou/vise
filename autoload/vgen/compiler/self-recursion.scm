(define-module vgen.compiler.self-recursion
  (use srfi-1)

  (use vgen.util)
  (use vgen.common)

  (use vgen.compiler.expand) 
  (use vgen.compiler.add-return) 
  (export vise-phase-self-recursion
    ))

(select-module vgen.compiler.self-recursion)

(define (vise-phase-self-recursion form-list)
  (sexp-traverse 
    form-list
    `((defun . ,self-recursion-defun)
      (defvar . ,self-recursion-var)
      (set! . ,self-recursion-var)
      (let . ,self-recursion-let))))

(define (self-recursion-defun form ctx loop)
  (let1 form (self-recursion-optimize (cadr form) form #f)
    (append
      (list
        (car form) ;defun
        (cadr form) ;name
        (caddr form);args
        (cadddr form));mofier
      (map (pa$ loop 'stmt) (cddddr form)))))

(define (self-recursion-var form ctx loop)
  (list
    (car form)
    (cadr form)
    (let ((sym (cadr form))
          (init (caddr form)))
      (loop 'expr
            (if (and (vsymbol? sym)
                  (list? init)
                  (eq? 'lambda (vexp (car init))))
              (self-recursion-optimize sym init #t)
              init)))))

(define (self-recursion-let form ctx loop)
  (append
    (list
      (car form) ;let
      (map
        (lambda (clause) 
          (list 
            (car clause)
            (let ((sym (car clause))
                  (init (cadr clause)))
              (loop 'expr 
                    (if (and (vsymbol? sym )
                          (list? init)
                          (eq? 'lambda (vexp (car init))))
                      (self-recursion-optimize sym init #t)
                      init)))))
        (cadr form)))
    (map (pa$ loop (if (eq? ctx 'toplevel) 'toplevel 'stmt)) (cddr form))))


;;; original
;;(letrec ((loop (lambda (a) 
;;                 (if (> a 100)
;;                   a 
;;                   (loop (+ a 10))))))
;;  (loop 10))
;;
;;; replace to
;;(letrec ((loop (lambda (a)
;;; added
;;                 (let ((a a)
;;                       (recursion #t))
;;                   (while recursion
;;                     (set! recursion #f)
;;; ;;;;;
;;                     (if (> a 100)
;;                       a
;;; added
;;                       (begin
;;                         (set! recursion #t)
;;                         (set! a (+ a 10))))))))) ;;replace
;;; ;;;;;
;;  (loop 10))
(define (self-recursion-optimize sym init lambda?)
  (let ([args (filter-map 
                (lambda (arg) (and (vsymbol? arg) (@ arg.exp)))
                ((if lambda? cadr caddr) init))]
        [self-data (env-find-data sym)]
        [injection-env (assq-ref (slot-ref (car init) 'prop) 'injection-env)]
        [has-tail-recursion? #f])
    (let1 exp `(,@(drop-right init 1)
                 , (find-tail-exp
                     (lambda (exp ctx)
                       (cond
                         [(and (list? exp) 
                            (vsymbol? (car exp)) (not (eq? (vexp (car exp)) 'quote)) 
                            (eq? self-data (env-find-data (car exp))))
                          (@dec! self-data.ref-count)
                          (set! has-tail-recursion? #t)
                          (expand-expression
                            injection-env 
                            'stmt
                            '()
                            `(begin 
                               (set! recursion #t)
                               ,@(map 
                                   (lambda (arg bind) `(set! ,arg ,bind))
                                   args (cdr exp))))]
                         [(return-add? exp ctx)
                          (list 
                            (make <vsymbol> :exp 'return :env injection-env)
                            exp)]
                         [else exp]))
                     'expr
                     (last init)))
      (if has-tail-recursion?
        (let1 new-injection-env (env-injection injection-env)
          ;;make new injection-env
          (assq-set! (slot-ref (car init) 'prop) 'injection-env new-injection-env)
          `(,@(take exp (if lambda? 2 4))
             ,(list
                (make <vsymbol> :exp 'let :env injection-env)
                (append
                  (map
                    (lambda (arg)
                      (list
                        (rlet1 sym (make <vsymbol> :exp arg :env injection-env)
                          (env-add-symbol injection-env sym 'local :attr '(auto-gen)))
                        (make <vsymbol> :exp arg :env new-injection-env)))
                    args)
                  (list (list
                          (rlet1 sym (make <vsymbol> :exp 'recursion :env injection-env)
                            (env-add-symbol injection-env sym 'local :attr '(auto-gen)))
                          #t)))
                (append
                  (list
                    (make <vsymbol> :exp 'while :env injection-env)
                    (make <vsymbol> :exp 'recursion :env injection-env)
                    (list
                      (make <vsymbol> :exp 'set! :env injection-env)
                      (make <vsymbol> :exp 'recursion :env injection-env)
                      #f))
                  ((if lambda? cddr cddddr) exp)))))
        exp))))


