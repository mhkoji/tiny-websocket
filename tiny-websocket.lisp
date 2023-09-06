(defpackage :tiny-websocket
  (:use :cl)
  (:export :is-opening-handshake
           :generate-accept-hash-value
           :client-stream
           :client-write-text
           :create-client
           :on-open
           :on-text
           :on-binary
           :client
           :handler
           :process-new-connection
           :taskmaster))
(in-package :tiny-websocket)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun simple-inserter (insert-fn)
    (lambda (acc next)
      (if (listp next)
          (funcall insert-fn acc next)
          (list next acc))))

  (defun insert-first (arg surround)
    (list* (car surround) arg (cdr surround)))

  (defun insert-last (arg surround)
    (append surround (list arg))))

(defmacro -> (initial-form &rest forms)
  (reduce (simple-inserter #'insert-first) forms
          :initial-value initial-form))

(defmacro ->> (initial-form &rest forms)
  (reduce (simple-inserter #'insert-last) forms
          :initial-value initial-form))

;;;

(defun is-opening-handshake (upgrade
                             sec-websocket-key
                             sec-websocket-version)
  (and (stringp upgrade)
       (stringp sec-websocket-key)
       (stringp sec-websocket-version)
       (string= upgrade "websocket")
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

(defun octet-to-bit-vector (byte bit-size)
  (let ((bit-vector (make-sequence '(vector bit) bit-size)))
    (loop for x = byte then (ash x -1)
          for j from (1- bit-size) downto 0 do
      (setf (bit bit-vector j) (logand x 1)))
    bit-vector))

(defun bit-vector-to-octet (bit-vec)
  (let ((value 0))
    (loop repeat (length bit-vec)
          for bit across bit-vec do
      (setf value (logior (ash value 1) bit)))
    value))

(defun octets-to-single-octet (octets)
  (loop for octet across octets
        for shift from (1- (length octets)) downto 0
        sum (ash octet (* 8 shift))))

(defun read-octets (stream byte-size)
  (let ((octets (make-array byte-size
                            :element-type '(unsigned-byte 8))))
    (read-sequence octets stream)
    octets))

(defun read-into-single-octet (stream byte-size)
  (octets-to-single-octet (read-octets stream byte-size)))

(defun read-frame (stream)
  (let ((frame (make-frame))
        (bit0-15 (-> (read-into-single-octet stream 2)
                     (octet-to-bit-vector 16))))
    (let ((rsv1 (bit bit0-15 1))
          (rsv2 (bit bit0-15 2))
          (rsv3 (bit bit0-15 3)))
      (assert (= rsv1 0))
      (assert (= rsv2 0))
      (assert (= rsv3 0)))
    (setf (frame-fin frame)
          (bit bit0-15 0))
    (setf (frame-opcode frame)
          (-> (subseq bit0-15 4 8)
              (bit-vector-to-octet)))
    (setf (frame-mask frame)
          (bit bit0-15 8))
    (setf (frame-payload-len frame)
          (-> (subseq bit0-15 9 16)
              (bit-vector-to-octet)))
    (setf (frame-extended-payload-len frame)
          (let ((payload-len (frame-payload-len frame)))
            (cond ((= payload-len 126)
                   (read-into-single-octet stream 2))
                  ((= payload-len 127)
                   (let ((octet (read-into-single-octet
                                 stream 8)))
                     (assert
                      (= (bit (octet-to-bit-vector octet 0)) 0))
                     octet))
                  (t
                   (assert (<= payload-len 125))
                   0))))
    (setf (frame-masking-key frame)
          (if (= (frame-mask frame) 1)
              (read-octets stream 4)
              nil))
    (setf (frame-payload-data frame)
          (let ((payload-len
                 (frame-payload-len frame))
                (extended-payload-len
                 (frame-extended-payload-len frame)))
            (read-octets stream
                         (if (= extended-payload-len 0)
                             payload-len
                             extended-payload-len))))
    frame))

(defun masking-transform (masking-key octets)
  (assert (= (length masking-key) 4))
  (let ((out-octets (make-array (length octets)
                                :element-type '(unsigned-byte 8))))
    (loop for i from 0 below (length octets) do
      (setf (aref out-octets i)
            (logxor (aref masking-key (mod i 4))
                    (aref octets i))))
    out-octets))

(defun frame-unmasked-payload (frame)
  (if (= (frame-mask frame) 1)
      (masking-transform (frame-masking-key frame)
                         (frame-payload-data frame))
      (frame-payload-data frame)))

;; TODO: may need write lock
(defun write-frame (stream frame)
  (let ((bit0-15 (make-sequence '(vector bit) 16
                                :initial-element 0)))
    (setf (bit bit0-15 0)
          (frame-fin frame))
    (setf (subseq bit0-15 4 8)
          (-> (frame-opcode frame)
              (octet-to-bit-vector 4)))
    (setf (bit bit0-15 8)
          (frame-mask frame))
    (setf (subseq bit0-15 9 16)
          (-> (frame-payload-len frame)
              (octet-to-bit-vector 7)))
    (write-byte (-> (subseq bit0-15 0 8)
                    (bit-vector-to-octet))
                stream)
    (write-byte (-> (subseq bit0-15 8 16)
                    (bit-vector-to-octet))
                stream))
  (let ((payload-len (frame-payload-len frame)))
    ;; TODO
    (assert (<= payload-len 125)))
  (when (= (frame-mask frame) 1)
    (write-sequence (frame-masking-key frame) stream))
  (write-sequence (frame-payload-data frame) stream)
  (force-output stream))

(let ((empty (make-array 0 :element-type '(unsigned-byte 8))))
  (let ((frame (make-frame
                :fin 1
                :opcode #x8
                :mask 0
                :payload-len 0
                :extended-payload-len 0
                :masking-key empty
                :payload-data empty)))
    (defun server-sent-frame/close () frame))

  (defun server-sent-frame/text (octets first-p fin-p)
    (let ((len (length octets)))
      (assert (< len 126))
      (make-frame
       :fin (if fin-p 1 0)
       :opcode (if first-p #x1 #x0)
       :mask 0
       :payload-len len
       :extended-payload-len 0
       :masking-key empty
       :payload-data octets)))

  (let ((frame (make-frame
                :fin 1
                :opcode #x9
                :mask 0
                :payload-len 0
                :extended-payload-len 0
                :masking-key empty
                :payload-data empty)))
    (defun server-sent-frame/ping () frame))

  (let ((frame (make-frame
                :fin 1
                :opcode #xA
                :mask 0
                :payload-len 0
                :extended-payload-len 0
                :masking-key empty
                :payload-data empty)))
    (defun server-sent-frame/pong () frame)))

;;;

(defgeneric client-stream (client))

(defun client-write-text (client string)
  (let ((stream (client-stream client))
        (octets (babel:string-to-octets string))
        (count 125))
    (let ((len (length octets)))
      (loop for start = 0 then end-maybe
            for end-maybe = (+ start count)
            for fin-p = (<= len end-maybe)
            for frame = (server-sent-frame/text
                         (subseq octets
                                 start
                                 (if fin-p len end-maybe))
                         (= start 0)
                         fin-p)
            do (write-frame stream frame)
            while (not fin-p)))))

(defgeneric create-client (handler stream)
  (:method (handler stream)
    (make-instance 'client :stream stream)))

(defgeneric on-open (handler client)
  (:method (handler client)
    nil))

(defgeneric on-text (handler client string)
  (:method (handler client string)
    nil))

(defgeneric on-binary (handler client seq)
  (:method (handler client seq)
    nil))


(defun append-seq (seq-list)
  (let ((ret-seq (make-array
                  (reduce #'+ (mapcar #'length seq-list))
                  :element-type '(unsigned-byte 8))))
    (loop for seq in seq-list
          for len = (length seq)
          for offset = 0 then (+ offset len) do
      (setf (subseq ret-seq offset (+ offset len)) seq))
    ret-seq))

(defun handle-frame (handler frames client)
  (let ((first-frame (car frames)))
    (let ((opcode (frame-opcode first-frame)))
      (cond ((or (= opcode #x1)
                 (= opcode #x2))
             (let ((octets (append-seq
                            (mapcar #'frame-unmasked-payload
                                    frames))))
               (if (= opcode 1)
                   ;; text
                   (let ((text (babel:octets-to-string octets)))
                     (on-text handler client text))
                   ;; binary
                   (on-binary handler client octets)))
             t)
            ((= opcode #x8)
             (write-frame (client-stream client)
                          (server-sent-frame/close))
             nil)
            ((= opcode #x9)
             (write-frame (client-stream client)
                          (server-sent-frame/pong))
             t)
            ((= opcode #xA)
             (write-frame (client-stream client)
                          (server-sent-frame/ping))
             t)
            (t
             (assert nil))))))

(defun read-frames (stream)
  (let ((frames nil))
    (loop for frame = (read-frame stream)
          while frame
          if (= (frame-mask frame) 0) do
            (return nil)
          else do
            (push frame frames)
          while (= (frame-fin frame) 0))
    (nreverse frames)))

(defun handler-loop (handler stream)
  (handler-case
      (let ((client (create-client handler stream)))
        (on-open handler client)
        (loop for frames = (read-frames stream)
              while frames
              for continue-p = (handle-frame handler frames client)
              while continue-p))
    (error (c)
      (print c)))) ;; TODO


(defclass client ()
  ((stream
    :initarg :stream
    :reader client-stream)))

(defclass handler () ())

;;;

(defgeneric process-new-connection (taskmaster handler stream))

(defclass taskmaster ()
  ((streams :initform nil
            :accessor taskmaster-streams)
   (streams-lock :initform (bt:make-lock "streams-lock")
                 :reader taskmaster-streams-lock)))

(defun call-with-stream-added (taskmaster stream fn)
  (with-accessors ((streams taskmaster-streams)
                   (streams-lock taskmaster-streams-lock)) taskmaster
    (bt:with-lock-held (streams-lock)
      (push stream streams))
    (unwind-protect
         (funcall fn)
      (bt:with-lock-held (streams-lock)
        (setf streams (remove stream streams))))))

(defmacro with-stream-added ((taskmaster stream) &body body)
  `(call-with-stream-added ,taskmaster ,stream (lambda () ,@body)))

(defmethod process-new-connection ((taskmaster taskmaster) handler stream)
  (bt:make-thread
   (lambda ()
     (with-stream-added (taskmaster stream)
       (handler-loop handler stream)
       (close stream)))))
