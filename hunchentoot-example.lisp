(defpackage :tiny-websocket.hunchentoot.example
  (:use :cl)
  (:export :start
           :stop))
(in-package :tiny-websocket.hunchentoot.example)

(defclass acceptor
    (tiny-websocket.hunchentoot:websocket-mixin
     hunchentoot:acceptor)
  ())

(defclass client (tiny-websocket:client)
  ((id :initarg :id
       :reader client-id)))

(defclass handler (tiny-websocket:handler)
  ())

(defmethod tiny-websocket:create-client ((hander handler) stream)
  (let ((id (get-universal-time)))
    (make-instance 'client :id id :stream stream)))

(defmethod tiny-websocket:on-text ((handler handler) client string)
  (log:info "~A" string))

(defmethod tiny-websocket:on-text ((handler handler) (client client)
                                   string)
  (log:info "[~A] ~A" (client-id client) string))

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
         :websocket-path-handler-alist
         (list (cons "/ws" (make-instance 'handler)))
         :port 9000))
  (hunchentoot:start *acceptor*))
