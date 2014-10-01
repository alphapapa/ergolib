
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;;  Lexicons - first-class lexical environments for common Lisp
;;;
;;;  Version 2.1-beta  December 2008
;;;
;;;  Based on a feature called "locales" in the T programming language
;;;
;;;  Copyright (c) 2003-2009 by Ron Garret.  This code is may be
;;;  freely distributed, modified and used for any purpose provided
;;;  this copyright notice is retained.
;;;
;;;  NOTE: This code is still experimental, and is likely to change.
;;;  Please send bug reports and comments to ron@flownet.com
;;;
;;;  Version history:
;;;  12/4/08 - Converted to use symbols rather than cells for bindings
;;;  12/15/08 - Fixed semi-hygienic macro bug
;;;  2/22/10 - Major new revision, using symbols as cells
;;;  2/23/10 - Bug fix: lslot-value didn't do the right thing
;;;

(defpackage :lexicons
  (:export :ldefun :ldefmacro :ldefclass :ldefmethod :ldefvar :lslot-value
           :lvalue :lfunction :lquote :current-lexicon :*current-lexicon* :*lexicons*
           :find-lexicon :in-lexicon :make-lexicon :use-lexicon :lexify-package))

(in-package :lexicons)

(defun symcat (&rest syms) (intern (format nil "~{~A~}" syms)))

(defstruct (lexicon (:constructor %make-lexicon)) name package parent library)

(defmethod print-object ((l lexicon) stream)
  (format stream "#<Lexicon ~A>" (lexicon-name l)))

; It's important the *lexicons* and *current-lexicon* only be initialized once
; or they can lose track of the root lexicon, which can cause problems.
(defmacro defv (var)
  `(defvar ,var (if (boundp ',var) ,var nil)))

(defv *current-lexicon*)

(defv *lexicons*)

(eval-when (:LOAD-TOPLEVEL :COMPILE-TOPLEVEL :EXECUTE)
  (defmacro %current-lexicon () *current-lexicon*)
  
  (defun env-lexicon (env) (macroexpand '(%current-lexicon) env))
)

(defmacro current-lexicon (&environment env) (env-lexicon env))

(define-symbol-macro current-lexicon (current-lexicon))

(defun make-lexicon (name &optional package)
  (if (find-lexicon name)
    (error "Lexicon name ~A is alreay in use." name))
  (when (null package)
    (if (find-package name)
      (error "A package named ~A already exists.~&If you want to wrap ~
              this package, pass it in as the second argument to make-lexicon."
             name))
    (setf package (make-package name :use nil)))
  (setf package (find-package package))
  (let ( (l (%make-lexicon :name name :parent *current-lexicon*
                           :package package)) )
    (push l *lexicons*)
    l))

(defun find-lexicon (name)
  (if (lexicon-p name)
    name
    (find name *lexicons* :test 'string-equal :key 'lexicon-name)))

(setf *current-lexicon* (or (find-lexicon :root) (make-lexicon :root)))

(defun in-lexicon (l)
  (setf *current-lexicon*
        (or (find-lexicon l)
            (error "~A is not a lexicon" l))))

(defun use-lexicon (lexicon &optional (in *current-lexicon*))
  (setf lexicon (or (find-lexicon lexicon) (error "No lexicon named ~A" lexicon)))
  (setf in (or (find-lexicon in) (error "No lexicon named ~A" in)))
  (push lexicon (lexicon-library in))
  (setf (lexicon-library in)
        (delete-duplicates (lexicon-library in) :from-end t))
  (lexicon-library in))

(defun find-cell (lexicon symbol &optional (search-library t) (search-parent t))
  (or (find-symbol (symbol-name symbol) (lexicon-package lexicon))
      (and search-library
           (some (lambda (lex) (find-cell lex symbol nil nil))
                 (lexicon-library lexicon)))
      (and search-parent
           (lexicon-parent lexicon)
           (find-cell (lexicon-parent lexicon) symbol nil t))))

(defun ref-form (symbol lexicon)
  (let ((c (find-cell lexicon symbol)))
    (if c
      `',c
      (let (c)
        (warn "Deferring lexical binding of ~S" symbol)
        `(funcall
          ,(lambda ()
             (or c
                 (format t "~&Resolving binding of ~S" symbol)
                 (setf c (find-cell lexicon symbol))
                 (error "~S is not bound in ~S" symbol lexicon))))))))

(defmacro lvalue (symbol &environment env)
  (let ((form (ref-form symbol (env-lexicon env))))
    (if (eq (car form) 'quote)
      (second form)
      `(symbol-value ,form))))

(defmacro lfunction (symbol &environment env)
  (let ((form (ref-form symbol (env-lexicon env))))
    (if (eq (car form) 'quote)
      `(cl:function ,(second form))
      `(symbol-function ,form))))

(defmacro lquote (form &environment env)
  `(quote ,(macroexpand form env)))

(defun lbind (symbol lexicon)
  (intern (symbol-name symbol) (lexicon-package lexicon)))

(defun lunbind (symbol lexicon)
  (unintern (find-symbol (symbol-name symbol) (lexicon-package lexicon))
            (lexicon-package lexicon)))

(defmacro lexify (symbol &environment env1)
  `(progn
     (define-symbol-macro ,symbol (lvalue ,symbol))
     (define-symbol-macro ,(symcat '^ symbol) (lvalue ,symbol))
     (defmacro ,(symcat '^ symbol) (&rest args)
       (macroexpand `(,',symbol ,@args) ,env1))
     (defmacro ,symbol (&rest args &environment env2)
       (let ((ref (ref-form ',symbol (env-lexicon env2))))
         (if (eq (car ref) 'quote)
           `(,(second ref) ,@args)
           `(funcall ,ref ,@args))))))

(defmacro ldefvar (symbol value &environment env)
  `(progn
     (lexify ,symbol)
     (defvar ,(lbind symbol (env-lexicon env)))
     (setf ,symbol ,value)))

(defmacro %dlet (var val &body body &environment env)
  (let ((rf (ref-form var (env-lexicon env))))
    (unless (eq (car rf) 'quote)
      (error "~A is not a global variable" var))
    (setf var (second rf))
    `(let ((,var ,val)) (declare (special ,var)) ,@body)))

(defmacro dlet (bindings &body body)
  (if (null bindings)
    `(progn ,@body)
    `(%dlet ,@(first bindings) (dlet ,(rest bindings) ,@body))))

(defmacro ldefun (symbol args &body body &environment env)
  `(progn
     (lexify ,symbol)
     (defun ,(lbind symbol (env-lexicon env)) ,args ,@body)))

(defmacro ldefmacro (symbol args &body body &environment env)
  `(progn
     (lexify ,symbol)
     (defmacro ,(lbind symbol (env-lexicon env)) ,args ,@body)))

(defun %lfind-class (name lexicon)
  (find-class (or (find-cell lexicon name)
                  (error "~A is not bound in ~A" name lexicon))))

(defmacro lfind-class (name &environment env)
  `(%lfind-class ,name ,(env-lexicon env)))

(defun munge-slot (s lexicon)
  (cons (intern (symbol-name (if (atom s) s (first s))) (lexicon-package lexicon))
        (if (atom s) nil (rest s))))

(defmacro ldefclass (name superclasses slots &rest stuff &environment env)
  (let ( (l (env-lexicon env)) )
    `(progn
       (lexify ,name)
       (defclass ,(lbind name l)
         ,(mapcar (lambda (c) (or (find-cell l c)
                                  (error "There is no class named ~S in the current lexical environment." c)))
                  superclasses)
         ,(mapcar (lambda (s) (munge-slot s l)) slots)
         ,@stuff))))

(defun %lmake-instance (class lexicon)
  (make-instance (if (symbolp class) (%lfind-class class lexicon) class)))

(defmacro lmake-instance (class &environment env)
  `(%lmake-instance ,class ,(env-lexicon env)))

(defmacro iterate (name bindings &body body)
  `(labels ((,name ,(mapcar 'first bindings) ,@body))
     (,name ,@(mapcar 'second bindings))))

(defun munge-specialized-lambda-list (l lexicon)
  (iterate loop1 ( (l l) )
    (let ( (arg (first l)) (args (rest l)) )
      (cond
       ((null l) nil)
       ((member arg '(&rest &optional &key &aux &body)) l)
       ((atom arg) (cons arg (loop1 args)))
       (t (cons (list (first arg)
                      (class-name (%lfind-class (second arg) lexicon)))
                (loop1 args)))))))

(defmacro ldefmethod (name &rest args &environment env)
  (let ( (ll (member-if 'listp args)) )
    (setf (first ll)
          (munge-specialized-lambda-list (first ll) (env-lexicon env))))
  `(progn
     (lexify ,name)
     (defmethod ,(lbind name (env-lexicon env)) ,@args)))

(defmacro lslot-value (instance slot &environment env)
  (if (and (consp slot) (eq (first slot) 'quote))
    (let ((slot-name (second slot)))
      (unless (symbolp slot-name) (error "~A is not a symbol" slot-name))
      `(lslotv ,instance ,slot-name))
    `(slot-value ,instance (find-cell ,slot ',(env-lexicon env)))))

(defmacro lslotv (instance slot &environment env)
  (unless (symbolp slot) (error "~A is not a symbol" slot))
  `(slot-value ,instance ,(ref-form slot (env-lexicon env))))

;;; Hooks to lexify free variables and undefined functions

(defun lexsym? (var)
  (and (symbolp var)
       (member (package-name (symbol-package var))
               '(:lexicons :lexical-common-lisp)
               :test 'string-equal)))

(defun free-variable-hook (var)
  (if (lexsym? var) (eval `(lexify ,var))))

(advise ccl::nx-transform
  (destructuring-bind (form &optional env &rest args) ccl::arglist
    (declare (ignore args))
    (when (and (symbolp form)
               (not (keywordp form))
               (null (ccl::variable-information form env)))
      (free-variable-hook form)))
  :when :before
  :name :free-variable-hook)

(require :combination-hook #P"~/devel/lisp-code/combination-hook")
(use-package :combination-hook)
(defun undefined-function-hook (form)
  (if (lexsym? (car form))
    (progn
      (eval `(lexify ,(car form)))
      (list 'progn form))  ; Return a differnt form to force recompilation
    form))

; Hygienic macros
(defmacro alias (thing &environment env) `',(macroexpand thing env))

(defmacro hlet (bindings &body body)
  (let* ((vars (mapcar 'first bindings))
         (aliases (mapcar (lambda (var) (list (symcat '^ var) `(alias ,var))) vars))
         (vals (mapcar 'second bindings))
         (gensyms (mapcar (lambda (v) (gensym (symbol-name v))) vars)))
    `(let ,(mapcar 'list gensyms vals)
       (symbol-macrolet ,(mapcar 'list vars gensyms)
         (symbol-macrolet ,aliases
           ,@body)))))

#|
; Hygienic macro example

(hlet ((x 1))
  (macrolet ((foo () (alias x)))
    (hlet ((x 2))
      (list x (foo)))))

(hlet ((x 1))
  (macrolet ((foo () ^x))
    (hlet ((x 2))
      (list x (foo)))))

(funcall
 (hlet ((x 1))
   (macrolet ((foo () `(incf ,^x)))
     (hlet ((x 5))
       (lambda () (list x (foo)))))))
|#

; Lexified packages

(defun lexify-package (package)
  (setf package (find-package package))
  (let ((l (find package *lexicons* :key 'lexicon-package)))
    (cond (l (warn "~S is already lexified as ~S." package l) l)
          (t (do-external-symbols (s package)
               (when s ; for when we're lexifying the CL package
                 (shadow (intern (symbol-name s) :lexicons) :lexicons)
                 (eval `(lexify ,(intern (symbol-name s) :lexicons)))))
             (make-lexicon (package-name package) package)))))

; Lexical Common Lisp -- this isn't quite ready for prime time.  It really should be
; in its own package, but the assumption that all lexified symbols live in the :lexicons
; package is woven pretty deeply into the fabric of the code at the moment.
(make-lexicon :lcl)

(in-lexicon :lcl)

(cl:defmacro make-lexical (s)
  (shadow s :lexicons)
  `(cl:defmacro ,(intern (symbol-name s) :lexicons) (&rest args)
     (cons ',(lexicons::symcat 'l s) args)))

#|
(make-lexical defun)
(make-lexical defmacro)
(make-lexical defclass)
(make-lexical defmethod)
(make-lexical defvar)
(make-lexical slot-value)
(make-lexical quote)
(make-lexical function)

(shadow 'in-package)
(defun in-package (p) (in-lexicon p))
(shadow 'make-package)
(defun make-package (p) (make-lexicon p))
|#

; Hemlock arglist hack
(in-package :hemlock)
(defun string-to-arglist (string buffer &optional quiet-if-unknown)
  (multiple-value-bind (name error)
      (let* ((*package* (or
                         (find-package
                          (variable-value 'current-package :buffer buffer))
                         *package*)))
        (ignore-errors (values (read-from-string string))))
    (unless error
      (when (typep name 'symbol)
        (setf name (or (lexicons::find-cell lexicons::*current-lexicon* name) name))
        (multiple-value-bind (arglist win)
            (ccl::arglist-string name)
          (if (or win (not quiet-if-unknown))
            (format nil "~S : ~A" name (if win (or arglist "()") "(unknown)"))))))))

(in-package :lexicons)

#+NIL(progn

(defun reset-demo ()
  (loop while (cdr *lexicons*) do (pop *lexicons*))
  (dolist (p '("L1" "L2" "L3" "L4"))
    (ignore-errors (delete-package p))))

(reset-demo)

(make-lexicon :l1)
(make-lexicon :l2)

(in-lexicon :l1)
(ldefvar var1 'l1-var1-value)
(ldefun fun1 (x) (list 'l1-fun1 x))
(ldefmacro mac1 (x) `(list 'l1-mac1 ',x))
(ldefclass class1 () ())
(ldefmethod method1 ((x class1) y) (list 'l1-method1 x y))

(in-lexicon :l2)
(ldefvar var1 'l2-var1-value)
(ldefun fun1 (x) (list 'l2-fun1 x))
(ldefmacro mac1 (x) `(list 'l2-mac1 ',x))
(ldefclass class1 () ())
(ldefmethod method1 ((x class1) y) (list 'l2-method1 x y))

(defun basic-demo ()
  (loop for x in 
    ; We need eval here because we want to show that different things
    ; happen depending on what lexicon we're in when the code is compiled.
    (eval
     '(list var1 (lfunction fun1) (lfunction method1) (lfunction mac1)
            (fun1 123)
            (mac1 xyz)
            (lmake-instance 'class1)
            (method1 (lmake-instance 'class1) 456)))
    do (print x)))

(in-lexicon :l1)
(basic-demo)
(in-lexicon :l2)
(basic-demo)

; Show that these really are bindings, not just values
(in-lexicon :l1)
(ldefun fun2 (x) (list var1 (fun1 x)))
(fun2 123)
(ldefun fun1 (x) (list 'new-fun1 x))
(setf var1 'new-l1-var1-value)
(fun2 123)   ; Note that we get the new definition for FUN1

; Demonstrate deferred bindings
(in-lexicon :root)
(make-lexicon :l3)
(in-lexicon :l3)
(ldefun deferred-binding-demo () (fun1 123))  ; Note that FUN1 is not yet bound
(use-lexicon :l1)          ; Now we get a binding for FUN1
(deferred-binding-demo)    ; But we don't have to recompile to use it
(deferred-binding-demo)    ; And the binding lookup happens only once

; Demonstrate 1-level binding resolution
(make-lexicon :l4)
(in-lexicon :l4)
(use-lexicon :l3)
(deferred-binding-demo)    ; Bindings from L4 are available
(ignore-errors (fun1 123)) ; but not bindings from L4's libraries

; Demonstrate pseudo-hygienic macros

(in-lexicon :l1)
(ldefun macro-helper (&rest args) (cons 'macro-helper-result args))
(ldefmacro regular-macro (thing) `(macro-helper var1 ',thing))
(ldefmacro safe-macro (thing) `(^macro-helper ^var1 ',thing))

(ldefun macro-test ()
  (flet ((macro-helper (&rest args) (cons 'shadowing-macro-helper args)))
    (let  ((var1 'shadowing-var1))
      (list (regular-macro foo) (safe-macro foo)))))

(macro-test)

; Make sure we've really picked up bindings, not just values
(ldefun macro-helper (&rest args) (cons 'new-macro-helper-result args))
(setf var1 'new-l1-var1-value)

(macro-test)

; Acid test for pseudo-hygienic macros.
(in-lexicon :l1)
(ldefun foo () 'foo1)
(ldefvar v 'v1)
(ldefmacro m1 () `(list (foo) (^foo) v ^v))
(in-lexicon :l2)
(use-lexicon :l1)
(ldefun foo () 'foo2)
(ldefvar v 'v2)
(setf v 'v2) ; Needed until we fix LDEFVAR to not expand into DEFVAR
(m1)

; Demonstrate lexical inheritance
(in-lexicon :l1)
(ldefclass class2 (class1) (x))
(method1 (lmake-instance 'class2) 123)

(in-lexicon :l2)
(ldefclass class2 (class1) (x))
(method1 (lmake-instance 'class2) 123)

(ldefclass class3 (class4) ())

; Test lslot-value
(in-lexicon :root)
(make-lexicon :lex1)
(make-lexicon :lex1-lib)
(in-lexicon :lex1-lib)
(ldefclass myclass-hidden () ((hidden-slot :initform :hidden)))
(in-lexicon :lex1)
(use-lexicon :lex1-lib :lex1)
(ldefclass myclass (myclass-hidden) ((visible-slot :initform :visible)))
(in-lexicon :root)
(use-lexicon :lex1)
(lmake-instance 'myclass)
(ldefvar mc1 *)
(lslot-value mc1 'visible-slot)

)
