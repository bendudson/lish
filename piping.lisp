;;
;; piping.lisp - Piping for Lish
;;

;; Piping, I/O redirection, and I/O functions that are useful for using in
;; a lish command line or script.

(in-package :lish)

(declaim (optimize (speed 0) (safety 3) (debug 3) (space 1)
		   (compilation-speed 0)))

(defun lisp-args-to-command (args &key (auto-space nil))
  "Turn the arguments into a string of arguments for a system command. String
arguments are concatenated together. Symbols are downcased and turned into
strings. Keywords are like symbols but prefixed with '--'. Everything else is
just turned into a string as printed with PRINC. If AUTO-SPACE is true, put
spaces between every argument."
  (with-output-to-string (str)
    (loop :with first-time = t
       :for a :in args :do
       (when auto-space
	 (if first-time
	     (setf first-time nil)
	     (princ " " str)))
       (typecase a
	 (keyword			; this is sort of goofy
	  (princ "--" str)
	  (princ (string-downcase (symbol-name a)) str))
	 (symbol
	  (princ (string-downcase (symbol-name a)) str))
	 (t
	  (princ a str))))))

(defun possibly-read (expr)
  (if (shell-expr-p expr)
      expr
      (shell-read expr)))

#|
;; This needs so much work.
(defun copy-stream (source destination)
  "Copy data from reading from SOURCE and writing to DESTINATION, until we get
an EOF on SOURCE."
  (let ((buf (make-array *buffer-size*
			 :element-type (stream-element-type source)))
	pos)
    (loop :do
       (setf pos (read-sequence buf source))
       (when (> pos 0)
	 (write-sequence buf destination :end pos))
       :while (= pos *buffer-size*))))
|#

(defun byte-copy-stream (source destination)
  "This seems like a slow thing that will only work on bivalent streams?"
  (loop :with b
     :while (setf b (read-byte source nil nil))
     :do (write-byte b destination)))

(defun append-files (input-files output-file &key callback)
  "Copy the data from INPUT-FILES appending it to OUTPUT-FILE. Create
OUTPUT-FILE if it doesn't exist."
  (with-open-file (out (quote-filename output-file) :direction :output
		       :if-exists :append
		       :if-does-not-exist :create
		       :element-type '(unsigned-byte 8))
    (loop :for file :in input-files :do
       (with-open-file (in (quote-filename file) :direction :input
			   :element-type '(unsigned-byte 8))
	 (when callback
	   (funcall callback file))
	 (copy-stream in out)))))

;; This is mostly for convenience from the command line
(defun append-file (input-file output-file)
  "Copy the data from INPUT-FILE appending it to OUTPUT-FILE. Create
OUTPUT-FILE if it doesn't exist."
  (append-files (list input-file) output-file))

(defun run-with-output-to (file-or-stream commands &key supersede append)
  "Run commands with output to a file or stream. COMMANDS can be a SHELL-EXPR,
or a list of arguments."
  (when (and supersede append)
    (error "Can't both supersede and append to a file."))
  (let ((result nil))
    (multiple-value-bind (vals in-stream)
	(shell-eval (possibly-read commands)
		    :context (modified-context *context* :out-pipe t))
      (unwind-protect
	   (when (and vals (> (length vals) 0))
	     (with-open-file-or-stream
		 (out-stream file-or-stream
			     :direction :output
			     :if-exists
			     (if supersede
				 :supersede
				 (if append
				     :append
				     :error))
			     :if-does-not-exist :create
			     #+sbcl :element-type #+sbcl :default
			     #-sbcl :element-type #-sbcl '(unsigned-byte 8)
			     )
	       #+sbcl
	       (if (and
		    (or (eq (stream-element-type in-stream) :default)
			(eq (stream-element-type in-stream) 'unsigned-byte))
		    (or (eq (stream-element-type out-stream) :default)
			(eq (stream-element-type out-stream) 'unsigned-byte)))
		   (byte-copy-stream in-stream out-stream)
		   (copy-stream in-stream out-stream))
	       #-sbcl (copy-stream in-stream out-stream))
	     (setf result vals))
	(when in-stream
	  (close in-stream))))
    result))

(defun run-with-input-from (file-or-stream commands)
  "Run commands with input from a file or stream. COMMANDS can be a SHELL-EXPR,
or a list to be converted by LISP-ARGS-TO-COMMAND."
  (let ((result nil))
    (with-open-file-or-stream (in-stream file-or-stream)
      (multiple-value-bind (vals)
	  (shell-eval (possibly-read commands)
		      :context (modified-context *context* :in-pipe in-stream))
	(setf result vals)))
    result))

(defun input-line-words ()
  "Return lines from *standard-input* as a string of words."
  (with-output-to-string (s)
    (loop :with l = nil :and first = t
       :while (setf l (read-line *standard-input* nil nil))
       :do
       (if first
	   (progn (format s "~a" l)
		  (setf first nil))
	   (format s " ~a" l)))))

(defun input-line-list (&optional (stream *standard-input*))
  "Return lines from *standard-input* as list of strings."
  (loop :with l = nil
     :while (setf l (read-line (or stream *standard-input*) nil nil))
     :collect l))

(defun map-output-lines (func command)
  "Return a list of the results of calling the function FUNC with each output
line of COMMAND. COMMAND should probably be a string, and FUNC should take one
string as an argument."
  (let (vals stream)
    (unwind-protect
      (progn
	(multiple-value-setq (vals stream)
	  (shell-eval (possibly-read command)
		      :context (modified-context *context* :out-pipe t)))
	(when (and vals (> (length vals) 0))
	  (loop :with l = nil
	     :while (setf l (read-line stream nil nil))
	     :collect (funcall func l))))
      (when stream
	(close stream)))))

;; This is basically backticks #\` or $() in bash.
(defun command-output-words (command &optional quoted)
  "Return lines output from command as a string of words."
  (labels ((convert-to-words (in-stream out-stream)
	     (loop :with l = nil :and first-time = t
		:while (setf l (read-line in-stream nil nil))
		:do
		(format out-stream
			(if quoted "~:[~; ~]\"~a\"" "~:[~; ~]~a")
			(not first-time) l)
		(setf first-time nil))))
    (with-output-to-string (s)
      (let (vals stream)
	(unwind-protect
	   (progn
	     (multiple-value-setq (vals stream)
	       (shell-eval (possibly-read command)
			   :context (modified-context *context* :out-pipe t)))
	     (when (and vals (> (length vals) 0))
	       (convert-to-words stream s)))
	  (when stream
	    (close stream)))))))

(defun command-output-list (command)
  "Return lines output from command as a list."
  (map-output-lines #'identity command))

(defun pipe (&rest commands)
  "Send output from commands to subsequent commands."
  (labels ((sub (cmds &optional in-stream)
	     (let (vals stream)
	       (unwind-protect
	         (progn
		   (multiple-value-setq (vals stream)
		     (shell-eval (possibly-read (car cmds))
				 :context (modified-context
					   *context*
					   :in-pipe in-stream
					   :out-pipe (and (cadr cmds) t))))
		   (if (and vals (listp vals) (> (length vals) 0))
		       (if (cdr cmds)
			   (apply #'pipe stream (cdr cmds))
			   (values-list vals))
		       nil))
		 (when stream
		   (finish-output stream)
		   (close stream))))))
    (if (streamp (car commands))
	(sub (cdr commands) (car commands))
	(sub commands))))

;; (defvar *files-to-delete* '()
;;   "A list of files to delete at the end of a command.")
;;
;; ;; This has a lot of potential problems / security issues.
;; (defun != (&rest commands)
;;   "Temporary file name output substitution."
;;   (multiple-value-bind (vals stream)
;;       (shell-eval (possibly-read commands)
;;                   :context (modified-context *context* :out-pipe t))
;;     (if (and vals (> (length vals) 0))
;; 	(let ((fn (nos:mktemp "lish")))
;; 	  (push fn *files-to-delete*)
;; 	  (with-posix-file (fd fn (logior O_WRONLY O_CREAT O_EXCL) #o600)
;; 	    (let ((buf (make-string (buffer-size))))
;; 	      (loop :while (read-sequence buf stream)
;; 	(progn
;; 	  (close stream)
;; 	  nil))))

;; I'm not really sure about these. I have a hard time remembering them,
;; and I worry they'll look like Perl.

(defun ! (&rest args)
  "Evaluate the shell command."
  (shell-eval (shell-read (lisp-args-to-command args))))

(defun !? (&rest args)
  "Evaluate the shell command, converting Unix shell result code into boolean.
This means the 0 is T and anything else is NIL."
  (let ((result
	 (shell-eval (shell-read (lisp-args-to-command args)))))
    (and (numberp result) (zerop result))))

(defun !$ (&rest command)
  "Return lines output from command as a string of words. This is basically
like $(command) in bash."
  (command-output-words (lisp-args-to-command command)))

(defun !$$ (&rest command)
  "Return lines of output from command as a string of quoted words."
  (command-output-words (lisp-args-to-command command) t))

(defun !@ (&rest command)
  "Return the output from command, broken into words by the shell reader."
  (shell-words-to-list (lish::shell-expr-words (shell-read (!- command)))))

(defun !_ (&rest command)
  "Return a list of the lines of output from the command."
  (command-output-list (lisp-args-to-command command)))

(defun !- (&rest command)
  "Return a string containing the output from the command."
  (with-output-to-string (str)
    (run-with-output-to str (lisp-args-to-command command))))

(defun !and (&rest commands)
  "Run commands until one fails."
  (declare (ignore commands))
  ;; @@@
  )

(defun !or (&rest commands)
  "Run commands if previous command succeeded."
  (declare (ignore commands))
  ;; @@@
  )

;; (defun !bg (&rest commands)
;;   "Run commands in the background."
;;   (declare (ignore commands))
;;   )

(defun !! (&rest commands)
  "Pipe output of commands. Return a stream of the output."
  (multiple-value-bind (vals stream)
      (shell-eval (shell-read (lisp-args-to-command commands))
		  :context (modified-context *context* :out-pipe t))
    (if (and vals (> (length vals) 0))
	stream
	(progn
	  (close stream)
	  nil))))

(defun !> (file-or-stream &rest commands)
  "Run commands with output to a file or stream."
  (run-with-output-to file-or-stream (lisp-args-to-command commands)))

(defun !>> (file-or-stream &rest commands)
  "Run commands with output appending to a file or stream."
  (declare (ignore file-or-stream commands))
  )

(defun !<> (file-or-stream &rest commands)
  "Run commands with input and output to a file or stream."
  (declare (ignore file-or-stream commands))
  )

(defun !>! (file-or-stream &rest commands)
  "Run commands with output to a file or stream, superseding it."
  (run-with-output-to file-or-stream commands :supersede t))

(defun !>>! (file-or-stream &rest commands)
  "Run commands with output appending to a file or stream, overwritting it."
  (declare (ignore file-or-stream commands))
  )

(defun !< (file-or-stream &rest commands)
  "Run commands with input from a file or stream."
  (run-with-input-from file-or-stream (lisp-args-to-command commands)))

(defun !!< (file-or-stream &rest commands)
  "Run commands with input from a file or stream and return a stream of output."
  (with-open-file-or-stream (in-stream file-or-stream)
    (multiple-value-bind (vals stream)
	(shell-eval (shell-read (lisp-args-to-command commands))
		    :context
		    (modified-context *context* :out-pipe t :in-pipe in-stream))
      (if (and vals (> (length vals) 0))
	  stream
	  (progn
	    (close stream)
	    nil)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; literal arg comands (= suffix)

(defun != (&rest args)
  "Run a command with the separate verbatim arguments, without shell syntax."
  (shell-eval (expr-from-args args)))

(defun !?= (&rest args)
  "Evaluate the shell command, converting Unix shell result code into boolean.
This means the 0 is T and anything else is NIL."
  (let ((result
	 (shell-eval (expr-from-args args))))
    (and (numberp result) (zerop result))))

(defun !$= (&rest command)
  "Return lines output from command as a string of words. This is basically
like $(command) in bash."
  (command-output-words (expr-from-args command)))

(defun !$$= (&rest command)
  "Return lines of output from command as a string of quoted words."
  (command-output-words (expr-from-args command) t))

(defun !@= (&rest command)
  "Return the output from command, broken into words by the shell reader."
  (shell-words-to-list
   (lish::shell-expr-words
    (shell-read
     (with-output-to-string (str)
       (run-with-output-to str (expr-from-args command)))))))

(defun !_= (&rest args)
  "Run a command with the separate verbatim arguments, without shell syntax."
  (command-output-list (expr-from-args args)))

(defun !-= (&rest command)
  "Return a string containing the output from the command."
  (with-output-to-string (str)
    (run-with-output-to str (expr-from-args command))))

(defun !!= (&rest commands)
  "Pipe output of commands. Return a stream of the output."
  (multiple-value-bind (vals stream)
      (shell-eval (expr-from-args commands)
		  :context (modified-context *context* :out-pipe t))
    (if (and vals (> (length vals) 0))
	stream
	(progn
	  (close stream)
	  nil))))

;; EOF
