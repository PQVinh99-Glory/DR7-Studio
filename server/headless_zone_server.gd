extends SceneTree
## Phase 1 Authoritative Godot 4.7.2 Headless Dedicated WebSocket Server (ADR-0001).
## - Supports lazy 700-zone sharding (idle zones sleep at 0 CPU; active zones tick at 20Hz).
## - Loads exact Rocky Plateau bounds & 4 steps from assets/maps/rocky_plateau/arena-stage.json.
## - Verifies signed alpha session tokens (HMAC-SHA256) or Supabase JWT (/auth/v1/user).
## - Authoritatively simulates 2+ Drum players ("Vinh" & "Thái") + 14 zone monsters, PvP & PvE combat,
##   Mana enforcement, terrain LOS, zone switching, and monotonic snapshot ticks across reconnects.

const STAGE_JSON_PATH := "res://assets/maps/rocky_plateau/arena-stage.json"
const SNAPSHOT_INTERVAL_S := 0.05 # 20 Hz
const MAX_ZONES_PER_MAP := 20
const PLAYER_MAX_HP := 1500.0
const PLAYER_MAX_MANA := 100.0
const PLAYER_RESPAWN_S := 3.0
const MONSTER_RESPAWN_S := 12.0

const DAMAGE_TABLE := {
	"attack_light": 200.0,
	"attack_heavy": 320.0,
	"power_up": 400.0,
}

const DEFAULT_MONSTER_SLOTS := [
	{"id": "g0", "character_id": "chilopoda", "hp": 1300.0, "x": 330.0, "y": 840.0, "zmin": -103.0, "zmax": 766.0},
	{"id": "g1", "character_id": "spinosaurus", "hp": 1500.0, "x": 1160.0, "y": 840.0, "zmin": 730.0, "zmax": 1590.0},
	{"id": "g2", "character_id": "tasmanian_king_crab", "hp": 1300.0, "x": 1990.0, "y": 840.0, "zmin": 1560.0, "zmax": 2430.0},
	{"id": "g3", "character_id": "t_rex", "hp": 1800.0, "x": 3270.0, "y": 890.0, "zmin": 2900.0, "zmax": 3640.0},
	{"id": "g4", "character_id": "sarcosuchus", "hp": 1500.0, "x": 4125.0, "y": 945.0, "zmin": 3750.0, "zmax": 4490.0},
	{"id": "g5", "character_id": "dilophosaurus", "hp": 1300.0, "x": 5180.0, "y": 975.0, "zmin": 4790.0, "zmax": 5500.0},
	{"id": "g6", "character_id": "spinosaurus", "hp": 1500.0, "x": 5960.0, "y": 1030.0, "zmin": 5610.0, "zmax": 6310.0},
	{"id": "f0", "character_id": "bat_chiroptera", "hp": 900.0, "x": 330.0, "y": 240.0, "zmin": -190.0, "zmax": 855.0},
	{"id": "f1", "character_id": "pteranodon", "hp": 1000.0, "x": 1160.0, "y": 240.0, "zmin": 635.0, "zmax": 1685.0},
	{"id": "f2", "character_id": "floating_camera", "hp": 800.0, "x": 1990.0, "y": 240.0, "zmin": 1465.0, "zmax": 2515.0},
	{"id": "f3", "character_id": "bat_chiroptera", "hp": 900.0, "x": 3270.0, "y": 260.0, "zmin": 2745.0, "zmax": 3795.0},
	{"id": "f4", "character_id": "pteranodon", "hp": 1000.0, "x": 4125.0, "y": 280.0, "zmin": 3600.0, "zmax": 4540.0},
	{"id": "f5", "character_id": "floating_camera", "hp": 800.0, "x": 5180.0, "y": 300.0, "zmin": 4740.0, "zmax": 5560.0},
	{"id": "f6", "character_id": "bat_chiroptera", "hp": 900.0, "x": 5960.0, "y": 320.0, "zmin": 5560.0, "zmax": 6360.0},
]

var bind_host: String = "0.0.0.0"
var bind_port: int = 8788
var hmac_secret: String = ""
var supabase_url: String = ""
var supabase_anon_key: String = ""

var tcp_server: TCPServer = TCPServer.new()
var peers: Dictionary = {} # peer_id -> Dictionary
var next_peer_id: int = 1
var zones: Dictionary = {} # "map_id:zone_id" -> Dictionary
var _tick_accum_s: float = 0.0
var _last_usec: int = 0
var _stage_left_x: float = -240.0
var _stage_right_x: float = 6360.0
var _stage_ground_y: float = 840.0
var _stage_steps: Array[Dictionary] = []


func _init() -> void:
	_parse_args()
	_load_stage_geometry()
	var err := tcp_server.listen(bind_port, bind_host)
	if err != OK:
		printerr("[server][FAIL] Unable to listen on %s:%d (err=%d)" % [bind_host, bind_port, err])
		quit(1)
		return
	_last_usec = Time.get_ticks_usec()
	print("[server][OK] DR7-Studio Godot 4.7.2 Headless Zone Server listening on ws://%s:%d" % [bind_host, bind_port])


func _parse_args() -> void:
	hmac_secret = OS.get_environment("DR7_ALPHA_SESSION_SECRET")
	supabase_url = OS.get_environment("DR7_SUPABASE_URL").trim_suffix("/")
	supabase_anon_key = OS.get_environment("DR7_SUPABASE_ANON_KEY")
	var env_port := OS.get_environment("DR7_WS_PORT")
	if not env_port.is_empty() and env_port.is_valid_int():
		bind_port = int(env_port)
	var args := OS.get_cmdline_user_args()
	var all_args := OS.get_cmdline_args()
	var merged: PackedStringArray = all_args + args
	var i := 0
	while i < merged.size():
		var a := merged[i]
		if a == "--port" and i + 1 < merged.size() and merged[i + 1].is_valid_int():
			bind_port = int(merged[i + 1])
			i += 2
			continue
		elif a == "--host" and i + 1 < merged.size():
			bind_host = merged[i + 1]
			i += 2
			continue
		elif a == "--secret" and i + 1 < merged.size():
			hmac_secret = merged[i + 1]
			i += 2
			continue
		i += 1


func _load_stage_geometry() -> void:
	if not FileAccess.file_exists(STAGE_JSON_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(STAGE_JSON_PATH))
	if not (parsed is Dictionary):
		return
	var gp: Dictionary = parsed.get("gameplay", {})
	_stage_ground_y = float(gp.get("ground_y", 840.0))
	var ext: Dictionary = parsed.get("map", {}).get("extended_map", {})
	var wb: Dictionary = ext.get("world_bounds", {})
	_stage_left_x = float(wb.get("left_x", -240.0))
	_stage_right_x = float(wb.get("right_x", 6360.0))
	_stage_steps.clear()
	var prev_y := _stage_ground_y
	for st in ext.get("steps", []):
		if st is Dictionary:
			var lower_y := _stage_ground_y + float(st.get("drop_y", 0.0))
			_stage_steps.append({
				"drop_x": float(st.get("drop_x", 0.0)),
				"wall_x": float(st.get("wall_x", 0.0)),
				"upper_y": prev_y,
				"lower_y": lower_y,
			})
			prev_y = lower_y


func _terrain_surface_y_at(world_x: float) -> float:
	var prev_y := _stage_ground_y
	for spec in _stage_steps:
		var drop_x := float(spec["drop_x"])
		var wall_x := float(spec["wall_x"])
		var lower_y := float(spec["lower_y"])
		if world_x <= drop_x:
			return prev_y
		if world_x < wall_x and wall_x > drop_x:
			return lerpf(prev_y, lower_y, (world_x - drop_x) / (wall_x - drop_x))
		prev_y = lower_y
	return prev_y


func _terrain_blocks_segment(from_pos: Vector2, to_pos: Vector2) -> bool:
	if from_pos.y > _terrain_surface_y_at(from_pos.x) + 0.001:
		return true
	if to_pos.y >= _terrain_surface_y_at(to_pos.x):
		return true
	var dx := to_pos.x - from_pos.x
	if absf(dx) <= 0.0001:
		return maxf(from_pos.y, to_pos.y) >= _terrain_surface_y_at(from_pos.x)
	var min_sx := minf(from_pos.x, to_pos.x)
	var max_sx := maxf(from_pos.x, to_pos.x)
	for spec in _stage_steps:
		var drop_x := float(spec["drop_x"])
		var wall_x := float(spec["wall_x"])
		if drop_x > min_sx and drop_x < max_sx:
			if lerpf(from_pos.y, to_pos.y, (drop_x - from_pos.x) / dx) >= float(spec["upper_y"]):
				return true
		if wall_x > min_sx and wall_x < max_sx:
			if lerpf(from_pos.y, to_pos.y, (wall_x - from_pos.x) / dx) >= float(spec["lower_y"]):
				return true
	return false


func _zone_key(map_id: String, zone_id: int) -> String:
	return "%s:%d" % [map_id, clampi(zone_id, 0, MAX_ZONES_PER_MAP - 1)]


func _get_or_create_zone(map_id: String, zone_id: int) -> Dictionary:
	var zid := clampi(zone_id, 0, MAX_ZONES_PER_MAP - 1)
	var key := _zone_key(map_id, zid)
	if zones.has(key):
		return zones[key]
	var mons := {}
	for m in DEFAULT_MONSTER_SLOTS:
		var mid := str(m["id"])
		mons[mid] = {
			"id": mid,
			"kind": "monster",
			"character_id": str(m["character_id"]),
			"x": float(m["x"]),
			"y": float(m["y"]),
			"zmin": float(m.get("zmin", float(m["x"]) - 300.0)),
			"zmax": float(m.get("zmax", float(m["x"]) + 300.0)),
			"hp": float(m["hp"]),
			"max_hp": float(m["hp"]),
			"alive": true,
			"respawn_timer_s": 0.0,
		}
	var z := {
		"key": key,
		"map_id": map_id,
		"zone_id": zid,
		"tick": 0,
		"players": {}, # user_id -> player dict
		"monsters": mons,
		"peer_ids": [],
	}
	zones[key] = z
	return z


func _process(delta: float) -> bool:
	var now_usec := Time.get_ticks_usec()
	var dt := float(now_usec - _last_usec) / 1000000.0
	_last_usec = now_usec
	if dt <= 0.0 or dt > 0.25:
		dt = delta if delta > 0.0 else 0.016

	# 1. Accept incoming TCP connections and upgrade to WebSocketPeer
	while tcp_server.is_connection_available():
		var tcp := tcp_server.take_connection()
		if tcp != null:
			var ws := WebSocketPeer.new()
			var err := ws.accept_stream(tcp)
			if err == OK:
				var pid := next_peer_id
				next_peer_id += 1
				peers[pid] = {
					"peer_id": pid,
					"ws": ws,
					"authenticated": false,
					"auth_pending": false,
					"user_id": "",
					"display_name": "",
					"character_id": "drum",
					"map_id": "rocky_plateau",
					"zone_id": 0,
					"zone_key": "",
				}

	# 2. Poll all WebSocket peers
	var to_remove: Array[int] = []
	for pid_v in peers.keys():
		var pid: int = int(pid_v)
		var pinfo: Dictionary = peers[pid]
		var ws := pinfo["ws"] as WebSocketPeer
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			if pinfo.has("close_at_msec") and Time.get_ticks_msec() >= int(pinfo["close_at_msec"]):
				ws.close(4001, str(pinfo.get("close_reason", "auth_rejected")))
				continue
			while ws.get_available_packet_count() > 0:
				var raw := ws.get_packet().get_string_from_utf8()
				var parsed = JSON.parse_string(raw)
				if parsed is Dictionary:
					_handle_peer_packet(pid, parsed as Dictionary)
		elif st == WebSocketPeer.STATE_CLOSED:
			to_remove.append(pid)

	for rpid in to_remove:
		_disconnect_peer(rpid)

	# 3. Authoritative 20Hz tick ONLY for active zones (idle zones sleep at 0 CPU)
	_tick_accum_s += dt
	while _tick_accum_s >= SNAPSHOT_INTERVAL_S:
		_tick_accum_s -= SNAPSHOT_INTERVAL_S
		_step_active_zones(SNAPSHOT_INTERVAL_S)

	return false


func _send_to_peer(pid: int, payload: Dictionary) -> void:
	if not peers.has(pid):
		return
	var ws := peers[pid]["ws"] as WebSocketPeer
	if ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(payload))


func _broadcast_zone(z: Dictionary, payload: Dictionary) -> void:
	var txt := JSON.stringify(payload)
	for pid_v in z["peer_ids"]:
		var pid := int(pid_v)
		if peers.has(pid):
			var ws := peers[pid]["ws"] as WebSocketPeer
			if ws != null and ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
				ws.send_text(txt)


func _verify_hmac_token(token: String) -> Dictionary:
	if hmac_secret.is_empty():
		return {}
	var parts := token.split(".")
	if parts.size() != 2:
		return {}
	var payload_b64 := parts[0]
	var sig_hex := parts[1].to_lower()
	var ctx := HMACContext.new()
	if ctx.start(HashingContext.HASH_SHA256, hmac_secret.to_utf8_buffer()) != OK:
		return {}
	ctx.update(payload_b64.to_utf8_buffer())
	var expected_hex := ctx.finish().hex_encode().to_lower()
	if expected_hex != sig_hex:
		return {}
	var pad := payload_b64.replace("-", "+").replace("_", "/")
	while pad.length() % 4 != 0:
		pad += "="
	var raw_json := Marshalls.base64_to_utf8(pad)
	var parsed = JSON.parse_string(raw_json)
	if not (parsed is Dictionary):
		return {}
	var claims: Dictionary = parsed
	if claims.has("exp") and int(claims["exp"]) < int(Time.get_unix_time_from_system()):
		return {}
	return claims


func _verify_supabase_jwt_async(pid: int, token: String, req_map: String, req_zone: int) -> void:
	var req := HTTPRequest.new()
	req.timeout = 8.0
	root.add_child(req)
	req.request_completed.connect(func(result: int, code: int, _hdrs: PackedStringArray, body: PackedByteArray) -> void:
		req.queue_free()
		if not peers.has(pid):
			return
		peers[pid]["auth_pending"] = false
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			_reject_peer_auth(pid, "invalid_supabase_jwt")
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if not (parsed is Dictionary):
			_reject_peer_auth(pid, "invalid_supabase_user")
			return
		var udoc: Dictionary = parsed
		var uid := str(udoc.get("id", "")).strip_edges()
		if uid.is_empty():
			_reject_peer_auth(pid, "missing_user_id")
			return
		var umeta: Dictionary = udoc.get("user_metadata", {}) if udoc.get("user_metadata") is Dictionary else {}
		var claims := {
			"user_id": uid,
			"username": str(umeta.get("username", udoc.get("email", ""))),
			"display_name": str(umeta.get("display_name", "Player")),
			"character_id": str(umeta.get("character_id", "drum")),
			"spawn_x": float(umeta.get("spawn_x", 560.0)),
		}
		_complete_peer_auth(pid, claims, req_map, req_zone)
	)
	var headers := PackedStringArray([
		"apikey: " + supabase_anon_key,
		"Authorization: Bearer " + token,
	])
	var err := req.request(supabase_url + "/auth/v1/user", headers, HTTPClient.METHOD_GET)
	if err != OK:
		req.queue_free()
		if peers.has(pid):
			peers[pid]["auth_pending"] = false
		_reject_peer_auth(pid, "supabase_request_failed")


func _reject_peer_auth(pid: int, reason: String) -> void:
	_send_to_peer(pid, {"op": "auth_error", "reason": reason})
	if peers.has(pid):
		peers[pid]["close_at_msec"] = Time.get_ticks_msec() + 120
		peers[pid]["close_reason"] = reason


func _complete_peer_auth(pid: int, claims: Dictionary, req_map: String, req_zone: int) -> void:
	if not peers.has(pid):
		return
	var uid := str(claims.get("user_id", "")).strip_edges()
	var dname := str(claims.get("display_name", "Player")).strip_edges()
	var cid := str(claims.get("character_id", "drum")).strip_edges()
	if uid.is_empty():
		_reject_peer_auth(pid, "missing_user_id")
		return
	if cid.is_empty():
		cid = "drum"
	var map_id := req_map if not req_map.is_empty() else "rocky_plateau"
	var zone_id := clampi(req_zone, 0, MAX_ZONES_PER_MAP - 1)
	var spawn_x := clampf(float(claims.get("spawn_x", 560.0)), _stage_left_x + 40.0, _stage_right_x - 40.0)

	# Evict any older stale peer with the same user_id
	for other_pid_v in peers.keys():
		var other_pid := int(other_pid_v)
		if other_pid != pid and str(peers[other_pid].get("user_id", "")) == uid:
			_disconnect_peer(other_pid)

	var pinfo: Dictionary = peers[pid]
	pinfo["authenticated"] = true
	pinfo["user_id"] = uid
	pinfo["display_name"] = dname
	pinfo["character_id"] = cid
	pinfo["map_id"] = map_id
	pinfo["zone_id"] = zone_id

	var z := _get_or_create_zone(map_id, zone_id)
	pinfo["zone_key"] = str(z["key"])
	if not (pid in z["peer_ids"]):
		z["peer_ids"].append(pid)
	var spawn_y := _terrain_surface_y_at(spawn_x)
	z["players"][uid] = {
		"id": uid,
		"kind": "player",
		"display_name": dname,
		"character_id": cid,
		"x": spawn_x,
		"y": spawn_y,
		"facing_left": false,
		"act": "idle",
		"hp": PLAYER_MAX_HP,
		"max_hp": PLAYER_MAX_HP,
		"mana": 0.0,
		"max_mana": PLAYER_MAX_MANA,
		"alive": true,
		"respawn_timer_s": 0.0,
	}

	_send_to_peer(pid, {
		"op": "auth_ok",
		"user_id": uid,
		"display_name": dname,
		"character_id": cid,
		"map_id": map_id,
		"zone_id": zone_id,
		"spawn_x": spawn_x,
		"spawn_y": spawn_y,
	})
	_emit_zone_snapshot(z)


func _handle_peer_packet(pid: int, pkt: Dictionary) -> void:
	if not peers.has(pid):
		return
	var pinfo: Dictionary = peers[pid]
	var op := str(pkt.get("op", pkt.get("type", "")))

	if op == "auth":
		if bool(pinfo["authenticated"]) or bool(pinfo["auth_pending"]):
			return
		var token := str(pkt.get("token", "")).strip_edges()
		var req_map := str(pkt.get("map_id", "rocky_plateau")).strip_edges()
		var req_zone := clampi(int(pkt.get("zone_id", 0)), 0, MAX_ZONES_PER_MAP - 1)
		if token.is_empty():
			_reject_peer_auth(pid, "missing_token")
			return
		var hmac_claims := _verify_hmac_token(token)
		if not hmac_claims.is_empty():
			_complete_peer_auth(pid, hmac_claims, req_map, req_zone)
			return
		if not supabase_url.is_empty() and not supabase_anon_key.is_empty():
			pinfo["auth_pending"] = true
			_verify_supabase_jwt_async(pid, token, req_map, req_zone)
			return
		_reject_peer_auth(pid, "invalid_token")
		return

	if not bool(pinfo["authenticated"]):
		_reject_peer_auth(pid, "not_authenticated")
		return

	if op == "join_zone":
		var target_map := str(pkt.get("map_id", "rocky_plateau")).strip_edges()
		if target_map.is_empty():
			target_map = "rocky_plateau"
		var target_zone := clampi(int(pkt.get("zone_id", 0)), 0, MAX_ZONES_PER_MAP - 1)
		_switch_peer_zone(pid, target_map, target_zone)
		return

	var zkey := str(pinfo.get("zone_key", ""))
	if not zones.has(zkey):
		return
	var z: Dictionary = zones[zkey]
	var uid := str(pinfo["user_id"])
	if not z["players"].has(uid):
		return
	var pdata: Dictionary = z["players"][uid]

	if op == "intent":
		if not bool(pdata["alive"]):
			return
		var req_x := clampf(float(pkt.get("x", pdata["x"])), _stage_left_x + 24.0, _stage_right_x - 24.0)
		var max_y := _terrain_surface_y_at(req_x)
		var req_y := clampf(float(pkt.get("y", pdata["y"])), 40.0, max_y)
		# Authoritative speed/step clamp (prevents blatant teleport-hacking while allowing legit Drum teleport)
		var cur_pos := Vector2(float(pdata["x"]), float(pdata["y"]))
		var next_pos := Vector2(req_x, req_y)
		if cur_pos.distance_to(next_pos) > 420.0:
			next_pos = cur_pos + (next_pos - cur_pos).normalized() * 420.0
		pdata["x"] = snappedf(next_pos.x, 0.1)
		pdata["y"] = snappedf(next_pos.y, 0.1)
		pdata["facing_left"] = bool(pkt.get("facing_left", pdata["facing_left"]))
		var act := str(pkt.get("act", "idle"))
		if act in ["idle", "walk", "run", "jump", "teleport", "attack_light", "attack_heavy", "power_up", "hit", "ko"]:
			pdata["act"] = act
		return

	if op == "player_pve_state":
		var dmg := clampf(float(pkt.get("damage", 0.0)), 0.0, 250.0)
		var alive_req := bool(pkt.get("alive", true))
		if dmg > 0.0 and bool(pdata["alive"]):
			pdata["hp"] = maxf(0.0, float(pdata["hp"]) - dmg)
			if float(pdata["hp"]) <= 0.0 or not alive_req:
				pdata["hp"] = 0.0
				pdata["alive"] = false
				pdata["act"] = "ko"
				pdata["respawn_timer_s"] = PLAYER_RESPAWN_S
		elif alive_req and not bool(pdata["alive"]) and float(pkt.get("hp", 0.0)) >= float(pdata["max_hp"]) - 1.0:
			pdata["alive"] = true
			pdata["hp"] = float(pdata["max_hp"])
			pdata["mana"] = 0.0
			pdata["act"] = "idle"
			pdata["respawn_timer_s"] = 0.0
		_emit_zone_snapshot(z)
		return

	if op == "combat_action":
		_handle_combat_action(z, uid, pkt)
		return


func _handle_combat_action(z: Dictionary, attacker_id: String, pkt: Dictionary) -> void:
	if not z["players"].has(attacker_id):
		return
	var attacker: Dictionary = z["players"][attacker_id]
	if not bool(attacker.get("alive", false)):
		return
	var action := str(pkt.get("action", "attack_light"))
	if not DAMAGE_TABLE.has(action):
		return
	var target_kind := str(pkt.get("target_kind", "player"))
	var target_id := str(pkt.get("target_id", "")).strip_edges()
	if target_id.is_empty():
		return
	if target_kind == "player" and target_id == attacker_id:
		return

	var target: Dictionary = {}
	if target_kind == "player":
		if not z["players"].has(target_id):
			return
		target = z["players"][target_id]
	elif target_kind == "monster":
		if not z["monsters"].has(target_id):
			return
		target = z["monsters"][target_id]
	else:
		return
	if not bool(target.get("alive", false)):
		return

	# Authoritative Mana enforcement
	if action == "power_up":
		if float(attacker.get("mana", 0.0)) < 100.0:
			return
		attacker["mana"] = 0.0

	# Authoritative distance & continuous terrain LOS check
	var a_pos := Vector2(float(attacker["x"]), float(attacker["y"]) - 36.0)
	var t_pos := Vector2(float(target["x"]), float(target["y"]) - 36.0)
	if target_kind == "monster":
		var pad := 1400.0 if action == "power_up" else 340.0
		var px := float(pkt.get("x", attacker["x"]))
		if px < float(target.get("zmin", target["x"])) - pad or px > float(target.get("zmax", target["x"])) + pad:
			return
	else:
		var dist := a_pos.distance_to(t_pos)
		var max_range := 1400.0 if action == "power_up" else 260.0
		if dist > max_range:
			return
		if action == "power_up" and _terrain_blocks_segment(a_pos, t_pos):
			return

	var dmg := float(DAMAGE_TABLE[action])
	target["hp"] = maxf(0.0, float(target["hp"]) - dmg)
	if action != "power_up":
		attacker["mana"] = minf(PLAYER_MAX_MANA, float(attacker["mana"]) + 20.0)
	if float(target["hp"]) <= 0.0:
		target["alive"] = false
		target["respawn_timer_s"] = PLAYER_RESPAWN_S if target_kind == "player" else MONSTER_RESPAWN_S
		if target_kind == "player":
			target["act"] = "ko"

	_broadcast_zone(z, {
		"op": "combat_event",
		"map_id": z["map_id"],
		"zone_id": z["zone_id"],
		"action": action,
		"attacker_id": attacker_id,
		"target_id": target_id,
		"target_kind": target_kind,
		"damage": dmg,
		"target_hp": float(target["hp"]),
		"target_alive": bool(target["alive"]),
		"attacker_mana": float(attacker["mana"]),
	})
	_emit_zone_snapshot(z)


func _switch_peer_zone(pid: int, target_map: String, target_zone: int) -> void:
	var pinfo: Dictionary = peers[pid]
	var uid := str(pinfo["user_id"])
	var old_key := str(pinfo.get("zone_key", ""))
	var preserved_player: Dictionary = {}
	if zones.has(old_key):
		var old_z: Dictionary = zones[old_key]
		if old_z["players"].has(uid):
			preserved_player = old_z["players"][uid].duplicate(true)
			old_z["players"].erase(uid)
		old_z["peer_ids"].erase(pid)
		_broadcast_zone(old_z, {"op": "zone_leave", "map_id": old_z["map_id"], "zone_id": old_z["zone_id"], "id": uid})

	var new_z := _get_or_create_zone(target_map, target_zone)
	pinfo["map_id"] = target_map
	pinfo["zone_id"] = target_zone
	pinfo["zone_key"] = str(new_z["key"])
	if not (pid in new_z["peer_ids"]):
		new_z["peer_ids"].append(pid)
	if preserved_player.is_empty():
		preserved_player = {
			"id": uid,
			"kind": "player",
			"display_name": str(pinfo["display_name"]),
			"character_id": str(pinfo["character_id"]),
			"x": 560.0,
			"y": _terrain_surface_y_at(560.0),
			"facing_left": false,
			"act": "idle",
			"hp": PLAYER_MAX_HP,
			"max_hp": PLAYER_MAX_HP,
			"mana": 0.0,
			"max_mana": PLAYER_MAX_MANA,
			"alive": true,
			"respawn_timer_s": 0.0,
		}
	new_z["players"][uid] = preserved_player
	_send_to_peer(pid, {"op": "zone_joined", "map_id": target_map, "zone_id": target_zone})
	_emit_zone_snapshot(new_z)


func _disconnect_peer(pid: int) -> void:
	if not peers.has(pid):
		return
	var pinfo: Dictionary = peers[pid]
	var zkey := str(pinfo.get("zone_key", ""))
	var uid := str(pinfo.get("user_id", ""))
	if zones.has(zkey):
		var z: Dictionary = zones[zkey]
		z["peer_ids"].erase(pid)
		if not uid.is_empty() and z["players"].has(uid):
			z["players"].erase(uid)
			_broadcast_zone(z, {"op": "zone_leave", "map_id": z["map_id"], "zone_id": z["zone_id"], "id": uid})
	peers.erase(pid)


func _step_active_zones(dt: float) -> void:
	for z_val in zones.values():
		var z: Dictionary = z_val
		if (z["peer_ids"] as Array).is_empty():
			continue # Idle zone sleeps at 0 CPU
		# Step player respawns
		for p_val in z["players"].values():
			var p: Dictionary = p_val
			if not bool(p["alive"]):
				p["respawn_timer_s"] = maxf(0.0, float(p["respawn_timer_s"]) - dt)
				if float(p["respawn_timer_s"]) <= 0.0:
					p["alive"] = true
					p["hp"] = float(p["max_hp"])
					p["x"] = 560.0
					p["y"] = _terrain_surface_y_at(560.0)
					p["act"] = "idle"
		# Step monster respawns
		for m_val in z["monsters"].values():
			var m: Dictionary = m_val
			if not bool(m["alive"]):
				m["respawn_timer_s"] = maxf(0.0, float(m["respawn_timer_s"]) - dt)
				if float(m["respawn_timer_s"]) <= 0.0:
					m["alive"] = true
					m["hp"] = float(m["max_hp"])
		_emit_zone_snapshot(z)


func _emit_zone_snapshot(z: Dictionary) -> void:
	z["tick"] = int(z["tick"]) + 1
	var entities: Array[Dictionary] = []
	for p_val in z["players"].values():
		entities.append((p_val as Dictionary).duplicate(true))
	for m_val in z["monsters"].values():
		entities.append((m_val as Dictionary).duplicate(true))
	_broadcast_zone(z, {
		"op": "zone_snapshot",
		"map_id": z["map_id"],
		"zone_id": z["zone_id"],
		"tick": int(z["tick"]),
		"entities": entities,
	})
