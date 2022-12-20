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
    php7.4 \
    php7.4-curl \
    php7.4-imap \
    php7.4-gd \
    php7.4-mysql \
    php7.4-mbstring \
    php7.4-xml \
    php7.4-memcached \
    php7.4-cli \
    php7.4-fpm \
    php7.4-zip \
    php7.4-bz2 \
    php7.4-ssh2 \
    php7.4-yaml \
    curl \
    vim \
    git-core

RUN \
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
  composer global require drush/drush:8.3.3 && \
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
  apt-get install -y php-pear gcc make autoconf libc-dev pkg-config php7.4-dev libmcrypt-dev && \
  printf "\n" | pecl install --nodeps mcrypt-snapshot && \
  bash -c "echo extension=mcrypt.so > /etc/php/7.4/mods-available/mcrypt.ini" && \
  bash -c "phpenmod mcrypt"


### PHP FPM Config
# remove default enabled site
RUN \
  mkdir -p /var/www/html/log/supervisor && \
  git clone https://github.com/NETivism/docker-sh.git /home/docker && \
  cp -f /home/docker/php/default73.ini /etc/php/7.4/docker_setup.ini && \
  ln -s /etc/php/7.4/docker_setup.ini /etc/php/7.4/fpm/conf.d/ && \
  cp -f /home/docker/php/default73_cli.ini /etc/php/7.4/cli/conf.d/ && \
  cp -f /home/docker/php/default_opcache_blacklist /etc/php/7.4/opcache_blacklist && \
  sed -i 's/^listen = .*/listen = 80/g' /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i 's/^pm = .*/pm = ondemand/g' /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i 's/;daemonize = .*/daemonize = no/g' /etc/php/7.4/fpm/php-fpm.conf && \
  sed -i 's/^pm\.max_children = .*/pm.max_children = 8/g' /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.process_idle_timeout = .*/pm.process_idle_timeout = 15s/g' /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.max_requests = .*/pm.max_requests = 50/g' /etc/php/7.4/fpm/pool.d/www.conf && \
  sed -i 's/^;request_terminate_timeout = .*/request_terminate_timeout = 7200/g' /etc/php/7.4/fpm/pool.d/www.conf

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

### develop tools
ENV \
  PATH=$PATH:/root/phpunit \
  PHANTOMJS_VERSION=1.9.8

#xdebug
RUN \
  mkdir -p /var/www/html/log/xdebug && chown -R www-data:www-data /var/www/html/log/xdebug && \
  apt-get update && \
  apt-get install -y php7.4-cgi net-tools && \
  pecl install xdebug && \
  bash -c "echo zend_extension=xdebug.so > /etc/php/7.4/mods-available/xdebug.ini" && \
  bash -c "phpenmod xdebug" && \
  cp -f /home/docker/php/develop.ini /etc/php/7.4/fpm/conf.d/x-develop.ini

#phpunit
RUN \
  mkdir -p /root/phpunit/extensions && \
  wget -O /root/phpunit/phpunit https://phar.phpunit.de/phpunit-7.phar && \
  chmod +x /root/phpunit/phpunit && \
  wget -O /root/phpunit/extensions/dbunit.phar https://phar.phpunit.de/dbunit.phar && \
  chmod +x /root/phpunit/extensions/dbunit.phar && \
  cp /home/docker/php/phpunit.xml /root/phpunit/ && \
  echo "alias phpunit='phpunit -c ~/phpunit/phpunit.xml'" > /root/.bashrc

#casperjs
RUN \
  apt-get install -y libfreetype6 libfontconfig bzip2 python && \
  mkdir -p /srv/var && \
  wget --no-check-certificate -O /tmp/phantomjs-$PHANTOMJS_VERSION-linux-x86_64.tar.bz2 https://bitbucket.org/ariya/phantomjs/downloads/phantomjs-$PHANTOMJS_VERSION-linux-x86_64.tar.bz2 && \
  tar -xjf /tmp/phantomjs-$PHANTOMJS_VERSION-linux-x86_64.tar.bz2 -C /tmp && \
  rm -f /tmp/phantomjs-$PHANTOMJS_VERSION-linux-x86_64.tar.bz2 && \
  mv /tmp/phantomjs-$PHANTOMJS_VERSION-linux-x86_64/ /srv/var/phantomjs && \
  ln -s /srv/var/phantomjs/bin/phantomjs /usr/bin/phantomjs && \
  git clone https://github.com/n1k0/casperjs.git /srv/var/casperjs && \
  ln -s /srv/var/casperjs/bin/casperjs /usr/bin/casperjs && \
  apt-get autoremove -y && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN \
  apt-get remove -y php7.4-dev gcc make autoconf libc-dev pkg-config php-pear && \
  apt-get autoremove -y && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

# npm / nodejs
RUN \
  cd /tmp && \
  curl -fsSL https://deb.nodesource.com/setup_16.x | bash - && \
  apt-get install -y nodejs && \
  curl https://www.npmjs.com/install.sh | sh && \
  node -v && npm -v

# playwright
RUN \
  sed -i 's/main$/main contrib non-free/g' /etc/apt/sources.list && apt-get update && \
  mkdir -p /tmp/playwright && cd /tmp/playwright && \
  npm install -g -D @playwright/test && \
  npx playwright install --with-deps chromium

### END
WORKDIR /var/www/html
ENV TERM=xterm
CMD ["/usr/bin/supervisord"]

