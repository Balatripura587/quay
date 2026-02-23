# Why `stream_read` Is Not Called for Some Blob GETs

## 1. What the script does

`pull_load.sh` fetches the manifest for a tag, then extracts **every** digest from the manifest and does a GET for each:

- **`_extract_digests`** uses grep to find all `"digest": "sha256:..."` in the manifest JSON.
- For an OCI image manifest that includes:
  - **config**: `"config": { "digest": "sha256:CONFIG_DIGEST", ... }`
  - **layers**: `"layers": [ { "digest": "sha256:LAYER_DIGEST", ... } ]`
- So you get **2 digests** for a typical image: one config, one layer (or more layers).

The script then calls **`_fetch_blob`** for each digest, i.e.:

- `GET /v2/admin/load-test/blobs/sha256:CONFIG_DIGEST`
- `GET /v2/admin/load-test/blobs/sha256:LAYER_DIGEST`

So the registry sees **two separate blob GET requests** per tag.

---

## 2. What happens in the registry for each GET

In **`endpoints/v2/blob.py`**, **`download_blob`** runs for each request:

```
download_blob(namespace_name, repo_name, digest)
  → blob = registry_model.get_cached_repo_blob(model_cache, namespace_name, repo_name, digest)
  → if blob is None: raise BlobUnknown()   ← EXIT HERE for some digests
  → ...
  → if direct_download_url: return redirect(...)   ← LocalStorage returns None, so we skip
  → return Response(storage.stream_read(blob.placements, path), ...)   ← ONLY REACHED IF blob WAS FOUND
```

So:

- **If `get_cached_repo_blob` returns `None`** → we **raise BlobUnknown** (404) and **never** call `stream_read`.
- **If `get_cached_repo_blob` returns a blob** → we eventually call **`storage.stream_read(blob.placements, path)`** and stream the response.

So **`stream_read` is only called when the blob is found**.

---

## 3. Why does `get_cached_repo_blob` return None for one of the digests?

Blob lookup is implemented in **`data/model/oci/blob.py`**:

- **`get_repository_blob_by_digest(repository, blob_digest)`** finds a blob that is:
  - linked to the repository via **ManifestBlob**, and
  - has **content_checksum == blob_digest**.

So we only find blobs that are stored as **manifest blobs** for that repo (i.e. linked in the `ManifestBlob` table).

In OCI:

- **Layer blobs** are linked to the manifest (and thus to the repo) as “manifest blobs”.
- The **config blob** is referenced by the manifest (e.g. in the manifest row or as config digest), but depending on how Quay models it, the **config** might not be stored as a row in **ManifestBlob** in the same way as layers.

So when the client requests:

- **Layer digest** → lookup finds it in ManifestBlob + ImageStorage → blob is returned → **stream_read is called**.
- **Config digest** → lookup does **not** find it (e.g. not present as a manifest blob for that repo) → **None** → **BlobUnknown** → **stream_read is not called** for that request.

So one of the two GETs (the one for the config digest) can 404 and never reach `stream_read`; the other (layer) does and does call `stream_read`.

---

## 4. Manifest list (index) and 404s

If the tag points to a **manifest list** (e.g. multi-arch), the initial `GET /manifests/<tag>` can return the index. The index JSON contains `"manifests": [ { "digest": "sha256:..." }, ... ]` — those digests are **manifest** digests, not blob digests. The script used to extract those and call `GET /blobs/<digest>` for each; the registry returns **404 BlobUnknown** for manifest digests because manifest bytes are not stored as blobs. **Fix:** the script now detects an index, fetches the first (or chosen) image manifest by digest, and extracts only **config + layer** digests from that image manifest, so all subsequent blob GETs are for real blobs and succeed.

## 5. Summary

| Request                    | Digest   | get_cached_repo_blob | Result        | stream_read called? |
|---------------------------|----------|----------------------|---------------|----------------------|
| GET blobs/CONFIG_DIGEST   | Config   | None                 | 404 BlobUnknown | **No**               |
| GET blobs/LAYER_DIGEST    | Layer    | Blob found           | 200 streamed  | **Yes**              |

So:

- **`stream_read` is not called** for any blob GET that gets **404 BlobUnknown** (e.g. when the “digest” was actually a manifest digest from an index, or config/layer not linked in the repo), because we raise before we ever get to `storage.stream_read(...)`.
- **`stream_read` is called** for blob GETs that are found (real config/layer blobs linked in ManifestBlob); that’s when the response is streamed from storage.

The script reports “tag 1 OK” when both GETs succeed (e.g. if the config is also found in your repo, or you only have one digest). If one GET returns 404, the script now fails (we removed `|| true`), so you’d see a failure for that tag.

---

## 6. How to confirm

- **Logs**: Look for **BlobUnknown** in Quay logs for one of the two digests per tag; that’s the request that never reaches `stream_read`.
- **Stream_read**: For the other digest, `LocalStorage.stream_read()` runs; its log line (`storage_stream_read started path=...`) goes to the gunicorn-registry log file (e.g. under `/tmp`), not to `docker logs`, as in `docs/verify-stream-read-logs.md`.
