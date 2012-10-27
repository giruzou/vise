
(define-module vgen.compiler 
  (use gauche.vport)
  (use gauche.parameter)
  (use util.match)
  (use srfi-1)
  (use srfi-13)
  (use util.list)
  (use file.util)

  (use vgen.util)
  (export-all)
  )

(select-module vgen.compiler)


(define-condition-type <vise-error> <error> #f)

;;-------------
;;Util Type
;;-------------

;;
;; <vexp>
(define-class <vexp> ()
  (
   (exp :init-keyword :exp)
   (attr :init-value '())
   (prop :init-keyword :prop  :init-value '())
   (parent :init-keyword :parent :init-value #f)
   (debug-info :init-keyword :debug-info :init-value #f)
   )
  )

(define-method write-object ((sym <vexp>) port)
  (format port "~a" (@ sym.exp)))

(define (vexp o)
  (if (is-a? o <vexp>)
    (@ o.exp)
    o))

;;
;; <vsymbol>
(define-class <vsymbol> (<vexp>)
  (
   (env :init-keyword :env)
   )
  )

(define vsymbol? (cut is-a? <> <vsymbol>))

(define (get-symbol sym)
  (cond 
    [(vsymbol? sym) (@ sym.exp)]
    [(symbol? sym) sym]
    [else #f]))

;;
;;<vmacro>
(define-class <vmacro> (<vexp>)
  (
   (env :init-keyword :env)
   )
  )

(define vmacro? (cut is-a? <> <vmacro>))

;;;;;
;;refer data
;;@slot scope {@ 'arg 'script 'global 'window 'buffer 'syntax}
(define-class <env-data> ()
  (
   (symbol :init-keyword :symbol)
   (exp :init-keyword :exp)
   (scope :init-keyword :scope)
   (attr :init-value '())
   (vim-name :init-value #f)
   (ref-count :init-value 0)
   (set-count :init-value 0)
   )
  )

(define (attr-push! o attr)
  (@! o.attr (set-cons (@ o.attr) attr)))

(define (attr-remove! o attr)
  (@! o.attr (remove! (pa$ equal? attr) (@ o.attr))))

(define (has-attr? o attr)
  (set-exists (@ o.attr) attr))

(define (get-vim-name env-data)
  (if (@ env-data.vim-name)
    (@ env-data.vim-name)
    (rlet1 name (vise-gensym (@ env-data.symbol) (@ env-data.scope) (@ env-data.attr))
      (@! env-data.vim-name name))))

(define (cmd-symbol? symbol)
  (string-scan (x->string (vexp symbol)) #\#))


;;;;;
;;@param scope {@ 'arg 'script 'global 'window 'buffer 'syntax}
;;@param attr {@ set-list}
(define (vise-gensym sym scope attr)
  (cond
    [(or (eq? scope 'syntax) (cmd-symbol? sym)) (x->string sym)]
    [(and (eq? scope 'arg) (set-exists attr 'rest)) "a:000"]
    [else 
      (let ((prefix (case scope
                      ((arg) #\a)
                      ((script) #\s)
                      ((global) #\g)
                      ((window) #\w)
                      ((buffer) #\b)
                      (else #f)))
            (name (if (set-exists attr 'func-call)
                   (string-titlecase (x->string sym))
                   (x->string sym))))
        (if prefix
          (let1 sym (x->string sym)
            (if (and (< 1 (string-length sym)) (eq? (string-ref name 1) #\:)
                  (eq? (string-ref name 0) prefix))
              name 
              (string-append (x->string prefix) ":" name)))
          (symbol->string (gensym (string-append name "_")))))]))

(define (remove-symbol-prefix symbol)
  (if-let1 ret (string-scan (x->string symbol) ":" 'after)
    ret
    symbol))

;;
;;environment
(define-class <env> ()
  (
   (symbols :init-value '())
   (children :init-value '())
   (parent :init-keyword :parent)
   (lambda-border? :init-keyword :lambda-border?)
   )
  )
(define-method write-object ((env <env>) port)
  (with-output-to-port 
    port
    (pa$ print-env-table env)))

(define (make-env parent :optional (lambda-border? #f))
  (rlet1 env (make <env> 
                   :parent parent
                   :lambda-border? lambda-border?)
    (when parent
      (@push! env.parent.children env))))

(define env-toplevel?  (.$ not (cut slot-ref <> 'parent)))

(define (env-add-symbol env symbol scope)
  (env-add-symbol&exp env symbol scope #f))

(define (env-add-symbol&exp env symbol scope exp)
  (let1 symbol (get-symbol symbol)
    (@push! env.symbols 
            (cons symbol (make <env-data>
                               :symbol symbol
                               :exp exp
                               :scope scope)))))

(define (env-find-data-with-outside-lambda? env symbol)
  (let1 symbol (get-symbol symbol)
    (let loop ((env env)
               (outside? #f))
      (if-let1 d (assq-ref (@ env.symbols) symbol)
        (values d outside?)
        (if (@ env.parent)
          (loop (@ env.parent) (or outside? (@ env.lambda-border?)))
          (values #f #f))))))

(define (env-find-data env symbol)
  (receive (d outside?) (env-find-data-with-outside-lambda? env symbol)
    d))

(define (env-find-exp env symbol)
  (if-let1 d (env-find-data env symbol)
    (@ d.exp)
    #f))

(define (allow-rebound? vsymbol)
  (if-let1 d (and (vsymbol? vsymbol) (env-find-data (@ vsymbol.env) vsymbol))
    (not (or (eq? (@ d.scope) 'arg) (eq? (@ d.scope) 'syntax)))
    #t))

(define (print-env-table env)
  (let loop ((env env))
    (for-each
      (lambda (item) (print (car item) ":" (cdr item)))
      (@ env.symbols))
    (when (@ env.parent)
      (print "->")
      (loop (@ env.parent))))
  (newline))

;;
;;virtual output port
(define-class <vise-output-port> (<virtual-output-port>)
  (
   (raw :init-keyword :raw)
   (prev :init-keyword :prev)
   (indent :init-keyword :indent)
   ))

(define (replace-indent prev str indent-level)
  (let* ([num (* indent-level 2)]
         [indent-str (if (zero? num)
                       ""
                       (format 
                         (string-append "~" (number->string num) ",,,' a")
                         " "))])
    (string-append 
      (if (rxmatch #/\n$/ prev) indent-str "")
      (regexp-replace #/\n +$/
                      (regexp-replace-all #/\n/ str (string-append "\n" indent-str))
                      "\n"))))

(define (make-vise-output-port port)
  (let ([prev (cons "" (undefined))]
        [indent (cons 0 (undefined))])
    (make <vise-output-port>
          :raw port
          :prev prev
          :indent indent
          :putc (lambda (c) 
                  (let* ([c (x->string c)]
                         [str (replace-indent (car prev) c (car indent))])
                    (set-car! prev c)
                    (display str port)))
          :puts (lambda (x)
                  (let* ([x-str (x->string x)]
                         [str (replace-indent (car prev) x-str (car indent))])
                    (set-car! prev x-str)
                    (display str port)))
          :flush  (pa$ flush port)))) 

(define (add-new-line :optional (port (current-output-port)))
  (unless (rxmatch #/\n$/ (car (@ port.prev)))
    (newline port)))

(define-macro (add-indent . body)
  `(unwind-protect
     (begin 
       (inc! (car (slot-ref (current-output-port) 'indent)))
       ,@body)
     (dec! (car (slot-ref (current-output-port) 'indent)))))

;;
;;set
(define (set-exists set obj)
  (any (.$ (pa$ equal? (vexp obj)) vexp) set))

(define (set-cons set obj)
  (if (set-exists set obj)
    set
    (cons obj set)))


;;----------
;;Compile
;;----------

(define (vise-error msg . obj)
  (let1 obj (map
              (lambda (obj)
                (if-let1 info (or (debug-source-info obj)
                                (and (pair? obj) (is-a? (car obj) <vexp>) (slot-ref (car obj) 'debug-info)))
                  (format "file:~a line:~a form:~a" (car info) (cadr info) obj)
                  obj))
              obj)
    (apply errorf <vise-error> msg obj)))


(define-constant traverse-apply-function-hook (gensym))

(define (sexp-traverse form-list hook)
  (define (loop ctx form)
    (if (list? form)
      (if-let1 func (assq-ref hook (vexp (car form)))
        (func form ctx loop)
        (case (vexp (car form))
          [(quote) form]
          [(defun) 
           (append
             (list
               (car form) ;defun
               (cadr form) ;name
               (caddr form) ;args
               (cadddr form)) ;modifier
             (map (pa$ loop 'stmt) (cddddr form)))]
          [(defvar)
           (list
             (car form) ;defvar
             (cadr form) ;name
             (loop 'expr (caddr form)))]
          [(lambda) 
           (append
             (list
               (car form) ;lambda
               (cadr form)) ;args
             (map (pa$ loop 'stmt) (cddr form)))]
          [(if) 
           (let1 cctx (if (eq? ctx 'expr) 'expr ctx)
             (if (null? (cdddr form))
               (list
                 (car form)
                 (loop 'expr (cadr form))
                 (loop cctx (caddr form)))
               (list
                 (car form)
                 (loop 'expr (cadr form))
                 (loop cctx (caddr form))
                 (loop cctx (cadddr form)))))]
          [(return)
           (if (null? (cdr form))
             form 
             (list
               (car form) ;return
               (loop 'expr (cadr form))))]
          [(set!) 
           (list
             (car form);set!
             (cadr form) ;name
             (loop 'expr (caddr form)))]
          [(let)
           (append
             (list
               (car form) ;let
               (map
                 (lambda (clause) (list (car clause) (loop 'expr (cadr clause))))
                 (cadr form)))
             (map (pa$ loop 'stmt) (cddr form)))]
          [(dolist)
           (append
             (list
               (car form)
               (list
                 (caadr form)
                 (loop 'expr (cadadr form))))
             (map (pa$ loop 'stmt) (cddr form)))]
          [(while)
           (append
             (list
               (car form) ;name
               (loop 'expr (cadr form)))
             (map (pa$ loop 'stmt) (cddr form)))]
          [(begin and or quasiquote unquote unquote-splicing augroup)
           (append
             (cons (car form) '()) ;name
             (map (pa$ loop (if (or* eq? (vexp (car form)) 'and 'or) 'expr ctx)) 
                  (cdr form)))]
          [(list-func)
           (list
             (car form) ;list
             (cadr form) ;function
             (loop 'expr (caddr form))
             (loop 'expr (cadddr form)))]
          [(autocmd)
           (list
             (car form) ;autocmd
             (cadr form);group
             (caddr form) ;events
             (cadddr form) ;pat
             (car (cddddr form)) ;nest
             (loop 'stmt (cadr (cddddr form))))] ;cmd
          [(dict)
           (append
             (cons (car form) '())
             (map
               (lambda (pair) (list (car pair) (loop 'expr (cadr pair))))
               (cdr form)))]
          [else 
            (if-let1 func (assq-ref hook traverse-apply-function-hook)
              (func form ctx loop)
              (map (pa$ loop 'expr) form))]))
      form))

  (map (pa$ loop 'toplevel) form-list))

(define (find-tail-exp action exp)
  (cond
    [(list? exp)
     (case (get-symbol (car exp))
       [(defun let lambda)
        `(,@(drop-right exp 1)
           ,(find-tail-exp action (car (last-pair (cddr exp)))))]
       [(begin and or) 
        `(,@(drop-right exp 1)
           ,(find-tail-exp action (car (last-pair (cdr exp)))))]
       [(if)
        (if (null? (cdddr exp))
          (list (car exp) (cadr exp)
                (find-tail-exp action (caddr exp))) ;then
          (list (car exp) (cadr exp)
                (find-tail-exp action (caddr exp)) ;then
                (find-tail-exp action (cadddr exp))))] ;else
       [(set!)
        (list (car exp) (cadr exp)
              (find-tail-exp action (caddr exp)))]
       [(return) (find-tail-exp action (cadr exp))]
       [(while augroup autocmd) exp]
       [(quasiquote) exp] ;;TODO
       [(try)
        `(,(car exp)
           ,(find-tail-exp action (cadr exp))
           ,@(map
               (lambda (clause)
                 (if (< 1 (length clause))
                   `(,@(drop-right clause 1)
                      ,(find-tail-exp action (car (last-pair clause))))
                   clause))
               (cddr exp)))]
       [(list-func)
        (list (car exp)
              (cadr exp)
              (caddr exp)
              (find-tail-exp action (cadddr exp)))]
       [else 
         (if (any (pa$ eq? (get-symbol (car exp))) vim-cmd-list)
           exp
           (action exp))])]
    [else (action exp)]))

;(add-load-path ".." :relative)
(include "compiler/read.scm")
(include "compiler/include.scm")
(include "compiler/expand.scm")
(include "compiler/check.scm")
(include "compiler/add-return.scm")
(include "compiler/render.scm")

(include "compiler/self-recursion.scm")

(define (vise-compile-from-string str)
  (vise-compile (open-input-string str)))

(define vim-symbol-list (include "vim-function.scm"))

(define (get-file-path in-port)
  (if (eq? (port-type in-port) 'file)
    (sys-dirname (port-name in-port))
    (sys-normalize-pathname "." :absolute #t :expand #t :canonicalize #t)))

(define (vise-compile in-port 
                      :key (out-port (current-output-port))
                      (load-path '()))
  (let* ((global-env (rlet1 env (make-env #f)
                       (hash-table-for-each
                         renderer-table
                         (lambda (k v) (env-add-symbol&exp env k 'syntax v)))
                       (for-each
                         (lambda (sym) (env-add-symbol env sym 'syntax))
                         vim-symbol-list)))
         (exp-list ((.$
                      vise-phase-render
                      vise-phase-self-recursion
                      vise-phase-add-return
                      (pa$ vise-phase-check global-env)
                      (pa$ vise-phase-expand global-env)
                      (pa$ vise-phase-include (append load-path (cons (get-file-path in-port) '())))
                      vise-phase-read)
                    in-port)))
    (with-output-to-port
      out-port
      (lambda ()
        (for-each print exp-list)))))

