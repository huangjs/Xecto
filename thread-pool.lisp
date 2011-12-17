(defpackage "WORK-QUEUE"
  (:use "CL" "SB-EXT" "SB-THREAD")
  (:export "MAKE" "P" "QUEUE" "ALIVE-P"
           "TASK" "TASK-P" "TASK-FUN" "BULK-TASK" "BULK-TASK-P" "TASK-DESIGNATOR"
           "ENQUEUE" "ENQUEUE-ALL" "STOP"
           "PUSH-SELF" "PUSH-SELF-ALL")
  (:import-from "WORK-STACK"
                "TASK" "TASK-P" "TASK-FUN"
                "BULK-TASK" "BULK-TASK-P"
                "TASK-DESIGNATOR")
  (:nicknames "WQ"))

(in-package "WORK-QUEUE")

(defstruct (queue
            (:constructor %make-queue
                (nthread state queue stacks threads)))
  (lock    (make-mutex)  :type mutex
                         :read-only t)
  (cvar    (make-waitqueue) :type waitqueue
                         :read-only t)
  (nthread (error "foo") :type (and unsigned-byte fixnum)
                         :read-only t)
  (state   (error "foo") :type cons
                         :read-only t)
  (queue   (sb-queue:make-queue) :type sb-queue:queue)
  (stacks  (error "Foo") :type (simple-array work-stack:stack 1)
                         :read-only t)
  (threads (error "Foo") :type (simple-array t 1)
                         :read-only t))

(declaim (inline p))
(defun p (x)
  (queue-p x))

(defun grab-task (queue stacks i)
  (let ((task (sb-queue:dequeue queue)))
    (when task
      (return-from grab-task task)))
  (let ((n (length stacks)))
    (dotimes (j n)
      (let* ((i    (mod (+ i j) n))
             (task (work-stack:steal (aref stacks i))))
        (when task
          (return-from grab-task task))))))

(defvar *worker-id* nil)

(defun %make-worker (wqueue i)
  (let* ((lock   (queue-lock   wqueue))
         (cvar   (queue-cvar   wqueue))
         (state  (queue-state  wqueue))
         (queue  (queue-queue  wqueue))
         (stacks (queue-stacks wqueue))
         (stack  (aref stacks i))
         (hint   (float (/ i (queue-nthread wqueue)) 1d0)))
    (make-thread
     (lambda (&aux (*worker-id* i))
       (loop named outer do
         (let ((task
                 (with-mutex (lock)
                   (loop
                     (when (eql (car state) :done)
                       (return-from outer))
                     (let ((task (grab-task queue stacks i)))
                       (when task
                         (return task)))
                     (condition-wait cvar lock)))))
           (if (bulk-task-p task)
               (work-stack:push stack task hint)
               (work-stack:execute-task task))
           (loop while (work-stack:run-one stack)))))
     :name "Work queue worker")))

(defun make (nthread &optional constructor &rest arguments)
  (declare (type (and unsigned-byte fixnum) nthread)
           (dynamic-extent arguments))
  (let* ((state   (list :running))
         (queue   (sb-queue:make-queue))
         (stacks  (map-into (make-array nthread) #'work-stack:make))
         (threads (make-array nthread))
         (wqueue  (if constructor
                      (apply constructor
                             :lock    (make-mutex)
                             :cvar    (make-waitqueue)
                             :nthread nthread
                             :state   state
                             :queue   queue
                             :stacks  stacks
                             :threads threads
                             arguments)
                      (%make-queue nthread
                                   state
                                   queue
                                   stacks
                                   threads))))
    (finalize wqueue (let ((lock  (queue-lock  wqueue))
                           (cvar  (queue-cvar  wqueue))
                           (state (queue-state wqueue)))
                      (lambda ()
                        (with-mutex (lock)
                          (setf (car state) :done)
                          (condition-broadcast cvar)))))
    (dotimes (i nthread wqueue)
      (setf (aref threads i)
            (%make-worker wqueue i)))))

(defun stop (queue)
  (declare (type queue queue))
  (with-mutex ((queue-lock queue))
    (setf (car (queue-state queue)) :done)
    (condition-broadcast (queue-cvar queue)))
  nil)

(defun alive-p (queue)
  (declare (type queue queue))
  (eql (car (queue-state queue)) :running))

(defun enqueue (queue task)
  (declare (type queue queue)
           (type task  task))
  (with-mutex ((queue-lock queue))
    (assert (alive-p queue))
    ;; FIXME
    (sb-queue:enqueue task (queue-queue queue))
    (condition-broadcast (queue-cvar queue)))
  nil)

(defun enqueue-all (queue tasks)
  (declare (type queue queue))
  (with-mutex ((queue-lock queue))
    (assert (alive-p queue))
    (let ((queue   (queue-queue queue)))
      (map nil (lambda (task)
                 (sb-queue:enqueue task queue))
           tasks))
    (condition-broadcast (queue-cvar queue)))
  nil)

(defun push-self (queue task)
  (declare (type queue queue)
           (type task  task))
  (assert (alive-p queue))
  (let ((id *worker-id*))
    (cond (id
           (assert (eql (aref (queue-threads queue) id)
                        *current-thread*))
           (work-stack:push (aref (queue-stacks queue) id) task))
          (t
           (enqueue queue task)))))

(defun push-self-all (queue tasks)
  (declare (type queue queue))
  (assert (alive-p queue))
  (let ((id *worker-id*))
    (cond (id
           (assert (eql (aref (queue-threads queue) id)
                        *current-thread*))
           (work-stack:push-all (aref (queue-stacks queue) id) tasks))
          (t
           (enqueue-all queue tasks)))))
