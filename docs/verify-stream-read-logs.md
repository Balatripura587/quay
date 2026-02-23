# Verifying download_blob and storage_stream_read

## Debug logs in download_blob

`download_blob` logs steps at INFO level with prefix `[download_blob]` so you can see where execution goes:

| Log message | Meaning |
|-------------|--------|
| `step=entered digest=... repo=...` | Request reached the handler |
| `step=blob_not_found digest=... -> BlobUnknown` | Blob lookup returned None → 404, **stream_read not called** |
| `step=blob_found digest=... path=...` | Blob found, continuing |
| `step=redirect digest=...` | Returning 302 (direct URL), **stream_read not called** |
| `step=streaming digest=... path=...` | Returning 200 and calling **stream_read** |

**Where these logs go:** Gunicorn-registry logs are captured by supervisord into files under `/tmp` in the container (e.g. `gunicorn-registry-stderr---supervisor-*.log`). They do **not** appear in `docker logs quay-quay` by default.

### Steps to see download_blob debug logs

1. **Restart Quay** so it loads the new code:
   ```bash
   docker restart quay-quay
   sleep 15
   ```

2. **Trigger blob GETs** (e.g. one tag pull):
   ```bash
   LOAD_REPO="localhost:8080/admin/load-test" START=1 END=1 CONCURRENCY=1 QUAY_USER=admin QUAY_PASS=redhat123 ./scripts/pull_load.sh
   ```

3. **Search for the debug logs inside the container:**
   ```bash
   docker exec quay-quay sh -c 'grep "\[download_blob\]" /tmp/*.log 2>/dev/null'
   ```
   Or only stderr (where Python logging often goes):
   ```bash
   docker exec quay-quay sh -c 'grep "\[download_blob\]" /tmp/gunicorn-registry-stderr*.log 2>/dev/null'
   ```

4. **Interpret the sequence:**
   - For each blob GET you should see `step=entered` then either:
     - `step=blob_not_found` → request stops there (404).
     - `step=blob_found` then either `step=redirect` or `step=streaming` → request completes.
   - If you see `step=entered` but no later step for that digest, something raised between steps (check for tracebacks in the same log files).

5. **Optional: stream logs while pulling** (in one terminal):
   ```bash
   docker exec -it quay-quay sh -c 'tail -f /tmp/gunicorn-registry-stderr---supervisor-*.log 2>/dev/null'
   ```
   Then run the pull in another terminal; you’ll see `[download_blob]` lines as requests are handled.

---

## Debug prints (QUAY_DEBUG) — legacy

To confirm whether blob GETs hit the Python app and whether they stream or redirect, **stderr** debug prints were added that bypass the logging system:

- **`QUAY_DEBUG download_blob entered digest=...`** – request reached `download_blob`
- **`QUAY_DEBUG download_blob REDIRECT digest=...`** – response was a 302 (no streaming)
- **`QUAY_DEBUG download_blob STREAMING path=...`** – response is streamed from storage
- **`QUAY_DEBUG storage_stream_read started path=...`** – `LocalStorage.stream_read` is running

These go to the gunicorn-registry process **stderr**, which supervisord may capture to a file (often under `/tmp`).

## Step 1: Restart and trigger one blob GET

```bash
docker restart quay-quay
# Wait for Quay to be ready, then get a blob digest from a manifest and do one GET:
# (Replace SHA256_DIGEST with a real digest from your repo, e.g. from the manifest of tag 1)
TOKEN=$(curl -s -u admin:redhat123 -G "http://localhost:8080/v2/auth" --data-urlencode "service=localhost:8080" --data-urlencode "scope=repository:admin/load-test:pull" | jq -r '.token')
curl -v -H "Authorization: Bearer $TOKEN" "http://localhost:8080/v2/admin/load-test/blobs/sha256:$(curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.oci.image.manifest.v1+json" "http://localhost:8080/v2/admin/load-test/manifests/1" | jq -r '.layers[0].digest' | sed 's/sha256://')" -o /dev/null 2>&1 | head -25
```

Check the curl output: **`< HTTP/1.1 302`** means redirect (stream path not used); **`< HTTP/1.1 200`** means streaming.

## Step 2: Find QUAY_DEBUG in the container

```bash
# Check docker logs and all common log locations:
docker logs quay-quay 2>&1 | grep QUAY_DEBUG
docker exec quay-quay sh -c 'grep -r QUAY_DEBUG /tmp 2>/dev/null'
docker exec quay-quay sh -c 'grep -r QUAY_DEBUG /var/log 2>/dev/null'
```

- If you see **`download_blob entered`** but **no STREAMING / no storage_stream_read**: the handler runs but responses are **redirects** (direct_download_url is set).
- If you see **`STREAMING`** and **`storage_stream_read started`**: streaming path and `stream_read` are used; remove the QUAY_DEBUG prints when done.
- If you see **no QUAY_DEBUG anywhere**: blob GETs are **not** reaching the Flask app (e.g. served by nginx or another process). Confirm with `curl -v` that the request goes to the registry and returns 200 or 302.

## Why logger.info didn't show up

Gunicorn's **stdout** (where the default logging handler writes) is captured by supervisord into log files (often under `/tmp`), not the container's main stdout. So `docker logs quay-quay` only shows supervisord's output, and `logger.info` lines may only appear in those files. The **QUAY_DEBUG** lines use **stderr** so they may appear in a different supervisord log; use the greps above to find them.
