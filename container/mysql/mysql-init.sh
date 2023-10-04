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

  for i in {30..0}; do
    if mysql -uroot -p$INIT_PASSWD --database=mysql <<<'SELECT 1' &> /dev/null; then
      break
    fi
    sleep 1
  done
  mariadb_note "Temporary process started."
  mariadb_backup_system_table

  mariadb_note "Upgrading system tables ..."
  mysql_upgrade -uroot -p$INIT_PASSWD --upgrade-system-tables
  mariadb_note "Upgrading completed."
  kill "$MARIADB_PID"
  wait "$MARIADB_PID"
}

mariadb_backup_system_table() {
  mariadb_note "[Perform Mariadb System Table Backup]"
  local oldfullversion="unknown_version"
  local backup_db="system_mysql_backup_unknown_version.sql.gz"

  if [ -r /var/lib/mysql/mysql_upgrade_info ]; then
    read -r -d '' oldfullversion < /var/lib/mysql/mysql_upgrade_info || true
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
  local maria_version="$(mariadb --version | awk '{ print $5 }')"
  maria_version="${maria_version%%[-+~]*}"
  echo -n "${maria_version}-MariaDB"
}

mariadb_upgrade_is_needed() {
  # 0 is true, 1 is false
  if [ ! -d "/var/lib/mysql/mysql" ]; then
    return 1
  fi

  MARIADB_VERSION=$(mariadb_version)
  if [ ! -f /var/lib/mysql/mysql_upgrade_info ]; then
    mariadb_note "MariaDB upgrade information missing, trying to upgrade system table to ${MARIADB_VERSION} anyway."
    return 0
  fi

  IFS='.-' read -ra new_version <<< $MARIADB_VERSION
  IFS='.-' read -ra old_version < /var/lib/mysql/mysql_upgrade_info || true
  if [[ ${#new_version[@]} -lt 2 ]] || [[ ${#old_version[@]} -lt 2 ]] \
    || [[ ${old_version[0]} -lt ${new_version[0]} ]] \
    || [[ ${old_version[0]} -eq ${new_version[0]} && ${old_version[1]} -lt ${new_version[1]} ]]; then
    mariadb_note "MariaDB upgrade may required from ${old_version[0]}.${old_version[1]} to ${new_version[0]}.${new_version[1]}"
    return 0
  fi

  mariadb_note "MariaDB upgrade not required. Old version: ${old_version[0]}.${old_version[1]}, New version: ${new_version[0]}.${new_version[1]}"
  return 1
}

# Config log and run
if [ ! -d "/var/run/mysqld" ]; then
  mkdir -p /var/run/mysqld
  chown mysql:mysql /var/run/mysqld
  echo "" > /var/www/html/log/mysql.log
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
  mariadb_do_upgrade
else
  mariadb_note 'MariaDB ready for start up'
fi

mariadb_note 'Perform MariadB process start using libtcmalloc_minimal ...'
exec env LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4 "mysqld" --basedir=/usr --datadir=/var/lib/mysql --plugin-dir=/usr/lib/mysql/plugin --user=mysql --log-error=/var/www/html/log/mysql.log
