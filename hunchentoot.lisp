(defpackage :tiny-websocket.hunchentoot
  (:use :cl))
(in-package :tiny-websocket.hunchentoot)

(defun is-opening-handshake (upgrade
                             sec-websocket-key
                             sec-websocket-version)
  (declare (ignore sec-websocket-version))
  (and (string= upgrade "websocket")
       (stringp sec-websocket-key)))

(let ((guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
  (defun generate-accept-hash-value (sec-websocket-key)
    (let ((new-str (concatenate 'string sec-websocket-key guid)))
      (sha1:sha1-base64 new-str #'base64:string-to-base64-string))))

(assert (string=
         (generate-accept-hash-value "dGhlIHNhbXBsZSBub25jZQ==")
         "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))

(defstruct frame
  fin
  opcode
  mask
  payload-len
  extended-payload-len
  masking-key
  payload-data)

(defun byte-vector->bit-vector (byte-vec)
  (let ((byte-num (length byte-vec)))
    (let ((bit-vector (make-sequence '(vector bit)
                                     (* 8 byte-num))))
      (loop for i from 0 for byte across byte-vec do
        (loop for x = byte then (ash x -1) for j from 7 downto 0 do
          (setf (bit bit-vector (+ j (* i 8))) (logand x 1))))
      bit-vector)))

(defun bit-vector->byte (bit-vec)
  (let ((value 0))
    (loop repeat (length bit-vec)
          for bit across bit-vec do
      (setf value (logior (ash value 1) bit)))
    value))

(defun read-seq (stream size)
  (let ((seq (make-array size :element-type '(unsigned-byte 8))))
    (read-sequence seq stream)
    seq))

(defun parse-frame (stream)
  (print (listen stream))
  (let ((frame (make-frame))
        (bit0-15 (byte-vector->bit-vector
                  (read-seq stream 2))))
    (let ((rsv1 (bit bit0-15 1))
          (rsv2 (bit bit0-15 2))
          (rsv3 (bit bit0-15 3)))
      (assert (= rsv1 0))
      (assert (= rsv2 0))
      (assert (= rsv3 0)))
    (setf (frame-fin frame)
          (bit bit0-15 0))
    (setf (frame-opcode frame)
          (bit-vector->byte (subseq bit0-15 4 8)))
    (setf (frame-mask frame)
          (bit bit0-15 8))
    (setf (frame-payload-len frame)
          (bit-vector->byte (subseq bit0-15 9 16)))
    (setf (frame-extended-payload-len frame)
          (cond ((<= (frame-payload-len frame) 125) 0)
                (t
                 (assert nil))))
    (setf (frame-masking-key frame)
          (if (= (frame-mask frame) 1)
              (read-seq stream 4)
              nil))
    (setf (frame-payload-data frame)
          (read-seq stream (frame-payload-len frame)))
    frame))

(defun unmask-payload-data (masking-key payload-data)
  (let ((seq (make-array (length payload-data)
                         :element-type '(unsigned-byte 8))))
    (loop for i from 0 below (length seq) do
      (setf (aref seq i)
            (logxor (aref masking-key (mod i 4))
                    (aref payload-data i))))
    seq))

(defun frame-unmasked-payload (frame)
  (unmask-payload-data (frame-masking-key frame)
                       (frame-payload-data frame)))

;;;

(defgeneric handle-frame (handler frame))

(defmethod handle-frame (handler frame)
  (print (list frame
               (babel:octets-to-string
                (frame-unmasked-payload frame)))))

(defun handler-loop (handler stream)
  (ignore-errors
   (loop for frame = (parse-frame stream)
         while frame do
           (handle-frame handler frame)
         when (= (frame-opcode frame) 8) do
           (return))))

;;;

(defgeneric process-new-connection (taskmaster stream))

(defclass taskmaster ()
  ((handler :initform :handler
            :reader taskmaster-handler)
   (streams :initform nil
            :accessor taskmaster-streams)
   (streams-lock :initform (bt:make-lock "streams-lock")
                 :reader taskmaster-streams-lock)))

#+nil
(defvar *debug-stream* nil)

(defun call-with-stream-added (taskmaster stream fn)
  (with-accessors ((streams taskmaster-streams)
                   (streams-lock taskmaster-streams-lock)) taskmaster
    (bt:with-lock-held (streams-lock)
      (push stream streams))
    (funcall fn)
    (bt:with-lock-held (streams-lock)
      (setf streams (remove stream streams)))))

(defmacro with-stream-added ((taskmaster stream) &body body)
  `(call-with-stream-added ,taskmaster ,stream (lambda () ,@body)))

(defmethod process-new-connection ((taskmaster taskmaster) stream)
  #+nil
  (setq *debug-stream* stream)
  (bt:make-thread
   (lambda ()
     (with-stream-added (taskmaster stream)
       (handler-loop (taskmaster-handler taskmaster) stream)))))

;;;

(defclass websocket-mixin ()
  ((path :initarg :websocket-path
         :reader websocket-path)
   (taskmaster :initarg :websocket-taskmaster
               :reader websocket-taskmaster)))

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
    (when (is-opening-handshake upgrade
                                sec-websocket-key
                                sec-websocket-version)
      ;; Keep socket open
      (hunchentoot:detach-socket websocket-mixin)
      (process-new-connection (websocket-taskmaster websocket-mixin)
                              ;; TODO: Use public method
                              (hunchentoot::content-stream request))
      (send-opening-handshake (generate-accept-hash-value sec-websocket-key))
      t)))

(defmethod hunchentoot:acceptor-dispatch-request ((mixin websocket-mixin)
                                                  request)
  (print (list (hunchentoot:script-name request)
               (hunchentoot:headers-in*)))
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
        (make-instance 'acceptor
                       :websocket-path "/ws"
                       :websocket-taskmaster (make-instance 'taskmaster)
                       :port 9000))
  (hunchentoot:start *acceptor*))
