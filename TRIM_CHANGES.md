# Fork changes vs upstream Hiddify-Manager v12.3.3

This fork is pinned to upstream tag **v12.3.3** (known-good — what the `test`
box runs). It strips features unused in an **xray-only (VLESS WS + Reality)**
deployment to cut CPU/RAM, and bakes in the xRay-core 4.10.2 compatibility
patch. Every change is marked with a `TRIM` or `PATCH` comment in-source so a
future `git diff v12.3.3` shows exactly what diverged.

## Why fork instead of tracking upstream
Upstream `bash <(curl https://i.hiddify.com/release)` installs *latest*, which
has repeatedly shipped regressions (the xRay-core allowInsecure break, etc.).
Pinning to v12.3.3 + this fork gives a controlled, reproducible install.

## Use-case this build targets
**VLESS WS over Cloudflare CDN only**, with **user create/delete via the panel
REST API**, and **GB-quota / expiry auto-disable kept on** (so Celery stays).
No Reality, no direct-IP serving, no sing-box protocols.

## Validated savings (measured on `test`, VLESS kept serving HTTP 200)
| Change | RAM | Other |
|---|---|---|
| Remove sing-box stack | ~26 MB | no idle sing-box CPU |
| MariaDB buffer pool 128→64M, max_conn 151→30 | ~30 MB | lower DB overhead |
| Celery loglevel debug→warning | ~0 MB | ongoing CPU + disk-I/O cut |
| Celery usage-sync 60s→300s | ~0 MB | **~5x less per-minute CPU** (quota/expiry still enforced, refreshes every 5 min) |
| nginx worker_processes auto→1 | ~15-29 MB | one worker is plenty for an internal WS dispatcher |
| **Total** | **~86 MB (994→908, ~9%)** | substantial CPU reduction |

Celery is **kept** (you need GB-quota + expiry auto-disable) — only its sync
cadence is slowed and its logging quieted.

## The changes

### 1. `install.sh` — disable sing-box install/run
- Commented out `install_run singbox &` (line ~125)
- Added `systemctl disable --now hiddify-singbox` so any pre-existing unit stops
- sing-box powers tuic/hysteria2/wireguard/warp/ss-faketls — none used in an
  xray-only build. Reality is an **xray** feature, unaffected.

### 2. `common/utils.sh` — drop sing-box from the startup readiness check
- Removed `hiddify-singbox` from the `for s in …` important-services loop
  (line ~359). Without this, the installer would fail waiting for a service we
  deliberately disabled.

### 3. `hiddify-panel/hiddify-panel-background-tasks.service` — quieter Celery
- `--loglevel debug` → `--loglevel warning`. Debug logging ran on every
  scheduled task (CPU + disk I/O waste).

### 4. `other/mysql/install.sh` — shrink MariaDB
- Appends `/etc/mysql/mariadb.conf.d/99-hiddify-trim.cnf`:
  `innodb_buffer_pool_size=64M`, `max_connections=30`, `performance_schema=OFF`.
- Idempotent (only writes if absent).

### 5. `hiddify-panel/install.sh` — standalone panel install + CLI wrappers + patches
First, two standalone-install fixes (so a bare `bash install.sh` works from a
clone, not just via `hiddify_installer.sh`):
- **Install panel from `./src`** if `hiddifypanel` isn't importable — upstream's
  `install.sh` only does this when `HIDDIFY_PANLE_SOURCE_DIR` is set (never on a
  clone), so the panel package would otherwise be missing.
- **Create `hiddify-panel-cli` / `hiddify-http-api` wrappers** — the pinned panel's
  `pyproject` ships only the `hiddifypanel` console-script; the PyPI wheel adds the
  other two but a source install does not. Without them `reload_all_configs` writes
  an empty `current.json` and the proxy services restart-loop. The wrappers `cd`
  into the panel dir (panel reads `app.cfg` relative to CWD) and exec `hiddifypanel`.

Then two patches applied after the `hiddifypanel` package installs (so we don't
have to fork HiddifyPanel separately):
- **xRay 4.10.2 allowInsecure**: no-ops `q['allowInsecure']='true'` /
  `q['insecure']='true'` in `hutils/proxy/xray.py`. Guarded by a
  `PATCHED 4.10.2-compat` marker + `.bak`, compile-checked (reverts if broken).
- **Celery usage-sync 60s→300s**: rewrites `add_periodic_task(60.0,
  usage.update_local_usage…)` → `300.0` in `celery.py`. Quota/expiry still
  enforced, ~5x less CPU.

### 6. `nginx/nginx.conf.j2` — single worker
- `worker_processes auto` → `1`. nginx is just an internal dispatcher in front
  of xray for WS; one worker suffices.

### 7. `common/hiddify_installer.sh` — install panel from bundled submodule (CRITICAL)
- The upstream `release` package-mode gated the HiddifyPanel install on a
  network version check (`get_release_version`). On a raw fork clone that call
  returns empty, so `current("") != latest("")` is false → the panel install was
  **silently skipped** → no `hiddifypanel` module → panel + bg-tasks fail to start.
- Fixed: the `release)` case now does `uv pip install
  /opt/hiddify-manager/hiddify-manager/hiddify-panel/src` (the pinned submodule),
  deterministic + self-contained. Only Python deps come from PyPI; hiddifypanel
  itself is the bundled v12.3.3 source. Without this fix `bash install.sh` from
  the fork produces a non-working box. Validated on a fresh VPS (139.59.243.108).

## Known minor residual
- The xRay 4.10.2 patch removes `allowInsecure`/`insecure` from the URL query
  params. `type=xhttp` configs ALSO embed `allowInsecure:true` inside their
  `extra=` downloadSettings JSON (a separate code path) — those are NOT patched.
  Irrelevant for a WS-only deployment. If you ever use xhttp, that JSON would
  need a separate patch.
- A fresh install enables Hiddify's default transports; WS (`ws_enable`) and the
  protocol mix are per-deployment DB settings configured via the panel/API after
  install (as on the reference box).

## NOT changed (left as upstream)
- xray, haproxy, nginx, redis, mariadb-server install — all needed.
- The panel Python submodule (`hiddify-panel/src`) is untouched; the xray.py
  tweak is applied at install time, so you don't need to fork HiddifyPanel too.
- wireguard/warp/dnstt/ssfaketls installs are already conditional on their
  `hconfig *_enable` flags (all 0 here), so they self-skip — no edit needed.

## How to deploy this fork
```bash
# Push this dir to your GitHub (e.g. github.com/532015/Hiddify-Manager-trim)
# On a fresh VPS:
git clone https://github.com/532015/Hiddify-Manager-trim.git /opt/hiddify-manager
cd /opt/hiddify-manager
git submodule update --init --recursive   # pulls HiddifyPanel @ pinned commit
bash install.sh
```
(Upstream's one-liner installer can also be pointed at your fork; see README.)

## Re-applying our other fleet fixes
The GUI tools (`disable_features.py`, `fix_direct2_show_domains.py`,
`fix_null_domain_fields.py`, etc.) still apply on top of a fork-installed box
exactly as on upstream installs.
