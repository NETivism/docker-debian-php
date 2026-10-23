FROM ghcr.io/netivism/docker-debian-base:trixie
MAINTAINER Jimmy Huang <jimmy@netivism.com.tw>

ENV \
  COMPOSER_HOME=/root/.composer \
  PATH=/root/.composer/vendor/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# basic packages install
RUN \
    apt-get update && \
    apt-get install -y rsyslog apt-transport-https wget gnupg gcc make autoconf libc-dev pkg-config google-perftools qpdf curl vim git-core supervisor procps

# add PHP sury
WORKDIR /etc/apt/sources.list.d
RUN curl -sSL https://packages.sury.org/php/README.txt | bash

#mariadb
RUN \
    apt-get install -y wget mariadb-server mariadb-backup mariadb-client

# wkhtmltopdf
WORKDIR /tmp
RUN \
  apt-get install -y fonts-droid-fallback fontconfig && \
  wget -nv https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb -O wkhtmltox.deb && \
  apt-get update && \
  apt-get install -y ./wkhtmltox.deb && \
  rm -f wkhtmltox.deb

# php
WORKDIR /
RUN \
  apt-get update && \
  apt-get install -y \
    php8.5 \
    php8.5-curl \
    php8.5-gd \
    php8.5-mysql \
    php8.5-mbstring \
    php8.5-xml \
    php8.5-memcached \
    php8.5-cli \
    php8.5-fpm \
    php8.5-zip \
    php8.5-bz2 \
    php8.5-ssh2 \
    php8.5-yaml

RUN \
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
  cd /root/.composer && \
  find . | grep .git | xargs rm -rf && \
  composer clearcache

### PHP FPM Config
# remove default enabled site
RUN \
  mkdir -p /var/www/html/log/supervisor && \
  git clone https://github.com/NETivism/docker-sh.git /home/docker && \
  cp -f /home/docker/php/default85.ini /etc/php/8.5/docker_setup.ini && \
  ln -s /etc/php/8.5/docker_setup.ini /etc/php/8.5/fpm/conf.d/ && \
  cp -f /home/docker/php/default85_cli.ini /etc/php/8.5/cli/conf.d/ && \
  cp -f /home/docker/php/default_opcache_blacklist /etc/php/opcache_blacklist && \
  sed -i 's/^listen = .*/listen = 80/g' /etc/php/8.5/fpm/pool.d/www.conf && \
  sed -i 's/^pm = .*/pm = ondemand/g' /etc/php/8.5/fpm/pool.d/www.conf && \
  sed -i 's/;daemonize = .*/daemonize = no/g' /etc/php/8.5/fpm/php-fpm.conf && \
  sed -i 's/^pm\.max_children = .*/pm.max_children = 8/g' /etc/php/8.5/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.process_idle_timeout = .*/pm.process_idle_timeout = 15s/g' /etc/php/8.5/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.max_requests = .*/pm.max_requests = 50/g' /etc/php/8.5/fpm/pool.d/www.conf && \
  sed -i 's/^;request_terminate_timeout = .*/request_terminate_timeout = 7200/g' /etc/php/8.5/fpm/pool.d/www.conf


COPY container/mysql/mysql-init.sh /usr/local/bin/mysql-init.sh
COPY container/rsyslogd/rsyslog.conf /etc/rsyslog.conf
COPY container/supervisord/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN \
  mkdir -p /run/php && chmod 777 /run/php

RUN \
  echo 'source $VIMRUNTIME/defaults.vim' > /etc/vim/vimrc.local && \
  echo "let skip_defaults_vim = 1" >> /etc/vim/vimrc.local && \
  echo "if has('mouse')" >> /etc/vim/vimrc.local && \
  echo "  set mouse=" >> /etc/vim/vimrc.local && \
  echo "endif" >> /etc/vim/vimrc.local


### END
WORKDIR /var/www/html
ENV TERM=xterm
CMD ["/usr/bin/supervisord"]
