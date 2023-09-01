(asdf:defsystem :tiny-websocket
  :serial t
  :components ((:file "tiny-websocket"))
  :depends-on (:cl-base64
               :babel
               :bordeaux-threads
               :sha1))
