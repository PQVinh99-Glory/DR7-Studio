class_name DragonBallLoadingOverlay
extends Control
## Reusable 7-Star Dragon Ball loading overlay (1 -> 2 -> ... -> 7 -> 1) centered inside Safe Area.
## Supports configurable per-ball step duration, timeout handling, retry, and cancellation.

signal retry_requested()
signal cancel_requested()

const DRAGON_BALLS_TRES := "res://assets/items/dragon_balls/godot/dragon_balls.tres"

@export var step_duration_s: float = 0.18
@export var ball_size_px: float = 52.0
@export var ball_gap_px: float = 16.0

var loading_active: bool = false
var error_active: bool = false
var active_ball_index: int = 0
var _step_accum_s: float = 0.0
var _elapsed_s: float = 0.0
var _timeout_s: float = 12.0
var _ball_textures: Array[Texture2D] = []
var _safe_insets: Dictionary = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
var _safe_rect: Rect2 = Rect2(0, 0, 1920, 1080)

var _center_box: VBoxContainer = null
var _balls_host: Control = null
var _status_label: Label = null
var _error_label: Label = null
var _btn_row: HBoxContainer = null
var _retry_btn: Button = null
var _cancel_btn: Button = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_load_dragon_ball_textures()
	_build_ui()
	get_viewport().size_changed.connect(_reposition_card)
	call_deferred("_reposition_card")


func _load_dragon_ball_textures() -> void:
	_ball_textures.clear()
	var sf := ResourceLoader.load(DRAGON_BALLS_TRES) as SpriteFrames
	if sf == null:
		return
	for i in range(1, 8):
		var anim := StringName("ball_%02d" % i)
		if sf.has_animation(anim) and sf.get_frame_count(anim) > 0:
			var tex := sf.get_frame_texture(anim, 0)
			if tex != null:
				_ball_textures.append(tex)


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.name = "LoadingCard"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.06, 0.12, 0.86)
	sb.border_color = Color(0.78, 0.86, 0.96, 0.65)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(16)
	sb.content_margin_left = 34
	sb.content_margin_right = 34
	sb.content_margin_top = 26
	sb.content_margin_bottom = 26
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	_center_box = VBoxContainer.new()
	_center_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_center_box.add_theme_constant_override("separation", 18)
	panel.add_child(_center_box)

	var total_w := ball_size_px * 7.0 + ball_gap_px * 6.0 + 24.0
	_balls_host = Control.new()
	_balls_host.name = "DragonBallsStrip"
	_balls_host.custom_minimum_size = Vector2(total_w, ball_size_px + 28.0)
	_balls_host.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_balls_host.draw.connect(_on_balls_draw)
	_center_box.add_child(_balls_host)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 22)
	_status_label.add_theme_color_override("font_color", Color(0.94, 0.97, 1.0, 1.0))
	_center_box.add_child(_status_label)

	_error_label = Label.new()
	_error_label.name = "ErrorLabel"
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.custom_minimum_size = Vector2(460.0, 0.0)
	_error_label.add_theme_font_size_override("font_size", 19)
	_error_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.38, 1.0))
	_error_label.visible = false
	_center_box.add_child(_error_label)

	_btn_row = HBoxContainer.new()
	_btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_btn_row.add_theme_constant_override("separation", 16)
	_btn_row.visible = false
	_center_box.add_child(_btn_row)

	_retry_btn = Button.new()
	_retry_btn.name = "RetryButton"
	_retry_btn.text = "Thử lại"
	_retry_btn.custom_minimum_size = Vector2(150.0, 48.0)
	_retry_btn.pressed.connect(func() -> void: retry_requested.emit())
	_btn_row.add_child(_retry_btn)

	_cancel_btn = Button.new()
	_cancel_btn.name = "CancelButton"
	_cancel_btn.text = "Quay lại"
	_cancel_btn.custom_minimum_size = Vector2(150.0, 48.0)
	_cancel_btn.pressed.connect(func() -> void: cancel_requested.emit())
	_btn_row.add_child(_cancel_btn)

	_reposition_card()


func apply_safe_area(layout_info: Dictionary) -> void:
	var insets: Dictionary = layout_info.get("safe_insets_logic", {})
	_safe_insets = {
		"left": float(insets.get("left", layout_info.get("inset_left", 0.0))),
		"top": float(insets.get("top", layout_info.get("inset_top", 0.0))),
		"right": float(insets.get("right", layout_info.get("inset_right", 0.0))),
		"bottom": float(insets.get("bottom", layout_info.get("inset_bottom", 0.0))),
	}
	_reposition_card()


func _reposition_card() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 1.0 or vp.y <= 1.0:
		vp = Vector2(1920.0, 1080.0)
	position = Vector2.ZERO
	size = vp
	var ins_l := float(_safe_insets.get("left", 0.0))
	var ins_r := float(_safe_insets.get("right", 0.0))
	var ins_t := float(_safe_insets.get("top", 0.0))
	var ins_b := float(_safe_insets.get("bottom", 0.0))
	_safe_rect = Rect2(ins_l, ins_t, maxf(320.0, vp.x - ins_l - ins_r), maxf(240.0, vp.y - ins_t - ins_b))
	var card := get_node_or_null("LoadingCard") as Control
	if card == null:
		queue_redraw()
		return
	var sz := card.get_combined_minimum_size()
	if sz.x < 100.0:
		sz = Vector2(560.0, 180.0)
	var cx := _safe_rect.position.x + _safe_rect.size.x * 0.5
	var cy := _safe_rect.position.y + _safe_rect.size.y * 0.5
	card.position = Vector2(roundf(cx - sz.x * 0.5), roundf(cy - sz.y * 0.5))
	card.size = sz
	queue_redraw()


func start_loading(status_text: String, timeout_s: float = 12.0) -> void:
	loading_active = true
	error_active = false
	active_ball_index = 0
	_step_accum_s = 0.0
	_elapsed_s = 0.0
	_timeout_s = maxf(0.5, timeout_s)
	visible = true
	if _status_label != null:
		_status_label.text = status_text
		_status_label.visible = true
	if _error_label != null:
		_error_label.visible = false
	if _btn_row != null:
		_btn_row.visible = false
	_reposition_card()
	if _balls_host != null:
		_balls_host.queue_redraw()
	queue_redraw()


func update_status(status_text: String) -> void:
	if _status_label != null:
		_status_label.text = status_text
	_reposition_card()


func finish_success() -> void:
	loading_active = false
	error_active = false
	visible = false


func show_error(error_text: String) -> void:
	loading_active = false
	error_active = true
	visible = true
	if _status_label != null:
		_status_label.text = "Kết nối gián đoạn"
	if _error_label != null:
		_error_label.text = error_text
		_error_label.visible = true
	if _btn_row != null:
		_btn_row.visible = true
	_reposition_card()
	if _balls_host != null:
		_balls_host.queue_redraw()


func step_loading(delta: float) -> void:
	if not loading_active or delta <= 0.0:
		return
	_elapsed_s += delta
	_step_accum_s += delta
	var dur := maxf(0.04, step_duration_s)
	var changed := false
	while _step_accum_s >= dur:
		_step_accum_s -= dur
		active_ball_index = (active_ball_index + 1) % 7
		changed = true
	if _elapsed_s >= _timeout_s:
		show_error("Hết thời gian chờ máy chủ. Vui lòng thử lại.")
		return
	if changed and _balls_host != null:
		_balls_host.queue_redraw()


func _process(delta: float) -> void:
	if loading_active:
		step_loading(delta)


func _draw() -> void:
	if visible:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.01, 0.03, 0.07, 0.72), true)


func _on_balls_draw() -> void:
	if _balls_host == null:
		return
	var host_sz := _balls_host.size
	var total_w := ball_size_px * 7.0 + ball_gap_px * 6.0
	var start_x := (host_sz.x - total_w) * 0.5
	var center_y := host_sz.y * 0.5
	for i in range(7):
		var is_lit := loading_active and (i == active_ball_index)
		var scale_m := 1.22 if is_lit else 0.96
		var draw_sz := ball_size_px * scale_m
		var cx := start_x + float(i) * (ball_size_px + ball_gap_px) + ball_size_px * 0.5
		if is_lit:
			_balls_host.draw_circle(Vector2(cx, center_y), draw_sz * 0.66, Color(1.0, 0.82, 0.24, 0.28))
			_balls_host.draw_circle(Vector2(cx, center_y), draw_sz * 0.54, Color(1.0, 0.92, 0.48, 0.36))
		var dst := Rect2(cx - draw_sz * 0.5, center_y - draw_sz * 0.5, draw_sz, draw_sz)
		if i < _ball_textures.size() and _ball_textures[i] != null:
			var tint := Color(1.28, 1.18, 0.96, 1.0) if is_lit else Color(0.55, 0.58, 0.66, 0.62)
			_balls_host.draw_texture_rect(_ball_textures[i], dst, false, tint)
		else:
			var col := Color(1.0, 0.76, 0.14, 1.0) if is_lit else Color(0.55, 0.42, 0.16, 0.65)
			_balls_host.draw_circle(Vector2(cx, center_y), draw_sz * 0.42, col)


func get_ball_texture_count() -> int:
	return _ball_textures.size()
