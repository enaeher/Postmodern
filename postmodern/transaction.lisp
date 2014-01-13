(in-package :postmodern)

(defparameter *transaction-level* 0)

(defclass transaction-handle ()
  ((open-p :initform t :accessor transaction-open-p)
   (connection :initform *database* :reader transaction-connection)
   (commit-hooks :initform nil :accessor commit-hooks)
   (abort-hooks :initform nil :accessor abort-hooks))
  (:documentation "Simple box type for storing the status and the
associated database connection of a transaction. When open-p is nil,
the transaction has been aborted or committed. commit-hooks and
abort-hooks hold lists of functions (which should require no
arguments) to be executed at commit and abort time, respectively."))

(defmacro with-transaction ((&optional name) &body body)
  "Execute the body within a database transaction, committing when the
body exits normally, and aborting otherwise. An optional name can be
given to the transaction, which can be used to force a commit or abort
before the body unwinds."
  (let ((name (or name (gensym))))
    `(let ((,name (make-instance 'transaction-handle))
           (*transaction-level* (1+ *transaction-level*)))
      (execute "BEGIN")
      (unwind-protect
           (multiple-value-prog1 (progn ,@body)
             (commit-transaction ,name))
        (abort-transaction ,name)))))

(defun abort-transaction (transaction)
  "Immediately abort an open transaction."
  (when (transaction-open-p transaction)
    (let ((*database* (transaction-connection transaction)))
      (execute "ABORT"))
    (mapc #'funcall (abort-hooks transaction))
    (setf (transaction-open-p transaction) nil)))

(defun commit-transaction (transaction)
  "Immediately commit an open transaction."
  (when (transaction-open-p transaction)
    (let ((*database* (transaction-connection transaction)))
      (execute "COMMIT"))
    (mapc #'funcall (commit-hooks transaction))
    (setf (transaction-open-p transaction) nil)))


(defclass savepoint-handle (transaction-handle)
  ((name :initform (error "Savepoint name is not provided.")
         :initarg :name :reader savepoint-name)
   (open-p :initform t :accessor savepoint-open-p)
   (connection :initform *database* :reader savepoint-connection))
  (:documentation "Simple box type for storing the state and the
associated database connection of a savepoint."))

(defmacro with-savepoint (name &body body)
  "Execute the body within a savepoint, releasing savepoint when the
body exits normally, and rolling back otherwise. NAME is both the
variable that can be used to release or rolled back before the body
unwinds, and the SQL name of the savepoint."
  `(let ((,name (make-instance 'savepoint-handle :name (to-sql-name ',name))))
     (execute (format nil "SAVEPOINT ~A" (savepoint-name ,name)))
     (unwind-protect (multiple-value-prog1 (progn ,@body)
                       (release-savepoint ,name))
       (rollback-savepoint ,name))))

(defun rollback-savepoint (savepoint)
  "Immediately roll back a savepoint, aborting it results."
  (when (savepoint-open-p savepoint)
    (let ((*database* (savepoint-connection savepoint))
          (*transaction-level* (1+ *transaction-level*)))
      (execute (format nil "ROLLBACK TO SAVEPOINT ~A"
                       (savepoint-name savepoint))))
    (mapc #'funcall (abort-hooks savepoint))
    (setf (savepoint-open-p savepoint) nil)))

(defun release-savepoint (savepoint)
  "Immediately release a savepoint, commiting its results."
  (when (savepoint-open-p savepoint)
    (let ((*database* (savepoint-connection savepoint)))
      (execute (format nil "RELEASE SAVEPOINT ~A"
                           (savepoint-name savepoint))))
    (mapc #'funcall (commit-hooks savepoint))
    (setf (transaction-open-p savepoint) nil)))

(defmacro with-logical-transaction ((&optional (name (gensym))) &body body)
  "Executes the body within a with-transaction (if no transaction is already in progress) or a with-savepoint (if one is), binding the transaction or savepoint to NAME (if supplied)"
  `(if (zerop *transaction-level*)
       (with-transaction (,name)
         ,@body)
       (with-savepoint ,name
         ,@body)))

(defmacro ensure-transaction (&body body)
  "Executes body within a with-transaction form if and only if no transaction is already in progress."
  `(if (zerop *transaction-level*)
       (with-transaction ()
         ,@body)
       ,@body))
