(asdf:defsystem :tiny-websocket-hunchentoot
  :serial t
  :components ((:file "hunchentoot"))
  :depends-on (:tiny-websocket
               :hunchentoot))
