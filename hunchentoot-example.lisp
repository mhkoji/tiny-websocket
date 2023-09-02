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

(defmethod tiny-websocket:on-text ((handler handler) stream string)
  (print string))

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
