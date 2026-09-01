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
