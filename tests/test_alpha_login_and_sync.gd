extends SceneTree
## Phase 2 & 3 Headless Verification:
## - Boot splash config & LoginScreen cover-mode scaling (K70E / iPad / 16:9)
## - 7-Star Dragon Ball sequential loading (1..7->1) + timeout/retry
## - Strict Alpha Login Gate (wrong password, network failure, retry, logout, no bypass)
## - ZoneClientSync server-confirmed zone switches, schema validation, monotonic ticks
## - Two-player Drum ("Vinh" & "Thái") spawn & combat event sync

const AppStartupScene := preload("res://scenes/AppStartup.tscn")
const ZoneClientSyncScript := preload("res://scenes/net/ZoneClientSync.gd")
const WebSocketTransportScript := preload("res://scenes/net/WebSocketTransport.gd")


func fail(msg: String) -> void:
	printerr("[FAIL] " + msg)
	quit(1)


func _init() -> void:
	call_deferred("run_test")


func run_test() -> void:
	# 1. Verify project.godot startup + splash configuration
	if str(ProjectSettings.get_setting("application/run/main_scene", "")) != "res://scenes/AppStartup.tscn":
		fail("main_scene must be res://scenes/AppStartup.tscn")
		return
	if str(ProjectSettings.get_setting("application/boot_splash/image", "")) != "res://assets/app_icon/android_adaptive_fg_432.png":
		fail("boot_splash/image must point to res://assets/app_icon/android_adaptive_fg_432.png")
		return

	# 2. Instantiate AppStartup -> MUST stay at LOGIN (no Arena before auth+snapshot)
	var startup := AppStartupScene.instantiate()
	root.add_child(startup)
	await process_frame

	if startup.active_arena != null:
		fail("Alpha build must NEVER enter ArenaSandbox before valid login & server snapshot")
		return
	if startup.state != startup.StartupState.LOGIN:
		fail("AppStartup must reach LOGIN state in headless boot, got %s" % str(startup.state))
		return

	# 3. Verify LoginScreen background (734x413), uniform cover scaling on K70E/iPad/16:9, masked password
	var login_ui = startup.login_screen
	var bg_tex: Texture2D = login_ui.call("get_background_texture")
	if bg_tex == null or int(bg_tex.get_width()) != 734 or int(bg_tex.get_height()) != 413:
		fail("Login background must load login_bg.png (734x413)")
		return
	if login_ui.size.x < 1900.0 or login_ui.size.y < 1060.0:
		fail("LoginScreen Control size must fill viewport under CanvasLayer so _draw() renders background, got %s" % str(login_ui.size))
		return
	var panel_center_x: float = login_ui._panel_root.position.x + login_ui._panel_root.size.x * login_ui._panel_root.scale.x * 0.5
	if absf(panel_center_x - login_ui.size.x * 0.5) > 6.0:
		fail("Login panel must be centered horizontally (center_x=%.1f vs %.1f)" % [panel_center_x, login_ui.size.x * 0.5])
		return
	for vp_sz in [Vector2(2712, 1220), Vector2(2048, 1536), Vector2(1920, 1080)]:
		var cover: Rect2 = login_ui.call("compute_cover_rect", vp_sz, Vector2(734, 413))
		if cover.size.x < vp_sz.x - 0.5 or cover.size.y < vp_sz.y - 0.5:
			fail("Login background cover rect must fill entire viewport %s without black bars, got %s" % [str(vp_sz), str(cover)])
			return
		var src_ar := 734.0 / 413.0
		var dst_ar := cover.size.x / cover.size.y
		if absf(src_ar - dst_ar) > 0.005:
			fail("Login background cover rect must preserve uniform X/Y aspect ratio on %s" % str(vp_sz))
			return
	var pass_edit := login_ui.get_node_or_null("LoginPanelRoot/FormVBox/PasswordRow/PasswordInput") as LineEdit
	if pass_edit == null or not pass_edit.secret:
		fail("Password input must mask characters (secret=true)")
		return

	# 4. Verify 7-Star Dragon Ball loading sequence 1->2->...->7->1 + timeout error
	var overlay = startup.loading_overlay
	if int(overlay.call("get_ball_texture_count")) != 7:
		fail("DragonBallLoadingOverlay must load all 7 ball textures from dragon_balls.tres")
		return
	overlay.step_duration_s = 0.10
	overlay.call("start_loading", "Test loading...", 0.85)
	var seq: Array[int] = [int(overlay.active_ball_index)]
	for _i in range(7):
		overlay.call("step_loading", 0.10)
		seq.append(int(overlay.active_ball_index))
	if seq != [0, 1, 2, 3, 4, 5, 6, 0]:
		fail("DragonBallLoadingOverlay must light balls sequentially 0..6->0, got %s" % str(seq))
		return
	overlay.call("step_loading", 0.30)
	if not bool(overlay.error_active):
		fail("DragonBallLoadingOverlay must transition to error state with retry on timeout")
		return
	overlay.call("finish_success")

	# 5. Auth flow tests: wrong password, network error, retry, valid login -> WSS -> snapshot -> Arena -> Logout
	var mock_mode := {"mode": "wrong_pass"}
	startup.auth_client.call("set_custom_auth_handler", func(u: String, p: String) -> Dictionary:
		if mock_mode["mode"] == "wrong_pass":
			return {"status": 401, "body": {"error": "invalid_credentials", "error_message": "Sai mật khẩu"}}
		if mock_mode["mode"] == "net_err":
			return {"status": 503, "body": {"error": "unavailable", "error_message": "Mất mạng tạm thời"}}
		return {
			"status": 200,
			"body": {
				"access_token": "test-jwt-vinh",
				"user_id": "uid-vinh",
				"username": u,
				"display_name": "Vinh",
				"character_id": "drum",
				"map_id": "rocky_plateau",
				"zone_id": 0,
				"ws_url": "ws://127.0.0.1:19999/ws",
				"spawn_x": 560.0,
			},
		}
	)
	# (5a) Wrong password
	login_ui.call("submit_credentials_programmatic", "vinhadmin", "wrong")
	if startup.state != startup.StartupState.LOGIN or startup.active_arena != null:
		fail("Wrong password must stay on LOGIN and never open Arena")
		return
	# (5b) Network error
	mock_mode["mode"] = "net_err"
	login_ui.call("submit_credentials_programmatic", "vinhadmin", "any")
	if startup.state != startup.StartupState.LOGIN or startup.active_arena != null:
		fail("Server/network failure must stay on LOGIN and allow retry")
		return
	# (5c) Valid login -> stays in CONNECTING_WSS/AWAITING_SNAPSHOT until auth_ok + zone_snapshot
	mock_mode["mode"] = "ok"
	login_ui.call("submit_credentials_programmatic", "vinhadmin", "valid-local-test")
	if startup.active_arena != null:
		fail("Must NOT enter Arena before server confirms auth_ok and first zone_snapshot")
		return
	if startup.state != startup.StartupState.CONNECTING_WSS and startup.state != startup.StartupState.AWAITING_SNAPSHOT:
		fail("Expected CONNECTING_WSS/AWAITING_SNAPSHOT after valid auth, got %s" % str(startup.state))
		return
	# Simulate server auth_ok + first snapshot containing BOTH Vinh and Thái (2 Drums)
	startup.transport.connected.emit({"transport": "websocket", "map_id": "rocky_plateau", "zone_id": 0})
	startup.transport.is_connected_state = true
	startup.transport.packet_received.emit({
		"op": "auth_ok",
		"user_id": "uid-vinh",
		"display_name": "Vinh",
		"character_id": "drum",
		"map_id": "rocky_plateau",
		"zone_id": 0,
		"spawn_x": 560.0,
	})
	if startup.active_arena != null:
		fail("Must still wait for first valid zone_snapshot before entering Arena")
		return
	startup.transport.packet_received.emit({
		"op": "zone_snapshot",
		"tick": 1,
		"map_id": "rocky_plateau",
		"zone_id": 0,
		"entities": [
			{"id": "uid-vinh", "kind": "player", "display_name": "Vinh", "character_id": "drum", "x": 560.0, "y": 840.0, "hp": 1500.0, "max_hp": 1500.0, "mana": 0.0, "max_mana": 100.0, "alive": true, "facing_left": false, "act": "idle"},
			{"id": "uid-thai", "kind": "player", "display_name": "Thái", "character_id": "drum", "x": 760.0, "y": 840.0, "hp": 1500.0, "max_hp": 1500.0, "mana": 40.0, "max_mana": 100.0, "alive": true, "facing_left": true, "act": "idle"},
		],
	})
	await process_frame
	if startup.state != startup.StartupState.IN_ARENA or startup.active_arena == null:
		fail("AppStartup must enter ArenaSandbox after auth_ok + first valid zone_snapshot")
		return
	var arena = startup.active_arena
	if arena.active_character_id != "drum" or arena.field_manager.local_display_name != "Vinh":
		fail("Arena must spawn Drum with local display_name='Vinh', got cid=%s name=%s" % [arena.active_character_id, arena.field_manager.local_display_name])
		return
	if not arena.field_manager.remote_player_slots.has("uid-thai"):
		fail("Arena must spawn remote Drum player 'Thái' from zone_snapshot")
		return
	var thai_slot: Dictionary = arena.field_manager.remote_player_slots["uid-thai"]
	if str(thai_slot.get("display_name", "")) != "Thái" or str(thai_slot.get("character_id", "")) != "drum":
		fail("Remote player slot must have display_name='Thái' and character_id='drum'")
		return

	# Simulate PvP combat_event (Thái hits Vinh with power_up orb for 400 dmg)
	startup.transport.packet_received.emit({
		"op": "combat_event",
		"map_id": "rocky_plateau",
		"zone_id": 0,
		"action": "power_up",
		"attacker_id": "uid-thai",
		"target_id": "uid-vinh",
		"target_kind": "player",
		"damage": 400.0,
		"target_hp": 1100.0,
	})
	if absf(arena.field_manager.player_hp - 1100.0) > 0.1:
		fail("PvP combat_event must reconcile authoritative local HP to 1100.0, got %.1f" % arena.field_manager.player_hp)
		return

	# Regression for online PvE desync (Owner 2026-11-19):
	# 1. Idle intent snapshot echo must NOT reset Drum PvE damage back to 1500 or Mana back to 0.
	# 2. Stale pre-kill monster snapshot (alive=true, hp=1300) must NEVER resurrect a locally killed monster.
	var fm_online = arena.field_manager
	fm_online.apply_damage_to_player(120.0)
	var hp_after_pve: float = fm_online.player_hp
	fm_online.player_mana = 40.0
	fm_online._local_mana_grace_s = 0.0
	# First snapshot anchors server baseline; second identical snapshot must NOT overwrite local PvE HP/Mana
	startup.transport.packet_received.emit({
		"op": "zone_snapshot",
		"tick": 2,
		"map_id": "rocky_plateau",
		"zone_id": 0,
		"entities": [
			{"id": "uid-vinh", "kind": "player", "display_name": "Vinh", "character_id": "drum", "x": 560.0, "y": 840.0, "hp": 1500.0, "max_hp": 1500.0, "mana": 0.0, "max_mana": 100.0, "alive": true, "facing_left": false, "act": "idle"},
			{"id": "g0", "kind": "monster", "character_id": "chilopoda", "x": 330.0, "y": 840.0, "hp": 1300.0, "max_hp": 1300.0, "alive": true},
		],
	})
	if absf(fm_online.player_hp - hp_after_pve) > 0.1:
		fail("Online snapshot during PvE grace window must NOT snap Drum HP back to 1500 (got %.1f vs %.1f)" % [fm_online.player_hp, hp_after_pve])
		return
	# Kill g0 locally -> stale server snapshot with alive=true (no false->true transition) must NOT resurrect g0!
	var g0_slot: Dictionary = fm_online.slots[0]
	fm_online.call("_kill_slot_monster", g0_slot)
	fm_online._slot_local_hit_grace.clear()
	startup.transport.packet_received.emit({
		"op": "zone_snapshot",
		"tick": 3,
		"map_id": "rocky_plateau",
		"zone_id": 0,
		"entities": [
			{"id": "uid-vinh", "kind": "player", "display_name": "Vinh", "character_id": "drum", "x": 560.0, "y": 840.0, "hp": 1500.0, "max_hp": 1500.0, "mana": 0.0, "max_mana": 100.0, "alive": true, "facing_left": false, "act": "idle"},
			{"id": "g0", "kind": "monster", "character_id": "chilopoda", "x": 330.0, "y": 840.0, "hp": 1300.0, "max_hp": 1300.0, "alive": true},
		],
	})
	if bool(g0_slot["alive"]):
		fail("Stale alive=true server snapshot must NEVER resurrect a killed monster (causes drop-while-alive bug)")
		return
	if absf(fm_online.player_hp - hp_after_pve) > 0.1:
		fail("Unchanged server HP snapshot must NOT overwrite local Drum PvE HP back to full")
		return

	# (5d) Logout cleans up Arena and returns strictly to LOGIN
	startup.logout_to_login("Đăng xuất thành công")
	await process_frame
	if startup.state != startup.StartupState.LOGIN or startup.active_arena != null:
		fail("Logout must destroy ArenaSandbox and return cleanly to LOGIN")
		return

	# 6. ZoneClientSync standalone strict validation checks
	var zcs = ZoneClientSyncScript.new()
	var wst = WebSocketTransportScript.new()
	zcs.attach_transport(wst)
	# Switch while disconnected must fail and NOT mutate map/zone
	if zcs.request_zone_switch("other_map", 9) == OK or zcs.current_map_id != "rocky_plateau" or zcs.current_zone_id != 0:
		fail("ZoneClientSync must NEVER mutate map/zone when disconnected")
		return
	# Auth then request switch -> must wait for zone_joined
	wst.is_connected_state = true
	wst.packet_received.emit({"op": "auth_ok", "map_id": "rocky_plateau", "zone_id": 0, "user_id": "u1", "display_name": "Vinh"})
	zcs.request_zone_switch("rocky_plateau", 3)
	if zcs.current_zone_id != 0:
		fail("ZoneClientSync must NOT commit zone switch before server zone_joined confirmation")
		return
	wst.packet_received.emit({"op": "zone_joined", "map_id": "rocky_plateau", "zone_id": 3})
	if zcs.current_zone_id != 3:
		fail("ZoneClientSync must commit zone_id=3 upon server zone_joined")
		return
	# Wrong zone snapshot rejected
	wst.packet_received.emit({"op": "zone_snapshot", "tick": 5, "map_id": "rocky_plateau", "zone_id": 0, "entities": [{"id": "wrong"}]})
	if zcs.last_snapshot_tick != -1 or not zcs.entities_by_id.is_empty():
		fail("ZoneClientSync must reject snapshot with mismatched zone_id")
		return
	# Valid snapshot accepted, stale tick rejected
	wst.packet_received.emit({"op": "zone_snapshot", "tick": 10, "map_id": "rocky_plateau", "zone_id": 3, "entities": [{"id": "u1", "kind": "player"}]})
	wst.packet_received.emit({"op": "zone_snapshot", "tick": 9, "map_id": "rocky_plateau", "zone_id": 3, "entities": [{"id": "stale", "kind": "player"}]})
	if zcs.last_snapshot_tick != 10 or zcs.entities_by_id.has("stale") or not zcs.entities_by_id.has("u1"):
		fail("ZoneClientSync must reject out-of-order / stale tick snapshots")
		return

	startup.queue_free()
	await process_frame
	print("[OK] Alpha Login, Splash, 7-Star Dragon Ball Loading, Strict Session Gate & ZoneClientSync PASSED!")
	quit(0)
