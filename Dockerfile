FROM nginx:1.29.8-alpine

# apache2-utils -> htpasswd (apr1 hashes; see 41-gbc-config.sh)
# su-exec        -> drop to uid 101 to prove the worker can write the bind mount
RUN apk add --no-cache apache2-utils su-exec

RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx/                /etc/nginx/
COPY docker-entrypoint.d/  /docker-entrypoint.d/

RUN mkdir -p /etc/nginx/gen /data/cache /data/tmp \
 && chown nginx:nginx /data/cache /data/tmp \
 && chmod +x /docker-entrypoint.d/*.sh

# /data is expected to be bind-mounted from the host; cache/ and tmp/ live inside
# it so they are always on the same filesystem.
VOLUME ["/data"]

EXPOSE 80

STOPSIGNAL SIGQUIT
