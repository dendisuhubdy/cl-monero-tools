;;;; This file is part of monero-tools
;;;; Copyright 2018 Guillaume LE VAILLANT
;;;; Distributed under the GNU GPL v3 or later.
;;;; See the file LICENSE for terms of use and distribution.


(in-package :monero-tools)


(defun cryptonight (data variant)
  (declare (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum variant)
           (optimize (speed 3) (space 0) (safety 0) (debug 0)))
  (when (and (= variant 1) (< (length data) 43))
    (error "Cryptonight variant 1 requires at least 43 bytes of data."))
  (let* ((+scratchpad-size+ #.(ash 1 21))
         (+bounce-iterations+ #.(ash 1 20))
         (+aes-block-size+ 16)
         (+init-size-blk+ 8)
         (+init-size-byte+ (* +init-size-blk+ +aes-block-size+)))
    ;; Step 1: Use Keccak1600 to initialize the STATE and TEXT buffers
    ;; from the DATA.
    (let* ((state (keccak1600 data))
           (text (make-array +init-size-byte+ :element-type '(unsigned-byte 8))))
      (declare (type (simple-array (unsigned-byte 8) (200)) state)
               (type (simple-array (unsigned-byte 8) (128)) text)
               (dynamic-extent text))
      (replace text state :start2 64)
      ;; Step 2: Iteratively encrypt the results from Keccak to fill the
      ;; 2MB large random access buffer.
      (let ((round-keys (pseudo-aes-expand-key state 0))
            (scratchpad (make-array +scratchpad-size+ :element-type '(unsigned-byte 8))))
        (declare (type aes-round-keys round-keys)
                 (type (simple-array (unsigned-byte 8) (#.(ash 1 21))) scratchpad))
        (dotimes (i (/ +scratchpad-size+ +init-size-byte+))
          (dotimes (j +init-size-blk+)
            (pseudo-aes-rounds text (* j +aes-block-size+) text (* j +aes-block-size+) round-keys))
          (replace scratchpad text :start1 (* i +init-size-byte+)))
        ;; Step 3: Bounce randomly 1,048,576 times through the mixing
        ;; buffer, using 524,288 iterations of the following mixing
        ;; function. Each execution performs two reads and writes from
        ;; the mixing buffer.
        (let ((a (make-array 16 :element-type '(unsigned-byte 8)))
              (b (make-array 32 :element-type '(unsigned-byte 8)))
              (c1 (make-array 16 :element-type '(unsigned-byte 8)))
              (c2 (make-array 16 :element-type '(unsigned-byte 8)))
              (d (make-array 16 :element-type '(unsigned-byte 8)))
              (tweak (if (= variant 1) (logxor (ub64ref/le state 192) (ub64ref/le data 35)) 0))
              (division-result (if (= variant 2) (ub64ref/le state 96) 0))
              (sqrt-result (if (= variant 2) (ub64ref/le state 104) 0)))
          (declare (type (simple-array (unsigned-byte 8) (16)) a c1 c2 d)
                   (type (simple-array (unsigned-byte 8) (32)) b)
                   (dynamic-extent a b c1 c2 d)
                   (type (unsigned-byte 64) tweak division-result sqrt-result))
          (xor-block 16 state 0 state 32 a 0)
          (xor-block 16 state 16 state 48 b 0)
          (when (= 2 variant)
            (xor-block 16 state 64 state 80 b 16))
          (dotimes (i (/ +bounce-iterations+ 2))
            ;; Iteration 1
            (let ((scratchpad-address (logand (ub32ref/le a 0) #x1ffff0)))
              (declare (type (unsigned-byte 21) scratchpad-address))
              (copy-block 16 scratchpad scratchpad-address c1 0)
              (pseudo-aes-round c1 0 c1 0 a)
              (when (= variant 2)
                (let* ((i1 (logxor scratchpad-address #x10))
                       (i2 (logxor scratchpad-address #x20))
                       (i3 (logxor scratchpad-address #x30))
                       (t0 (ub64ref/le scratchpad i1))
                       (t1 (ub64ref/le scratchpad (+ i1 8))))
                  (declare (type (unsigned-byte 21) i1 i2 i3)
                           (type (unsigned-byte 64) t0 t1))
                  (setf (ub64ref/le scratchpad i1) (mod64+ (ub64ref/le scratchpad i3)
                                                           (ub64ref/le b 16))
                        (ub64ref/le scratchpad (+ i1 8)) (mod64+ (ub64ref/le scratchpad (+ i3 8))
                                                                 (ub64ref/le b 24))
                        (ub64ref/le scratchpad i3) (mod64+ (ub64ref/le scratchpad i2)
                                                           (ub64ref/le a 0))
                        (ub64ref/le scratchpad (+ i3 8)) (mod64+ (ub64ref/le scratchpad (+ i2 8))
                                                                 (ub64ref/le a 8))
                        (ub64ref/le scratchpad i2) (mod64+ t0 (ub64ref/le b 0))
                        (ub64ref/le scratchpad (+ i2 8)) (mod64+ t1 (ub64ref/le b 8)))))
              (xor-block 16 b 0 c1 0 scratchpad scratchpad-address)
              (when (= variant 1)
                (let* ((tmp (aref scratchpad (+ scratchpad-address 11)))
                       (index (logand (ash (logior (logand (ash tmp -3) 6) (logand tmp 1)) 1) #xff)))
                  (declare (type (unsigned-byte 8) tmp index))
                  (setf (aref scratchpad (+ scratchpad-address 11))
                        (logxor tmp (logand (ash #x75310 (- index)) #x30)))))
              ;; Iteration 2
              (setf scratchpad-address (logand (ub32ref/le c1 0) #x1ffff0))
              (copy-block 16 scratchpad scratchpad-address c2 0)
              (when (= variant 2)
                (setf (ub64ref/le c2 0) (logxor (ub64ref/le c2 0)
                                                division-result
                                                (mod64ash sqrt-result 32)))
                (let ((dividend (ub64ref/le c1 8))
                      (divisor (logior #x80000001
                                       (logand #xffffffff
                                               (mod64+ (ub64ref/le c1 0)
                                                       (logand #xffffffff
                                                               (mod64ash sqrt-result 1)))))))
                  (declare (type (unsigned-byte 64) dividend)
                           (type (unsigned-byte 32) divisor))
                  (multiple-value-bind (q r) (truncate dividend divisor)
                    (declare (type (unsigned-byte 64) q r))
                    (setf division-result (mod64+ (logand q #xffffffff) (mod64ash r 32))))
                  (let* ((sqrt-input (mod64+ (ub64ref/le c1 0) division-result))
                         (t0 (logand sqrt-input #xffffffff))
                         (t1 (ash sqrt-input -32)))
                    (declare (type (unsigned-byte 64) sqrt-input)
                             (type (unsigned-byte 32) t0 t1))
                    ;; On SBCL x86-64, converting sqrt-input to a double-float
                    ;; conses a bignum, which slows down the loop a lot.
                    ;; Separating it in two parts and making conversions of
                    ;; smaller integers solves this problem.
                    (setf sqrt-result (floor (- (* 2.0d0 (sqrt (+ t0 (* t1 4294967296.0d0)
                                                                  18446744073709551616.0d0)))
                                                8589934592.0d0)))
                    (let* ((s (ash sqrt-result -1))
                           (b (logand sqrt-result 1))
                           (r (mod64+ (mod64* s (mod64+ s b)) (mod64ash sqrt-result 32))))
                      (declare (type (unsigned-byte 64) s b r))
                      (when (> (mod64+ r b) sqrt-input)
                        (decf sqrt-result))
                      (when (< (mod64+ r #.(ash 1 32)) (mod64- sqrt-input s))
                        (incf sqrt-result))))))
              (let* ((t0 (* (ub32ref/le c1 0) (ub32ref/le c2 0)))
                     (t1 (* (ub32ref/le c1 0) (ub32ref/le c2 4)))
                     (t2 (* (ub32ref/le c1 4) (ub32ref/le c2 0)))
                     (t3 (* (ub32ref/le c1 4) (ub32ref/le c2 4)))
                     (carry (+ (ash t0 -32) (logand t1 #xffffffff) (logand t2 #xffffffff)))
                     (s0 (logior (logand t0 #xffffffff) (mod64ash carry 32)))
                     (carry (+ (ash carry -32) (ash t1 -32) (ash t2 -32)))
                     (s1 (mod64+ t3 carry)))
                (declare (type (unsigned-byte 64) t0 t1 t2 t3 s0 s1 carry))
                (setf (ub64ref/le d 0) s1)
                (setf (ub64ref/le d 8) s0))
              (when (= variant 2)
                (let ((i1 (logxor scratchpad-address #x10))
                      (i2 (logxor scratchpad-address #x20))
                      (i3 (logxor scratchpad-address #x30)))
                  (declare (type (unsigned-byte 21) i1 i2 i3))
                  (xor-block 16 d 0 scratchpad i1 scratchpad i1)
                  (xor-block 16 d 0 scratchpad i2 d 0)
                  (let ((t0 (ub64ref/le scratchpad i1))
                        (t1 (ub64ref/le scratchpad (+ i1 8))))
                    (declare (type (unsigned-byte 64) t0 t1))
                    (setf (ub64ref/le scratchpad i1) (mod64+ (ub64ref/le scratchpad i3)
                                                             (ub64ref/le b 16))
                          (ub64ref/le scratchpad (+ i1 8)) (mod64+ (ub64ref/le scratchpad (+ i3 8))
                                                                   (ub64ref/le b 24))
                          (ub64ref/le scratchpad i3) (mod64+ (ub64ref/le scratchpad i2)
                                                             (ub64ref/le a 0))
                          (ub64ref/le scratchpad (+ i3 8)) (mod64+ (ub64ref/le scratchpad (+ i2 8))
                                                                   (ub64ref/le a 8))
                          (ub64ref/le scratchpad i2) (mod64+ t0 (ub64ref/le b 0))
                          (ub64ref/le scratchpad (+ i2 8)) (mod64+ t1 (ub64ref/le b 8))))))
              (setf (ub64ref/le a 0) (mod64+ (ub64ref/le a 0) (ub64ref/le d 0)))
              (setf (ub64ref/le a 8) (mod64+ (ub64ref/le a 8) (ub64ref/le d 8)))
              (copy-block 16 a 0 scratchpad scratchpad-address)
              (xor-block 16 a 0 c2 0 a 0)
              (when (= variant 1)
                (setf (ub64ref/le scratchpad (+ scratchpad-address 8))
                      (logxor (ub64ref/le scratchpad (+ scratchpad-address 8)) tweak)))
              (when (= variant 2)
                (copy-block 16 b 0 b 16))
              (copy-block 16 c1 0 b 0))))
        ;; Step 4: Sequentially pass through the mixing buffer and use
        ;; 10 rounds of AES encryption to mix the random data back into
        ;; the TEXT buffer. TEXT was originally created with the output
        ;; of Keccak1600.
        (replace text state :start2 64)
        (setf round-keys (pseudo-aes-expand-key state 32))
        (dotimes (i (/ +scratchpad-size+ +init-size-byte+))
          (dotimes (j +init-size-blk+)
            (xor-block 16 text (* j +aes-block-size+)
                       scratchpad (+ (* i +init-size-byte+) (* j +aes-block-size+))
                       text (* j +aes-block-size+))
            (pseudo-aes-rounds text (* j +aes-block-size+) text (* j +aes-block-size+) round-keys)))
        ;; Step 5: Apply Keccak to the state again, and then use the
        ;; resulting data to select which of four finalizer hash
        ;; functions to apply to the data (Blake, Groestl, JH, or
        ;; Skein). Use this hash to squeeze the state array down to the
        ;; final 256 bit hash output.
        (replace state text :start1 64)
        (let ((state-64 (make-array 25 :element-type '(unsigned-byte 64))))
          (declare (type (simple-array (unsigned-byte 64) (25)) state-64)
                   (dynamic-extent state-64))
          (dotimes (i 25)
            (setf (aref state-64 i) (ub64ref/le state (* 8 i))))
          (keccakf state-64)
          (dotimes (i 25)
            (setf (ub64ref/le state (* 8 i)) (aref state-64 i))))
        (digest-sequence (case (logand (aref state 0) 3)
                           ((0) :blake256)
                           ((1) :groestl/256)
                           ((2) :jh/256)
                           ((3) :skein512/256))
                         state)))))
