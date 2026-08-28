FROM nginx:1.29.8-alpine

# apache2-utils -> htpasswd (apr1 hashes; see 41-gbc-config.sh)
# su-exec        -> drop to uid 101 to prove the worker can write the bind mount
# gettext        -> envsubst (already in the nginx image; pinned here explicitly)
RUN apk add --no-cache apache2-utils su-exec gettext

RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx/nginx.conf   /etc/nginx/nginx.conf
COPY nginx/site.conf    /etc/nginx/gbc/10-site.conf
COPY nginx/cache.conf   /etc/nginx/gbc-src/cache.conf
COPY docker-entrypoint.d/ /docker-entrypoint.d/

RUN mkdir -p /etc/nginx/gbc /etc/nginx/gbc-inc /etc/nginx/gbc-src /data/cache /data/tmp \
 && chown nginx:nginx /data/cache /data/tmp \
 && chmod +x /docker-entrypoint.d/*.sh

# /data is expected to be bind-mounted from the host; cache/ and tmp/ live inside
# it so they are always on the same filesystem.
VOLUME ["/data"]

EXPOSE 80

STOPSIGNAL SIGQUIT
