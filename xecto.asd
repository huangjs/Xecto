(asdf:defsystem "xecto"
  :version "0.0.0"
  :licence "BSD"
  :description "Xecto is a simple parallel vector-processing library"
  :depends-on ("sb-concurrency")
  :components
  ((:file "thread-pool")
   (:file "futures")
   (:file "parallel-futures" :depends-on ("thread-pool" "futures"))
   (:file "vector-futures" :depends-on ("parallel-futures"))
   (:file "loop-nest-transpose")
   (:file "xecto-impl" :depends-on ("vector-futures"))
   (:file "xecto-impl-reshape" :depends-on ("xecto-impl"))
   (:file "xecto-impl-map" :depends-on ("xecto-impl"))))