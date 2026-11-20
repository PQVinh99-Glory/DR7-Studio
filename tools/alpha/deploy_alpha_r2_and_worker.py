#!/usr/bin/env python3
"""Deploy DR7-Studio Alpha Staging artifacts to Cloudflare R2 + Wrangler Worker, then verify live downloads & SHA-256.

- Reads Cloudflare & Supabase credentials from local .env (NEVER prints secrets).
- Creates R2 bucket 'dr7-alpha-artifacts' if missing.
- Uploads APK, unsigned IPA, and full Godot Web export to versioned R2 keys BEFORE switching manifest.json.
- Sets Worker secrets (SUPABASE_URL, SUPABASE_ANON_KEY) via stdin and deploys via wrangler.
- Downloads live artifacts from staging URL and asserts 100% SHA-256 parity + live login check.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ENV_PATH = REPO_ROOT / ".env"
WORKER_DIR = REPO_ROOT / "cloudflare" / "alpha-staging"
BUCKET_NAME = "dr7-alpha-artifacts"
STAGING_URL = "https://dr7-alpha-staging.hem-tra.workers.dev"


def load_env(path: pathlib.Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def run_wrangler(args: list[str], cf_env: dict[str, str], stdin_text: str | None = None) -> subprocess.CompletedProcess:
    proc_env = os.environ.copy()
    proc_env.update(cf_env)
    return subprocess.run(
        ["wrangler", *args],
        cwd=str(WORKER_DIR),
        env=proc_env,
        input=stdin_text,
        text=True,
        capture_output=True,
        check=False,
    )


def upload_r2_file(r2_key: str, local_path: pathlib.Path, content_type: str, cf_env: dict[str, str]) -> None:
    last_err = ""
    for attempt in range(1, 5):
        res = run_wrangler(
            [
                "r2",
                "object",
                "put",
                f"{BUCKET_NAME}/{r2_key}",
                "--remote",
                "--file",
                str(local_path),
                "--content-type",
                content_type,
            ],
            cf_env,
        )
        if res.returncode == 0:
            return
        last_err = res.stderr.strip() or res.stdout.strip()
        if attempt < 4:
            wait_s = attempt * 2
            print(f"[retry] R2 upload {r2_key} failed (attempt {attempt}/4), retrying in {wait_s}s...", flush=True)
            time.sleep(wait_s)
    raise RuntimeError(f"R2 upload failed for {r2_key}: {last_err}")


def mime_for(name: str) -> str:
    low = name.lower()
    if low.endswith(".html"):
        return "text/html; charset=utf-8"
    if low.endswith(".js"):
        return "application/javascript; charset=utf-8"
    if low.endswith(".wasm"):
        return "application/wasm"
    if low.endswith(".png"):
        return "image/png"
    if low.endswith(".json"):
        return "application/json; charset=utf-8"
    if low.endswith(".apk"):
        return "application/vnd.android.package-archive"
    return "application/octet-stream"


def download_and_sha256(url: str) -> tuple[int, int, str]:
    req = urllib.request.Request(url, headers={"User-Agent": "DR7-Alpha-Verifier/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        h = hashlib.sha256()
        total = 0
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
            total += len(chunk)
        return resp.status, total, h.hexdigest()


def main() -> int:
    env = load_env(ENV_PATH)
    cf_env = {
        "CLOUDFLARE_API_TOKEN": env["API_TOKEN_WANGLER"],
        "CLOUDFLARE_ACCOUNT_ID": env["ID_ACOUNT_WANGLER"],
    }
    parsed_sb = urllib.parse.urlparse(env["API_URL"].strip())
    sb_base = f"{parsed_sb.scheme}://{parsed_sb.netloc}"
    sb_anon = env["anon_public"]

    version = (REPO_ROOT / "VERSION").read_text(encoding="utf-8").strip()
    commit_full = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=str(REPO_ROOT), text=True).strip()
    commit_short = commit_full[:8]
    built_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    build_prefix = f"builds/v{version}-{commit_short}"

    apk_path = REPO_ROOT / "build" / "android" / "dr7-studio-debug.apk"
    ipa_path = REPO_ROOT / "build" / "ios" / "dr7-studio-unsigned.ipa"
    web_dir = REPO_ROOT / "build" / "web"
    for req_p in (apk_path, ipa_path, web_dir / "index.html", web_dir / "index.wasm", web_dir / "index.pck"):
        if not req_p.is_file():
            print(f"[FAIL] Missing build artifact: {req_p}", file=sys.stderr)
            return 1

    # 1. Ensure R2 bucket exists
    print(f"[deploy] Ensuring R2 bucket '{BUCKET_NAME}' exists...")
    r_create = run_wrangler(["r2", "bucket", "create", BUCKET_NAME], cf_env)
    if r_create.returncode != 0 and "already exists" not in (r_create.stderr + r_create.stdout).lower():
        print(f"[FAIL] Cannot create R2 bucket: {r_create.stderr or r_create.stdout}", file=sys.stderr)
        return 1
    print(f"[OK] R2 bucket '{BUCKET_NAME}' ready.")

    # 2. Upload artifacts FIRST under versioned prefix
    apk_sha = sha256_file(apk_path)
    ipa_sha = sha256_file(ipa_path)
    pck_sha = sha256_file(web_dir / "index.pck")
    wasm_sha = sha256_file(web_dir / "index.wasm")

    apk_key = f"{build_prefix}/dr7-studio-debug.apk"
    ipa_key = f"{build_prefix}/dr7-studio-unsigned.ipa"
    web_prefix = f"{build_prefix}/web"

    print(f"[deploy] Uploading APK ({apk_path.stat().st_size} B) to R2: {apk_key}")
    upload_r2_file(apk_key, apk_path, "application/vnd.android.package-archive", cf_env)

    print(f"[deploy] Uploading unsigned IPA ({ipa_path.stat().st_size} B) to R2: {ipa_key}")
    upload_r2_file(ipa_key, ipa_path, "application/octet-stream", cf_env)

    web_files = sorted(p for p in web_dir.iterdir() if p.is_file())
    print(f"[deploy] Uploading {len(web_files)} Godot Web files to R2: {web_prefix}/...")
    web_manifest_files = {}
    for wf in web_files:
        wkey = f"{web_prefix}/{wf.name}"
        upload_r2_file(wkey, wf, mime_for(wf.name), cf_env)
        web_manifest_files[wf.name] = {
            "bytes": wf.stat().st_size,
            "sha256": sha256_file(wf),
        }

    # 3. Upload manifest.json LAST so links switch atomically
    stage_sha = sha256_file(REPO_ROOT / "assets" / "maps" / "rocky_plateau" / "arena-stage.json")
    manifest = {
        "schema": "dr7.alpha_manifest.v1",
        "version": version,
        "commit": commit_full,
        "commit_short": commit_short,
        "built_at_utc": built_at,
        "arena_stage_sha256": stage_sha,
        "artifacts": {
            "apk": {
                "r2_key": apk_key,
                "bytes": apk_path.stat().st_size,
                "sha256": apk_sha,
                "signed": True,
                "signing_type": "android_debug",
            },
            "ipa": {
                "r2_key": ipa_key,
                "bytes": ipa_path.stat().st_size,
                "sha256": ipa_sha,
                "signed": False,
                "signing_type": "unsigned_pending_signing",
            },
            "web": {
                "r2_prefix": web_prefix,
                "pck_bytes": (web_dir / "index.pck").stat().st_size,
                "pck_sha256": pck_sha,
                "wasm_bytes": (web_dir / "index.wasm").stat().st_size,
                "wasm_sha256": wasm_sha,
                "files": web_manifest_files,
            },
        },
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as tf:
        json.dump(manifest, tf, indent=2)
        tmp_manifest = pathlib.Path(tf.name)
    try:
        upload_r2_file("manifest.json", tmp_manifest, "application/json; charset=utf-8", cf_env)
        upload_r2_file(f"{build_prefix}/manifest.json", tmp_manifest, "application/json; charset=utf-8", cf_env)
    finally:
        tmp_manifest.unlink(missing_ok=True)
    print("[OK] Uploaded manifest.json atomically to R2.")

    # 4. Deploy Worker first (creates script if new), then set secrets
    print("[deploy] Deploying Cloudflare Worker 'dr7-alpha-staging'...")
    r_dep = run_wrangler(["deploy"], cf_env)
    if r_dep.returncode != 0:
        print(f"[FAIL] wrangler deploy failed:\n{r_dep.stdout}\n{r_dep.stderr}", file=sys.stderr)
        return 1
    print("[OK] Worker deployed.")

    for sec_name, sec_val in (("SUPABASE_URL", sb_base), ("SUPABASE_ANON_KEY", sb_anon)):
        r_sec = run_wrangler(["secret", "put", sec_name], cf_env, stdin_text=sec_val + "\n")
        if r_sec.returncode != 0:
            print(f"[FAIL] wrangler secret put {sec_name} failed: {r_sec.stderr}", file=sys.stderr)
            return 1
        print(f"[OK] Worker secret '{sec_name}' configured.")

    # 5. Live post-deploy verification: health + manifest + real downloads SHA-256 + real login API
    print("[verify] Checking live staging endpoints & downloading real binaries to compare SHA-256...")
    ua_headers = {"User-Agent": "DR7-Alpha-Verifier/1.0"}
    with urllib.request.urlopen(urllib.request.Request(f"{STAGING_URL}/api/health", headers=ua_headers), timeout=20) as r:
        health = json.loads(r.read().decode("utf-8"))
    assert health.get("ok") and health.get("r2_ready") and health.get("supabase_configured"), f"Bad health: {health}"
    print(f"[OK] /api/health: {health}")

    for label, url, expected_sha, expected_bytes in [
        ("APK", f"{STAGING_URL}/download/apk", apk_sha, apk_path.stat().st_size),
        ("IPA(unsigned)", f"{STAGING_URL}/download/ipa", ipa_sha, ipa_path.stat().st_size),
        ("Web PCK", f"{STAGING_URL}/play/index.pck", pck_sha, (web_dir / "index.pck").stat().st_size),
        ("Web WASM", f"{STAGING_URL}/play/index.wasm", wasm_sha, (web_dir / "index.wasm").stat().st_size),
    ]:
        st, got_bytes, got_sha = download_and_sha256(url)
        if st != 200 or got_bytes != expected_bytes or got_sha != expected_sha:
            print(
                f"[FAIL] {label} live download mismatch! status={st} bytes={got_bytes}/{expected_bytes} sha={got_sha}/{expected_sha}",
                file=sys.stderr,
            )
            return 1
        print(f"[OK] Live download verified {label}: {got_bytes} B | SHA-256={got_sha}")

    # Verify live /api/alpha/login for both users + wrong password
    for uname, env_key, expect_name in (("vinhadmin", "USER_1", "Vinh"), ("thaiadmin", "USER_2", "Thái")):
        raw_v = env[env_key]
        prefix = f"{uname}_"
        pwd = raw_v[len(prefix):] if raw_v.lower().startswith(prefix.lower()) else raw_v
        req = urllib.request.Request(
            f"{STAGING_URL}/api/alpha/login",
            data=json.dumps({"username": uname, "password": pwd}).encode("utf-8"),
            headers={"Content-Type": "application/json", "User-Agent": "DR7-Alpha-Verifier/1.0"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=20) as r:
            body = json.loads(r.read().decode("utf-8"))
        assert body.get("display_name") == expect_name and body.get("character_id") == "drum" and body.get("access_token"), f"Login mismatch for {uname}"
        print(f"[OK] Live /api/alpha/login verified: {uname} -> display_name={body['display_name']} character_id={body['character_id']}")

    bad_req = urllib.request.Request(
        f"{STAGING_URL}/api/alpha/login",
        data=json.dumps({"username": "vinhadmin", "password": "wrong-password-test"}).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": "DR7-Alpha-Verifier/1.0"},
        method="POST",
    )
    try:
        urllib.request.urlopen(bad_req, timeout=20)
        print("[FAIL] Live /api/alpha/login accepted wrong password!", file=sys.stderr)
        return 1
    except urllib.error.HTTPError as exc:
        if exc.code != 401:
            print(f"[FAIL] Expected 401 for wrong password, got {exc.code}", file=sys.stderr)
            return 1
        print("[OK] Live /api/alpha/login rejected wrong password with HTTP 401")

    print(f"\n[DONE] Alpha Staging LIVE at: {STAGING_URL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
