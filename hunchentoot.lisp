(defpackage :tiny-websocket.hunchentoot
  (:use :cl)
  (:export :websocket-mixin))
(in-package :tiny-websocket.hunchentoot)

(defclass websocket-mixin ()
  ;; Selecting a handler depends on a request, which interface is
  ;; heavily affected by implementation of a web server.
  ;; Thus this alist is in this layer.
  ;; However we can select a handler in the taskmaster layer and it 
  ;; might be a more appropriate design.
  ((path-handler-alist
    :initarg :websocket-path-handler-alist
    :reader websocket-path-handler-alist)
   (taskmaster
    :initform (make-instance 'tiny-websocket:taskmaster)
    :reader websocket-taskmaster)
   (timeout-sec
    :initform 300
    :reader websocket-timeout-sec)))

(defvar *current-socket*
  nil)

(defun send-opening-handshake (sec-websocket-accept)
  (setf (hunchentoot:return-code*) hunchentoot:+http-switching-protocols+)
  (setf (hunchentoot:header-out "Upgrade") "websocket")
  (setf (hunchentoot:header-out "Connection") "Upgrade")
  (setf (hunchentoot:header-out "Sec-WebSocket-Accept") sec-websocket-accept))

(defun find-handler (websocket-mixin request)
  (cdr (assoc (hunchentoot:script-name request)
              (websocket-path-handler-alist websocket-mixin)
              :test #'string=)))

(defun handle-opening-handshake (websocket-mixin request)
  (let* ((headers (hunchentoot:headers-in request))
         (upgrade (cdr (assoc :upgrade headers)))
         (sec-websocket-key (cdr (assoc :sec-websocket-key headers)))
         (sec-websocket-version (cdr (assoc :sec-websocket-version headers))))
    (when (tiny-websocket:is-opening-handshake upgrade
                                               sec-websocket-key
                                               sec-websocket-version)
      (let ((handler (find-handler websocket-mixin request)))
        (when handler
          ;; Keep socket open
          (hunchentoot:detach-socket websocket-mixin)
          (let ((timeout-sec (websocket-timeout-sec websocket-mixin)))
            ;; TODO: Use public method
            (hunchentoot::set-timeouts *current-socket* timeout-sec timeout-sec))
          (send-opening-handshake (tiny-websocket:generate-accept-hash-value
                                   sec-websocket-key))
          (let ((taskmaster (websocket-taskmaster websocket-mixin))
                ;; TODO: Use public method
                (stream (hunchentoot::content-stream request)))
            (tiny-websocket:process-new-connection taskmaster handler stream))
          t)))))

(defmethod hunchentoot:process-connection :around ((mixin websocket-mixin)
                                                   socket)
  (let ((*current-socket* socket))
    (call-next-method)))

(defmethod hunchentoot:acceptor-dispatch-request ((mixin websocket-mixin)
                                                  request)
  (let ((opening-handshake-success-p
         (handle-opening-handshake mixin request)))
    (when (not opening-handshake-success-p)
      (call-next-method))))
