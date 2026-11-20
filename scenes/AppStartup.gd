extends Node
## Startup Coordinator for DR7-Studio Alpha:
## Boot Splash (single-logo smooth fade) -> Login -> Auth -> WSS Connect -> Server Session & Zone Snapshot -> Arena.
## Strict Alpha Gate: tester builds NEVER bypass login; explicit dev sandbox bypass is restricted to CLI flag or localhost query.

enum StartupState {
	SPLASH,
	LOGIN,
	AUTHENTICATING,
	CONNECTING_WSS,
	AWAITING_SNAPSHOT,
	IN_ARENA,
}

const ArenaSandboxScene := preload("res://scenes/ArenaSandbox.tscn")
const DisplayPolicyScript := preload("res://scenes/runtime/DisplayPolicy.gd")
const LoginScreenScript := preload("res://scenes/ui/LoginScreen.gd")
const LoadingOverlayScript := preload("res://scenes/ui/DragonBallLoadingOverlay.gd")
const AlphaSessionClientScript := preload("res://scenes/net/AlphaSessionClient.gd")
const WebSocketTransportScript := preload("res://scenes/net/WebSocketTransport.gd")
const ZoneClientSyncScript := preload("res://scenes/net/ZoneClientSync.gd")

const SPLASH_LOGO_PATH := "res://assets/app_icon/android_adaptive_fg_432.png"
const SPLASH_HOLD_S := 0.35
const SPLASH_FADE_OUT_S := 0.40

var state: StartupState = StartupState.SPLASH
var ui_layer: CanvasLayer = null
var splash_root: Control = null
var splash_logo: TextureRect = null
var login_screen: Control = null
var loading_overlay: Control = null
var auth_client: Node = null
var transport: WebSocketTransport = null
var zone_sync: ZoneClientSync = null
var active_arena: Node = null
var current_session: Dictionary = {}

var _splash_elapsed_s: float = 0.0
var _last_username: String = ""
var _last_password: String = ""
var _last_failed_stage: String = ""
var _display_layout_info: Dictionary = {}
var _skip_splash_for_test: bool = false


func _ready() -> void:
	_setup_services()
	_setup_ui()
	_refresh_layout()
	get_viewport().size_changed.connect(_refresh_layout)

	if _should_enter_dev_sandbox_bypass():
		_enter_dev_sandbox()
		return
	if _skip_splash_for_test or DisplayServer.get_name() == "headless":
		_transition_to_login()
	else:
		_start_splash()


func _setup_services() -> void:
	auth_client = AlphaSessionClientScript.new()
	auth_client.name = "AlphaSessionClient"
	add_child(auth_client)
	auth_client.auth_succeeded.connect(_on_auth_succeeded)
	auth_client.auth_failed.connect(_on_auth_failed)

	transport = WebSocketTransportScript.new()
	transport.connected.connect(_on_ws_connected)
	transport.disconnected.connect(_on_ws_disconnected)
	transport.auth_rejected.connect(_on_ws_auth_rejected)

	zone_sync = ZoneClientSyncScript.new()
	zone_sync.attach_transport(transport)
	zone_sync.session_confirmed.connect(_on_session_confirmed)
	zone_sync.session_rejected.connect(_on_ws_auth_rejected)
	zone_sync.snapshot_applied.connect(_on_first_snapshot_applied)


func _setup_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.name = "StartupUILayer"
	ui_layer.layer = 50
	add_child(ui_layer)

	login_screen = LoginScreenScript.new()
	login_screen.name = "LoginScreen"
	login_screen.visible = false
	login_screen.login_submitted.connect(_on_login_submitted)
	ui_layer.add_child(login_screen)

	loading_overlay = LoadingOverlayScript.new()
	loading_overlay.name = "DragonBallLoadingOverlay"
	loading_overlay.step_duration_s = float(auth_client.loading_step_duration_s)
	loading_overlay.retry_requested.connect(_on_loading_retry)
	loading_overlay.cancel_requested.connect(_on_loading_cancel)
	ui_layer.add_child(loading_overlay)

	splash_root = Control.new()
	splash_root.name = "SplashOverlay"
	splash_root.mouse_filter = Control.MOUSE_FILTER_STOP
	splash_root.visible = false
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.08, 0.14, 1.0)
	splash_root.add_child(bg)

	splash_logo = TextureRect.new()
	splash_logo.name = "SplashLogo"
	splash_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	splash_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var logo_res := ResourceLoader.load(SPLASH_LOGO_PATH)
	if logo_res is Texture2D:
		splash_logo.texture = logo_res as Texture2D
	splash_logo.anchor_left = 0.5
	splash_logo.anchor_top = 0.5
	splash_logo.anchor_right = 0.5
	splash_logo.anchor_bottom = 0.5
	splash_logo.offset_left = -216.0
	splash_logo.offset_top = -216.0
	splash_logo.offset_right = 216.0
	splash_logo.offset_bottom = 216.0
	splash_root.add_child(splash_logo)
	ui_layer.add_child(splash_root)


func _refresh_layout() -> void:
	var vp_sz := get_viewport().get_visible_rect().size if get_viewport() != null else Vector2(1920.0, 1080.0)
	if vp_sz.x <= 1.0 or vp_sz.y <= 1.0:
		vp_sz = Vector2(1920.0, 1080.0)
	if splash_root != null:
		splash_root.position = Vector2.ZERO
		splash_root.size = vp_sz
	var win_sz := DisplayServer.window_get_size() if DisplayServer.get_name() != "headless" else Vector2i(1920, 1080)
	if win_sz.x <= 0 or win_sz.y <= 0:
		win_sz = Vector2i(1920, 1080)
	var is_mobile_os := OS.get_name() == "Android" or OS.get_name() == "iOS"
	var safe_rect := DisplayServer.get_display_safe_area() if (is_mobile_os and DisplayServer.get_name() != "headless") else Rect2i(0, 0, win_sz.x, win_sz.y)
	_display_layout_info = DisplayPolicyScript.compute_profile_layout(win_sz.x, win_sz.y, false, safe_rect)
	if login_screen != null and login_screen.has_method("apply_safe_area"):
		login_screen.call("apply_safe_area", _display_layout_info)
	if loading_overlay != null and loading_overlay.has_method("apply_safe_area"):
		loading_overlay.call("apply_safe_area", _display_layout_info)


func _should_enter_dev_sandbox_bypass() -> bool:
	for a in OS.get_cmdline_args():
		if a == "--dr7-dev-sandbox":
			return true
	for ua in OS.get_cmdline_user_args():
		if ua == "--dr7-dev-sandbox":
			return true
	if OS.get_name() == "Web":
		var host_v: Variant = JavaScriptBridge.eval("window.location.hostname || ''")
		var search_v: Variant = JavaScriptBridge.eval("window.location.search || ''")
		var host := str(host_v) if host_v != null else ""
		var search := str(search_v) if search_v != null else ""
		if (host == "localhost" or host == "127.0.0.1") and search.contains("dev_sandbox=1"):
			return true
	return false


func _start_splash() -> void:
	state = StartupState.SPLASH
	_splash_elapsed_s = 0.0
	if login_screen != null:
		login_screen.visible = true
	if splash_root != null:
		splash_root.visible = true
		splash_root.modulate = Color(1.0, 1.0, 1.0, 1.0)


func _transition_to_login(notice: String = "") -> void:
	state = StartupState.LOGIN
	if splash_root != null:
		splash_root.visible = false
	if loading_overlay != null:
		loading_overlay.call("finish_success")
	if login_screen != null:
		login_screen.visible = true
		if not notice.is_empty():
			login_screen.call("reset_for_logout", notice)


func _enter_dev_sandbox() -> void:
	state = StartupState.IN_ARENA
	if splash_root != null:
		splash_root.visible = false
	if login_screen != null:
		login_screen.visible = false
	if loading_overlay != null:
		loading_overlay.call("finish_success")
	active_arena = ArenaSandboxScene.instantiate()
	add_child(active_arena)


func _on_login_submitted(username: String, password: String) -> void:
	if state != StartupState.LOGIN:
		return
	_last_username = username
	_last_password = password
	_last_failed_stage = "auth"
	state = StartupState.AUTHENTICATING
	loading_overlay.call("start_loading", "Đang xác thực tài khoản...", float(auth_client.connect_timeout_s))
	auth_client.call("login", username, password)


func _on_auth_succeeded(session: Dictionary) -> void:
	if state != StartupState.AUTHENTICATING:
		return
	current_session = session.duplicate(true)
	_last_password = ""
	_start_zone_connection()


func _on_auth_failed(_code: String, message: String) -> void:
	if state != StartupState.AUTHENTICATING:
		return
	_last_failed_stage = "auth"
	state = StartupState.LOGIN
	loading_overlay.call("finish_success")
	login_screen.call("set_error", message)


func _start_zone_connection() -> void:
	if current_session.is_empty():
		_transition_to_login("Phiên đăng nhập chưa hợp lệ.")
		return
	_last_failed_stage = "wss"
	state = StartupState.CONNECTING_WSS
	zone_sync.reset_session()
	zone_sync.local_user_id = str(current_session.get("user_id", ""))
	zone_sync.local_display_name = str(current_session.get("display_name", ""))
	loading_overlay.call("start_loading", "Đang kết nối máy chủ khu vực...", float(auth_client.connect_timeout_s))
	var ws_url := str(current_session.get("ws_url", ""))
	var map_id := str(current_session.get("map_id", "rocky_plateau"))
	var zone_id := int(current_session.get("zone_id", 0))
	var jwt := str(current_session.get("access_token", ""))
	var err := transport.connect_to_zone(ws_url, map_id, zone_id, jwt)
	if err != OK:
		loading_overlay.call("show_error", "Không thể mở kết nối WebSocket tới máy chủ (mã %d)." % err)


func _on_ws_connected(_info: Dictionary) -> void:
	if state == StartupState.CONNECTING_WSS:
		state = StartupState.AWAITING_SNAPSHOT
		loading_overlay.call("update_status", "Đang xác nhận phiên & tải khu vực...")


func _on_session_confirmed(payload: Dictionary) -> void:
	if state == StartupState.CONNECTING_WSS or state == StartupState.AWAITING_SNAPSHOT:
		state = StartupState.AWAITING_SNAPSHOT
		if payload.has("map_id"):
			current_session["map_id"] = str(payload.get("map_id"))
		if payload.has("zone_id"):
			current_session["zone_id"] = int(payload.get("zone_id"))
		if payload.has("character_id"):
			current_session["character_id"] = str(payload.get("character_id"))
		if payload.has("display_name"):
			current_session["display_name"] = str(payload.get("display_name"))
		if payload.has("spawn_x"):
			current_session["spawn_x"] = float(payload.get("spawn_x"))
		loading_overlay.call("update_status", "Đang đồng bộ nhân vật & quái...")


func _on_first_snapshot_applied(_tick: int, _payload: Dictionary) -> void:
	if state != StartupState.AWAITING_SNAPSHOT:
		return
	if not zone_sync.is_ready_to_play():
		return
	_enter_alpha_arena()


func _on_ws_auth_rejected(reason: String) -> void:
	if state == StartupState.CONNECTING_WSS or state == StartupState.AWAITING_SNAPSHOT:
		transport.close_connection("auth_rejected")
		loading_overlay.call("show_error", "Máy chủ từ chối phiên đăng nhập (%s)." % reason)


func _on_ws_disconnected(reason: String) -> void:
	if state == StartupState.CONNECTING_WSS or state == StartupState.AWAITING_SNAPSHOT:
		loading_overlay.call("show_error", "Mất kết nối máy chủ khu vực (%s). Vui lòng thử lại." % (reason if not reason.is_empty() else "disconnected"))


func _on_loading_retry() -> void:
	if _last_failed_stage == "wss" and not current_session.is_empty():
		_start_zone_connection()
	elif not _last_username.is_empty() and not _last_password.is_empty():
		state = StartupState.AUTHENTICATING
		loading_overlay.call("start_loading", "Đang thử đăng nhập lại...", float(auth_client.connect_timeout_s))
		auth_client.call("login", _last_username, _last_password)
	else:
		_transition_to_login()


func _on_loading_cancel() -> void:
	auth_client.call("cancel_in_flight")
	transport.close_connection("user_cancel")
	zone_sync.reset_session()
	current_session.clear()
	_last_password = ""
	_transition_to_login("Đã hủy kết nối.")


func _enter_alpha_arena() -> void:
	if current_session.is_empty() or not zone_sync.is_ready_to_play():
		return
	state = StartupState.IN_ARENA
	if splash_root != null:
		splash_root.visible = false
	if login_screen != null:
		login_screen.visible = false
	if loading_overlay != null:
		loading_overlay.call("finish_success")
	active_arena = ArenaSandboxScene.instantiate()
	add_child(active_arena)
	if active_arena.has_signal("logout_requested"):
		active_arena.connect("logout_requested", _on_arena_logout_requested)
	if active_arena.has_method("configure_alpha_session"):
		active_arena.call("configure_alpha_session", current_session.duplicate(true), transport, zone_sync)


func _on_arena_logout_requested() -> void:
	logout_to_login("Đã đăng xuất tài khoản.")


func logout_to_login(notice: String = "") -> void:
	if active_arena != null and is_instance_valid(active_arena):
		active_arena.queue_free()
		active_arena = null
	transport.close_connection("logout")
	zone_sync.reset_session()
	auth_client.call("logout")
	current_session.clear()
	_last_password = ""
	_transition_to_login(notice)


func _process(delta: float) -> void:
	if state == StartupState.SPLASH:
		_splash_elapsed_s += delta
		if _splash_elapsed_s >= SPLASH_HOLD_S:
			var t := clampf((_splash_elapsed_s - SPLASH_HOLD_S) / maxf(0.05, SPLASH_FADE_OUT_S), 0.0, 1.0)
			if splash_root != null:
				splash_root.modulate.a = 1.0 - t
			if t >= 1.0:
				_transition_to_login()
	if state == StartupState.CONNECTING_WSS or state == StartupState.AWAITING_SNAPSHOT:
		if transport != null:
			transport.poll_events()
