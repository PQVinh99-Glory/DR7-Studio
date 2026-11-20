class_name AlphaSessionClient
extends Node
## Client-side Alpha authentication adapter (never stores or logs passwords).
## Talks to staging/local auth endpoint (/api/alpha/login), validates returned session schema,
## and supports clean error/retry/logout semantics.

signal auth_succeeded(session: Dictionary)
signal auth_failed(code: String, message: String)

const ENDPOINTS_JSON := "res://assets/config/alpha_endpoints.json"

var auth_base_url: String = ""
var default_ws_url: String = ""
var default_map_id: String = "rocky_plateau"
var default_zone_id: int = 0
var default_character_id: String = "drum"
var loading_step_duration_s: float = 0.18
var connect_timeout_s: float = 12.0

var active_session: Dictionary = {}
var _http: HTTPRequest = null
var _busy: bool = false
var _custom_handler: Callable = Callable()


func _ready() -> void:
	load_endpoints_config()
	_http = HTTPRequest.new()
	_http.name = "AuthHTTPRequest"
	_http.timeout = connect_timeout_s
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func load_endpoints_config() -> Dictionary:
	var cfg := {}
	var p := ENDPOINTS_JSON
	if FileAccess.file_exists(p):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
		if parsed is Dictionary:
			cfg = parsed
	auth_base_url = str(cfg.get("auth_base_url", "http://127.0.0.1:8787")).trim_suffix("/")
	default_ws_url = str(cfg.get("ws_url", "ws://127.0.0.1:8788"))
	default_map_id = str(cfg.get("default_map_id", "rocky_plateau"))
	default_zone_id = int(cfg.get("default_zone_id", 0))
	default_character_id = str(cfg.get("default_character_id", "drum"))
	loading_step_duration_s = float(cfg.get("loading_step_duration_s", 0.18))
	connect_timeout_s = float(cfg.get("connect_timeout_s", 12.0))
	# Allow runtime override on Web via URL origin/query (for localhost or staging Worker)
	if OS.get_name() == "Web":
		var origin_v: Variant = JavaScriptBridge.eval("window.location.origin || ''")
		var host_v: Variant = JavaScriptBridge.eval("window.location.hostname || ''")
		var search_v: Variant = JavaScriptBridge.eval("window.location.search || ''")
		var host_str := str(host_v) if host_v != null else ""
		var origin_str := str(origin_v).trim_suffix("/") if origin_v != null else ""
		var search_str := str(search_v) if search_v != null else ""
		if not origin_str.is_empty() and (host_str.ends_with(".workers.dev") or host_str == "localhost" or host_str == "127.0.0.1"):
			if host_str.ends_with(".workers.dev"):
				auth_base_url = origin_str
				default_ws_url = origin_str.replace("https://", "wss://").replace("http://", "ws://") + "/ws"
		var q_auth := _extract_query_param(search_str, "auth_url")
		var q_ws := _extract_query_param(search_str, "ws_url")
		if not q_auth.is_empty():
			auth_base_url = q_auth.trim_suffix("/")
		if not q_ws.is_empty():
			default_ws_url = q_ws
	return cfg


static func _extract_query_param(search_str: String, key: String) -> String:
	var raw := search_str.trim_prefix("?")
	if raw.is_empty():
		return ""
	for pair in raw.split("&"):
		var kv := pair.split("=", false, 1)
		if kv.size() == 2 and kv[0] == key:
			return kv[1].uri_decode()
	return ""


func set_custom_auth_handler(handler: Callable) -> void:
	_custom_handler = handler


func is_busy() -> bool:
	return _busy


func login(username: String, password: String) -> Error:
	if _busy:
		return ERR_BUSY
	var uname := username.strip_edges()
	if uname.is_empty() or password.is_empty():
		auth_failed.emit("invalid_input", "Vui lòng nhập đầy đủ tên đăng nhập và mật khẩu.")
		return ERR_INVALID_PARAMETER
	_busy = true
	if _custom_handler.is_valid():
		var resp: Variant = _custom_handler.call(uname, password)
		_busy = false
		if resp is Dictionary:
			_process_auth_payload(int(resp.get("status", 200)), resp.get("body", resp))
		else:
			auth_failed.emit("network_error", "Không thể kết nối máy chủ đăng nhập.")
		return OK
	if _http == null:
		_http = HTTPRequest.new()
		_http.timeout = connect_timeout_s
		add_child(_http)
		_http.request_completed.connect(_on_request_completed)
	_http.timeout = connect_timeout_s
	var url := auth_base_url.trim_suffix("/") + "/api/alpha/login"
	var body := JSON.stringify({"username": uname, "password": password})
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_busy = false
		auth_failed.emit("network_error", "Không gửi được yêu cầu đăng nhập (mã %d)." % err)
	return err


func cancel_in_flight() -> void:
	if _http != null:
		_http.cancel_request()
	_busy = false


func logout() -> void:
	cancel_in_flight()
	active_session.clear()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS:
		if result == HTTPRequest.RESULT_TIMEOUT:
			auth_failed.emit("timeout", "Hết thời gian kết nối máy chủ đăng nhập. Vui lòng thử lại.")
		else:
			auth_failed.emit("network_error", "Mất kết nối mạng hoặc không tới được máy chủ đăng nhập.")
		return
	var raw_txt := body.get_string_from_utf8()
	var parsed = JSON.parse_string(raw_txt)
	if not (parsed is Dictionary):
		auth_failed.emit("invalid_response", "Phản hồi máy chủ đăng nhập không hợp lệ (HTTP %d)." % response_code)
		return
	_process_auth_payload(response_code, parsed as Dictionary)


func _process_auth_payload(status_code: int, payload: Dictionary) -> void:
	if status_code == 401 or status_code == 403:
		var msg := str(payload.get("error_message", payload.get("error", "Sai tên đăng nhập hoặc mật khẩu.")))
		auth_failed.emit("invalid_credentials", msg)
		return
	if status_code < 200 or status_code >= 300:
		var msg2 := str(payload.get("error_message", payload.get("error", "Máy chủ đăng nhập lỗi (HTTP %d)." % status_code)))
		auth_failed.emit("server_error", msg2)
		return
	var validated := validate_session_payload(payload)
	if validated.is_empty():
		auth_failed.emit("invalid_schema", "Hồ sơ đăng nhập thiếu trường bắt buộc từ máy chủ.")
		return
	active_session = validated
	auth_succeeded.emit(active_session.duplicate(true))


func validate_session_payload(payload: Dictionary) -> Dictionary:
	var token := str(payload.get("access_token", "")).strip_edges()
	var uid := str(payload.get("user_id", "")).strip_edges()
	var dname := str(payload.get("display_name", "")).strip_edges()
	if token.is_empty() or uid.is_empty() or dname.is_empty():
		return {}
	var cid := str(payload.get("character_id", default_character_id)).strip_edges()
	if cid.is_empty():
		cid = default_character_id
	var mid := str(payload.get("map_id", default_map_id)).strip_edges()
	if mid.is_empty():
		mid = default_map_id
	var zid := clampi(int(payload.get("zone_id", default_zone_id)), 0, 19)
	var ws := str(payload.get("ws_url", default_ws_url)).strip_edges()
	if ws.is_empty():
		ws = default_ws_url
	return {
		"access_token": token,
		"user_id": uid,
		"username": str(payload.get("username", "")),
		"display_name": dname,
		"character_id": cid,
		"map_id": mid,
		"zone_id": zid,
		"ws_url": ws,
		"spawn_x": float(payload.get("spawn_x", 560.0)),
	}
