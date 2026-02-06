FROM ghcr.io/netivism/docker-debian-base:bullseye
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
RUN \
    echo "deb https://packages.sury.org/php/ bullseye main" > phpsury.list && \
    echo "deb-src https://packages.sury.org/php/ bullseye main" >> phpsury.list && \
    wget https://packages.sury.org/php/apt.gpg  && apt-key add apt.gpg && rm -f apt.gpg && \
    apt-get update

#mariadb
RUN \
    apt-get install -y wget mariadb-server mariadb-backup mariadb-client

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
    php8.3 \
    php8.3-curl \
    php8.3-imap \
    php8.3-gd \
    php8.3-mysql \
    php8.3-mbstring \
    php8.3-xml \
    php8.3-memcached \
    php8.3-cli \
    php8.3-fpm \
    php8.3-zip \
    php8.3-bz2 \
    php8.3-ssh2 \
    php8.3-yaml

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
  cp -f /home/docker/php/default83.ini /etc/php/8.3/docker_setup.ini && \
  ln -s /etc/php/8.3/docker_setup.ini /etc/php/8.3/fpm/conf.d/ && \
  cp -f /home/docker/php/default83_cli.ini /etc/php/8.3/cli/conf.d/ && \
  cp -f /home/docker/php/default_opcache_blacklist /etc/php/8.3/opcache_blacklist && \
  sed -i 's/^listen = .*/listen = 80/g' /etc/php/8.3/fpm/pool.d/www.conf && \
  sed -i 's/^pm = .*/pm = ondemand/g' /etc/php/8.3/fpm/pool.d/www.conf && \
  sed -i 's/;daemonize = .*/daemonize = no/g' /etc/php/8.3/fpm/php-fpm.conf && \
  sed -i 's/^pm\.max_children = .*/pm.max_children = 8/g' /etc/php/8.3/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.process_idle_timeout = .*/pm.process_idle_timeout = 15s/g' /etc/php/8.3/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.max_requests = .*/pm.max_requests = 50/g' /etc/php/8.3/fpm/pool.d/www.conf && \
  sed -i 's/^;request_terminate_timeout = .*/request_terminate_timeout = 7200/g' /etc/php/8.3/fpm/pool.d/www.conf


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

### develop tools
ENV \
  PATH=$PATH:/root/phpunit \
  PHANTOMJS_VERSION=1.9.8

#xdebug
RUN \
  apt-get update && \
  apt-get install -y php-pear gcc make autoconf libc-dev pkg-config php8.3-dev libmcrypt-dev php8.3-cgi net-tools
RUN \
  mkdir -p /var/www/html/log/xdebug && chown -R www-data:www-data /var/www/html/log/xdebug && \
  pecl install xdebug && \
  bash -c "echo zend_extension=xdebug.so > /etc/php/8.3/mods-available/xdebug.ini" && \
  bash -c "phpenmod xdebug" && \
  cp -f /home/docker/php/develop.ini /etc/php/8.3/fpm/conf.d/x-develop.ini

#phpunit
RUN \
  mkdir -p /root/phpunit/extensions && \
  wget -O /root/phpunit/phpunit https://phar.phpunit.de/phpunit-10.phar && \
  chmod +x /root/phpunit/phpunit && \
  cp /home/docker/php/phpunit.xml /root/phpunit/ && \
  echo "alias phpunit='phpunit -c ~/phpunit/phpunit.xml'" > /root/.bashrc

RUN \
  apt-get remove -y php8.3-dev gcc make autoconf libc-dev pkg-config php-pear && \
  apt-get autoremove -y && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# npm / nodejs
RUN \
  sed -i 's/main$/main contrib non-free/g' /etc/apt/sources.list && apt-get update && \
  cd /tmp && \
  mkdir -p /tmp/playwright && cd /tmp/playwright && \
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash && \
  \. "$HOME/.nvm/nvm.sh" && \
  nvm install 20 && \
  node -v && npm -v && \
  npm install -g -D @playwright/test && \
  npx playwright install --with-deps chromium

### END
WORKDIR /var/www/html
ENV TERM=xterm
CMD ["/usr/bin/supervisord"]
