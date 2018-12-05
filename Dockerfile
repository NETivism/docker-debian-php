FROM netivism/docker-debian-base
MAINTAINER Jimmy Huang <jimmy@netivism.com.tw>

ENV \
  COMPOSER_HOME=/root/.composer \
  PATH=/root/.composer/vendor/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#mariadb
RUN \
  apt-get update && \
  apt-get install -y mariadb-server

WORKDIR /etc/apt/sources.list.d
RUN echo "deb https://packages.sury.org/php/ stretch main" > phpsury.list && \
    echo "deb-src https://packages.sury.org/php/ stretch main" >> phpsury.list && \
    apt-get install -y wget ca-certificates apt-transport-https && \
    wget -q https://packages.sury.org/php/apt.gpg  && apt-key add apt.gpg && rm -f apt.gpg

WORKDIR /
RUN \
  apt-get install -y \
    rsyslog \
    php7.2 \
    php7.2-curl \
    php7.2-imap \
    php7.2-gd \
    php7.2-mcrypt \
    php7.2-mysql \
    php7.2-mbstring \
    php7.2-xml \
    php7.2-memcached \
    php7.2-cli \
    php7.2-fpm \
    curl \
    vim \
    git-core

RUN \
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
  composer global require drush/drush:8.1.5 && \
  git clone https://github.com/NETivism/docker-sh.git /home/docker && \
  cd /root/.composer && \
  find . | grep .git | xargs rm -rf && \
  rm -rf /root/.composer/cache/*

### PHP FPM Config
# remove default enabled site
RUN \
  mkdir -p /var/www/html/log/supervisor && \
  cp -f /home/docker/php/default72.ini /etc/php/7.2/docker_setup.ini && \
  ln -s /etc/php/7.2/docker_setup.ini /etc/php/7.2/fpm/conf.d/ && \
  cp -f /home/docker/php/default72_cli.ini /etc/php/7.2/cli/conf.d/ && \
  cp -f /home/docker/php/default_opcache_blacklist /etc/php/7.2/opcache_blacklist && \
  sed -i 's/^listen = .*/listen = 80/g' /etc/php/7.2/fpm/pool.d/www.conf && \
  sed -i 's/^pm = .*/pm = ondemand/g' /etc/php/7.2/fpm/pool.d/www.conf && \
  sed -i 's/;daemonize = .*/daemonize = no/g' /etc/php/7.2/fpm/php-fpm.conf && \
  sed -i 's/^pm\.max_children = .*/pm.max_children = 8/g' /etc/php/7.2/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.process_idle_timeout = .*/pm.process_idle_timeout = 15s/g' /etc/php/7.2/fpm/pool.d/www.conf && \
  sed -i 's/^;pm\.max_requests = .*/pm.max_requests = 50/g' /etc/php/7.2/fpm/pool.d/www.conf && \
  sed -i 's/^;request_terminate_timeout = .*/request_terminate_timeout = 7200/g' /etc/php/7.2/fpm/pool.d/www.conf

RUN apt-get install -y supervisor procps

# wkhtmltopdf
WORKDIR /tmp
RUN \
  apt-get install -y fonts-noto-cjk fontconfig libfontconfig1 libfreetype6 libpng12-0 libssl1.0.0 libx11-6 libxext6 libxrender1 xfonts-75dpi xfonts-base && \
  wget -nv https://downloads.wkhtmltopdf.org/0.12/0.12.5/wkhtmltox_0.12.5-1.stretch_amd64.deb -O wkhtmltox.deb && \
  dpkg -i wkhtmltox.deb && \
  rm -f wkhtmltox.deb && \
  apt-get clean && rm -rf /var/lib/apt/lists/*

ADD container/supervisord/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
ADD container/mysql/mysql-init.sh /usr/local/bin/mysql-init.sh
ADD container/rsyslogd/rsyslog.conf /etc/rsyslog.conf

### END
WORKDIR /var/www/html
ENV TERM=xterm
CMD ["/usr/bin/supervisord"]
