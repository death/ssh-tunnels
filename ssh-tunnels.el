;;; ssh-tunnels.el --- Manage SSH tunnels

;; Author: death <github.com/death>
;; Version: 1.0
;; Package-Requires: ((cl-lib "0.5") (emacs "24"))
;; Keywords: tools, convenience
;; URL: http://github.com/death/ssh-tunnels

;; This file is not part of GNU Emacs.

;; Copyright (c) 2015 death

;; Permission is hereby granted, free of charge, to any person
;; obtaining a copy of this software and associated documentation
;; files (the "Software"), to deal in the Software without
;; restriction, including without limitation the rights to use, copy,
;; modify, merge, publish, distribute, sublicense, and/or sell copies
;; of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
;; BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
;; ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;; CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; This package lets you run and kill SSH tunnels.  To use it:
;;
;; - Set the variable `ssh-tunnels-configurations', e.g.:
;;
;;   (setq ssh-tunnels-configurations
;;         '((:name "my local tunnel"
;;            :local-port 1234
;;            :remote-port 3306
;;            :login "me@host")
;;           (:name "my remote tunnel"
;;            :type "-R"
;;            :local-port 1234
;;            :remote-port 3306
;;            :login "me@host")
;;           (:name "my local socket tunnel"
;;            :type "-L"
;;            :local-socket "/tmp/socket"
;;            :remote-socket "/tmp/socket"
;;            :login "me@host")))
;;
;; - Type M-x ssh-tunnels RET
;;
;; - You should see the list of tunnels; running tunnels will have 'R'
;;   in their state column
;;
;; - To run the tunnel at the current line, type r
;;
;; - To kill a running tunnel, type k
;;
;; - You may want to temporarily change a tunnel's local port.  To do
;;   that you may provide a prefix argument to the run command, for
;;   example by typing C-u 1235 r

;;; Code:

(require 'cl-lib)
(require 'netrc)
(require 'tabulated-list)

(defgroup ssh-tunnels nil
  "View and manipulate SSH tunnels."
  :group 'tools
  :group 'convenience)

(defcustom ssh-tunnels-use-header-line t
  "If non-nil, use the header line to display ssh-tunnels column titles."
  :type 'boolean
  :group 'ssh-tunnels)

(defface ssh-tunnels-name
  '((t (:weight bold)))
  "Face for ssh tunnel names in the ssh tunnels buffer."
  :group 'ssh-tunnels)

(defcustom ssh-tunnels-name-width 20
  "Width of tunnel name column in the ssh tunnels buffer."
  :type 'number
  :group 'ssh-tunnels)

(defcustom ssh-tunnels-local-port-width 7
  "Width of tunnel local port column in the ssh tunnels buffer."
  :type 'number
  :group 'ssh-tunnels)

(defcustom ssh-tunnels-host-width 50
  "Width of tunnel host column in the ssh tunnels buffer."
  :type 'number
  :group 'ssh-tunnels)

(defcustom ssh-tunnels-remote-port-width 7
  "Width of tunnel remote port column in the ssh tunnels buffer."
  :type 'number
  :group 'ssh-tunnels)

(defcustom ssh-tunnels-login-width 50
  "Width of tunnel login column in the ssh tunnels buffer."
  :type 'number
  :group 'ssh-tunnels)

(defcustom ssh-tunnels-program "ssh"
  "The name of the SSH program."
  :type 'string
  :group 'ssh-tunnels)

(defcustom ssh-tunnels-configurations '()
  "A list of SSH tunnel configurations.  Each element is a plist
with the following properties:

  :name - The name of the tunnel.

  :type - Tunnel type; defaults to \"-L\" (Local).
          May also be \"-R\" or \"-D\" for Remote and Dynamic tunnels.
          If set to \"SH\", no port forwarding will be attempted and your ssh
          client is responsible for tunnelling (e.g. with ~/.ssh/config), in
          this case `:login' must match your ~/.ssh/config entry and `:host',
          `:local-port', `:remote-port', `:local-socket', `:remote-socket'
          are ignored.

  :login - The SSH login to use.

  :host - The tunneling host; defaults to \"localhost\".

  :local-port - The tunnel's local port; defaults
                to the value of `:remote-port'.

  :remote-port - The tunnel's remote port; defaults
                 to the value of `:local-port'.

For tunneling sockets, use the properties below, instead of `:local-port'
and/or `:remote-port'.

  :local-socket - The tunnel's local socket; defaults
                  to the value of `:remote-socket'.

  :remote-socket - The tunnel's remote socket; defaults
                   to the value of `:local-socket'."
  :type 'sexp
  :group 'ssh-tunnels)

(defcustom ssh-tunnels-temp-directory "/tmp/"
  "The directory where SSH control socket files will reside."
  :type 'string
  :group 'ssh-tunnels)

(defvar ssh-tunnels--state-table
  (make-hash-table :test 'equal)
  "A table to keep tunnel-related state.

Note that we'll lose this state if the user exits Emacs (rms
forbid...), or it may become irrelevant if
`ssh-tunnels-configurations' changes.

The table is keyed by tunnel names.  The state is the local port
or socket associated with the tunnel.")

(defvar ssh-tunnels-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "q" 'quit-window)
    (define-key map "g" 'ssh-tunnels-refresh)
    (define-key map "r" 'ssh-tunnels-run)
    (define-key map "k" 'ssh-tunnels-kill)
    (define-key map "R" 'ssh-tunnels-rerun)
    map))

(define-derived-mode ssh-tunnels-mode tabulated-list-mode "SSH tunnels"
  "Major mode for managing SSH tunnels."
  (add-hook 'tabulated-list-revert-hook 'ssh-tunnels-refresh nil t))

;;;###autoload
(defun ssh-tunnels ()
  "View and manipulate SSH tunnels."
  (interactive)
  (switch-to-buffer (ssh-tunnels--noselect)))

(defun ssh-tunnels--noselect ()
  (let ((buffer (get-buffer-create "*SSH tunnels*")))
    (with-current-buffer buffer
      (ssh-tunnels-mode)
      (ssh-tunnels-refresh))
    buffer))

(defun ssh-tunnels-refresh ()
  (interactive)
  (let ((name-width ssh-tunnels-name-width)
        (local-port-width ssh-tunnels-local-port-width)
        (host-width ssh-tunnels-host-width)
        (remote-port-width ssh-tunnels-remote-port-width)
        (login-width ssh-tunnels-login-width))
    (setq tabulated-list-format
          (vector `("S" 1 t)
                  `("Name" ,name-width t)
                  `("Type" 4 t)
                  `("LPort" ,local-port-width ssh-tunnels--lport> :right-align t)
                  `("Host" ,host-width t)
                  `("RPort" ,remote-port-width ssh-tunnels--rport> :right-align t)
                  `("Login" ,login-width t))))
  (setq tabulated-list-use-header-line ssh-tunnels-use-header-line)
  (let ((entries '()))
    (dolist (tunnel ssh-tunnels-configurations)
      (let* ((name (ssh-tunnels--property tunnel :name))
             (tunnel-type (ssh-tunnels--property tunnel :type))
             (local-port (ssh-tunnels--property tunnel :local-port))
	     (remote-port (ssh-tunnels--property tunnel :remote-port))
	     (local-socket (ssh-tunnels--property tunnel :local-socket))
	     (remote-socket (ssh-tunnels--property tunnel :remote-socket))
             (host (ssh-tunnels--property tunnel :host))
             (login (ssh-tunnels--property tunnel :login)))
	(ssh-tunnels--validate tunnel)
        (push (list tunnel
                    (vector (if (ssh-tunnels--check tunnel) "R" " ")
                            (ssh-tunnels--pretty-name name)
                            tunnel-type
                            (if (numberp local-port)
                                (number-to-string local-port)
			      local-socket)
                            host
			    (if (numberp remote-port)
                                (number-to-string remote-port)
			      remote-socket)
                            login))
              entries)))
    (setq tabulated-list-entries (nreverse entries)))
  (tabulated-list-init-header)
  (tabulated-list-print t))

(defun ssh-tunnels--lport> (entry1 entry2)
  (> (string-to-number (aref (cadr entry1) 3))
     (string-to-number (aref (cadr entry2) 3))))

(defun ssh-tunnels--rport> (entry1 entry2)
  (> (string-to-number (aref (cadr entry1) 5))
     (string-to-number (aref (cadr entry2) 5))))

(defun ssh-tunnels--pretty-name (name)
  (propertize name
              'font-lock-face 'ssh-tunnels-name
              'mouse-face 'highlight))

(defun ssh-tunnels--tunnel (&optional error-if-does-not-exist)
  (let ((tunnel (tabulated-list-get-id)))
    (cond ((null tunnel)
           (if error-if-does-not-exist
               (error "No tunnel on this line")))
          (t tunnel))))

(defun ssh-tunnels-run (&optional arg)
  (interactive "P")
  (let ((tunnel (ssh-tunnels--tunnel t)))
    (when (numberp arg)
      ;; Use an ad-hoc local port instead of the local port or socket
      ;; specified in configuration.
      (setf tunnel (cl-copy-list tunnel))
      (cl-remf tunnel :local-port)
      (cl-remf tunnel :local-socket)
      (setf tunnel (cl-list* :local-port arg tunnel)))
    (ssh-tunnels--validate tunnel)
    (when (not (ssh-tunnels--check tunnel))
      (message "Tunneling...")
      (ssh-tunnels--run tunnel)
      (let ((name (ssh-tunnels--property tunnel :name))
            (local-port (ssh-tunnels--property tunnel :local-port))
	    (local-socket (ssh-tunnels--property tunnel :local-socket)))
        (if (numberp local-port)
            (message "Tunnel '%s' on port %d" name local-port)
          (message "Tunnel '%s' on socket '%s'" name local-socket)))))
  (forward-line)
  (ssh-tunnels-refresh))

(defun ssh-tunnels-kill ()
  (interactive)
  (let ((tunnel (ssh-tunnels--tunnel t)))
    (when (ssh-tunnels--check tunnel)
      (ssh-tunnels--kill tunnel)
      (message "Tunnel '%s' killed" (ssh-tunnels--property tunnel :name))))
  (forward-line)
  (ssh-tunnels-refresh))

(defun ssh-tunnels-rerun (&optional arg)
  (interactive "P")
  (ssh-tunnels-kill)
  (forward-line -1)
  (ssh-tunnels-run arg))

(defun ssh-tunnels--property (tunnel key)
  (cond ((eq key :host)
         (or (cl-getf tunnel :host) "localhost"))
        ((eq key :type)
         (or (cl-getf tunnel :type) "-L"))
        ((eq key :local-port)
         (let ((state (gethash (cl-getf tunnel :name) ssh-tunnels--state-table)))
           (if (numberp state)
               state
             (or (cl-getf tunnel :local-port)
                 (and (null (cl-getf tunnel :local-socket))
                      (cl-getf tunnel :remote-port))))))
        ((eq key :remote-port)
         (or (cl-getf tunnel :remote-port)
             (and (null (cl-getf tunnel :remote-socket))
                  (cl-getf tunnel :local-port))))
        ((eq key :local-socket)
         (let ((state (gethash (cl-getf tunnel :name) ssh-tunnels--state-table)))
           (if (stringp state)
               state
             (or (cl-getf tunnel :local-socket)
                 (and (null (cl-getf tunnel :local-port))
                      (cl-getf tunnel :remote-socket))))))
        ((eq key :remote-socket)
         (or (cl-getf tunnel :remote-socket)
             (and (null (cl-getf tunnel :local-port))
                  (cl-getf tunnel :local-socket))))
        (t
         (cl-getf tunnel key))))

(defun ssh-tunnels--validate (tunnel)
  ;; Note that we don't use ssh-tunnels--property to check for
  ;; mutually exclusive options, to avoid its default value behavior.
  (when (and (cl-getf tunnel :local-port)
             (cl-getf tunnel :local-socket))
    (error "Tunnel '%s' has both a `:local-port' and a `:local-socket'"
           (ssh-tunnels--property tunnel :name)))
  (when (and (cl-getf tunnel :remote-port)
             (cl-getf tunnel :remote-socket))
    (error "Tunnel '%s' has both a ':remote-port' and a ':remote-socket'"
           (ssh-tunnels--property tunnel :name))))

(defun ssh-tunnels--command (tunnel command)
  (let* ((name (ssh-tunnels--property tunnel :name))
         (tunnel-type (ssh-tunnels--property tunnel :type))
         (login (ssh-tunnels--property tunnel :login))
         (args
          (cond ((eq command :run)
                 (append (list "-M" "-f" "-N" "-T")
                         (if (string= tunnel-type "SH")
                             '()
                           (list tunnel-type
                                 (ssh-tunnels--forward-definition tunnel)))))
                ((eq command :kill)
                 (list "-O" "exit"))
                ((eq command :check)
                 (list "-O" "check"))
                (t (error "Unknown ssh-tunnels command '%s'" command))))
         (default-directory ssh-tunnels-temp-directory))
    (apply 'call-process ssh-tunnels-program nil nil nil
           "-S" (shell-quote-argument name)
           (append args (list login)))))

(defun ssh-tunnels--run (tunnel)
  (remhash (ssh-tunnels--property tunnel :name)
           ssh-tunnels--state-table)
  (puthash (ssh-tunnels--property tunnel :name)
           (or (ssh-tunnels--property tunnel :local-port)
               (ssh-tunnels--property tunnel :local-socket))
           ssh-tunnels--state-table)
  (ssh-tunnels--command tunnel :run))

(defun ssh-tunnels--kill (tunnel)
  (ssh-tunnels--command tunnel :kill)
  (remhash (ssh-tunnels--property tunnel :name)
           ssh-tunnels--state-table))

(defun ssh-tunnels--check (tunnel)
  (eql 0 (ssh-tunnels--command tunnel :check)))

(defun ssh-tunnels--toggle-state (tunnel)
  (if (ssh-tunnels--check tunnel)
      (ssh-tunnels--kill tunnel)
    (ssh-tunnels--run tunnel)))

(defun ssh-tunnels--forward-definition (tunnel)
  (let* ((name (ssh-tunnels--property tunnel :name))
         (tunnel-type (ssh-tunnels--property tunnel :type))
         (local-port (ssh-tunnels--property tunnel :local-port))
         (remote-port (ssh-tunnels--property tunnel :remote-port))
         (local-socket (ssh-tunnels--property tunnel :local-socket))
         (remote-socket (ssh-tunnels--property tunnel :remote-socket))
         (host (ssh-tunnels--property tunnel :host))
         (host
          (if (string-match-p (regexp-quote ":") host)
	      (format "[%s]" host)
            host)))
    (cond ((string= tunnel-type "-D")
           (unless (numberp local-port)
             (error "No local port specified for tunnel '%s'" name))
           (format "%s:%s" host local-port))
          ((string= tunnel-type "-R")
           (if (and remote-socket local-socket)
               (format "%s:%s" remote-socket local-socket)
             (format "%s:%s:%s"
                     (or remote-port remote-socket)
                     host
                     (or local-port local-socket))))
          (t
           ;; Default Local port forwarding
           (if (and local-socket remote-socket)
               (format "%s:%s" local-socket remote-socket)
             (format "%s:%s:%s"
                     (or local-port local-socket)
                     host
                     (or remote-port remote-socket)))))))

;;; completing-read frontend

(defun ssh-tunnels--read-tunnel ()
  (let* ((candidates (cl-loop
                      for tunnel in ssh-tunnels-configurations
                      collect (ssh-tunnels--property tunnel :name)))
         (candidate (completing-read "Tunnel: " candidates nil t)))
    (cl-find candidate ssh-tunnels-configurations
             :test #'string=
             :key (lambda (tunnel)
                    (ssh-tunnels--property tunnel :name)))))

(defun ssh-tunnels-run-tunnel ()
  "Start a configured SSH tunnel."
  (interactive)
  (ssh-tunnels--run (ssh-tunnels--read-tunnel)))

(defun ssh-tunnels-kill-tunnel ()
  "Kill a running SSH tunnel."
  (interactive)
  (ssh-tunnels--kill (ssh-tunnels--read-tunnel)))

;;; auto-ssh-tunnels mode

(defun ssh-tunnels--lookup (host service)
  "Return an SSH tunnel that matches the supplied HOST and
SERVICE, or NIL if there is no match."
  ;; According to OPEN-NETWORK-STREAM documentation, SERVICE may be a
  ;; service name, or an integer, or an integer string.  If it is an
  ;; integer string, we convert it to an integer here.
  (when (and (stringp service)
             (cl-some #'cl-digit-char-p service)
             (cl-every #'cl-digit-char-p service))
    (setq service (string-to-number service)))
  (cl-find-if (lambda (tunnel)
                (and (not (string= "SH" (ssh-tunnels--property tunnel :type)))
                     (string= host (ssh-tunnels--property tunnel :host))
                     (let ((tunnel-lport (ssh-tunnels--property tunnel :local-port)))
                       (and (numberp tunnel-lport)
                            (if (stringp service)
                                (netrc-port-equal service tunnel-lport)
                              (= service tunnel-lport))))))
              ssh-tunnels-configurations))

(defun open-network-stream@run-ssh-tunnel (name buffer host service &rest parameters)
  "Start SSH tunnel, if needed, before connecting to HOST.

Check whether `ssh-tunnels-configurations' has a tunnel matching
the host and service and, if so, make sure that the tunnel is
running."
  (let ((tunnel (ssh-tunnels--lookup host service)))
    (when (and tunnel (not (ssh-tunnels--check tunnel)))
      (message "Starting tunnel '%s'..." (ssh-tunnels--property tunnel :name))
      (ssh-tunnels--run tunnel))))

(define-minor-mode auto-ssh-tunnels-mode "Automatically start SSH tunnels"
  :global t
  :group 'ssh-tunnels
  (if auto-ssh-tunnels-mode
      (advice-add 'open-network-stream :before
                  #'open-network-stream@run-ssh-tunnel)
    (advice-remove 'open-network-stream #'open-network-stream@run-ssh-tunnel)))

(provide 'ssh-tunnels)

;;; ssh-tunnels.el ends here
