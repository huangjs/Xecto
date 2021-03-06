(defpackage "FUTURE"
  (:use "CL" "SB-EXT" "SB-THREAD")
  (:export "FUTURE"
           "DEPENDENTS"
           "STATUS" "WAIT" "CANCEL"
           "MARK-DEPENDENCIES" "THAW" "MARK-DONE"))

;;; Infrastructure for futures: lenient-evaluated values
;;;
;;; A future is a computation with a set of dependencies; whenever
;;; all the dependencies for a computation have been fully executed,
;;; it too is executed.
;;;
;;; In order to do so, each future also tracks its dependents
;;; in list of weak pointers.  When the future is marked as done, the
;;; depcount (number of yet unfulfilled dependencies) of its
;;; dependents is decremented.  When all the dependencies are
;;; fullfilled (depcount is zero), the future is recursively executed.
;;;
;;; For convenience, futures are also bulk-tasks, but this is irrelevant
;;; to the interface.
;;;
;;; Slots in a FUTURE:
;;;  function: list designator of functions to be called on execution;
;;;            they receive the future as their single argument.
;;;  dependents: list of weak pointers to dependents, initialized
;;;              to zero and updated on demand.
;;;  dependencies: vector of dependencies
;;;  depcount: number of dependencies yet to be fullfilled, updated on
;;;            demand.
;;;  %status: current status of the future.  Upgraded to a slow, lock-ful
;;;           representation as needed.
;;;
;;; A future goes through a few stages:
;;;
;;;  :orphan is the initial stage.  The future is initialized, but not
;;;     yet linked to its dependencies.
;;;  :frozen futures have been linked to their dependencies (via
;;;    MARK-DEPENDENCIES), but not been marked for execution.
;;;  :waiting futures have been marked for execution (via THAW),
;;;    and will wait until all their dependencies are satisfied.
;;;  :running futures have had all their dependencies satisfied
;;;  :done futures have finished executing
;;;  :cancelled futures have been cancalled
;;;
;;; STATUS and WAIT can be used to poll a future's current status or wait
;;;  until it becomes equal to a value in a set of status.
;;;
;;; CANCEL marks a future as cancelled, unless it is already executing.
;;;
;;; Creating a future should follow this pattern:
;;;  - Allocate a future
;;;  - MARK-DEPENDENCIES
;;;  - Maybe walk its DEPENDENTS list for analyses
;;;  - THAW it
;;;  - Maybe WAIT until :cancelled or :done

(in-package "FUTURE")

(deftype status ()
  '(member :orphan :frozen :waiting :running :done :cancelled))

(defstruct (future
            (:include work-stack:bulk-task)
            (:constructor nil))
  (function     nil :type (or list symbol function))
  (dependents   nil :type (or list (member :done :cancelled)))
  (dependencies nil :type simple-vector)
  (depcount       0 :type word)
  (%status  :orphan :type (or status slow-status)))

(defun dependents (future)
  (let ((dependents (future-dependents future)))
    (and (listp dependents)
         dependents)))

(status:define-status-type slow-status
    (:fast-type future
     :status-type status
     :default-status :orphan
     :final-states (:done :cancelled))
    future-%status status wait status-upgrade)

(defun execute (future)
  (unless (eql (status-upgrade future :running :waiting)
               :waiting)
    (return-from execute))
  (let ((function (future-function future)))
    (etypecase function
      (null)
      (cons
       (dolist (function function)
         (funcall function future)))
      ((or symbol function)
       (funcall function future)))
    (setf (future-function future) nil))
  nil)

(defun cancel (future)
  (declare (type future future))
  (let ((status (status-upgrade future :cancelled :orphan :frozen :waiting)))
    (when (member status '(:frozen :waiting))
      ;; recursively mark as cancelled?
      (setf (future-dependents future) :cancelled))
    status))

(defun thaw (future &key (recursive t))
  (declare (type future future))
  (labels ((rec (future)
             (declare (type future future))
             (case (status-upgrade future :waiting :frozen)
               (:orphan (error "Thawing orphan future"))
               (:frozen
                (when recursive
                  (map nil #'rec (future-dependencies future)))
                (when (zerop (future-depcount future))
                  (execute future))))))
    (rec future))
  future)

(defun mark-dependencies (future &key (thaw t) (recursive nil))
  (declare (type future future))
  (assert (eql (status-upgrade future :frozen :orphan) :orphan))
  (let ((wp (make-weak-pointer future)))
    (flet ((mark-dep (dep)
             (declare (type future dep))
             (ecase (status dep)
               (:orphan
                (if recursive
                    (mark-dependencies dep :thaw thaw :recursive t)
                    (error "Dependency is an orphan")))
               ((:frozen :waiting :running))
               (:done
                (return-from mark-dep))
               (:cancelled
                (error "Dependency cancelled")))
             (let ((cons (list wp)))
               (atomic-incf (future-depcount future))
               (loop
                 (let ((dependents (future-dependents dep)))
                   (setf (cdr cons) dependents)
                   (cond ((eql dependents :done)
                          (atomic-decf (future-depcount future))
                          (return-from mark-dep))
                         ((eql dependents :cancelled)
                          ;; cancel self?
                          (atomic-decf (future-depcount future))
                          (error "Dependency cancelled"))
                         ((eql (cas (future-dependents dep)
                                    dependents cons)
                               dependents)
                          (return-from mark-dep))))))))
      (declare (dynamic-extent #'mark-dep))
      (map nil #'mark-dep (future-dependencies future))
      (when thaw (thaw future)))))

(defun mark-done (future)
  (declare (type future future))
  (unless (eql :running (status-upgrade future :done :running))
    (return-from mark-done))
  (setf (future-dependencies future) #())
  (let ((dependents
          (loop
            (let ((dependents (future-dependents future)))
              (when (or (eql dependents :done)
                        (eql dependents :cancelled))
                (return-from mark-done))
              (when (eql (cas (future-dependents future)
                              dependents :done)
                         dependents)
                (return dependents))))))
    (dolist (wp dependents)
      (let ((value (weak-pointer-value wp)))
        (when (and value
                   (= 1 (atomic-decf (future-depcount value)))
                   (eql :waiting (status value)))
          (execute value))))))
