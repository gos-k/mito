(in-package :cl-user)
(defpackage mito.migration.versions
  (:use #:cl
        #:sxql)
  (:import-from #:mito.migration.table
                #:migration-expressions)
  (:import-from #:mito.dao
                #:dao-class
                #:dao-table-class
                #:table-definition)
  (:import-from #:mito.connection
                #:*connection*
                #:check-connected)
  (:import-from #:mito.class
                #:table-name)
  (:import-from #:mito.db
                #:execute-sql
                #:retrieve-by-sql
                #:table-exists-p)
  (:export #:all-migration-expressions
           #:current-migration-version
           #:update-migration-version
           #:generate-migrations
           #:migrate))
(in-package :mito.migration.versions)

(defun schema-migrations-table-definition ()
  (sxql:create-table (:schema_migrations :if-not-exists t)
      ((version :type '(:varchar 255)
                :primary-key t))))

(defun initialize-migrations-table ()
  (check-connected)
  (execute-sql (schema-migrations-table-definition)))

(defun all-dao-classes ()
  (remove-if-not (lambda (class)
                   (typep class 'dao-table-class))
                 (c2mop:class-direct-subclasses (find-class 'dao-class))))

(defun all-migration-expressions ()
  (check-connected)
  (mapcan (lambda (class)
            (if (table-exists-p *connection* (table-name class))
                (migration-expressions class)
                (list (table-definition class))))
          (all-dao-classes)))

(defun current-migration-version ()
  (initialize-migrations-table)
  (getf (first (retrieve-by-sql
                (sxql:select :version
                  (sxql:from :schema_migrations)
                  (sxql:order-by (:desc :version))
                  (sxql:limit 1))))
        :version))

(defun update-migration-version (version)
  (execute-sql
   (sxql:insert-into :schema_migrations
     (sxql:set= :version version))))

(defun generate-version ()
  (multiple-value-bind (sec min hour day mon year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D~2,'0D~2,'0D~2,'0D~2,'0D~2,'0D"
            year mon day hour min sec)))

(defun generate-migrations (directory &key dry-run)
  (let* ((directory (merge-pathnames #P"migrations/" directory))
         (destination (make-pathname :name (generate-version)
                                     :type "sql"
                                     :defaults directory))
         (expressions (all-migration-expressions)))
    (if expressions
        (progn
          (unless dry-run
            (ensure-directories-exist directory)
            (with-open-file (out destination
                                 :direction :output
                                 :if-does-not-exist :create)
              (map nil
                   (lambda (ex)
                     (format out "~&~A;~%" (sxql:yield ex)))
                   expressions)))
          (format t "~&Successfully generated: ~A~%" destination)
          destination)
        (format t "~&Nothing to migrate.~%"))))

(defun migration-file-version (file)
  (let* ((name (pathname-name file))
         (pos (position #\_ name))
         (version
           (if pos
               (subseq name 0 pos)
               name)))
    (when (and (= (length version) 14)
               (every #'digit-char-p version))
      version)))

(defun read-one-sql (stream)
  (let ((sql
          (string-trim '(#\Space #\Tab #\Newline #\LineFeed)
                       (with-output-to-string (s)
                         (loop for char = (read-char stream nil nil)
                               while char
                               until (char= char #\;)
                               do (write-char char s))))))
    (if (= (length sql) 0)
        nil
        sql)))

(defun migrate (directory &key dry-run)
  (let* ((schema.sql (merge-pathnames #P"schema.sql" directory))
         (current-version (current-migration-version))
         (sql-files (sort (uiop:directory-files (merge-pathnames #P"migrations/" directory)
                                                "*.sql")
                          #'string<
                          :key #'pathname-name))
         (sql-files
           (if current-version
               (remove-if-not (lambda (version)
                                (and version
                                     (string< current-version version)))
                              sql-files
                              :key #'migration-file-version)
               sql-files)))
    (if sql-files
        (progn
          (dbi:with-transaction *connection*
            (dolist (file sql-files)
              (format t "~&Applying '~A'...~%" file)
              (with-open-file (in file)
                (loop for sql = (read-one-sql in)
                      while sql
                      do (format t "~&-> ~A;~%" sql)
                         (unless dry-run
                           (execute-sql sql)))))
            (let ((version (migration-file-version (first (last sql-files)))))
              (update-migration-version version)
              (format t "~&Successfully updated to the version ~S.~%" version)))
          (with-open-file (out schema.sql
                               :direction :output
                               :if-exists :supersede)
            (loop for class in (all-dao-classes)
                  do (format out "~2&~A~%" (table-definition class)))
            (let ((sxql:*use-placeholder* nil))
              (format out "~2&~A~%"
                      (sxql:yield (schema-migrations-table-definition)))
              (format out "~&INSERT INTO schema_migrations (version) VALUES ('~A');~%"
                      current-version)))
          (format t "~&Version ~S is up to date.~%" current-version)))))
