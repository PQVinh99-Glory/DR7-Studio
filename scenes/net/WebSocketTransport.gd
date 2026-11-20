class_name WebSocketTransport
extends NetworkTransport
## Phase 1 WebSocketTransport (Godot 4 WebSocketPeer) compatible with Cloudflare Free Proxy (port 443 wss://).
## Distinguishes socket open (is_connected_state), server-confirmed auth (is_authenticated), and ready (is_ready_state).

signal auth_confirmed(payload: Dictionary)
signal auth_rejected(reason: String)

var peer: WebSocketPeer = WebSocketPeer.new()
var active_endpoint: String = ""
var active_map_id: String = ""
var active_zone_id: int = 0
var is_authenticated: bool = false
var is_ready_state: bool = false
var _was_open: bool = false
var _connecting: bool = false
var _pending_jwt: String = ""


func connect_to_zone(endpoint_url: String, map_id: String, zone_id: int, supabase_jwt: String) -> Error:
	close_connection("reconnecting")
	# Always allocate a fresh WebSocketPeer so reconnects do not hit ERR_ALREADY_IN_USE
	# while the previous peer is still in STATE_CLOSING, and stale handshake headers never leak.
	peer = WebSocketPeer.new()
	active_endpoint = endpoint_url
	active_map_id = map_id
	active_zone_id = zone_id
	_pending_jwt = supabase_jwt
	var sep := "&" if endpoint_url.contains("?") else "?"
	var url := "%s%smap=%s&zone=%d" % [endpoint_url, sep, map_id.uri_encode(), zone_id]
	# Browsers block custom HTTP headers on WebSocket handshake (Godot Web); send header on native only and always send first-packet auth on STATE_OPEN.
	if not supabase_jwt.is_empty() and OS.get_name() != "Web":
		peer.handshake_headers = PackedStringArray(["Authorization: Bearer " + supabase_jwt])
	else:
		peer.handshake_headers = PackedStringArray()
	var err := peer.connect_to_url(url)
	_was_open = false
	is_connected_state = false
	is_authenticated = false
	is_ready_state = false
	_connecting = (err == OK)
	return err


func send_packet(payload: Dictionary) -> Error:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_CONNECTION_ERROR
	return peer.send_text(JSON.stringify(payload))


func poll_events() -> void:
	peer.poll()
	var state := peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _was_open:
			_was_open = true
			_connecting = false
			is_connected_state = true
			is_authenticated = false
			is_ready_state = false
			if not _pending_jwt.is_empty():
				send_packet({
					"op": "auth",
					"type": "auth",
					"token": _pending_jwt,
					"map_id": active_map_id,
					"zone_id": active_zone_id,
				})
				_pending_jwt = ""
			connected.emit({"transport": "websocket", "map_id": active_map_id, "zone_id": active_zone_id})
		_drain_incoming_packets()
	elif state == WebSocketPeer.STATE_CLOSING:
		_drain_incoming_packets()
	elif state == WebSocketPeer.STATE_CLOSED and (_was_open or is_connected_state or _connecting):
		_drain_incoming_packets()
		var was_connecting := _connecting and not _was_open
		_was_open = false
		_connecting = false
		is_connected_state = false
		is_authenticated = false
		is_ready_state = false
		var reason := peer.get_close_reason()
		if reason.is_empty() and was_connecting:
			reason = "handshake_failed"
		disconnected.emit(reason)


func _drain_incoming_packets() -> void:
	while peer.get_available_packet_count() > 0:
		var raw := peer.get_packet().get_string_from_utf8()
		var parsed = JSON.parse_string(raw)
		if parsed is Dictionary:
			var pkt: Dictionary = parsed
			var op := str(pkt.get("op", ""))
			if op == "auth_ok":
				is_authenticated = true
				auth_confirmed.emit(pkt)
			elif op == "auth_error":
				is_authenticated = false
				is_ready_state = false
				auth_rejected.emit(str(pkt.get("reason", "auth_rejected")))
			elif op == "zone_snapshot" and is_authenticated:
				is_ready_state = true
			packet_received.emit(pkt)


func close_connection(reason: String = "client_close") -> void:
	if peer != null and (peer.get_ready_state() == WebSocketPeer.STATE_OPEN or peer.get_ready_state() == WebSocketPeer.STATE_CONNECTING):
		peer.close(1000, reason)
	_was_open = false
	_connecting = false
	is_connected_state = false
	is_authenticated = false
	is_ready_state = false
