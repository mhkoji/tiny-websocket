(defpackage :tiny-websocket.hunchentoot.example
  (:use :cl)
  (:export :start
           :stop))
(in-package :tiny-websocket.hunchentoot.example)

(defclass acceptor
    (tiny-websocket.hunchentoot:websocket-mixin
     hunchentoot:acceptor)
  ())

(defvar *acceptor* nil)

(defun stop ()
  (when *acceptor*
    (hunchentoot:stop *acceptor*))
  (values))

(defun start ()
  (stop)
  (setq *acceptor*
        (let ((handler (make-instance 'tiny-websocket:handler)))
          (make-instance 'acceptor
                         :websocket-path "/ws"
                         :websocket-taskmaster
                         (make-instance 'tiny-websocket:taskmaster
                                        :handler handler)
                         :port 9000)))
  (hunchentoot:start *acceptor*))
