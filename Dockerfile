FROM nginx:1.29.8-alpine

RUN apk add --no-cache apache2-utils su-exec

RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx/                /etc/nginx/
COPY docker-entrypoint.d/  /docker-entrypoint.d/

RUN mkdir -p /etc/nginx/gen /data/cache /data/tmp \
 && chown nginx:nginx /data/cache /data/tmp \
 && chmod +x /docker-entrypoint.d/*.sh

# /data is persistent on the host and contains the cache/ and tmp/ directories
# which are expected to be on the same filesystem
VOLUME ["/data"]

EXPOSE 80

# graceful nginx shutdown
STOPSIGNAL SIGQUIT
