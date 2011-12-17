(asdf:defsystem "xecto"
  :version "0.0.0"
  :licence "BSD"
  :description "Xecto is a simple parallel vector-processing library"
  :depends-on ("sb-queue")
  :components
  (#+nil (:file "mpsc-queue")
   (:file "work-stack")
   (:file "thread-pool" :depends-on ("work-stack"))
   (:file "futures" :depends-on ("work-stack"))
   #||
   (:file "parallel-futures" :depends-on ("thread-pool" "futures"))
   (:file "vector-futures" :depends-on ("parallel-futures"))
   (:file "loop-nest-transpose")
   (:file "xecto-impl" :depends-on ("vector-futures" "loop-nest-transpose"))
   (:file "xecto-impl-reshape" :depends-on ("xecto-impl"))
   (:file "xecto-impl-map" :depends-on ("xecto-impl"))
   (:file "xecto-impl-reduce" :depends-on ("xecto-impl"))
   (:file "xecto-impl-scan" :depends-on ("xecto-impl"))
   ||#
   ))
