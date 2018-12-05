#!/bin/bash
set -eo pipefail

# Get config

if [ ! -d "/var/lib/mysql/mysql" ]; then
  mkdir -p "/var/lib/mysql"

  echo 'Initializing database'
  mysql_install_db --datadir="/var/lib/mysql"
  echo 'Database initialized'

  "mysqld" --skip-networking &
  pid="$!"

  mysql=( mysql --protocol=socket -uroot )

  for i in {30..0}; do
    if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
      break
    fi
    echo 'MySQL init process in progress...'
    sleep 1
  done
  if [ "$i" = 0 ]; then
    echo >&2 'MySQL init process failed.'
    exit 1
  fi

  if ! kill -s TERM "$pid" || ! wait "$pid"; then
    echo >&2 'MySQL init process failed.'
    exit 1
  fi

  echo
  echo 'MySQL init process done. Ready for start up.'
  echo
fi

exec "mysqld" --basedir=/usr --datadir=/var/lib/mysql --plugin-dir=/usr/lib/mysql/plugin --user=mysql --log-error=/var/www/html/log/mysql.log
