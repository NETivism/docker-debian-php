FROM ghcr.io/netivism/docker-debian-php:7.3
MAINTAINER Jimmy Huang <jimmy@netivism.com.tw>

### END
WORKDIR /var/www/html
ENV TERM=xterm
CMD ["/usr/bin/supervisord"]

