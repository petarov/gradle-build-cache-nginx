# gradle-build-cache-nginx

A Gradle remote [build cache](https://docs.gradle.org/current/userguide/build_cache.html): 
nginx with `ngx_http_dav_module` in a container, storing entries as plain files. 
No database, no JVM, no license required.

> [!NOTE]
> This project is WIP.

Gradle's HTTP build cache protocol is two verbs against `{url}{cacheKey}`:
`GET` returns 200 with the entry or 404 for a miss, `PUT` stores it and returns
any 2xx. **Any status outside 200/201/204/404 (and 401) makes Gradle log one 
warning and disable the remote cache for the rest of that build.** Because
of this this setup has no rate limiting (503), no custom error pages (500), 
malformed keys are answered with 404 rather than 403.

Entries live at `<data-dir>/store/cache/<first 2 hex>/<32 hex key>`, sharded 256
ways. Uploads in progress live in `<data-dir>/store/tmp`, renamed when done,
so the `rename()` is atomic.

## Install

```bash
git clone <repo> /opt/gradle-build-cache-nginx
cd /opt/gradle-build-cache-nginx
cp .env.example .env && chmod 600 .env   # then edit it
mkdir -p /var/lib/gradle-build-cache-nginx/store /var/lib/gradle-build-cache-nginx/logs
chown -R 101:101 /var/lib/gradle-build-cache-nginx/store
docker compose up -d --build
```

`101` is the nginx uid inside the container. The preflight script refuses to
start if it cannot write the store, rather than letting the first `PUT` fail with
status code `500`.

View configuration and log files:

```bash
docker compose exec gbc nginx -T          # effective config
docker compose logs gbc                   # startup, preflight, auth state
tail -f /var/lib/gradle-build-cache-nginx/logs/access.log
```

### Configuration

All in `.env`. The first five are read by `docker-compose.yml`, the last two only
by `systemd/gbc-evict.sh`.

| Variable | Default | Meaning |
|---|---|---|
| `GBC_DATA_DIR` | `/var/lib/gradle-build-cache-nginx` | holds `store/` and `logs/` |
| `GBC_BIND` / `GBC_HTTP_PORT` | `127.0.0.1` / `80` | where the cache is published |
| `GBC_MAX_ENTRY_SIZE` | `512m` | larger entries get 413 |
| `GBC_HTTP_GET_USER` / `_PASSWORD` | empty | empty means anyone may read |
| `GBC_HTTP_PUT_USER` / `_PASSWORD` | empty | empty means anyone may write |
| `GBC_MAX_SIZE_GB` | `200` | eviction threshold |
| `GBC_MAX_AGE_DAYS`| `14`  | eviction threshold |

`PUT` is a CI-only verb, so the usual setup is to set the `PUT` pair only and
leave reads open - a laptop then cannot write to the shared cache whatever its
`isPush` flag says. `.env.example` documents each variable.

### TLS

There is none. Terminate it on a proxy in front. Example `location` for an nginx
host proxy, with `GBC_HTTP_PORT=8017`:

```nginx
location /gbc/ {
    proxy_pass http://127.0.0.1:8017/cache/;

    # >= GBC_MAX_ENTRY_SIZE, or the proxy returns 413 before the cache sees it
    client_max_body_size 512m;

    # stream the PUT body instead of spooling the whole entry to disk first
    proxy_request_buffering off;
    proxy_buffering off;

    # match the cache's timeouts
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    # a build makes hundreds of requests; keep the upstream connection open
    proxy_http_version 1.1;
    proxy_set_header Connection "";

    gzip off;   # entries are opaque bytes, already packed by Gradle

    proxy_set_header Host            $http_host;
    proxy_set_header X-Real-IP       $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

## Eviction and Logs

Optional, on the host:

```bash
cp systemd/*.service systemd/*.timer /etc/systemd/system/   # not the .sh
cp systemd/gbc-logrotate.conf /etc/logrotate.d/gradle-build-cache
systemctl daemon-reload
systemctl enable --now gbc-evict.timer
```

Edit the path to the logs in `gbc-logrotate.conf` to what your `GBC_DATA_DIR` points to.

`systemd/gbc-evict.sh` runs on the host, hourly via `gbc-evict.timer`. Two
passes: delete entries not read for `GBC_MAX_AGE_DAYS`, then delete
least-recently-read entries until the store is under `GBC_MAX_SIZE_GB`. It
refuses to run in a directory without the `.gbc-cache-root` marker.

The size pass is true LRU and depends on access times, so the filesystem must
not be mounted `noatime`. Ubuntu's default `relatime` is fine. `--dry-run`
reports what it would delete.

## Java clients projects

In the project's `settings.gradle.kts` (not `build.gradle.kts`, the cache is
configured before projects are evaluated), with `org.gradle.caching=true`:

```kotlin
import org.gradle.caching.http.HttpBuildCache

buildCache {
    local { isEnabled = true }
    remote<HttpBuildCache> {
        url = uri("https://cache.example/cache/")       // trailing slash required
        isPush = System.getenv("CI") != null            // CI pushes, laptops pull
        credentials {
            username = System.getenv("GRADLE_CACHE_USER")
            password = System.getenv("GRADLE_CACHE_PASSWORD")
        }
    }
}
```

## Testing

Protocol conformance — round trip, re-store, malformed keys, torn upload,
concurrent writes to one key, the auth matrix:

```bash
./tests/gbc-smoke-test.sh https://cache.example/cache/ ci:secret [dev:secret]
```

End to end with real Gradle — two clones with the local cache disabled, so a
hit can only be remote:

```bash
./tests/testproject/run-cache-test.sh https://cache.example/cache/ ci:secret
```

## AI-Disclaimer

> [!IMPORTANT]
> AI-assisted code with manual edits. I have reviewed the output the agent 
> produced, but if you have your concerns about AI, you should abstain from 
> using this project.

## License

[MIT](LICENSE)
