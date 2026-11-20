extends SceneTree
## Phase 3 Real Two-Client End-to-End Integration Test against the REAL Godot 4.7.2 Headless Server.
## Verifies:
## 1. Invalid token rejected (auth_error).
## 2. Two real WebSocket clients ("Vinh" & "Thái", both Drum) authenticate and see each other in Zone 0.
## 3. Player intent sync (Vinh moves & faces Thái -> Thái receives updated coordinates).
## 4. Authoritative PvP combat (Vinh attack_light hits Thái: -200 HP, +20 Mana) & PvE combat (Thái hits g0).
## 5. Zone switch (Thái switches 0 -> 1 -> 0 with server confirmation & zone_leave).
## 6. Disconnect & reconnect without tick rollback.

const WebSocketTransportScript := preload("res://scenes/net/WebSocketTransport.gd")
const ZoneClientSyncScript := preload("res://scenes/net/ZoneClientSync.gd")

const TEST_PORT := 18788
const TEST_SECRET := "dr7-headless-ci-test-secret-only"

var _server_pid: int = -1


func fail(msg: String) -> void:
	printerr("[FAIL] " + msg)
	_stop_server()
	quit(1)


func _stop_server() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		_server_pid = -1


func _make_signed_token(claims: Dictionary) -> String:
	var raw_json := JSON.stringify(claims)
	var b64 := Marshalls.utf8_to_base64(raw_json).replace("+", "-").replace("/", "_").trim_suffix("=")
	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, TEST_SECRET.to_utf8_buffer())
	ctx.update(b64.to_utf8_buffer())
	var sig := ctx.finish().hex_encode()
	return b64 + "." + sig


func _pump(transports: Array, frames: int = 12, sleep_ms: int = 15) -> void:
	for _i in range(frames):
		for t in transports:
			t.poll_events()
		OS.delay_msec(sleep_ms)


func _init() -> void:
	call_deferred("run_test")


func run_test() -> void:
	var godot_exe := OS.get_executable_path()
	var proj_path := ProjectSettings.globalize_path("res://")
	_server_pid = OS.create_process(godot_exe, PackedStringArray([
		"--headless",
		"--path", proj_path,
		"--script", "res://server/headless_zone_server.gd",
		"--",
		"--host", "127.0.0.1",
		"--port", str(TEST_PORT),
		"--secret", TEST_SECRET,
	]))
	if _server_pid <= 0:
		fail("Failed to launch Godot Headless Zone Server process")
		return

	# Wait briefly for headless server to bind port
	OS.delay_msec(800)
	var ws_url := "ws://127.0.0.1:%d/ws" % TEST_PORT

	# 1. Invalid token must be rejected
	var bad_ws = WebSocketTransportScript.new()
	var bad_sync = ZoneClientSyncScript.new()
	bad_sync.attach_transport(bad_ws)
	var bad_rejected := {"flag": false}
	bad_sync.session_rejected.connect(func(_r: String) -> void: bad_rejected["flag"] = true)
	bad_ws.connect_to_zone(ws_url, "rocky_plateau", 0, "forged.token")
	for _w in range(40):
		bad_ws.poll_events()
		if bad_rejected["flag"]:
			break
		OS.delay_msec(25)
	if not bad_rejected["flag"] or bad_sync.session_authenticated:
		fail("Server must reject invalid token with auth_error")
		return
	bad_ws.close_connection("done")

	# 2. Connect TWO real clients: Vinh and Thái (both Drum)
	var tok_vinh := _make_signed_token({"user_id": "uid-vinh", "display_name": "Vinh", "character_id": "drum", "spawn_x": 560.0})
	var tok_thai := _make_signed_token({"user_id": "uid-thai", "display_name": "Thái", "character_id": "drum", "spawn_x": 720.0})

	var ws_vinh = WebSocketTransportScript.new()
	var sync_vinh = ZoneClientSyncScript.new()
	sync_vinh.attach_transport(ws_vinh)

	var ws_thai = WebSocketTransportScript.new()
	var sync_thai = ZoneClientSyncScript.new()
	sync_thai.attach_transport(ws_thai)

	var combat_events_thai: Array[Dictionary] = []
	sync_thai.combat_event_received.connect(func(ev: Dictionary) -> void: combat_events_thai.append(ev))

	ws_vinh.connect_to_zone(ws_url, "rocky_plateau", 0, tok_vinh)
	ws_thai.connect_to_zone(ws_url, "rocky_plateau", 0, tok_thai)

	for _w2 in range(60):
		ws_vinh.poll_events()
		ws_thai.poll_events()
		if sync_vinh.is_ready_to_play() and sync_thai.is_ready_to_play() \
				and sync_vinh.players_by_id.has("uid-thai") and sync_thai.players_by_id.has("uid-vinh"):
			break
		OS.delay_msec(25)

	if not (sync_vinh.is_ready_to_play() and sync_thai.is_ready_to_play()):
		fail("Both Vinh and Thái must reach ready state on real Godot Headless Server")
		return
	if not sync_vinh.players_by_id.has("uid-thai") or not sync_thai.players_by_id.has("uid-vinh"):
		fail("Vinh and Thái must see each other in Zone 0 snapshot")
		return
	if str(sync_vinh.players_by_id["uid-thai"].get("display_name", "")) != "Thái" or str(sync_thai.players_by_id["uid-vinh"].get("display_name", "")) != "Vinh":
		fail("Display names must match 'Vinh' and 'Thái'")
		return

	# 3. Intent sync: Vinh moves toward Thái (x=660)
	sync_vinh.send_player_intent(Vector2(660.0, 840.0), 1, "walk", false)
	_pump([ws_vinh, ws_thai], 16, 20)
	var vinh_seen_by_thai: Dictionary = sync_thai.players_by_id.get("uid-vinh", {})
	if absf(float(vinh_seen_by_thai.get("x", 0.0)) - 660.0) > 2.0:
		fail("Thái must receive Vinh's moved x=660 from server, got %s" % str(vinh_seen_by_thai.get("x")))
		return

	# 4. Authoritative PvP (Vinh hits Thái with attack_light -> -200 HP, +20 Mana) & PvE (Thái hits g0 -> -200 HP)
	sync_vinh.send_combat_action("attack_light", "uid-thai", "player", Vector2(660.0, 840.0), false)
	sync_thai.send_combat_action("attack_light", "g0", "monster", Vector2(720.0, 840.0), true)
	_pump([ws_vinh, ws_thai], 16, 20)
	if absf(float(sync_thai.players_by_id["uid-thai"].get("hp", 0.0)) - 1300.0) > 0.5:
		fail("Authoritative PvP hit must reduce Thái HP to 1300, got %s" % str(sync_thai.players_by_id["uid-thai"].get("hp")))
		return
	if absf(float(sync_vinh.players_by_id["uid-vinh"].get("mana", 0.0)) - 20.0) > 0.5:
		fail("Authoritative PvP hit must grant Vinh +20 Mana, got %s" % str(sync_vinh.players_by_id["uid-vinh"].get("mana")))
		return
	if absf(float(sync_vinh.monsters_by_id["g0"].get("hp", 0.0)) - 1100.0) > 0.5:
		fail("Both clients must see authoritative PvE monster g0 (chilopoda 1300->1100) HP=1100, got %s" % str(sync_vinh.monsters_by_id["g0"].get("hp")))
		return
	if combat_events_thai.is_empty():
		fail("Thái must receive broadcast combat_event from server")
		return

	# 5. Zone switch: Thái moves from Zone 0 -> Zone 1 -> Zone 0
	sync_thai.request_zone_switch("rocky_plateau", 1)
	_pump([ws_vinh, ws_thai], 18, 20)
	if sync_thai.current_zone_id != 1 or sync_vinh.players_by_id.has("uid-thai"):
		fail("After Thái switches to Zone 1, Thái must be in Zone 1 and removed from Vinh's Zone 0")
		return
	sync_thai.request_zone_switch("rocky_plateau", 0)
	_pump([ws_vinh, ws_thai], 18, 20)
	if sync_thai.current_zone_id != 0 or not sync_vinh.players_by_id.has("uid-thai"):
		fail("After Thái switches back to Zone 0, Vinh must see Thái again")
		return

	# 6. Disconnect & reconnect without tick rollback
	var tick_before_dc: int = sync_thai.last_snapshot_tick
	ws_thai.close_connection("simulate_drop")
	_pump([ws_vinh, ws_thai], 10, 20)
	ws_thai.connect_to_zone(ws_url, "rocky_plateau", 0, tok_thai)
	for _w3 in range(50):
		ws_vinh.poll_events()
		ws_thai.poll_events()
		if sync_thai.is_ready_to_play() and sync_thai.last_snapshot_tick > tick_before_dc:
			break
		OS.delay_msec(25)
	if not sync_thai.is_ready_to_play() or sync_thai.last_snapshot_tick <= tick_before_dc:
		fail("Reconnect must resume monotonically without tick rollback (before=%d after=%d)" % [tick_before_dc, sync_thai.last_snapshot_tick])
		return

	ws_vinh.close_connection("test_done")
	ws_thai.close_connection("test_done")
	_stop_server()
	print("[OK] Real Godot 4.7.2 Headless Server 2-Client E2E (Vinh & Thái Drum, PvP, PvE, Zone Switch, Reconnect) PASSED!")
	quit(0)
