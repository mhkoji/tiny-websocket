(defpackage :tiny-websocket.hunchentoot.example
  (:use :cl)
  (:export :start
           :stop))
(in-package :tiny-websocket.hunchentoot.example)

(defclass acceptor
    (tiny-websocket.hunchentoot:websocket-mixin
     hunchentoot:acceptor)
  ())

(defclass handler (tiny-websocket:handler)
  ())

(defclass client (tiny-websocket:client)
  ((id :initarg :id
       :reader client-id)))

(defmethod tiny-websocket:create-client ((hander handler) stream)
  (make-instance 'client
                 :id (get-universal-time)
                 :stream stream))

(defmethod tiny-websocket:on-text ((handler handler) client string)
  (print string))

(defmethod tiny-websocket:on-text ((handler handler) (client client)
                                   string)
  (print (list (client-id client) string)))

;;;

(defvar *acceptor* nil)

(defun stop ()
  (when *acceptor*
    (hunchentoot:stop *acceptor*))
  (values))

(defun start ()
  (stop)
  (setq *acceptor*
        (make-instance 'acceptor
         :websocket-path "/ws"
         :websocket-taskmaster (make-instance 'tiny-websocket:taskmaster
                                :handler (make-instance 'handler))
         :port 9000))
  (hunchentoot:start *acceptor*))
