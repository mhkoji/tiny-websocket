(asdf:defsystem :tiny-websocket
  :serial t
  :components ((:file "tiny-websocket"))
  :depends-on (:babel
               :bordeaux-threads
               :cl-base64
               :sha1))
