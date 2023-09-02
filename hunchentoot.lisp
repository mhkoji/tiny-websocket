(defpackage :tiny-websocket.hunchentoot
  (:use :cl))
(in-package :tiny-websocket.hunchentoot)

(defclass websocket-mixin ()
  ((path
    :initarg :websocket-path
    :reader websocket-path)
   (timeout-sec
    :initform 300
    :reader websocket-timeout-sec)
   (taskmaster
    :initarg :websocket-taskmaster
    :reader websocket-taskmaster)))

(defvar *current-socket*
  nil)

(defun send-opening-handshake (sec-websocket-accept)
  (setf (hunchentoot:return-code*) hunchentoot:+http-switching-protocols+)
  (setf (hunchentoot:header-out "Upgrade") "websocket")
  (setf (hunchentoot:header-out "Connection") "Upgrade")
  (setf (hunchentoot:header-out "Sec-WebSocket-Accept") sec-websocket-accept))

(defun handle-opening-handshake (websocket-mixin request)
  (let* ((headers (hunchentoot:headers-in request))
         (upgrade (cdr (assoc :upgrade headers)))
         (sec-websocket-key (cdr (assoc :sec-websocket-key headers)))
         (sec-websocket-version (cdr (assoc :sec-websocket-version headers))))
    (when (tiny-websocket:is-opening-handshake upgrade
                                               sec-websocket-key
                                               sec-websocket-version)
      ;; Keep socket open
      (hunchentoot:detach-socket websocket-mixin)
      (let ((timeout-sec (websocket-timeout-sec websocket-mixin)))
        ;; TODO: Use public method
        (hunchentoot::set-timeouts *current-socket* timeout-sec timeout-sec))
      (send-opening-handshake (tiny-websocket:generate-accept-hash-value sec-websocket-key))
      (tiny-websocket:process-new-connection (websocket-taskmaster websocket-mixin)
                                             ;; TODO: Use public method
                                             (hunchentoot::content-stream request))
      t)))

(defmethod hunchentoot:process-connection :around ((mixin websocket-mixin)
                                                   socket)
  (let ((*current-socket* socket))
    (call-next-method)))

(defmethod hunchentoot:acceptor-dispatch-request ((mixin websocket-mixin)
                                                  request)
  (let ((opening-handshake-success-p
         (and (string= (hunchentoot:script-name request)
                       (websocket-path mixin))
              (handle-opening-handshake mixin request))))
    (when (not opening-handshake-success-p)
      (call-next-method))))

;;;

(defclass acceptor (websocket-mixin
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
