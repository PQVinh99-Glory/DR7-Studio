/**
 * DR7-Studio Alpha Staging Worker (Cloudflare Workers Free + Private R2 Bucket + Free SQLite Durable Object Relay).
 * - Serves all large artifacts (>25 MiB APK, IPA, WASM, PCK) from R2 via manifest.json.
 * - Authenticates alpha test admin users (vinhadmin -> Vinh, thaiadmin -> Thái) against real Supabase Auth.
 * - /ws routes to GODOT_WS_ORIGIN (real Godot 4.7.2 Headless Server) when configured, otherwise uses
 *   ZoneRoomDO (transparently labeled "cloudflare_do_staging_relay" in /api/health) so Vinh & Thái can
 *   test real-time 2-Drum multiplayer (PvP + PvE + zone switch) over Internet at 0d immediately.
 */

const ALPHA_USERS = {
  vinhadmin: {
    email: "vinhadmin@dr7-alpha.local",
    display_name: "Vinh",
    character_id: "drum",
    spawn_x: 560.0,
  },
  thaiadmin: {
    email: "thaiadmin@dr7-alpha.local",
    display_name: "Thái",
    character_id: "drum",
    spawn_x: 760.0,
  },
};

const MIME_BY_EXT = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".json": "application/json; charset=utf-8",
  ".ico": "image/x-icon",
};

const DEFAULT_MONSTERS = [
  { id: "g0", character_id: "chilopoda", hp: 1300, x: 330, y: 840, zmin: -103, zmax: 766 },
  { id: "g1", character_id: "spinosaurus", hp: 1500, x: 1160, y: 840, zmin: 730, zmax: 1590 },
  { id: "g2", character_id: "tasmanian_king_crab", hp: 1300, x: 1990, y: 840, zmin: 1560, zmax: 2430 },
  { id: "g3", character_id: "t_rex", hp: 1800, x: 3270, y: 890, zmin: 2900, zmax: 3640 },
  { id: "g4", character_id: "sarcosuchus", hp: 1500, x: 4125, y: 945, zmin: 3750, zmax: 4490 },
  { id: "g5", character_id: "dilophosaurus", hp: 1300, x: 5180, y: 975, zmin: 4790, zmax: 5500 },
  { id: "g6", character_id: "spinosaurus", hp: 1500, x: 5960, y: 1030, zmin: 5610, zmax: 6310 },
  { id: "f0", character_id: "bat_chiroptera", hp: 900, x: 330, y: 240, zmin: -190, zmax: 855 },
  { id: "f1", character_id: "pteranodon", hp: 1000, x: 1160, y: 240, zmin: 635, zmax: 1685 },
  { id: "f2", character_id: "floating_camera", hp: 800, x: 1990, y: 240, zmin: 1465, zmax: 2515 },
  { id: "f3", character_id: "bat_chiroptera", hp: 900, x: 3270, y: 260, zmin: 2745, zmax: 3795 },
  { id: "f4", character_id: "pteranodon", hp: 1000, x: 4125, y: 280, zmin: 3600, zmax: 4540 },
  { id: "f5", character_id: "floating_camera", hp: 800, x: 5180, y: 300, zmin: 4740, zmax: 5560 },
  { id: "f6", character_id: "bat_chiroptera", hp: 900, x: 5960, y: 320, zmin: 5560, zmax: 6360 },
];

const DAMAGE_TABLE = {
  attack_light: 200,
  attack_heavy: 320,
  power_up: 400,
};

const RATE_LIMIT_MAP = new Map();

function corsHeaders(extra = {}) {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, HEAD, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    ...extra,
  };
}

function jsonResp(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: corsHeaders({
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders,
    }),
  });
}

function formatMiB(bytes) {
  return `${(Number(bytes || 0) / (1024 * 1024)).toFixed(2)} MiB`;
}

function getMime(path) {
  const lower = path.toLowerCase();
  for (const [ext, mime] of Object.entries(MIME_BY_EXT)) {
    if (lower.endsWith(ext)) return mime;
  }
  return "application/octet-stream";
}

function checkRateLimit(ip) {
  const now = Date.now();
  const windowMs = 60_000;
  const maxAttempts = 30;
  const prev = (RATE_LIMIT_MAP.get(ip) || []).filter((ts) => now - ts < windowMs);
  if (prev.length >= maxAttempts) {
    RATE_LIMIT_MAP.set(ip, prev);
    return false;
  }
  prev.push(now);
  RATE_LIMIT_MAP.set(ip, prev);
  return true;
}

async function readManifest(env) {
  const obj = await env.ARTIFACTS.get("manifest.json");
  if (!obj) return null;
  try {
    return await obj.json();
  } catch {
    return null;
  }
}

const SW_SELF_PURGE_JS = `// DR7-Studio Staging Service Worker Cleanup:
// Immediately replace any stale Godot PWA cache-first SW, wipe all CacheStorage entries,
// unregister itself, and reload controlled windows so /play/ always loads the latest R2 build.
self.addEventListener("install", () => {
  self.skipWaiting();
});
self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
    } catch {}
    try {
      await self.clients.claim();
      const clients = await self.clients.matchAll({ type: "window" });
      for (const c of clients) {
        try { c.postMessage({ type: "DR7_SW_PURGED" }); } catch {}
        try { if (c.navigate) c.navigate(c.url); } catch {}
      }
    } catch {}
    try {
      await self.registration.unregister();
    } catch {}
  })());
});
self.addEventListener("fetch", (event) => {
  event.respondWith(fetch(event.request));
});
`;

const CLIENT_SW_CLEANUP_SNIPPET = `<script>
(function(){
  try {
    if ("caches" in window) {
      caches.keys().then(function(ks){ ks.forEach(function(k){ caches.delete(k); }); });
    }
    if ("serviceWorker" in navigator) {
      var hadCtrl = Boolean(navigator.serviceWorker.controller);
      navigator.serviceWorker.getRegistrations().then(function(regs){
        var hadAny = regs.length > 0;
        Promise.all(regs.map(function(r){ return r.unregister(); })).then(function(){
          if ((hadCtrl || hadAny) && !sessionStorage.getItem("dr7_sw_cleaned_once")) {
            sessionStorage.setItem("dr7_sw_cleaned_once", "1");
            location.reload();
          }
        });
      });
    }
  } catch(e) {}
})();
</script>`;

function renderPortalHtml(manifest, origin, wsBackend) {
  const ver = manifest?.version || "0.17.0";
  const commit = manifest?.commit_short || "unknown";
  const builtAt = manifest?.built_at_utc || "N/A";
  const apk = manifest?.artifacts?.apk || null;
  const ipa = manifest?.artifacts?.ipa || null;
  const web = manifest?.artifacts?.web || null;
  const apkTag = apk?.sha256 ? apk.sha256.slice(0, 12) : commit;
  const ipaTag = ipa?.sha256 ? ipa.sha256.slice(0, 12) : commit;
  const webTag = web?.pck_sha256 ? web.pck_sha256.slice(0, 12) : commit;

  const esc = (s) =>
    String(s ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;");

  const wsLabel =
    wsBackend === "godot_headless_origin"
      ? "Godot Headless Origin (Live)"
      : "Cloudflare DO Staging Relay (Live 0đ)";

  return `<!doctype html>
<html lang="vi">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>DR7-Studio Alpha Staging v${esc(ver)}</title>
  ${CLIENT_SW_CLEANUP_SNIPPET}
  <style>
    :root { --bg:#080d18; --card:#101828; --border:#2b3c58; --accent:#2bb8ff; --gold:#f5c443; --text:#eef4ff; --muted:#9fb0cc; }
    * { box-sizing:border-box; }
    body { margin:0; font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif; background:radial-gradient(circle at top,#13223b 0%,var(--bg) 62%); color:var(--text); min-height:100vh; padding:24px 16px 48px; }
    .wrap { max-width:860px; margin:0 auto; }
    .hero { background:var(--card); border:1px solid var(--border); border-radius:16px; padding:24px; margin-bottom:20px; box-shadow:0 14px 36px rgba(0,0,0,.35); }
    h1 { margin:0 0 8px; font-size:26px; letter-spacing:.2px; }
    .meta { color:var(--muted); font-size:14px; display:flex; flex-wrap:wrap; gap:12px; }
    .badge { display:inline-block; padding:3px 9px; border-radius:999px; font-size:12px; font-weight:600; border:1px solid var(--border); background:#0c1424; }
    .badge-warn { border-color:#d48c28; color:#ffd479; background:rgba(212,140,40,.14); }
    .badge-ok { border-color:#26a869; color:#7cf0b4; background:rgba(38,168,105,.14); }
    .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:16px; }
    .card { background:var(--card); border:1px solid var(--border); border-radius:14px; padding:20px; display:flex; flex-direction:column; gap:12px; }
    .card h2 { margin:0; font-size:19px; }
    .btn { display:inline-flex; align-items:center; justify-content:center; padding:12px 16px; border-radius:10px; font-weight:700; text-decoration:none; color:#04101d; background:linear-gradient(135deg,#3cd0ff,#1594e5); border:1px solid rgba(255,255,255,.35); }
    .btn-gold { background:linear-gradient(135deg,#ffd666,#e8a620); }
    .btn-muted { background:#1c2940; color:var(--text); border-color:var(--border); }
    .sha { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:11.5px; color:#b8cae8; word-break:break-all; background:#09101d; padding:8px 10px; border-radius:8px; border:1px solid #1d2b44; }
    .small { font-size:13px; color:var(--muted); line-height:1.5; }
    .foot { margin-top:20px; padding:16px 20px; border-radius:12px; background:rgba(16,24,40,.75); border:1px solid var(--border); font-size:13px; color:var(--muted); line-height:1.6; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="hero">
      <h1>DR7-Studio Alpha Staging — v${esc(ver)}</h1>
      <div class="meta">
        <span class="badge">Commit: ${esc(commit)}</span>
        <span class="badge">Build UTC: ${esc(builtAt)}</span>
        <span class="badge badge-ok">R2 Artifact Hosting (&gt;25 MiB safe)</span>
        <span class="badge badge-ok">WSS: ${esc(wsLabel)}</span>
      </div>
    </div>

    <div class="grid">
      <div class="card">
        <h2>Android APK (Redmi K70E)</h2>
        <div class="small">Build <code>arm64-v8a</code> cài trực tiếp trên K70E.<br/>
        Kích thước: <b>${apk ? `${esc(apk.bytes.toLocaleString("en-US"))} B (${formatMiB(apk.bytes)})` : "Chưa có"}</b></div>
        ${apk ? `<div class="sha">SHA-256: ${esc(apk.sha256)}</div><a class="btn btn-gold" href="/download/apk?v=${esc(apkTag)}">Tải Android APK (.apk)</a>` : `<span class="badge badge-warn">Chưa upload APK</span>`}
      </div>

      <div class="card">
        <h2>iOS IPA <span class="badge badge-warn">Unsigned — chờ ký</span></h2>
        <div class="small">Bản đóng gói đồng bộ PCK từ cùng mã nguồn (chưa ký Apple Cert; Owner đã hoãn bước ký).<br/>
        Kích thước: <b>${ipa ? `${esc(ipa.bytes.toLocaleString("en-US"))} B (${formatMiB(ipa.bytes)})` : "Chưa có"}</b></div>
        ${ipa ? `<div class="sha">SHA-256: ${esc(ipa.sha256)}</div><a class="btn btn-muted" href="/download/ipa?v=${esc(ipaTag)}">Tải iOS IPA Unsigned (.ipa)</a>` : `<span class="badge badge-warn">Chưa upload IPA</span>`}
      </div>

      <div class="card">
        <h2>Godot Web (Compatibility)</h2>
        <div class="small">Chạy trực tiếp bản export Godot 4.7.2 Web từ Cloudflare R2 (không bị giới hạn 25 MiB của Workers Static Assets).<br/>
        WASM: <b>${web?.wasm_bytes ? formatMiB(web.wasm_bytes) : "N/A"}</b> · PCK: <b>${web?.pck_bytes ? formatMiB(web.pck_bytes) : "N/A"}</b></div>
        ${web ? `<div class="sha">PCK SHA-256: ${esc(web.pck_sha256)}</div><a class="btn" href="/play/v/${esc(webTag)}/index.html">Mở Godot Web Staging</a>` : `<span class="badge badge-warn">Chưa upload Web</span>`}
      </div>
    </div>

    <div class="foot">
      <b>Trạng thái Alpha & Chính sách:</b><br/>
      • Tài khoản test nội bộ: <code>vinhadmin</code> (tên hiển thị <b>Vinh</b>) và <code>thaiadmin</code> (tên hiển thị <b>Thái</b>), mặc định tướng <b>Drum</b>. Hai tài khoản ngoại lệ này sẽ được gỡ trước khi thương mại hóa.<br/>
      • Chính sách chặn IP (JP 100% / chặn tải VN) <b>chưa bật</b> trong giai đoạn Alpha nội bộ chưa thương mại theo chỉ đạo Owner.<br/>
      • Kiểm chứng tự động: <a style="color:#69d2ff" href="/manifest.json">${esc(origin)}/manifest.json</a> · <a style="color:#69d2ff" href="/api/health">${esc(origin)}/api/health</a>
    </div>
  </div>
</body>
</html>`;
}

async function handleAlphaLogin(request, env, origin) {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }
  if (request.method !== "POST") {
    return jsonResp({ error: "method_not_allowed" }, 405);
  }
  const clientIp = request.headers.get("CF-Connecting-IP") || "unknown";
  if (!checkRateLimit(clientIp)) {
    return jsonResp({ error: "rate_limited", error_message: "Thử đăng nhập quá nhiều lần, vui lòng đợi 1 phút." }, 429);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResp({ error: "invalid_json", error_message: "Dữ liệu đăng nhập không hợp lệ." }, 400);
  }
  const username = String(body?.username || "").trim().toLowerCase();
  const password = String(body?.password || "");
  if (!username || !password) {
    return jsonResp({ error: "missing_fields", error_message: "Vui lòng nhập đầy đủ tên đăng nhập và mật khẩu." }, 400);
  }
  const userSpec = ALPHA_USERS[username];
  if (!userSpec) {
    return jsonResp({ error: "invalid_credentials", error_message: "Sai tên đăng nhập hoặc mật khẩu." }, 401);
  }
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) {
    return jsonResp({ error: "auth_not_configured", error_message: "Máy chủ xác thực chưa cấu hình Supabase." }, 503);
  }

  const sbResp = await fetch(`${env.SUPABASE_URL.replace(/\/+$/, "")}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: {
      apikey: env.SUPABASE_ANON_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      email: userSpec.email,
      password,
    }),
  });

  if (!sbResp.ok) {
    return jsonResp({ error: "invalid_credentials", error_message: "Sai tên đăng nhập hoặc mật khẩu." }, 401);
  }
  const sbData = await sbResp.json();
  const accessToken = String(sbData?.access_token || "");
  const userObj = sbData?.user || {};
  const userId = String(userObj?.id || "");
  if (!accessToken || !userId) {
    return jsonResp({ error: "auth_upstream_error", error_message: "Phản hồi xác thực Supabase thiếu token." }, 502);
  }

  const meta = userObj.user_metadata || {};
  const wsUrl = env.PUBLIC_WS_URL || `${origin.replace(/^https:/, "wss:").replace(/^http:/, "ws:")}/ws`;
  return jsonResp({
    access_token: accessToken,
    user_id: userId,
    username,
    display_name: String(meta.display_name || userSpec.display_name),
    character_id: String(meta.character_id || userSpec.character_id || "drum"),
    map_id: "rocky_plateau",
    zone_id: 0,
    spawn_x: Number(meta.spawn_x ?? userSpec.spawn_x ?? 560.0),
    ws_url: wsUrl,
  });
}

async function serveR2Object(env, key, opts = {}) {
  const isHead = opts.method === "HEAD";
  const obj = isHead ? await env.ARTIFACTS.head(key) : await env.ARTIFACTS.get(key);
  if (!obj) {
    return new Response("Artifact not found", { status: 404, headers: corsHeaders() });
  }
  const headers = new Headers(corsHeaders());
  headers.set("Content-Type", opts.contentType || obj.httpMetadata?.contentType || getMime(key));
  headers.set("Content-Length", String(obj.size));
  if (obj.httpEtag) headers.set("ETag", obj.httpEtag);
  headers.set("Cache-Control", opts.cacheControl || "no-store, no-cache, must-revalidate");
  if (opts.downloadName) {
    headers.set("Content-Disposition", `attachment; filename="${opts.downloadName}"`);
  }
  if (opts.sha256) headers.set("X-DR7-SHA256", opts.sha256);
  if (opts.extraHeaders) {
    for (const [k, v] of Object.entries(opts.extraHeaders)) headers.set(k, v);
  }
  return new Response(isHead ? null : obj.body, { status: 200, headers });
}

/**
 * Cloudflare Free SQLite Durable Object — Staging WebSocket Zone Relay.
 * Implements the exact same protocol as server/headless_zone_server.gd so Vinh & Thái
 * can log in, see each other as 2 Drums, interact PvP/PvE, and switch zones over Internet at 0d.
 */
export class ZoneRoomDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.zones = new Map(); // "map:zone" -> { map_id, zone_id, tick, players: Map, monsters: Map, sockets: Set }
    this.peers = new Map(); // ws -> peerInfo
  }

  _zoneKey(mapId, zoneId) {
    const z = Math.max(0, Math.min(19, Number(zoneId) | 0));
    return `${mapId || "rocky_plateau"}:${z}`;
  }

  _getZone(mapId, zoneId) {
    const m = mapId || "rocky_plateau";
    const zid = Math.max(0, Math.min(19, Number(zoneId) | 0));
    const key = this._zoneKey(m, zid);
    if (this.zones.has(key)) return this.zones.get(key);
    const monsters = new Map();
    for (const d of DEFAULT_MONSTERS) {
      monsters.set(d.id, {
        id: d.id,
        kind: "monster",
        character_id: d.character_id,
        x: d.x,
        y: d.y,
        zmin: d.zmin,
        zmax: d.zmax,
        hp: d.hp,
        max_hp: d.hp,
        alive: true,
        respawn_at: 0,
      });
    }
    const zObj = { key, map_id: m, zone_id: zid, tick: 0, players: new Map(), monsters, sockets: new Set() };
    this.zones.set(key, zObj);
    return zObj;
  }

  _send(ws, payload) {
    try {
      ws.send(JSON.stringify(payload));
    } catch {
      // ignore closed socket
    }
  }

  _broadcastZone(z, payload) {
    const raw = JSON.stringify(payload);
    for (const sock of z.sockets) {
      try {
        sock.send(raw);
      } catch {
        // ignore closed
      }
    }
  }

  _emitSnapshot(z) {
    const now = Date.now();
    for (const p of z.players.values()) {
      if (!p.alive && p.respawn_at > 0 && now >= p.respawn_at) {
        p.alive = true;
        p.hp = p.max_hp;
        p.x = 560;
        p.y = 840;
        p.act = "idle";
        p.respawn_at = 0;
      }
    }
    for (const m of z.monsters.values()) {
      if (!m.alive && m.respawn_at > 0 && now >= m.respawn_at) {
        m.alive = true;
        m.hp = m.max_hp;
        m.respawn_at = 0;
      }
    }
    z.tick += 1;
    const entities = [];
    for (const p of z.players.values()) entities.push({ ...p });
    for (const m of z.monsters.values()) entities.push({ ...m });
    this._broadcastZone(z, {
      op: "zone_snapshot",
      map_id: z.map_id,
      zone_id: z.zone_id,
      tick: z.tick,
      entities,
    });
  }

  async _verifySupabaseJwt(token) {
    if (!token || !this.env.SUPABASE_URL || !this.env.SUPABASE_ANON_KEY) return null;
    try {
      const resp = await fetch(`${this.env.SUPABASE_URL.replace(/\/+$/, "")}/auth/v1/user`, {
        method: "GET",
        headers: {
          apikey: this.env.SUPABASE_ANON_KEY,
          Authorization: `Bearer ${token}`,
        },
      });
      if (!resp.ok) return null;
      const u = await resp.json();
      if (!u?.id) return null;
      const meta = u.user_metadata || {};
      return {
        user_id: String(u.id),
        username: String(meta.username || u.email || ""),
        display_name: String(meta.display_name || "Player"),
        character_id: String(meta.character_id || "drum") || "drum",
        spawn_x: Number(meta.spawn_x ?? 560.0),
      };
    } catch {
      return null;
    }
  }

  _removePeer(ws) {
    const info = this.peers.get(ws);
    if (!info) return;
    if (info.zone_key && this.zones.has(info.zone_key)) {
      const z = this.zones.get(info.zone_key);
      z.sockets.delete(ws);
      if (info.user_id && z.players.has(info.user_id)) {
        z.players.delete(info.user_id);
        this._broadcastZone(z, {
          op: "zone_leave",
          map_id: z.map_id,
          zone_id: z.zone_id,
          id: info.user_id,
        });
      }
    }
    this.peers.delete(ws);
  }

  async _handleMessage(ws, raw) {
    let pkt;
    try {
      pkt = JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
    } catch {
      return;
    }
    if (!pkt || typeof pkt !== "object") return;
    const info = this.peers.get(ws);
    if (!info) return;
    const op = String(pkt.op || pkt.type || "");

    if (op === "auth") {
      if (info.authenticated) return;
      const token = String(pkt.token || "").trim();
      const claims = await this._verifySupabaseJwt(token);
      if (!claims) {
        this._send(ws, { op: "auth_error", reason: "invalid_supabase_jwt" });
        try { ws.close(4001, "invalid_supabase_jwt"); } catch {}
        return;
      }
      // Evict older duplicate socket for same user_id
      for (const [otherWs, otherInfo] of this.peers.entries()) {
        if (otherWs !== ws && otherInfo.user_id === claims.user_id) {
          this._removePeer(otherWs);
          try { otherWs.close(1000, "replaced_by_new_session"); } catch {}
        }
      }
      const mapId = String(pkt.map_id || "rocky_plateau").trim() || "rocky_plateau";
      const zoneId = Math.max(0, Math.min(19, Number(pkt.zone_id ?? 0) | 0));
      const z = this._getZone(mapId, zoneId);
      info.authenticated = true;
      info.user_id = claims.user_id;
      info.display_name = claims.display_name;
      info.character_id = claims.character_id;
      info.map_id = mapId;
      info.zone_id = zoneId;
      info.zone_key = z.key;
      z.sockets.add(ws);
      const sx = Math.max(-200, Math.min(6320, Number(claims.spawn_x || 560)));
      z.players.set(claims.user_id, {
        id: claims.user_id,
        kind: "player",
        display_name: claims.display_name,
        character_id: claims.character_id,
        x: sx,
        y: 840,
        facing_left: false,
        act: "idle",
        hp: 1500,
        max_hp: 1500,
        mana: 0,
        max_mana: 100,
        alive: true,
        respawn_at: 0,
      });
      this._send(ws, {
        op: "auth_ok",
        user_id: claims.user_id,
        display_name: claims.display_name,
        character_id: claims.character_id,
        map_id: mapId,
        zone_id: zoneId,
        spawn_x: sx,
        spawn_y: 840,
        ws_backend: "cloudflare_do_staging_relay",
      });
      this._emitSnapshot(z);
      return;
    }

    if (!info.authenticated) {
      this._send(ws, { op: "auth_error", reason: "not_authenticated" });
      return;
    }

    if (op === "join_zone") {
      const targetMap = String(pkt.map_id || "rocky_plateau").trim() || "rocky_plateau";
      const targetZone = Math.max(0, Math.min(19, Number(pkt.zone_id ?? 0) | 0));
      let preserved = null;
      if (info.zone_key && this.zones.has(info.zone_key)) {
        const oldZ = this.zones.get(info.zone_key);
        preserved = oldZ.players.get(info.user_id) || null;
        oldZ.players.delete(info.user_id);
        oldZ.sockets.delete(ws);
        this._broadcastZone(oldZ, { op: "zone_leave", map_id: oldZ.map_id, zone_id: oldZ.zone_id, id: info.user_id });
      }
      const newZ = this._getZone(targetMap, targetZone);
      info.map_id = targetMap;
      info.zone_id = targetZone;
      info.zone_key = newZ.key;
      newZ.sockets.add(ws);
      newZ.players.set(
        info.user_id,
        preserved || {
          id: info.user_id,
          kind: "player",
          display_name: info.display_name,
          character_id: info.character_id,
          x: 560,
          y: 840,
          facing_left: false,
          act: "idle",
          hp: 1500,
          max_hp: 1500,
          mana: 0,
          max_mana: 100,
          alive: true,
          respawn_at: 0,
        }
      );
      this._send(ws, { op: "zone_joined", map_id: targetMap, zone_id: targetZone });
      this._emitSnapshot(newZ);
      return;
    }

    const z = this.zones.get(info.zone_key);
    if (!z) return;
    const p = z.players.get(info.user_id);
    if (!p) return;

    if (op === "intent") {
      if (!p.alive) return;
      const rx = Math.max(-216, Math.min(6336, Number(pkt.x ?? p.x)));
      const ry = Math.max(40, Math.min(1060, Number(pkt.y ?? p.y)));
      p.x = Math.round(rx * 10) / 10;
      p.y = Math.round(ry * 10) / 10;
      p.facing_left = Boolean(pkt.facing_left ?? p.facing_left);
      const act = String(pkt.act || "idle");
      if (["idle", "walk", "run", "jump", "teleport", "attack_light", "attack_heavy", "power_up", "hit", "ko"].includes(act)) {
        p.act = act;
      }
      this._emitSnapshot(z);
      return;
    }

    if (op === "player_pve_state") {
      const dmg = Math.max(0, Math.min(250, Number(pkt.damage ?? 0)));
      const aliveReq = Boolean(pkt.alive ?? true);
      if (dmg > 0 && p.alive) {
        p.hp = Math.max(0, p.hp - dmg);
        if (p.hp <= 0 || !aliveReq) {
          p.hp = 0;
          p.alive = false;
          p.act = "ko";
          p.respawn_at = Date.now() + 3000;
        }
      } else if (aliveReq && !p.alive && Number(pkt.hp ?? 0) >= p.max_hp - 1) {
        p.alive = true;
        p.hp = p.max_hp;
        p.mana = 0;
        p.act = "idle";
        p.respawn_at = 0;
      }
      this._emitSnapshot(z);
      return;
    }

    if (op === "combat_action") {
      if (!p.alive) return;
      const action = String(pkt.action || "attack_light");
      const dmg = DAMAGE_TABLE[action];
      if (!dmg) return;
      const targetKind = String(pkt.target_kind || "player");
      const targetId = String(pkt.target_id || "").trim();
      if (!targetId || (targetKind === "player" && targetId === info.user_id)) return;
      const target = targetKind === "player" ? z.players.get(targetId) : z.monsters.get(targetId);
      if (!target || !target.alive) return;
      if (action === "power_up") {
        if (p.mana < 100) return;
        p.mana = 0;
      }
      if (targetKind === "monster") {
        const pad = action === "power_up" ? 1400 : 340;
        const px = Number(pkt.x ?? p.x ?? 0);
        if (px < (target.zmin ?? target.x) - pad || px > (target.zmax ?? target.x) + pad) return;
      } else {
        const dist = Math.hypot((p.x || 0) - (target.x || 0), (p.y || 0) - (target.y || 0));
        const maxRange = action === "power_up" ? 1400 : 280;
        if (dist > maxRange) return;
      }
      target.hp = Math.max(0, target.hp - dmg);
      if (action !== "power_up") p.mana = Math.min(p.max_mana, p.mana + 20);
      if (target.hp <= 0) {
        target.alive = false;
        target.respawn_at = Date.now() + (targetKind === "player" ? 3000 : 12000);
        if (targetKind === "player") target.act = "ko";
      }
      this._broadcastZone(z, {
        op: "combat_event",
        map_id: z.map_id,
        zone_id: z.zone_id,
        action,
        attacker_id: info.user_id,
        target_id: targetId,
        target_kind: targetKind,
        damage: dmg,
        target_hp: target.hp,
        target_alive: target.alive,
        attacker_mana: p.mana,
      });
      this._emitSnapshot(z);
    }
  }

  async fetch(request) {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket upgrade", { status: 426 });
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.accept();
    this.peers.set(server, {
      authenticated: false,
      user_id: "",
      display_name: "",
      character_id: "drum",
      map_id: "rocky_plateau",
      zone_id: 0,
      zone_key: "",
    });
    server.addEventListener("message", (evt) => {
      this._handleMessage(server, evt.data);
    });
    server.addEventListener("close", () => this._removePeer(server));
    server.addEventListener("error", () => this._removePeer(server));
    return new Response(null, { status: 101, webSocket: client });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;
    const origin = url.origin;
    const wsBackend = env.GODOT_WS_ORIGIN ? "godot_headless_origin" : "cloudflare_do_staging_relay";

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    if (path === "/api/alpha/login") {
      return handleAlphaLogin(request, env, origin);
    }

    if (path === "/api/health") {
      const manifest = await readManifest(env);
      return jsonResp({
        ok: true,
        service: "dr7-alpha-staging",
        version: manifest?.version || null,
        commit_short: manifest?.commit_short || null,
        r2_ready: Boolean(manifest),
        supabase_configured: Boolean(env.SUPABASE_URL && env.SUPABASE_ANON_KEY),
        ws_backend: wsBackend,
        godot_ws_origin_configured: Boolean(env.GODOT_WS_ORIGIN),
        geo_block_active: false,
      });
    }

    if (path === "/manifest.json") {
      const manifest = await readManifest(env);
      if (!manifest) return jsonResp({ error: "manifest_not_found" }, 404);
      return jsonResp(manifest, 200, { "Cache-Control": "no-store, no-cache, must-revalidate" });
    }

    if (path === "/ws") {
      if (env.GODOT_WS_ORIGIN) {
        const target = new URL(env.GODOT_WS_ORIGIN);
        target.search = url.search;
        return fetch(new Request(target.toString(), request));
      }
      const roomId = env.ZONE_ROOMS.idFromName("alpha-global-hub");
      const stub = env.ZONE_ROOMS.get(roomId);
      return stub.fetch(request);
    }

    if (path === "/" || path === "/index.html") {
      const manifest = await readManifest(env);
      return new Response(renderPortalHtml(manifest, origin, wsBackend), {
        status: 200,
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "no-store, no-cache, must-revalidate",
        },
      });
    }

    if (path === "/download/apk" || path === "/download/dr7-studio-debug.apk") {
      const manifest = await readManifest(env);
      const apk = manifest?.artifacts?.apk;
      if (!apk?.r2_key) return new Response("APK not available", { status: 404 });
      return serveR2Object(env, apk.r2_key, {
        method: request.method,
        contentType: "application/vnd.android.package-archive",
        downloadName: "dr7-studio-debug.apk",
        sha256: apk.sha256,
        extraHeaders: { "X-DR7-Build-Commit": manifest.commit_short || "" },
      });
    }

    if (path === "/download/ipa" || path === "/download/dr7-studio-unsigned.ipa") {
      const manifest = await readManifest(env);
      const ipa = manifest?.artifacts?.ipa;
      if (!ipa?.r2_key) return new Response("IPA not available", { status: 404 });
      return serveR2Object(env, ipa.r2_key, {
        method: request.method,
        contentType: "application/octet-stream",
        downloadName: "dr7-studio-unsigned.ipa",
        sha256: ipa.sha256,
        extraHeaders: {
          "X-DR7-Build-Commit": manifest.commit_short || "",
          "X-DR7-Signing-Status": "unsigned",
        },
      });
    }

    if (path === "/play" || path === "/play/") {
      const manifest = await readManifest(env);
      const webTag = manifest?.artifacts?.web?.pck_sha256 ? manifest.artifacts.web.pck_sha256.slice(0, 12) : "latest";
      return Response.redirect(`${origin}/play/v/${webTag}/index.html`, 302);
    }

    if (path.startsWith("/play/")) {
      const manifest = await readManifest(env);
      const webPrefix = manifest?.artifacts?.web?.r2_prefix;
      if (!webPrefix) return new Response("Godot Web build not available", { status: 404 });
      const pckSha = manifest?.artifacts?.web?.pck_sha256 || "";
      const webTag = pckSha ? pckSha.slice(0, 12) : "latest";
      let rel = path.slice("/play/".length);
      // Support cache-busted versioned namespace: /play/v/<pck_hash12>/<file>
      if (rel.startsWith("v/")) {
        const parts = rel.split("/");
        if (parts.length < 3 || !parts[1]) {
          return Response.redirect(`${origin}/play/v/${webTag}/index.html`, 302);
        }
        rel = parts.slice(2).join("/");
      }
      if (!rel || rel.includes("..") || rel.startsWith("/")) {
        return new Response("Invalid path", { status: 400 });
      }
      // Replace Godot's cache-first PWA service worker on staging with an immediate self-purging SW
      // so browsers with an older SW cached under /play/ immediately wipe stale index.pck caches.
      if (rel === "index.service.worker.js") {
        return new Response(request.method === "HEAD" ? null : SW_SELF_PURGE_JS, {
          status: 200,
          headers: corsHeaders({
            "Content-Type": "application/javascript; charset=utf-8",
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "X-DR7-PCK-SHA256": pckSha,
          }),
        });
      }
      if (rel === "index.html") {
        const obj = await env.ARTIFACTS.get(`${webPrefix}/index.html`);
        if (!obj) return new Response("Artifact not found", { status: 404, headers: corsHeaders() });
        let html = await obj.text();
        // Disable Godot PWA serviceWorker registration on staging & purge any old SW/CacheStorage
        html = html.replace('"serviceWorker":"index.service.worker.js"', '"serviceWorker":""');
        html = html.replace("</head>", `${CLIENT_SW_CLEANUP_SNIPPET}\n</head>`);
        return new Response(request.method === "HEAD" ? null : html, {
          status: 200,
          headers: corsHeaders({
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "X-DR7-PCK-SHA256": pckSha,
          }),
        });
      }
      return serveR2Object(env, `${webPrefix}/${rel}`, {
        method: request.method,
        contentType: getMime(rel),
        cacheControl: "no-store, no-cache, must-revalidate",
        extraHeaders: { "X-DR7-PCK-SHA256": pckSha },
      });
    }

    return new Response("Not Found", { status: 404 });
  },
};
