# gradle-build-cache-raw

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
ways. Uploads in progress live in `<data-dir>/store/tmp`, on the same filesystem
so the rename is atomic.

## Install

TODO ...

## Disclaimer

> [!IMPORTANT]
> AI-assisted code with manual edits. I have reviewed the output the agent 
> produced, but if you have your concerns about AI, you should abstain from 
> using this project.

## License

[MIT](LICENSE)
