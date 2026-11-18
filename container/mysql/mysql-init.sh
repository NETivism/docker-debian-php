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

# MariaDB 11.x uses mariadb-* names, mysql* names are only compat symlinks
pick_bin() {
  local b
  for b in "$@"; do
    if command -v "$b" > /dev/null 2>&1; then
      echo "$b"
      return
    fi
  done
  echo "$1"
}
MARIADBD=$(pick_bin mariadbd mysqld)
MARIADB=$(pick_bin mariadb mysql)
MARIADB_DUMP=$(pick_bin mariadb-dump mysqldump)
MARIADB_UPGRADE=$(pick_bin mariadb-upgrade mysql_upgrade)
MARIADB_INSTALL_DB=$(pick_bin mariadb-install-db mysql_install_db)

MYSQL_LOG=/var/www/html/log/mysql.log
# detail of upgrade / table check, kept in host mounted log dir
CHECK_REPORT=/var/www/html/log/mysql-upgrade-check.log
# exists while upgrade / table check is running, so an interrupted run will be retried on next start.
# touch this file and restart mysql to force a full table check again.
CHECK_PENDING=/var/lib/mysql/.mariadb_upgrade_check_pending

MYSQL_AUTH=( --protocol=socket -uroot )
if [ -n "$INIT_PASSWD" ]; then
  MYSQL_AUTH+=( "--password=$INIT_PASSWD" )
fi

mariadb_sql() {
  "$MARIADB" "${MYSQL_AUTH[@]}" -N -B "$@" < /dev/null
}

mariadb_report() {
  printf '%s %s\n' "$(date --rfc-3339=seconds)" "$*" >> "$CHECK_REPORT"
}

mariadb_quote_ident() {
  local bt='`'
  printf '%s%s%s' "$bt" "${1//$bt/$bt$bt}" "$bt"
}

mariadb_start_temp_server() {
  mariadb_note "Waiting temporary process start up ..."
  # slow shutdown after upgrade, purge undo logs and let new innodb settings take effect on next start
  "$MARIADBD" \
    --skip-networking \
    --skip-grant-tables \
    --skip-slave-start \
    --wsrep_on=OFF \
    --expire-logs-days=0 \
    --loose-innodb_buffer_pool_load_at_startup=0 \
    --loose-innodb_buffer_pool_dump_at_shutdown=0 \
    --innodb_fast_shutdown=0 \
    --basedir=/usr \
    --datadir=/var/lib/mysql \
    --plugin-dir=/usr/lib/mysql/plugin \
    --user=mysql \
    --log-error=$MYSQL_LOG &
  MARIADB_PID=$!
  # stop temporary process and restore datadir owner for previous image when mariadb_error exit
  trap 'set +e; kill "$MARIADB_PID" 2> /dev/null; wait "$MARIADB_PID"; chown -R "$DATADIR_OWNER" /var/lib/mysql' EXIT

  for i in {300..0}; do
    if mariadb_sql --database=mysql -e 'SELECT 1' &> /dev/null; then
      break
    fi
    if ! kill -0 "$MARIADB_PID" 2> /dev/null; then
      mariadb_error "Temporary process exited, check $MYSQL_LOG. If it shows 'Upgrade after a crash is not supported', start previous image and shutdown cleanly before upgrade."
    fi
    sleep 1
  done
  if [ "$i" = 0 ]; then
    mariadb_error 'Temporary process failed to start.'
  fi
  mariadb_note "Temporary process started."
}

mariadb_stop_temp_server() {
  trap - EXIT
  kill "$MARIADB_PID"
  wait "$MARIADB_PID"
}

mariadb_do_upgrade() {
  mariadb_note "[Perform Mariadb System Table Upgrade]"
  touch "$CHECK_PENDING"
  chown mysql:mysql "$CHECK_PENDING"
  mariadb_report "========== Upgrade / table check start, server version $(mariadb_version) =========="

  # never touch redo log, mariadb upgrade it by itself after clean shutdown
  # restore it if renamed by previous version of this script, MariaDB >= 10.8 refuses to start without it
  if [ ! -f /var/lib/mysql/ib_logfile0 ] && [ -f /var/lib/mysql/ib_logfile0.old ]; then
    mariadb_note "Restore innodb redo log"
    mv /var/lib/mysql/ib_logfile0.old /var/lib/mysql/ib_logfile0
  fi

  mariadb_start_temp_server
  mariadb_backup_system_table

  # full upgrade (not only --upgrade-system-tables): also run check-upgrade / auto-repair on every user table.
  # --force: still run when upgrade info already shows current version (retry of interrupted run)
  mariadb_note "Upgrading system tables and checking user tables ..."
  if "$MARIADB_UPGRADE" "${MYSQL_AUTH[@]}" --force 2>&1 | tee -a "$CHECK_REPORT"; then
    mariadb_note "Upgrading completed."
    rm -f /var/lib/mysql/ib_logfile0.old /var/lib/mysql/ib_logfile1.old
  else
    mariadb_warn "mariadb-upgrade reported errors (see $CHECK_REPORT), continue to check and fix tables."
  fi

  if mariadb_check_all_tables; then
    rm -f "$CHECK_PENDING"
  else
    mariadb_warn "Table check did not complete, it will run again on next start."
  fi
  mariadb_report "========== Upgrade / table check end =========="
  mariadb_stop_temp_server
}

# CHECK TABLE, print result rows (Table, Op, Msg_type, Msg_text), return 0 when table is fine
mariadb_check_table() {
  local out rc=0
  out=$(mariadb_sql -e "CHECK TABLE $1" 2>&1) || rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || return 1
  awk -F'\t' '
    tolower($3) == "error" { bad = 1 }
    tolower($3) == "status" && $4 != "OK" && $4 != "Table is already up to date" { bad = 1 }
    END { exit bad }
  ' <<< "$out"
}

# try repair / recreate the table until CHECK TABLE passes
mariadb_fix_table() {
  local q="$1" engine="$2" sql out
  local attempts=()
  case "${engine,,}" in
    myisam|aria|archive|csv)
      attempts+=( "REPAIR TABLE $q" "REPAIR TABLE $q EXTENDED" )
      ;;
  esac
  # recreate table, InnoDB doesn't support REPAIR TABLE.
  # innodb_strict_mode=OFF: old COMPACT/REDUNDANT tables may hit "Row size too large" when rebuild on new version
  attempts+=( "ALTER TABLE $q FORCE" "ALTER TABLE $q FORCE, ALGORITHM=COPY" )

  for sql in "${attempts[@]}"; do
    mariadb_note "  -> $sql"
    mariadb_report "FIX     $sql"
    out=$(mariadb_sql -e "SET SESSION sql_log_bin=0; SET SESSION innodb_strict_mode=OFF; $sql" 2>&1) || true
    if [ -n "$out" ]; then
      mariadb_report "$out"
    fi
    if out=$(mariadb_check_table "$q"); then
      mariadb_note "  -> fixed"
      mariadb_report "FIXED   $q"
      return 0
    fi
    mariadb_report "$out"
  done
  return 1
}

# equivalent of "mysqlcheck --all-databases --check", but handle each failed table by its engine
mariadb_check_all_tables() {
  mariadb_note "[Perform MariaDB Table Check]"
  local tables schema table engine q out
  local total=0 fixed=0 failed=0
  local failed_list=()

  if ! tables=$(mariadb_sql -r -e "
    SELECT TABLE_SCHEMA, TABLE_NAME, IFNULL(ENGINE, '')
    FROM information_schema.TABLES
    WHERE TABLE_TYPE IN ('BASE TABLE', 'SYSTEM VERSIONED')
      AND TABLE_SCHEMA NOT IN ('information_schema', 'performance_schema', 'sys')
      AND NOT (TABLE_SCHEMA = 'mysql' AND TABLE_NAME IN ('general_log', 'slow_log'))
    ORDER BY TABLE_SCHEMA, TABLE_NAME" 2>&1); then
    mariadb_warn "Unable to list tables: $tables"
    return 1
  fi

  while IFS=$'\t' read -r schema table engine; do
    [ -n "$schema" ] || continue
    if ! kill -0 "$MARIADB_PID" 2> /dev/null; then
      mariadb_error "Temporary process died while checking $schema.$table, see $MYSQL_LOG"
    fi
    total=$((total + 1))
    q="$(mariadb_quote_ident "$schema").$(mariadb_quote_ident "$table")"
    if out=$(mariadb_check_table "$q"); then
      mariadb_report "OK      $schema.$table"
      continue
    fi
    mariadb_warn "Table $schema.$table (${engine:-unknown engine}) check failed, try to fix it."
    mariadb_report "FAILED  $schema.$table (${engine:-unknown engine})"
    mariadb_report "$out"
    if mariadb_fix_table "$q" "$engine"; then
      fixed=$((fixed + 1))
    else
      failed=$((failed + 1))
      failed_list+=( "$schema.$table" )
      mariadb_report "BROKEN  $schema.$table"
    fi
  done <<< "$tables"

  mariadb_note "Table check finished. total: $total, fixed: $fixed, still broken: $failed (detail: $CHECK_REPORT)"
  mariadb_report "SUMMARY total: $total, fixed: $fixed, still broken: $failed"
  if [ "$failed" -gt 0 ]; then
    mariadb_warn "These tables still have problems, please fix manually (dump/reload, or restore from backup): ${failed_list[*]}"
  fi
  return 0
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
  if ! "$MARIADB_DUMP" "${MYSQL_AUTH[@]}" --skip-lock-tables --replace --databases mysql | gzip -9 > /var/lib/mysql/${backup_db}; then
    mariadb_error "Unable backup system database for upgrade from $oldfullversion."
  fi
  mariadb_note "Backup completed."
}

mariadb_version() {
  local maria_version
  maria_version="$("$MARIADBD" --version 2> /dev/null | awk '{ print $3 }')"
  maria_version="${maria_version%%[-+~]*}"
  echo -n "${maria_version}-MariaDB"
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

mariadb_check_is_pending() {
  if [ -f "$CHECK_PENDING" ]; then
    mariadb_note "Found $CHECK_PENDING, previous upgrade / table check not finished (or requested), run it again."
    return 0
  fi
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
# always fix owner, mysql uid may change between images
mkdir -p /var/run/mysqld
touch $MYSQL_LOG
chown mysql:mysql /var/run/mysqld $MYSQL_LOG

if [ ! -d "/var/lib/mysql/mysql" ]; then
  mkdir -p /var/lib/mysql

  mariadb_note 'Initializing database..'
  "$MARIADB_INSTALL_DB" --datadir="/var/lib/mysql"
  mariadb_note 'Database initialized'

  "$MARIADBD" --skip-networking &
  pid="$!"

  mariadb_note 'MariaDB init process in progress...'
  for i in {30..0}; do
    if "$MARIADB" --protocol=socket -uroot -e 'SELECT 1' < /dev/null &> /dev/null; then
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
elif mariadb_upgrade_is_needed || mariadb_check_is_pending; then
  DATADIR_OWNER=$(stat -c '%u:%g' /var/lib/mysql/mysql)
  mariadb_fix_permission
  mariadb_do_upgrade
  mariadb_fix_permission
else
  mariadb_note 'MariaDB ready for start up'
fi

MALLOC_LIB=/usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2
if [ -f "$MALLOC_LIB" ]; then
  mariadb_note 'Perform MariadB process start using libjemalloc ...'
  export LD_PRELOAD="$MALLOC_LIB"
else
  mariadb_warn "$MALLOC_LIB not found, start MariaDB with default glibc malloc"
fi
exec "$MARIADBD" --basedir=/usr --datadir=/var/lib/mysql --plugin-dir=/usr/lib/mysql/plugin --user=mysql --log-error=$MYSQL_LOG
