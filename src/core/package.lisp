(in-package :cl-user)
(defpackage cl21.core.package
  (:use :cl)
  (:shadow :in-package
           :use-package
           :defpackage
           :find-package
           :delete-package
           :rename-package)
  (:import-from :named-readtables
                :defreadtable
                :find-readtable
                :rename-readtable
                :unregister-readtable
                :in-readtable)
  (:import-from :alexandria
                :ensure-list)
  (:export :package
           :export
           :find-symbol
           :find-package
           :list-all-packages
           :make-package
           :rename-package
           :delete-package
           :import
           :shadow
           :shadowing-import
           :with-package-iterator
           :unexport
           :in-package
           :use-package
           :unuse-package
           :defpackage
           :find-all-symbols
           :do-all-symbols
           :intern
           :unintern
           :package-name
           :package-nicknames
           :package-shadowing-symbols
           :package-use-list
           :package-used-by-list
           :packagep
           :*package*
           :package-error
           :package-error-package
           :do-external-symbols
           :do-symbols
           :do-all-symbols

           :add-package-local-nickname))
(cl:in-package :cl21.core.package)

(defvar *package-use* (make-hash-table :test 'eq))

(defmacro defpackage (name &rest options)
  (let* (package-local-nicknames
         (valid-options
           (loop for option in options
                 if (eq (car option) :use)
                   collect `(:use ,@(loop for use-package in (cdr option)
                                          if (and (listp use-package)
                                                  (string= (second use-package) :as)
                                                  (null (nthcdr 3 use-package)))
                                            do (push `(add-package-local-nickname
                                                       ,(let ((nickname (third use-package)))
                                                          (if (keywordp nickname)
                                                              nickname
                                                              (intern (string nickname) :keyword)))
                                                       ,(first use-package) ',name)
                                                     package-local-nicknames)
                                          else
                                            collect use-package))
                 else
                   collect option)))
    `(eval-when (:execute :load-toplevel :compile-toplevel)
       (prog1
           (cl:defpackage ,name ,@valid-options)
         ,@(nreverse package-local-nicknames)
         ,@(if (member :use valid-options :key #'car)
               `((setf (gethash ,(intern (string name) :keyword) *package-use*)
                       ',(loop for use in (cdr (assoc :use valid-options))
                               when (keywordp use)
                                 collect use
                               else
                                 collect (intern (string use) :keyword))))
               nil)))))

(defvar *package-readtables* (make-hash-table :test 'eq))

(defun get-package-readtable-options (package-name)
  (gethash package-name *package-readtables*))

(defun create-readtable-for-package (name)
  (let ((readtable-options (loop for use in (gethash (intern (string name) :keyword) *package-use*)
                                 append (get-package-readtable-options use))))
    (eval
     `(progn
        (defreadtable ,name
          (:merge :standard)
          ,@readtable-options)
        (find-readtable ',name)))))

(defun find-or-create-readtable-for-package (name)
  (or (find-readtable name)
      (progn
        (create-readtable-for-package name)
        (find-readtable name))))

(defmacro in-package (name)
  `(eval-when (:execute :load-toplevel :compile-toplevel)
     (prog1
         (cl:in-package ,name)
       (if (find-readtable ',name)
           (in-readtable ,name)
           (progn
             (create-readtable-for-package ',name)
             (in-readtable ,name))))))

(defmacro use-package (packages-to-use &optional (package *package*))
  `(prog1
       (cl:use-package ,packages-to-use ,package)
     (setf (gethash ,(intern (package-name package) :keyword) *package-use*)
           (append
            ',(loop for use in (ensure-list packages-to-use)
                    when (keywordp use)
                      collect use
                    else
                      collect (intern (symbol-name use) :keyword))
            (gethash ,(intern (package-name package) :keyword) *package-use*)))
     (defreadtable ,(intern (package-name package))
       (:merge :current)
       ,@(loop for use in (ensure-list packages-to-use)
               append (get-package-readtable-options use)))
     (in-readtable ,(intern (package-name package)))))

(defun delete-package (package-designator)
  (let* ((package (cl:find-package package-designator))
         (key (intern (package-name package) :keyword)))
    (remhash key *package-readtables*)
    (remhash package *package-local-nicknames*)
    (cl:delete-package package)
    (unregister-readtable key)))

(defun rename-package (package-designator new-name &optional new-nicknames)
  (let* ((package (cl:find-package package-designator))
         (new-key (intern (string new-name) :keyword))
         (old-key (intern (package-name package) :keyword)))
    (prog1
        (cl:rename-package package-designator new-name new-nicknames)

      (setf (gethash new-key *package-readtables*)
            (gethash old-key *package-readtables*))
      (remhash old-key *package-readtables*)
      (when (find-readtable old-key)
        (rename-readtable old-key new-key)))))

(defvar *package-local-nicknames* (make-hash-table :test 'eq))

(defun find-package (package-designator &optional (package *package*))
  (or (cl:find-package package-designator)
      (let ((package (cl:find-package package)))
        (symbol-macrolet ((package-nicknames (gethash package *package-local-nicknames*)))
          (and package-nicknames
               (gethash package-designator package-nicknames))))))

(defun add-package-local-nickname (nickname actual-package &optional (package-designator *package*))
  (let ((package (cl:find-package package-designator)))
    #+(or sbcl ccl)
    (unless package
      #+sbcl
      (error 'sb-kernel:simple-package-error
             :package package-designator
             :format-control "The name ~S does not designate any package."
             :format-arguments (list package-designator))
      #+ccl
      (error 'ccl::no-such-package
             :package package-designator))

    (symbol-macrolet ((package-nicknames (gethash (cl:find-package package) *package-local-nicknames*)))
      (unless package-nicknames
        (setf package-nicknames (make-hash-table :test 'eq)))

      (setf (gethash nickname package-nicknames)
            (cl:find-package actual-package)))

    ;; Inject CL21-PACKAGE-LOCAL-NICKNAME-SYNTAX into *readtable* of the package.
    (let ((readtable (find-or-create-readtable-for-package
                      (intern (package-name package) :keyword))))
      (funcall (symbol-function (intern #.(string :use-syntax) :cl21.core.readtable))
               (intern #.(string :cl21-package-local-nickname-syntax) :cl21.core.readtable)
               readtable))

    package))
