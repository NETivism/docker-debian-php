#!/bin/bash
set -eo pipefail

# logging functions
mariadb_log() {
  local type="$1"; shift
  printf '%s [%s] [Entrypoint]: %s\n' "$(date --rfc-3339=seconds)" "$type" "$*"
}
mariadb_note() {
  mariadb_log Note "$@"
}
mariadb_warn() {
  mariadb_log Warn "$@" >&2
}
mariadb_error() {
  mariadb_log ERROR "$@" >&2
  exit 1
}

mariadb_do_upgrade() {
  mariadb_note "[Perform Mariadb System Table Upgrade]"
  if mariadb_redo_log_required; then
    mariadb_restore_redo_log
  else
    mariadb_note "Delete exists innodb redo log due to block of upgrade"
    if [ -f /var/lib/mysql/ib_logfile0 ]; then
      mv /var/lib/mysql/ib_logfile0 /var/lib/mysql/ib_logfile0.old
    fi
    if [ -f /var/lib/mysql/ib_logfile1 ]; then
      mv /var/lib/mysql/ib_logfile1 /var/lib/mysql/ib_logfile1.old
    fi
  fi
  mariadb_note "Waiting temporary process start up ..."
  mysqld \
    --skip-networking \
    --wsrep_on=OFF \
    --expire-logs-days=0 \
    --loose-innodb_buffer_pool_load_at_startup=0 \
    --basedir=/usr \
    --datadir=/var/lib/mysql \
    --plugin-dir=/usr/lib/mysql/plugin \
    --user=mysql \
    --log-error=/var/www/html/log/mysql.log &
  MARIADB_PID=$!
  # stop temporary process when script exit by error, or it will hold the lock of datadir
  trap 'kill "$MARIADB_PID" 2> /dev/null; wait "$MARIADB_PID" 2> /dev/null' EXIT

  for i in {30..0}; do
    # make sure SELECT 1 is answered by our temporary process, not other process using the same socket
    if ! kill -0 "$MARIADB_PID" 2> /dev/null; then
      mariadb_error 'Temporary process exited unexpectedly.'
    fi
    if mysql -uroot -p$INIT_PASSWD --database=mysql <<<'SELECT 1' &> /dev/null; then
      break
    fi
    sleep 1
  done
  if [ "$i" = 0 ]; then
    mariadb_error 'Temporary process failed to start.'
  fi
  mariadb_note "Temporary process started."
  mariadb_backup_system_table

  mariadb_note "Upgrading system tables ..."
  mariadb-upgrade -uroot -p$INIT_PASSWD --upgrade-system-tables
  mariadb_note "Upgrading completed."
  if [ -f /var/lib/mysql/ib_logfile0.old ] && [ -f /var/lib/mysql/ib_logfile0 ]; then
    rm /var/lib/mysql/ib_logfile0.old
  fi
  if [ -f /var/lib/mysql/ib_logfile1.old ]; then
    rm /var/lib/mysql/ib_logfile1.old
  fi
  trap - EXIT
  kill "$MARIADB_PID"
  wait "$MARIADB_PID"
}

mariadb_backup_system_table() {
  mariadb_note "[Perform Mariadb System Table Backup]"
  local oldfullversion="unknown_version"
  local backup_db="system_mysql_backup_unknown_version.sql.gz"

  if [ -r $UPGRADE_INFO ]; then
    read -r -d '' oldfullversion < $UPGRADE_INFO || true
    if [ -n "$oldfullversion" ]; then
      backup_db="system_mysql_backup_${oldfullversion}.sql.gz"
    fi
  fi

  mariadb_note "Backing up system database to $backup_db ..."
  if ! mysqldump --skip-lock-tables --replace --databases mysql -uroot -p$INIT_PASSWD mysql | gzip -9 > /var/lib/mysql/${backup_db}; then
    mariadb_error "Unable backup system database for upgrade from $oldfullversion."
  fi
  mariadb_note "Backup completed."
}

mariadb_version() {
  local maria_version="$(mysqld --version 2> /dev/null | awk '{ print $3 }')"
  maria_version="${maria_version%%[-+~]*}"
  echo -n "${maria_version}-MariaDB"
}

mariadb_redo_log_required() {
  # MariaDB >= 10.8 refuses to start without redo log
  local new_version
  IFS='.-' read -ra new_version <<< "$(mariadb_version)"
  [[ ${new_version[0]} -gt 10 ]] || [[ ${new_version[0]} -eq 10 && ${new_version[1]} -ge 8 ]]
}

mariadb_restore_redo_log() {
  # redo log may be renamed by previous upgrade, restore it before any start up
  if [ ! -f /var/lib/mysql/ib_logfile0 ] && [ -f /var/lib/mysql/ib_logfile0.old ]; then
    mariadb_note "Restore innodb redo log for MariaDB >= 10.8"
    mv /var/lib/mysql/ib_logfile0.old /var/lib/mysql/ib_logfile0
  fi
}

mariadb_upgrade_is_needed() {
  # 0 is true, 1 is false
  if [ ! -d "/var/lib/mysql/mysql" ]; then
    return 1
  fi

  MARIADB_VERSION=$(mariadb_version)
  if [ ! -f $UPGRADE_INFO ]; then
    mariadb_note "MariaDB upgrade information missing, trying to upgrade system table to ${MARIADB_VERSION} anyway."
    return 0
  fi

  IFS='.-' read -ra new_version <<< $MARIADB_VERSION
  IFS='.-' read -ra old_version < $UPGRADE_INFO || true
  if [[ ${#new_version[@]} -lt 2 ]] || [[ ${#old_version[@]} -lt 2 ]] \
    || [[ ${old_version[0]} -lt ${new_version[0]} ]] \
    || [[ ${old_version[0]} -eq ${new_version[0]} && ${old_version[1]} -lt ${new_version[1]} ]]; then
    mariadb_note "MariaDB upgrade may required from ${old_version[0]}.${old_version[1]} to ${new_version[0]}.${new_version[1]}"
    return 0
  fi

  mariadb_note "MariaDB upgrade not required. Old version: ${old_version[0]}.${old_version[1]}, New version: ${new_version[0]}.${new_version[1]}"
  return 1
}

# MariaDB 11.x renamed mysql_upgrade_info to mariadb_upgrade_info
UPGRADE_INFO=/var/lib/mysql/mysql_upgrade_info
if [ -f /var/lib/mysql/mariadb_upgrade_info ]; then
  UPGRADE_INFO=/var/lib/mysql/mariadb_upgrade_info
fi

mariadb_fix_permission() {
  # owner should be mysql user of this container, mode follow mariadb default UMASK_DIR=0700 UMASK=0660
  if [ -n "$(find /var/lib/mysql \( ! -user mysql -o ! -group mysql \) -print -quit)" ]; then
    mariadb_note "Fix owner of /var/lib/mysql to mysql:mysql ($(id -u mysql):$(id -g mysql))"
    chown -R mysql:mysql /var/lib/mysql
  fi
  find /var/lib/mysql -type d ! -perm 700 -exec chmod 700 {} +
  find /var/lib/mysql -type f ! -perm 660 -exec chmod 660 {} +
}

# Config log and run
if [ ! -d "/var/run/mysqld" ]; then
  mkdir -p /var/run/mysqld
  chown mysql:mysql /var/run/mysqld
  echo "" > /var/www/html/log/mysql.log
fi
# log dir is mounted from host, owner may be changed outside container
if [ ! -f /var/www/html/log/mysql.log ] || [ "$(stat -c %U /var/www/html/log/mysql.log)" != "mysql" ]; then
  touch /var/www/html/log/mysql.log
  chown mysql:mysql /var/www/html/log/mysql.log
fi

if [ ! -d "/var/lib/mysql/mysql" ]; then
  mkdir -p /var/lib/mysql

  mariadb_note 'Initializing database..'
  mysql_install_db --datadir="/var/lib/mysql"
  mariadb_note 'Database initialized'

  "mysqld" --skip-networking &
  pid="$!"

  mysql=( mysql --protocol=socket -uroot )

  mariadb_note 'MariaDB init process in progress...'
  for i in {30..0}; do
    if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
      break
    fi
    sleep 1
  done
  if [ "$i" = 0 ]; then
    mariadb_error 'MariaDB init process failed.'
  fi

  if ! kill -s TERM "$pid" || ! wait "$pid"; then
    mariadb_error 'MariaDB init process failed.'
  fi

  echo
  mariadb_note 'MariaDB init process done. Ready for start up.'
  echo
elif mariadb_upgrade_is_needed; then
  mariadb_fix_permission
  mariadb_do_upgrade
  mariadb_fix_permission
else
  if mariadb_redo_log_required; then
    mariadb_restore_redo_log
  fi
  mariadb_note 'MariaDB ready for start up'
fi

MALLOC_LIB=/usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2
if [ -f "$MALLOC_LIB" ]; then
  mariadb_note 'Perform MariadB process start using libjemalloc ...'
  export LD_PRELOAD="$MALLOC_LIB"
else
  mariadb_warn "$MALLOC_LIB not found, start MariaDB with default glibc malloc"
fi
exec "mysqld" --basedir=/usr --datadir=/var/lib/mysql --plugin-dir=/usr/lib/mysql/plugin --user=mysql --log-error=/var/www/html/log/mysql.log
