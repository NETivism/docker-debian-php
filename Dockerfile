FROM netivism/docker-debian-base:buster
MAINTAINER Jimmy Huang <jimmy@netivism.com.tw>

ENV \
  COMPOSER_HOME=/root/.composer \
  PATH=/root/.composer/vendor/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#mariadb
WORKDIR /etc/apt/sources.list.d
RUN \
    apt-get update && \
    apt-get install -y apt-transport-https wget gnupg && \
    echo "deb https://packages.sury.org/php/ buster main" > phpsury.list && \
    echo "deb-src https://packages.sury.org/php/ buster main" >> phpsury.list && \
    wget https://packages.sury.org/php/apt.gpg  && apt-key add apt.gpg && rm -f apt.gpg && \
    apt-get update && \
    apt-get install -y wget mariadb-server mariadb-backup gcc make autoconf libc-dev pkg-config google-perftools qpdf


WORKDIR /
RUN \
  apt-get install -y \
    rsyslog \
    php7.3 \
    php7.3-curl \
    php7.3-imap \
    php7.3-gd \
    php7.3-mysql \
    php7.3-mbstring \
    php7.3-xml \
    php7.3-memcached \
    php7.3-cli \
    php7.3-fpm \
    php7.3-zip \
    php7.3-bz2 \
    php7.3-ssh2 \
    php7.3-yaml \
    curl \
    vim \
    git-core

RUN \
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
  composer global require drush/drush:8.3.0 && \
  cd /root/.composer && \
  find . | grep .git | xargs rm -rf && \
  composer clearcache

RUN apt-get install -y supervisor procps

# wkhtmltopdf
WORKDIR /tmp
RUN \
  apt-get install -y fonts-droid-fallback fontconfig ca-certificates fontconfig libc6 libfreetype6 libjpeg62-turbo libpng16-16 libssl1.1 libstdc++6 libx11-6 libxcb1 libxext6 libxrender1 xfonts-75dpi xfonts-base zlib1g && \
  wget -nv https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.buster_amd64.deb -O wkhtmltox.deb && \
  dpkg -i wkhtmltox.deb && \
  rm -f wkhtmltox.deb

# php mcrypt
RUN \
  apt-get install -y php-pear gcc make autoconf libc-dev pkg-config php7.3-dev libmcrypt-dev && \
  printf "\n" | pecl install --nodeps mcrypt-snapshot && \
  bash -c "echo extension=/usr/lib/php/20180731/mcrypt.so > /etc/php/7.3/mods-available/mcrypt.ini" && \
  bash -c "phpenmod mcrypt"

RUN \
  apt-get remove -y php7.3-dev gcc make autoconf libc-dev pkg-config php-pear && \
  apt-get autoremove -y && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

### PHP FPM Config
# remove default enabled site
RUN \
  mkdir -p /var/www/html/log/supervisor && \
  git clone https://github.com/NETivism/docker-sh.git /home/docker && \
  cp -f /home/docker/php/default73.ini /etc/php/7.3/docker_setup.ini && \
  ln -s /etc/php/7.3/docker_setup.ini /etc/php/7.3/fpm/conf.d/ && \
  cp -f /home/docker/php/default73_cli.ini /etc/php/7.3/cli/conf.d/ && \
  cp -f /home/docker/php/default_opcache_blacklist /etc/php/7.3/opcache_blacklist && \
  sed -i 's/^listen = .*/listen = 80/g' /etc/php/7.3/fpm/pool.d/www.conf && \
  sed -i 's/^pm = .*/pm = ondemand/g' /etc/php/7.3/fpm/pool.d/www.conf && \
  sed -i 's/;daemonize = .*/daemonize = no/g' /etc/php/7.3/fpm/php-fpm.conf && \
  sed -i 's/^pm\.max_children = .*/pm.max_children = 8/g' /etc/php/7.3/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.process_idle_timeout = .*/pm.process_idle_timeout = 15s/g' /etc/php/7.3/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.max_requests = .*/pm.max_requests = 50/g' /etc/php/7.3/fpm/pool.d/www.conf && \
  sed -i 's/^;request_terminate_timeout = .*/request_terminate_timeout = 7200/g' /etc/php/7.3/fpm/pool.d/www.conf


COPY container/mysql/mysql-init.sh /usr/local/bin/mysql-init.sh
COPY container/rsyslogd/rsyslog.conf /etc/rsyslog.conf
COPY container/supervisord/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN \
  mkdir -p /run/php && chmod 777 /run/php

RUN \
  echo "source /usr/share/vim/vim81/defaults.vim" > /etc/vim/vimrc.local && \
  echo "let skip_defaults_vim = 1" >> /etc/vim/vimrc.local && \
  echo "if has('mouse')" >> /etc/vim/vimrc.local && \
  echo "  set mouse=" >> /etc/vim/vimrc.local && \
  echo "endif" >> /etc/vim/vimrc.local

### END
WORKDIR /var/www/html
ENV TERM=xterm
CMD ["/usr/bin/supervisord"]

