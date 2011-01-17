;;; wdoc.el --- Documentation authoring the WikiWay

;; Copyright (C) 2001, 2002  Alex Schroeder <alex@gnu.org>
;; Copyright (C) 2011 Eric Merritt <ericbmerritt@gmail.com>

;; This file is not part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free
;; Software Foundation; either version 2, or (at your option) any later
;; version.
;;
;; This is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
;; for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
;; MA 02111-1307, USA.


;;; Code:

(require 'easy-mmode); for easy-mmode-define-minor-mode
(require 'info); for info-xref face
(require 'thingatpt); for thing-at-point-looking-at and other things
(require 'compile); for grep-command
(load "goto-addr" t t); optional, for goto-address-mail-regexp

;; Options

(defgroup wdoc nil
  "Options controlling the behaviour of Wdoc Mode.
See `wdoc-mode' for more information.")

(defcustom wdoc-directories '(list (expand-file-name "~/Wdoc/"))
  "List of directories where all wdoc files are stored.
The directories should contain fully expanded directory names and they
should end with a slash on most systems, because each element in the
list is compared to the return value of `file-name-directory'.  And that
function returns trailing slashes.  Use `expand-file-name' to expand
directory names if necessary."
  :group 'wdoc
  :type '(hook))

(defcustom wdoc-date-format "%Y-%m-%d"
  "Format of current date for `wdoc-current-date'.
This string must be a valid argument to `format-time-string'."
  :group 'wdoc
  :type 'string)

(defcustom wdoc-highlight-buffer-hook '(wdoc-highlight-wdoc-names)
  "Hook with functions to call when a buffer is highlighted."
  :group 'wdoc
  :type 'hook)

(defgroup wdoc-link nil
  "Options controlling links in Wdoc Mode."
  :group 'wdoc)

(defcustom wdoc-name-regexp "\\<[A-Z]+[a-z]*\\([A-Z]+[a-z]*\\)+\\>"
  "Regexp matching WikiNames.
Whenever the regexp is searched for, case is never ignored:
`case-fold-search' will allways be bound to nil.

See `wdoc-no-name-p' if you want to exclude certain matches.
See `wdoc-name-no-more' if highlighting is not removed correctly."
  :group 'wdoc-link
  :type 'regexp)

(defcustom wdoc-file-name-regexp
  "\\<[A-Z]+[a-z]*\\([A-Z]+[a-z]*\\)+\\(.[a-z]+\\)*\\>"
  "Regexp matching Wdoc File Names.
Whenever the regexp is searched for, case is never ignored:
`case-fold-search' will allways be bound to nil."
  :group 'wdoc-link
  :type 'regexp)

(defcustom wdoc-name-no-more "[A-Za-z]+"
  "Regexp matching things that might once have been WdocNames.
Usually that amounts to all legal characters in `wdoc-name-regexp'.
This is used to remove highlighting from former WdocNames."
  :group 'wdoc-link
  :type 'regexp)

(defcustom wdoc-highlight-name-exists 'wdoc-name-exists-p
  "Function to call in order to determine wether a WikiName exists already.
This is used when highlighting words using `wdoc-highlight-match': If
the word is a non-existing wdoc-name, a question mark is appended.

See `wdoc-name-regexp' for possible names considered a WdocName."
  :group 'wdoc-link
  :type 'function)

(defcustom wdoc-follow-name-action 'find-file
  "Function to use when following references.
The function should accept a string parameter, the WdocName.
If the WdocName exists as a file in `wdoc-directories', the
fully qualified filename will be passed to the function."
  :group 'wdoc-link
  :type 'function)

(defgroup wdoc-parse nil
  "Options controlling parsing of the wdoc files.
These function only come in handy if you want to do complex things such
as find clusters in the graph or generate a structured table of contents."
  :group 'wdoc)

(defcustom wdoc-include-function t
  "Function to decide wether to include a file in the `wdoc-filter', or t.
If t, then all pages will be included.
The function should accept a filename and a wdoc structure as returned
by `wdoc-parse-files' as arguments and return non-nil if the file is to
be part of the graph."
  :group 'wdoc-parse
  :type '(choice (const :tag "All pages" t)
		 (const :tag "Significant fan out" wdoc-significant-fan-out)
		 function))

(defcustom wdoc-significant-fan-out 3
  "Pages with a fan out higher than this are significant.
This is used by `wdoc-significant-fan-out' which is a
possible value for `wdoc-include-function'."
  :group 'wdoc-parse
  :type 'integer)

;; Starting up

(defsubst wdoc-page-name ()
  "Return page name."
  (file-name-nondirectory buffer-file-name))

(defun wdoc-no-name-p ()
  "Return non-nil if point is within a URL.
This function is faster than checking using `thing-at-point-looking-at'
and `thing-at-point-url-regexp'.  Override this function if you do not
like it."
  (let ((pos (point)))
    (and (re-search-backward "[]\t\n \"'()<>[^`{}]" nil t)
	 (goto-char (match-end 0))
	 (looking-at thing-at-point-url-regexp)
	 (<= pos (match-end 0)))))

(defun wdoc-name-p (&optional shortcut)
  "Return non-nil when `point' is at a true wdoc name.
A true wdoc name matches `wdoc-name-regexp' and doesn't trigger
`wdoc-no-name-p'.  In addition to that, it may not be equal to the
current filename.  This modifies the data returned by `match-data'.

If optional argument SHORTCUT is non-nil, we assume that
`wdoc-name-regexp' has just been searched for.  Note that the potential
wdoc name must be available via `match-string'."
  (let ((case-fold-search nil))
    (and (or shortcut (thing-at-point-looking-at wdoc-name-regexp))
	 (or (not buffer-file-name)
	     (not (string-equal (wdoc-page-name) (match-string 0))))
	 (not (save-match-data
		(save-excursion
		  (wdoc-no-name-p)))))))

(defun wdoc-maybe ()
  "Maybe turn `wdoc-mode' on for this file.
This happens when the file's directory is a member of
`wdoc-directories'."
  (if (member (file-name-directory buffer-file-name)
              wdoc-directories)
      (wdoc-mode 1)
    (wdoc-mode 0)))

(add-hook 'find-file-hooks 'wdoc-maybe)

(defun wdoc-install ()
  "Install `wdoc-highlight-word-wrapper'."
  (make-local-variable 'after-change-functions)
  (add-to-list 'after-change-functions 'wdoc-highlight-word-wrapper))

(defun wdoc-deinstall ()
  "Deinstall `wdoc-highlight-word-wrapper'."
  (setq after-change-functions (delq 'wdoc-highlight-word-wrapper
				     after-change-functions)))

;; The minor mode (this is what you get)

(defvar wdoc-local-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'wdoc-follow-name-at-point)
    (if (featurep 'xemacs)
	(define-key map (kbd "<button2>") 'wdoc-follow-name-at-mouse)
      (define-key map (kbd "<mouse-2>") 'wdoc-follow-name-at-mouse))
    map)
  "Local keymap used by wdoc minor mode while on a WdocName.")

(defvar wdoc-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-l") 'wdoc-highlight-buffer)
    (define-key map (kbd "C-c C-p") 'wdoc-publish)
    (define-key map (kbd "C-c C-v") 'wdoc-view-published)
    (define-key map (kbd "C-c C-b") 'wdoc-backlink)
    (define-key map (kbd "C-c =") 'wdoc-backup)
    (define-key map (kbd "<tab>") 'wdoc-next-reference)
    (define-key map (kbd "M-n") 'wdoc-next-reference)
    (define-key map (kbd "M-p") 'wdoc-previous-reference)
    map)
  "Keymap used by wdoc minor mode.")

(easy-mmode-define-minor-mode
 wdoc-mode
 "Wdoc mode transform all WdocNames into links.

Wdoc is a hypertext and a content management system: Normal users are
encouraged to enhance the hypertext by editing and refactoring existing
wdocs and by adding more.  This is made easy by requiring a certain way
of writing the wdocs.  It is not as complicated as a markup language
such as HTML.  The general idea is to write plain ASCII.

Words with mixed case such as ThisOne are WdocNames.  WdocNames are
links you can follow.  If a wdoc with that name exists, you will be
taken there.  If such a does not exist, following the link will create a
new wdoc for you to fill.  WdocNames for non-existing wdocs have a `?'
appended so that you can see wether following the link will give you any
informatin or not.

In order to follow a link, hit RET when point is on the link, or use
mouse-2.

All wdocs reside in `wdoc-directories'.

\\{wdoc-mode-map}"
 nil
 " Wdoc"
 wdoc-mode-map)

(add-hook 'wdoc-mode-on-hook 'wdoc-install)
(add-hook 'wdoc-mode-on-hook 'wdoc-highlight-buffer)
(add-hook 'wdoc-mode-on-hook (lambda () (setq indent-tabs-mode nil)))

(add-hook 'wdoc-mode-off-hook 'wdoc-deinstall)
(add-hook 'wdoc-mode-off-hook 'wdoc-delete-extents)

(when (fboundp 'goto-address)
  (add-hook 'wdoc-highlight-buffer-hook 'goto-address))

;; List of known wdoc files

(defvar wdoc-last-update nil
  "Time when the `wdoc-file-alist' was last updated.")

(defvar wdoc-file-alist nil
  "List of existing WdocNames.
This is used by `wdoc-existing-names' as a cache.")

(defsubst wdoc-existing-page-names ()
  "Return all page names from `wdoc-existing-names'."
  (mapcar (lambda (f) (car f)) (wdoc-existing-names)))

(defsubst wdoc-existing-file-names ()
  "Return all file names from `wdoc-existing-names'."
  (mapcar (lambda (f) (cdr f)) (wdoc-existing-names)))

(defun wdoc-existing-names ()
  "Return wdoc filenames in `wdoc-directories' as an alist.
Wdoc filenames match `wdoc-name-regexp'.  The result is cached and
updated when necessary based upon directory modification dates.  The car
of each element is the page name, the cdr of each element is the fully
qualified filename.  Use `wdoc-existing-page-names' and
`wdoc-existing-file-names' to get lists of page names or file names."
  (let* ((dirs wdoc-directories)
         last-mod)
    (while dirs
      (let ((mod-time (nth 5 (file-attributes (car dirs)))))
        (if (or (null last-mod)
                (time-less-p last-mod mod-time))
            (setq last-mod mod-time)))
      (setq dirs (cdr dirs)))
    (if (not (or (null wdoc-last-update)
                 (null last-mod)
                 (time-less-p wdoc-last-update last-mod)))
        wdoc-file-alist
      (setq wdoc-last-update last-mod
	    wdoc-file-alist (wdoc-read-directories)))))

(defun wdoc-read-directories ()
  "Return list of all files in `wdoc-directories'.
Each element in the list is a cons cell.  The car holds the pagename,
the cdr holds the fully qualified filename."
  (let ((dirs wdoc-directories)
	(regexp (concat "^" wdoc-file-name-regexp "$"))
	result)
    (setq dirs wdoc-directories)
    (while dirs
      (let ((files (mapcar (lambda (f)
			     (cons (file-name-nondirectory
				    (file-name-sans-extension f)) f))
			   (directory-files (car dirs) t regexp t))))
	(setq result (nconc files result)))
      (setq dirs (cdr dirs)))
    result))

(defun wdoc-name-exists-p (name)
  "Return non-nil when NAME is an existing wdoc-name."
  (assoc name (wdoc-existing-names)))

(defun wdoc-expand-name (name)
  "Return the expanded filename for NAME.
This relies on `wdoc-existing-names'."
  (cdr (assoc name (wdoc-existing-names))))

;; Following hyperlinks
(defun wdoc-create-file-name (name)
  " If a file doesn't exist create it with the correct
extention. This is probably the extention of the file in the
current buffer"
  (let ((new-ext (file-name-extension (buffer-file-name))))
    (if new-ext
	(funcall wdoc-follow-name-action (concat name "." new-ext))
      (funcall wdoc-follow-name-action name))))

(defun wdoc-follow-name (name)
  "Follow the link NAME by invoking `wdoc-follow-name-action'.
If NAME is part a key in the alist returned by `wdoc-existing-names',
then the corresponding filename is used instead of NAME."
  (let ((file (cdr (assoc name (wdoc-existing-names)))))
    (if file
	(funcall wdoc-follow-name-action file)
      (wdoc-create-file-name name))))

(defun wdoc-follow-name-at-point ()
  "Find wdoc name at point.
See `wdoc-name-p' and `wdoc-follow-name'."
  (interactive)
  (if (wdoc-name-p)
      (wdoc-follow-name (match-string 0))
    (error "Point is not at a WdocName")))

(defun wdoc-follow-name-at-mouse (event)
  "Find wdoc name at the mouse position.
See `wdoc-follow-name-at-point'."
  (interactive "e")
  (save-excursion
    (mouse-set-point event)
    (wdoc-follow-name-at-point)))

(defun wdoc-next-reference ()
  "Jump to next wdoc name.
This modifies the data returned by `match-data'.
Returns the new position of point or nil.
See `wdoc-name-p'."
  (interactive)
  (let ((case-fold-search nil)
	found match)
    (save-excursion
      (condition-case nil
	  ;; will cause an error in empty buffers
	  (forward-char 1)
	(error))
      (when (re-search-forward wdoc-name-regexp nil t)
	(setq found (match-beginning 0)
	      match (match-data)))
      (while (and found (not (wdoc-name-p 'shortcut)))
	(forward-char 1)
	(if (re-search-forward wdoc-name-regexp nil t)
	    (setq found (match-beginning 0)
		  match (match-data))
	  (setq found nil
		match nil))))
    (set-match-data match)
    (when found
      (goto-char found))))

(defun wdoc-previous-reference ()
  "Jump to previous wdoc name.
See `wdoc-name-p'."
  (interactive)
  (let ((case-fold-search nil)
	found)
    (save-excursion
      (save-match-data
	(setq found (re-search-backward wdoc-name-regexp nil t))
	(while (and found (not (wdoc-name-p 'shortcut)))
	  (forward-char -1)
	  (setq found (re-search-backward wdoc-name-regexp nil t)))))
    (when found
      (goto-char found))))

;; Backlink and other searches

(defun wdoc-backlink ()
  "Return all backlinks to the current page using `grep'."
  (interactive)
  (when (not grep-command)
    (grep-compute-defaults))
  (grep (concat grep-command
		(wdoc-page-name)
		" *"))
  (set-buffer "*grep*"))

(defun wdoc-backup ()
  "Run `diff-backup' on the current file."
  (interactive)
  (diff-backup buffer-file-name))

;; Highlighting hyperlinks

(defun wdoc-highlight-buffer ()
  "Highlight the buffer.
Delete all existing wdoc highlighting using `wdoc-delete-extents' and
call all functions in `wdoc-highlight-buffer-hook'."
  (interactive)
  (wdoc-delete-extents)
  (run-hooks 'wdoc-highlight-buffer-hook))

(defun wdoc-highlight-wdoc-names ()
  "Highlight all WdocNames in the buffer.
This uses `wdoc-highlight-match' to do the job.
The list of existing names is recomputed using `wdoc-existing-names'."
  (interactive)
  (wdoc-delete-extents)
  (save-excursion
    (goto-char (point-min))
    (when (wdoc-name-p)
      (wdoc-highlight-match))
    (while (wdoc-next-reference)
      (wdoc-highlight-match))))

(defun wdoc-highlight-match ()
  "Highlight the latest match as a WdocName.
`wdoc-name-p' is not called again to verify the latest match.
Existing WdocNames are highlighted using face `info-xref'."
  (save-match-data
    (let ((with-glyph (not (funcall wdoc-highlight-name-exists
				    (match-string 0)))))
      (wdoc-make-extent (match-beginning 0)
			(match-end 0)
			wdoc-local-map
			with-glyph))))

(defun wdoc-highlight-word-wrapper (&optional start end len)
  "Highlight the current word if it is a WdocName.
This function can be put on `after-change-functions'.
It calls `wdoc-highlight-word' to do the job."
  (when start
    (wdoc-highlight-word start))
  (when (= 0 len); for insertions
    (wdoc-highlight-word end)))

(defun wdoc-highlight-word (pos)
  "Highlight the current word if it is a WdocName.
This uses `wdoc-highlight-match' to do the job.  POS specifies a buffer
position."
  (save-excursion
    (goto-char pos)
    (save-match-data
      (cond ((wdoc-name-p); found a wdoc name
	     (wdoc-delete-extents (match-beginning 0) (match-end 0))
	     (wdoc-highlight-match))
	    ;; The following code makes sure that when a WdocName is
	    ;; edited such that is no longer is a wdoc name, the
	    ;; extent/overlay is removed.
	    ((thing-at-point-looking-at wdoc-name-no-more)
	     (wdoc-delete-extents (match-beginning 0) (match-end 0)))))))

;; Parsing all files into a directed graph

(defun wdoc-parse-files ()
  "Return all pages and the links they contain in an alist.
Each element in the alist has the form
\(NAME LINK1 LINK2 ...)
See `wdoc-parse-file'.  The list of existing names is recomputed using
`wdoc-existing-file-names'."
  (mapcar (function wdoc-parse-file) (wdoc-existing-file-names)))

(defun wdoc-parse-file (file)
  "Build a list of links for FILE.
Returns a list of the form
\(NAME LINK1 LINK2 ...)
See `wdoc-parse-files'."
  (message "Parsing %s" file)
  (let ((page (list (file-name-nondirectory file))))
    (with-temp-buffer
      ;; fake an existing buffer-file-name in the temp buffer
      (let ((buffer-file-name file))
	(insert-file-contents file)
	(goto-char (point-min))
	(while (wdoc-next-reference)
	  (let ((this (match-string 0)))
	    (when (and (wdoc-name-exists-p this)
		       (not (member this page)))
	      (setq page (cons this page)))))))
    (reverse page)))

;; Filtering the directed graph

(defun wdoc-filter (structure)
  "Filter STRUCTURE according to `wdoc-include-function'."
  (if (eq wdoc-include-function t)
      structure
    (wdoc-filter-links
     (wdoc-filter-pages
      (copy-alist structure)))))

(defun wdoc-filter-pages (structure)
  "Filter pages structure according to `wdoc-include-function'."
  (let ((pages structure)
	page)
    (while pages
      (setq page (car pages)
	    pages (cdr pages))
      (if (funcall wdoc-include-function
		   (car page) structure)
	  (message "Keeping %s" (car page))
	(message "Filtering %s" (car page))
	(setq structure (delete page structure))
	;; restart!
	(setq pages structure)))
    structure))

(defun wdoc-filter-links (structure)
  "Filter links to nonexisting pages from structure."
  (let ((pages structure)
	page)
    (while pages
      (setq page (car pages)
	    pages (cdr pages))
      (setcdr page (delq nil (mapcar (lambda (link)
				       (if (assoc link structure)
					   link
					 nil))
				     (cdr page)))))
    structure))

;; Example filtering functions

(defun wdoc-significant-fan-out (name structure)
  "Return non-nil when `wdoc-fan-out' is significant.
This is determined by `wdoc-significant-fan-out'."
  (> (wdoc-fan-out name structure) wdoc-significant-fan-out))

(defun wdoc-fan-out (name structure)
  "Return number of links pointing away from NAME.
This is calculated from STRUCTURE as returned by `wdoc-parse-files'."
  (length (cdr (assoc name structure))))

;; Example applications of parsing and filtering

(defun wdoc-list-by-fan-out ()
  "List the wdoc site structure by fan-out."
  (interactive)
  (let ((graph (mapcar (lambda (page)
			 (cons (car page) (length (cdr page))))
		       (wdoc-parse-files))))
    (message "Preparing...")
    (setq graph (sort graph
		      (lambda (p1 p2)
			(< (cdr p1) (cdr p2)))))
    (let ((buf (get-buffer-create "*wdoc*")))
      (set-buffer buf)
      (erase-buffer)
      (pp graph buf)
      (emacs-lisp-mode)
      (wdoc-mode 1)
      (switch-to-buffer buf)
      (message "Preparing...done"))))


;; Emacs/XEmacs compatibility layer

(defun wdoc-make-extent (from to map with-glyph)
  "Make an extent for the range [FROM, TO) in the current buffer.
MAP is the local keymap to use, if any.
WITH-GLYPH non-nil will add a question-mark after the extent.
XEmacs uses `make-extent', Emacs uses `make-overlay'."
  ;; I don't use (fboundp 'make-extent) because of (require 'lucid)
  (if (featurep 'xemacs)
      ;; Extents for XEmacs
      (let ((extent (make-extent from to)))
	(set-extent-property extent 'face 'info-xref)
	(set-extent-property extent 'mouse-face 'highlight)
	(when map
	  (set-extent-property extent 'keymap map))
	(set-extent-property extent 'evaporate t)
	(set-extent-property extent 'wdocname t)
	(when with-glyph
	  (set-extent-property extent 'end-glyph (make-glyph '("?"))))
	extent)
    ;; Overlays for Emacs
    (let ((overlay (make-overlay from to)))
      (overlay-put overlay 'face 'info-xref)
      (overlay-put overlay 'mouse-face 'highlight)
      (when map
	(overlay-put overlay 'local-map map))
      (overlay-put overlay 'evaporate t)
      (overlay-put overlay 'wdocname t)
      (when with-glyph
	(overlay-put overlay 'after-string "?"))
      overlay)))

(defun wdoc-delete-extents (&optional start end)
  "Delete all extents/overlays created by `wdoc-make-extent'.
If optional arguments START and END are given, only the overlays in that
region will be deleted.  XEmacs uses extents, Emacs uses overlays."
  (if (featurep 'xemacs)
      (let ((extents (extent-list nil start end))
	    extent)
	(while extents
	  (setq extent (car extents)
		extents (cdr extents))
	  (when (extent-property extent 'wdocname)
	    (delete-extent extent))))
    (let ((overlays (overlays-in (or start (point-min))
				 (or end (point-max))))
	  overlay)
      (while overlays
	(setq overlay (car overlays)
	      overlays (cdr overlays))
	(when (overlay-get overlay 'wdocname)
	  (delete-overlay overlay))))))

(unless (fboundp 'time-less-p)
  (defun time-less-p (t1 t2)
    "Say whether time T1 is less than time T2."
    (or (< (car t1) (car t2))
	(and (= (car t1) (car t2))
	     (< (nth 1 t1) (nth 1 t2))))))

(provide 'wdoc)
