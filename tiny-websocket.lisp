(defpackage :tiny-websocket
  (:use :cl)
  (:export :is-opening-handshake
           :generate-accept-hash-value
           :process-new-connection
           :handler
           :taskmaster))
(in-package :tiny-websocket)

(defun simple-inserter (insert-fn)
  (lambda (acc next)
    (if (listp next)
        (funcall insert-fn acc next)
        (list next acc))))

(defun insert-first (arg surround)
  (list* (car surround) arg (cdr surround)))

(defun insert-last (arg surround)
  (append surround (list arg)))

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

(defun bit-vector->ubyte (bit-vec)
  (let ((value 0))
    (loop repeat (length bit-vec)
          for bit across bit-vec do
      (setf value (logior (ash value 1) bit)))
    value))

(defun byte->bit-vector (bit-size byte)
  (let ((bit-vector (make-sequence '(vector bit) bit-size)))
    (loop for x = byte then (ash x -1)
          for j from (1- bit-size) downto 0 do
      (setf (bit bit-vector j) (logand x 1)))
    bit-vector))

(defun read-seq (stream byte-size)
  (let ((seq (make-array byte-size :element-type '(unsigned-byte 8))))
    (read-sequence seq stream)
    seq))

(defun read-frame (stream)
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
          (-> (subseq bit0-15 4 8)
              (bit-vector->ubyte)))
    (setf (frame-mask frame)
          (bit bit0-15 8))
    (setf (frame-payload-len frame)
          (-> (subseq bit0-15 9 16)
              (bit-vector->ubyte)))
    (setf (frame-extended-payload-len frame)
          (let ((payload-len (frame-payload-len frame)))
            (cond ((= payload-len 126)
                   (-> (read-seq stream 2)
                       (byte-vector->bit-vector)
                       (bit-vector->ubyte)))
                  ((= payload-len 127)
                   (let ((bit-vector
                          (-> (read-seq stream 8)
                              (byte-vector->bit-vector))))
                     (assert (= (bit bit-vector 0) 0))
                     (bit-vector->ubyte bit-vector)))
                  (t
                   (assert (<= payload-len 125))
                   0))))
    (setf (frame-masking-key frame)
          (if (= (frame-mask frame) 1)
              (read-seq stream 4)
              nil))
    (setf (frame-payload-data frame)
          (let ((payload-len
                 (frame-payload-len frame))
                (extended-payload-len
                 (frame-extended-payload-len frame)))
            (read-seq stream
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
          (->> (frame-opcode frame)
               (byte->bit-vector 4)))
    (setf (bit bit0-15 8)
          (frame-mask frame))
    (setf (subseq bit0-15 9 16)
          (->> (frame-payload-len frame)
               (byte->bit-vector 7)))
    (write-byte (-> (subseq bit0-15 0 8)
                    (bit-vector->ubyte))
                stream)
    (write-byte (-> (subseq bit0-15 8 16)
                    (bit-vector->ubyte))
                stream))
  (let ((payload-len (frame-payload-len frame)))
    ;; TODO
    (cond ((= payload-len 126))
          ((= payload-len 127))))
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

  (defun server-sent-frame/text (text)
    (let ((payload-data (babel:string-to-octets text)))
      (let ((len (length payload-data)))
        (assert (< len 126))
        (make-frame
         :fin 1
         :opcode #x1
         :mask 0
         :payload-len len
         :extended-payload-len 0
         :masking-key empty
         :payload-data payload-data))))

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

(defclass handler () ())

(defgeneric on-open (handler stream)
  (:method (handler stream)
    nil))

(defgeneric on-text (handler stream string)
  (:method (handler stream string)
    (print string)
    nil))

(defgeneric on-binary (handler stream seq)
  (:method (handler stream seq)
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

(defun handle-frame (handler frames output-stream)
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
                     (on-text handler output-stream text))
                   ;; binary
                   (on-binary handler output-stream octets)))
             t)
            ((= opcode #x8)
             (write-frame output-stream (server-sent-frame/close))
             nil)
            ((= opcode #x9)
             (write-frame output-stream (server-sent-frame/pong))
             t)
            ((= opcode #xA)
             (write-frame output-stream (server-sent-frame/ping))
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
      (progn
        (on-open handler stream)
        (loop for frames = (read-frames stream)
              while frames
              for continue-p = (handle-frame handler frames stream)
              while continue-p))
    (error (c)
      (print c)))) ;; TODO

;;;

(defgeneric process-new-connection (taskmaster stream))

(defclass taskmaster ()
  ((handler :initform :handler
            :initarg :handler
            :reader taskmaster-handler)
   (streams :initform nil
            :accessor taskmaster-streams)
   (streams-lock :initform (bt:make-lock "streams-lock")
                 :reader taskmaster-streams-lock)))

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
  (bt:make-thread
   (lambda ()
     (with-stream-added (taskmaster stream)
       (handler-loop (taskmaster-handler taskmaster) stream)
       (close stream)))))
