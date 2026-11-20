class_name ZoneClientSync
extends RefCounted
## Client-side Zone state manager (<= 20 players + <= 20 monsters + drops = ~50 entities/zone).
## Strictly commits zone switches ONLY on server confirmation, validates snapshot schema/map/zone,
## and rejects stale/out-of-order ticks so state never rolls back across reconnects.

signal session_confirmed(payload: Dictionary)
signal session_rejected(reason: String)
signal zone_switched(map_id: String, zone_id: int)
signal snapshot_applied(tick: int, payload: Dictionary)
signal combat_event_received(payload: Dictionary)

const MAX_ZONE_ENTITIES := 50
const SNAPSHOT_RATE_HZ := 20.0

var transport: NetworkTransport = null
var current_map_id: String = "rocky_plateau"
var current_zone_id: int = 0
var pending_map_id: String = ""
var pending_zone_id: int = -1
var session_authenticated: bool = false
var zone_confirmed: bool = false
var local_user_id: String = ""
var local_display_name: String = ""
var entities_by_id: Dictionary = {}
var players_by_id: Dictionary = {}
var monsters_by_id: Dictionary = {}
var last_snapshot_tick: int = -1


func attach_transport(t: NetworkTransport) -> void:
	if transport != null and transport != t:
		if transport.packet_received.is_connected(_on_packet):
			transport.packet_received.disconnect(_on_packet)
		if transport.disconnected.is_connected(_on_transport_disconnected):
			transport.disconnected.disconnect(_on_transport_disconnected)
	transport = t
	if transport != null:
		if not transport.packet_received.is_connected(_on_packet):
			transport.packet_received.connect(_on_packet)
		if not transport.disconnected.is_connected(_on_transport_disconnected):
			transport.disconnected.connect(_on_transport_disconnected)


func is_ready_to_play() -> bool:
	return session_authenticated and zone_confirmed and last_snapshot_tick >= 0


func reset_session() -> void:
	session_authenticated = false
	zone_confirmed = false
	pending_map_id = ""
	pending_zone_id = -1
	entities_by_id.clear()
	players_by_id.clear()
	monsters_by_id.clear()
	last_snapshot_tick = -1


func _on_transport_disconnected(_reason: String) -> void:
	session_authenticated = false
	zone_confirmed = false
	pending_map_id = ""
	pending_zone_id = -1


func request_zone_switch(map_id: String, zone_id: int) -> Error:
	var target_map := map_id.strip_edges()
	var target_zone := clampi(zone_id, 0, 19)
	if target_map.is_empty():
		return ERR_INVALID_PARAMETER
	if transport == null or not transport.is_connected_state or not session_authenticated:
		return ERR_UNAVAILABLE
	# Never commit current_map_id / current_zone_id before server confirmation!
	pending_map_id = target_map
	pending_zone_id = target_zone
	return transport.send_packet({
		"op": "join_zone",
		"map_id": target_map,
		"zone_id": target_zone,
	})


func send_player_intent(pos: Vector2, dir_x: int, action: String = "", facing_left: bool = false, extra: Dictionary = {}) -> Error:
	if transport == null or not transport.is_connected_state or not session_authenticated or not zone_confirmed:
		return ERR_UNAVAILABLE
	var pkt := {
		"op": "intent",
		"map_id": current_map_id,
		"zone_id": current_zone_id,
		"x": snappedf(pos.x, 0.1),
		"y": snappedf(pos.y, 0.1),
		"dir": dir_x,
		"facing_left": facing_left,
		"act": action,
	}
	for k in extra.keys():
		if not pkt.has(k):
			pkt[k] = extra[k]
	return transport.send_packet(pkt)


func send_combat_action(action_kind: String, target_id: String, target_kind: String, origin_pos: Vector2, facing_left: bool) -> Error:
	if transport == null or not transport.is_connected_state or not session_authenticated or not zone_confirmed:
		return ERR_UNAVAILABLE
	return transport.send_packet({
		"op": "combat_action",
		"map_id": current_map_id,
		"zone_id": current_zone_id,
		"action": action_kind,
		"target_id": target_id,
		"target_kind": target_kind,
		"x": snappedf(origin_pos.x, 0.1),
		"y": snappedf(origin_pos.y, 0.1),
		"facing_left": facing_left,
	})


func send_player_pve_state(damage: float, new_hp: float, alive: bool) -> Error:
	if transport == null or not transport.is_connected_state or not session_authenticated or not zone_confirmed:
		return ERR_UNAVAILABLE
	return transport.send_packet({
		"op": "player_pve_state",
		"map_id": current_map_id,
		"zone_id": current_zone_id,
		"damage": snappedf(maxf(0.0, damage), 0.1),
		"hp": snappedf(maxf(0.0, new_hp), 0.1),
		"alive": alive,
	})


func _on_packet(payload: Dictionary) -> void:
	if not (payload is Dictionary):
		return
	var op := str(payload.get("op", ""))
	if op == "auth_ok":
		var confirmed_map := str(payload.get("map_id", current_map_id)).strip_edges()
		var confirmed_zone := clampi(int(payload.get("zone_id", current_zone_id)), 0, 19)
		var switched_zone := (confirmed_map != current_map_id) or (confirmed_zone != current_zone_id)
		session_authenticated = true
		zone_confirmed = true
		current_map_id = confirmed_map if not confirmed_map.is_empty() else current_map_id
		current_zone_id = confirmed_zone
		pending_map_id = ""
		pending_zone_id = -1
		if payload.has("user_id"):
			local_user_id = str(payload.get("user_id", ""))
		if payload.has("display_name"):
			local_display_name = str(payload.get("display_name", ""))
		if switched_zone:
			entities_by_id.clear()
			players_by_id.clear()
			monsters_by_id.clear()
			last_snapshot_tick = -1
		session_confirmed.emit(payload)
		return
	if op == "auth_error":
		session_authenticated = false
		zone_confirmed = false
		session_rejected.emit(str(payload.get("reason", "auth_rejected")))
		return
	if op == "zone_joined":
		if not session_authenticated:
			return
		var joined_map := str(payload.get("map_id", "")).strip_edges()
		if joined_map.is_empty() or not payload.has("zone_id"):
			return
		current_map_id = joined_map
		current_zone_id = clampi(int(payload.get("zone_id", 0)), 0, 19)
		pending_map_id = ""
		pending_zone_id = -1
		zone_confirmed = true
		entities_by_id.clear()
		players_by_id.clear()
		monsters_by_id.clear()
		last_snapshot_tick = -1
		zone_switched.emit(current_map_id, current_zone_id)
		return
	if op == "zone_snapshot":
		# Validate schema: tick must be numeric >= 0, entities must be Array, and map/zone must match active zone.
		var tick_v: Variant = payload.get("tick", null)
		if not (tick_v is int or tick_v is float):
			return
		var snap_tick := int(tick_v)
		if snap_tick < 0 or snap_tick <= last_snapshot_tick:
			return
		if payload.has("map_id") and str(payload.get("map_id", "")) != current_map_id:
			return
		if payload.has("zone_id") and int(payload.get("zone_id", -1)) != current_zone_id:
			return
		var raw_entities: Variant = payload.get("entities", null)
		if not (raw_entities is Array):
			return
		var incoming: Array = raw_entities
		var next_map := {}
		var next_players := {}
		var next_monsters := {}
		for i in range(mini(incoming.size(), MAX_ZONE_ENTITIES)):
			var item = incoming[i]
			if item is Dictionary and item.has("id"):
				var eid := str(item["id"])
				if eid.is_empty():
					continue
				next_map[eid] = item
				var ekind := str(item.get("kind", "player"))
				if ekind == "player":
					next_players[eid] = item
				elif ekind == "monster" or ekind == "boss":
					next_monsters[eid] = item
		last_snapshot_tick = snap_tick
		entities_by_id = next_map
		players_by_id = next_players
		monsters_by_id = next_monsters
		snapshot_applied.emit(snap_tick, payload)
		return
	if op == "zone_leave" and payload.has("id"):
		if payload.has("map_id") and str(payload.get("map_id", "")) != current_map_id:
			return
		if payload.has("zone_id") and int(payload.get("zone_id", -1)) != current_zone_id:
			return
		var lid := str(payload["id"])
		entities_by_id.erase(lid)
		players_by_id.erase(lid)
		monsters_by_id.erase(lid)
		return
	if op == "combat_event":
		if payload.has("map_id") and str(payload.get("map_id", "")) != current_map_id:
			return
		if payload.has("zone_id") and int(payload.get("zone_id", -1)) != current_zone_id:
			return
		combat_event_received.emit(payload)
