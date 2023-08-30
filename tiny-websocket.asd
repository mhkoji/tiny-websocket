(asdf:defsystem :tiny-websocket
  :serial t
  :components ((:file "hunchentoot"))
  :depends-on (:sha1
               :hunchentoot))
