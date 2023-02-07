FROM netivism/docker-debian-base:bullseye
MAINTAINER Jimmy Huang <jimmy@netivism.com.tw>

ENV \
  COMPOSER_HOME=/root/.composer \
  PATH=/root/.composer/vendor/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#mariadb
WORKDIR /etc/apt/sources.list.d
RUN \
    apt-get update && \
    apt-get install -y apt-transport-https wget gnupg && \
    echo "deb https://packages.sury.org/php/ bullseye main" > phpsury.list && \
    echo "deb-src https://packages.sury.org/php/ bullseye main" >> phpsury.list && \
    wget https://packages.sury.org/php/apt.gpg  && apt-key add apt.gpg && rm -f apt.gpg && \
    apt-get update && \
    apt-get install -y wget mariadb-server mariadb-backup gcc make autoconf libc-dev pkg-config google-perftools qpdf

RUN apt-get install -y supervisor procps

# wkhtmltopdf
WORKDIR /tmp
RUN \
  apt-get install -y fonts-droid-fallback fontconfig ca-certificates fontconfig libc6 libfreetype6 libjpeg62-turbo libpng16-16 libssl1.1 libstdc++6 libx11-6 libxcb1 libxext6 libxrender1 xfonts-75dpi xfonts-base zlib1g && \
  wget -nv https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.buster_amd64.deb -O wkhtmltox.deb && \
  dpkg -i wkhtmltox.deb && \
  rm -f wkhtmltox.deb


WORKDIR /
RUN \
  apt-get update && \
  apt-get install -y \
    rsyslog \
    php8.1 \
    php8.1-curl \
    php8.1-imap \
    php8.1-gd \
    php8.1-mysql \
    php8.1-mbstring \
    php8.1-xml \
    php8.1-memcached \
    php8.1-cli \
    php8.1-fpm \
    php8.1-zip \
    php8.1-bz2 \
    php8.1-ssh2 \
    php8.1-yaml \
    curl \
    vim \
    git-core

RUN \
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
  composer global require drush/drush:8.3.3 && \
  cd /root/.composer && \
  find . | grep .git | xargs rm -rf && \
  composer clearcache

### PHP FPM Config
# remove default enabled site
RUN \
  mkdir -p /var/www/html/log/supervisor && \
  git clone https://github.com/NETivism/docker-sh.git /home/docker && \
  cp -f /home/docker/php/default81.ini /etc/php/8.1/docker_setup.ini && \
  ln -s /etc/php/8.1/docker_setup.ini /etc/php/8.1/fpm/conf.d/ && \
  cp -f /home/docker/php/default81_cli.ini /etc/php/8.1/cli/conf.d/ && \
  cp -f /home/docker/php/default_opcache_blacklist /etc/php/8.1/opcache_blacklist && \
  sed -i 's/^listen = .*/listen = 80/g' /etc/php/8.1/fpm/pool.d/www.conf && \
  sed -i 's/^pm = .*/pm = ondemand/g' /etc/php/8.1/fpm/pool.d/www.conf && \
  sed -i 's/;daemonize = .*/daemonize = no/g' /etc/php/8.1/fpm/php-fpm.conf && \
  sed -i 's/^pm\.max_children = .*/pm.max_children = 8/g' /etc/php/8.1/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.process_idle_timeout = .*/pm.process_idle_timeout = 15s/g' /etc/php/8.1/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.max_requests = .*/pm.max_requests = 50/g' /etc/php/8.1/fpm/pool.d/www.conf && \
  sed -i 's/^;request_terminate_timeout = .*/request_terminate_timeout = 7200/g' /etc/php/8.1/fpm/pool.d/www.conf


COPY container/mysql/mysql-init.sh /usr/local/bin/mysql-init.sh
COPY container/rsyslogd/rsyslog.conf /etc/rsyslog.conf
COPY container/supervisord/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN \
  mkdir -p /run/php && chmod 777 /run/php

RUN \
  echo "source /usr/share/vim/vim82/defaults.vim" > /etc/vim/vimrc.local && \
  echo "let skip_defaults_vim = 1" >> /etc/vim/vimrc.local && \
  echo "if has('mouse')" >> /etc/vim/vimrc.local && \
  echo "  set mouse=" >> /etc/vim/vimrc.local && \
  echo "endif" >> /etc/vim/vimrc.local


### END
WORKDIR /var/www/html
ENV TERM=xterm
CMD ["/usr/bin/supervisord"]

