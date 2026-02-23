# Pyroscope integration – commands from start to finish

Step-by-step commands to run Quay with Grafana Pyroscope continuous profiling.

---

## 1. Prerequisites

Install on your machine:

- **Docker** or **Podman**
- **docker-compose** (or `podman-compose` if using Podman)
- **Python 3.12** (for local installs or running tests)
- **Node 16+** (for frontend build)

Check versions:

```bash
python3 --version   # 3.12.x
docker --version   # or: podman --version
docker compose version
```

---

## 2. Clone and enter the repo (if needed)

```bash
cd /path/to/quay
# or
git clone <your-quay-repo-url>
cd quay
```

---

## 3. Install Python dependencies (with Pyroscope)

Required so the new `pyroscope-io` dependency is available.

**Option A – Using a virtualenv (recommended for local runs/tests):**

```bash
python3.12 -m venv venv
source venv/bin/activate   # Linux/macOS
# Windows: venv\Scripts\activate

pip install --upgrade pip
pip install -r requirements.txt
```

**Option B – When using Docker/Podman:**

Dependencies are installed during the **image build**. Ensure `requirements.txt` contains `pyroscope-io>=0.8.0` (already added). The image is built in step 6.

---

## 4. (Optional) Run a Pyroscope server to receive profiles

If you don’t have a Pyroscope server yet, run one locally so Quay can send profiles to it.

**Using Docker:**

```bash
docker run -d --name pyroscope -p 4040:4040 grafana/pyroscope:latest
```

**Using Podman:**

```bash
podman run -d --name pyroscope -p 4040:4040 grafana/pyroscope:latest
```

Server URL from the host: `http://localhost:4040`.

From another container on the same host (e.g. Quay in docker-compose), use the service name or host gateway:

- Same compose network: `http://pyroscope:4040` (if you add a `pyroscope` service).
- From host into container: `http://host.containers.internal:4040` (Podman on Mac) or `http://host.docker.internal:4040` (Docker Desktop).

---

## 5. Configure Quay to use Pyroscope

Set the Pyroscope server address so the app can send profiles.

**Option A – Config file (local dev):**

Edit `local-dev/stack/config.yaml` and add:

```yaml
# Pyroscope continuous profiling
PYROSCOPE_SERVER_ADDRESS: "http://localhost:4040"
```

If Pyroscope runs in another container and Quay needs to reach the host:

- **Podman (Mac):** `http://host.containers.internal:4040`
- **Docker Desktop:** `http://host.docker.internal:4040`
- **Compose with a pyroscope service:** `http://pyroscope:4040`

**Option B – Environment variable:**

```bash
export PYROSCOPE_SERVER_ADDRESS="http://localhost:4040"
```

For Docker/Podman, set this in `docker-compose.yaml` under the `quay` service `environment` (see step 6).

---

## 6. Build and start Quay (local dev)

The Quay image is built from `Dockerfile` and `requirements.txt`. After adding `pyroscope-io`, force a rebuild so the new dependency is in the image.

**Force rebuild the Quay image (required once after adding pyroscope-io):**

```bash
rm -f .build-image-quay-stamp
```

**Build images and start the stack:**

```bash
make local-dev-up
```

This will:

1. Run `local-dev-clean`
2. Install frontend deps and build frontend (if needed)
3. Build the Quay image (including `pip install -r requirements.txt` → pyroscope-io)
4. Start PostgreSQL, Redis, frontend builder, then Quay

Wait until you see: **"You can now access the frontend at http://localhost:8080"**.

**Using Podman instead of Docker:**

```bash
DOCKER=podman DOCKER_COMPOSE="podman compose" make local-dev-up
```

**With Clair (security scanner):**

```bash
make local-dev-up-with-clair
```

---

## 7. (Optional) Add Pyroscope to docker-compose

To run Pyroscope in the same compose stack and point Quay to it:

1. In `docker-compose.yaml`, add a `pyroscope` service and put the Quay service on the same network.
2. In `local-dev/stack/config.yaml` set:
   - `PYROSCOPE_SERVER_ADDRESS: "http://pyroscope:4040"`

Then:

```bash
make local-dev-down
make local-dev-up
```

---

## 8. Apply config or code changes without full rebuild

**Only config changed (e.g. `local-dev/stack/config.yaml`):**

```bash
podman restart quay-quay
# or
docker restart quay-quay
```

**Code changed (e.g. `app.py`):** Same as above; the repo is mounted into the container, so a restart is enough.

**Python dependencies changed (e.g. `requirements.txt`):** Rebuild the image and restart:

```bash
rm -f .build-image-quay-stamp
make local-dev-up
# or only rebuild and restart Quay:
# docker compose build quay && docker compose up -d quay
```

---

## 9. Verify Pyroscope is enabled

**Logs:**

```bash
podman logs quay-quay 2>&1 | grep -i pyroscope
# or
docker logs quay-quay 2>&1 | grep -i pyroscope
```

You should see a line like: **"Pyroscope profiling enabled"** with the server address.

**Generate some load, then check Pyroscope UI:**

1. Open Quay: http://localhost:8080  
2. Browse, push/pull images, etc.  
3. Open Pyroscope: http://localhost:4040 (if running locally)  
4. Select application **quay** and view profiles/flame graphs.

---

## 10. Shut down

```bash
make local-dev-down
```

Stops all services and runs `local-dev-clean`.

---

## Quick reference

| Goal                         | Command |
|-----------------------------|--------|
| First-time run with Pyroscope | `rm -f .build-image-quay-stamp && make local-dev-up` |
| Start (image already built) | `make local-dev-up` |
| Restart Quay (config/code)  | `podman restart quay-quay` or `docker restart quay-quay` |
| Rebuild Quay image          | `rm -f .build-image-quay-stamp && make local-dev-up` |
| View Quay logs              | `podman logs quay-quay -f` or `docker logs quay-quay -f` |
| Stop everything             | `make local-dev-down` |

---

## How to check Pyroscope logs

### 1. Quay (Python client) logs

The Pyroscope SDK in Quay uses `enable_logging=True`, so client-side messages (e.g. push success/failure) go to the same place as Quay’s application logs.

**Docker:**

```bash
# All Quay logs (follow)
docker logs quay-quay -f

# Only Pyroscope-related lines
docker logs quay-quay 2>&1 | grep -i pyroscope
```

**Podman:**

```bash
podman logs quay-quay -f
podman logs quay-quay 2>&1 | grep -i pyroscope
```

You should see at startup: **"Pyroscope profiling enabled"**. Any push errors from the SDK will also appear in these logs (e.g. connection refused, timeouts).

### 2. Pyroscope server logs

If you run Pyroscope in a container:

**Docker:**

```bash
docker logs pyroscope -f
```

**Podman:**

```bash
podman logs pyroscope -f
```

Replace `pyroscope` with your container name if different. These logs show ingestion, storage, and any server-side errors.

---

## Filtering by tags in the UI

Quay uses `pyroscope.tag_wrapper({"controller": "<name>"})` directly in each function (see [Python SDK – Add profiling labels](https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/python/#add-profiling-labels-to-python-applications)):

- **`controller`** = one of:
  - `app_request_entry` – entry point (every request; use this to verify tagging)
  - `fetch_manifest_by_tagname`
  - `fetch_manifest_by_digest`
  - `check_blob_exists`
  - `download_blob`
  - `list_manifest_referrers`
  - `list_all_tags`

In the Pyroscope or Grafana UI, select application **quay** and filter by label **controller** (e.g. `controller="app_request_entry"` to verify, or `controller="download_blob"` for blob pulls).

---

## Flow of functions during a Docker pull

A single `docker pull` triggers **multiple HTTP requests** to Quay. Execution flow:

1. **Resolve tag → manifest (by tag)**  
   `app_request_entry` → … → `parse_repository_name` → `process_registry_jwt_auth` → … → **`fetch_manifest_by_tagname`** → `get_repo_tag` → `get_manifest_for_tag` → DB/storage.

2. **Optional: fetch manifest by digest**  
   If the client follows a digest from the manifest list, you get **`fetch_manifest_by_digest`**.

3. **For each layer: HEAD blob (optional)**  
   **`check_blob_exists`** – client may HEAD each blob before downloading.

4. **For each layer: GET blob**  
   **`download_blob`** – stream layer data from storage (often one request per layer).

So the **full** pull flow in terms of our tagged controllers is:  
`app_request_entry` → **`fetch_manifest_by_tagname`** (and possibly `fetch_manifest_by_digest`) → then one or more **`check_blob_exists`** and **`download_blob`** (per layer).

### Why you might not see `download_blob` in the flame graph

- **CPU vs I/O:** Pyroscope’s default profile is **CPU** (e.g. `process_cpu`).  
  - **Manifest path** does a lot of CPU work (auth, DB, manifest parsing), so it shows up clearly.  
  - **Blob download** is mostly **I/O** (streaming bytes from storage). While the request is in `download_blob`, the process is often waiting on storage/network, so there are fewer CPU samples and the flame graph can be dominated by the manifest request.

- **Time window:** A short (e.g. 10 ms) window may contain only the manifest request; blob requests happen in separate requests (and possibly other workers).

**Why only some controller tags appear in "Select Tag":**

The dropdown is filled from **profiled data in the selected time range**. Only controller values that had CPU activity in that range appear. So it’s normal to see only:

- `app_request_entry` (every request)
- `fetch_manifest_by_tagname` (manifest-by-tag during pull)
- `list_manifest_referrers` (if the client or UI asked for referrers)

and **not** see `download_blob` or `check_blob_exists` if:

- Blob requests were mostly I/O (little CPU), or
- Blobs were served via **redirect** (client downloads from storage; Quay only does a quick redirect), or
- The time range didn’t include those requests.

**How to see blob-related controllers:**

- Use a **longer time range** (e.g. last 5–10 minutes), run `docker pull` for an image with **multiple layers**, then reopen "Select Tag" and see if `download_blob` or `check_blob_exists` appear.
- Manually add a filter: in the query bar, add `controller="download_blob"` (syntax depends on UI). If no data exists for that tag, the graph will be empty but confirms the tag name.
- With **local storage** (no redirect), blob streaming goes through Quay, so `download_blob` is more likely to show up in the dropdown after a pull.

---

## Troubleshooting

- **"Pyroscope profiling disabled" in logs**  
  - Check `PYROSCOPE_SERVER_ADDRESS` in config or env.  
  - From inside the Quay container, ensure the Pyroscope URL is reachable (e.g. `curl http://pyroscope:4040` or `http://host.containers.internal:4040`).

- **ImportError: No module named 'pyroscope'**  
  - Image was built before adding `pyroscope-io` to `requirements.txt`. Run:
    - `rm -f .build-image-quay-stamp && make local-dev-up`

- **Profiling in tests**  
  - Pyroscope is disabled when `TESTING` is true, so unit tests do not start the profiler.
