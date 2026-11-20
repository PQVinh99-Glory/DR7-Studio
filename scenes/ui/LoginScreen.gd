class_name LoginScreen
extends Control
## Alpha Login UI matching image.png sci-fi silver-framed layout over image copy.png cover background.
## Uses lightweight frosted-glass translucency (GL Compatibility safe), Safe Area, and mobile soft keyboard lift.

signal login_submitted(username: String, password: String)

const LOGIN_BG_PATH := "res://assets/ui/login/login_bg.png"

var _bg_tex: Texture2D = null
var _safe_insets: Dictionary = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
var _safe_rect: Rect2 = Rect2(0, 0, 1920, 1080)
var _panel_root: Control = null
var _frame_bg: Control = null
var _username_edit: LineEdit = null
var _password_edit: LineEdit = null
var _show_pass_btn: Button = null
var _status_label: Label = null
var _login_btn: Button = null
var _submitting: bool = false
var _last_kb_height: float = 0.0
var _last_vp_size: Vector2 = Vector2.ZERO


func _ready() -> void:
	_load_bg_once()
	_build_panel()
	get_viewport().size_changed.connect(_layout_panel)
	_layout_panel()
	call_deferred("_layout_panel")


func _load_bg_once() -> void:
	if _bg_tex != null:
		return
	var res := ResourceLoader.load(LOGIN_BG_PATH)
	if res is Texture2D:
		_bg_tex = res as Texture2D
		return
	var abs_p := ProjectSettings.globalize_path(LOGIN_BG_PATH)
	if FileAccess.file_exists(abs_p):
		var img := Image.new()
		if img.load(abs_p) == OK:
			_bg_tex = ImageTexture.create_from_image(img)


func _build_panel() -> void:
	_panel_root = Control.new()
	_panel_root.name = "LoginPanelRoot"
	_panel_root.custom_minimum_size = Vector2(580.0, 384.0)
	_panel_root.size = Vector2(580.0, 384.0)
	add_child(_panel_root)

	_frame_bg = Control.new()
	_frame_bg.name = "SilverGlassFrame"
	_frame_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_frame_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame_bg.draw.connect(_on_frame_draw)
	_panel_root.add_child(_frame_bg)

	var title_lbl := Label.new()
	title_lbl.name = "TitleLabel"
	title_lbl.text = "ĐĂNG NHẬP"
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_lbl.position = Vector2(40.0, 12.0)
	title_lbl.size = Vector2(500.0, 50.0)
	title_lbl.add_theme_font_size_override("font_size", 28)
	title_lbl.add_theme_color_override("font_color", Color(0.96, 0.99, 1.0, 1.0))
	title_lbl.add_theme_color_override("font_outline_color", Color(0.03, 0.12, 0.24, 0.95))
	title_lbl.add_theme_constant_override("outline_size", 4)
	_panel_root.add_child(title_lbl)

	var body := VBoxContainer.new()
	body.name = "FormVBox"
	body.position = Vector2(46.0, 86.0)
	body.size = Vector2(488.0, 214.0)
	body.add_theme_constant_override("separation", 14)
	_panel_root.add_child(body)

	var input_sb := _make_input_style(Color(0.70, 0.80, 0.92, 0.55))
	var input_focus := _make_input_style(Color(0.32, 0.78, 1.0, 0.95))

	_username_edit = LineEdit.new()
	_username_edit.name = "UsernameInput"
	_username_edit.placeholder_text = "Tên đăng nhập"
	_username_edit.custom_minimum_size = Vector2(488.0, 54.0)
	_username_edit.add_theme_font_size_override("font_size", 22)
	_username_edit.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0, 1.0))
	_username_edit.add_theme_color_override("font_placeholder_color", Color(0.62, 0.72, 0.84, 0.85))
	_username_edit.add_theme_stylebox_override("normal", input_sb)
	_username_edit.add_theme_stylebox_override("focus", input_focus)
	_username_edit.text_submitted.connect(func(_t: String) -> void:
		if _password_edit != null:
			_password_edit.grab_focus()
	)
	body.add_child(_username_edit)

	var pass_row := HBoxContainer.new()
	pass_row.name = "PasswordRow"
	pass_row.add_theme_constant_override("separation", 8)
	body.add_child(pass_row)

	_password_edit = LineEdit.new()
	_password_edit.name = "PasswordInput"
	_password_edit.placeholder_text = "Mật khẩu"
	_password_edit.secret = true
	_password_edit.secret_character = "•"
	_password_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_password_edit.custom_minimum_size = Vector2(380.0, 54.0)
	_password_edit.add_theme_font_size_override("font_size", 22)
	_password_edit.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0, 1.0))
	_password_edit.add_theme_color_override("font_placeholder_color", Color(0.62, 0.72, 0.84, 0.85))
	_password_edit.add_theme_stylebox_override("normal", input_sb)
	_password_edit.add_theme_stylebox_override("focus", input_focus)
	_password_edit.text_submitted.connect(func(_t: String) -> void: _submit())
	pass_row.add_child(_password_edit)

	_show_pass_btn = Button.new()
	_show_pass_btn.name = "TogglePasswordButton"
	_show_pass_btn.text = "Hiện"
	_show_pass_btn.custom_minimum_size = Vector2(92.0, 54.0)
	_show_pass_btn.add_theme_font_size_override("font_size", 18)
	_show_pass_btn.pressed.connect(func() -> void:
		if _password_edit != null:
			_password_edit.secret = not _password_edit.secret
			_show_pass_btn.text = "Hiện" if _password_edit.secret else "Ẩn"
	)
	pass_row.add_child(_show_pass_btn)

	_status_label = Label.new()
	_status_label.name = "LoginStatusLabel"
	_status_label.text = ""
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(488.0, 44.0)
	_status_label.add_theme_font_size_override("font_size", 18)
	_status_label.add_theme_color_override("font_color", Color(1.0, 0.48, 0.40, 1.0))
	body.add_child(_status_label)

	_login_btn = Button.new()
	_login_btn.name = "LoginButton"
	_login_btn.text = "ĐĂNG NHẬP"
	_login_btn.position = Vector2(165.0, 316.0)
	_login_btn.size = Vector2(250.0, 54.0)
	_login_btn.add_theme_font_size_override("font_size", 22)
	_login_btn.add_theme_color_override("font_color", Color(0.98, 0.99, 1.0, 1.0))
	_login_btn.add_theme_stylebox_override("normal", _make_btn_style(Color(0.06, 0.50, 0.78, 0.96), Color(0.84, 0.90, 0.97, 0.95)))
	_login_btn.add_theme_stylebox_override("hover", _make_btn_style(Color(0.10, 0.60, 0.90, 0.98), Color(0.95, 0.98, 1.0, 1.0)))
	_login_btn.add_theme_stylebox_override("pressed", _make_btn_style(Color(0.04, 0.38, 0.62, 0.98), Color(0.75, 0.84, 0.94, 0.95)))
	_login_btn.add_theme_stylebox_override("disabled", _make_btn_style(Color(0.22, 0.30, 0.38, 0.85), Color(0.55, 0.62, 0.70, 0.70)))
	_login_btn.pressed.connect(_submit)
	_panel_root.add_child(_login_btn)


func _make_input_style(border_col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.06, 0.11, 0.72)
	sb.border_color = border_col
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _make_btn_style(bg_col: Color, border_col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_col
	sb.border_color = border_col
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(8)
	return sb


func apply_safe_area(layout_info: Dictionary) -> void:
	var insets: Dictionary = layout_info.get("safe_insets_logic", {})
	_safe_insets = {
		"left": float(insets.get("left", layout_info.get("inset_left", 0.0))),
		"top": float(insets.get("top", layout_info.get("inset_top", 0.0))),
		"right": float(insets.get("right", layout_info.get("inset_right", 0.0))),
		"bottom": float(insets.get("bottom", layout_info.get("inset_bottom", 0.0))),
	}
	_layout_panel()
	queue_redraw()


func _layout_panel() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 1.0 or vp.y <= 1.0:
		vp = Vector2(1920.0, 1080.0)
	position = Vector2.ZERO
	size = vp
	_last_vp_size = vp
	var ins_l := float(_safe_insets.get("left", 0.0))
	var ins_r := float(_safe_insets.get("right", 0.0))
	var ins_t := float(_safe_insets.get("top", 0.0))
	var ins_b := float(_safe_insets.get("bottom", 0.0))
	_safe_rect = Rect2(ins_l, ins_t, maxf(320.0, vp.x - ins_l - ins_r), maxf(240.0, vp.y - ins_t - ins_b))
	if _panel_root == null:
		queue_redraw()
		return
	var base_sz := Vector2(580.0, 384.0)
	var avail_w := maxf(320.0, _safe_rect.size.x - 48.0)
	var avail_h := maxf(240.0, _safe_rect.size.y - 48.0)
	var sc := minf(1.15, minf(avail_w / base_sz.x, avail_h / base_sz.y))
	_panel_root.scale = Vector2(sc, sc)
	var drawn_w := base_sz.x * sc
	var drawn_h := base_sz.y * sc
	var kb_h := _get_virtual_keyboard_logical_height(vp.y)
	var usable_bottom := _safe_rect.end.y - kb_h
	var cx := _safe_rect.position.x + _safe_rect.size.x * 0.5
	var cy := _safe_rect.position.y + maxf(drawn_h * 0.5 + 12.0, (usable_bottom - _safe_rect.position.y) * 0.5)
	if cy + drawn_h * 0.5 > usable_bottom - 10.0:
		cy = maxf(_safe_rect.position.y + drawn_h * 0.5 + 8.0, usable_bottom - drawn_h * 0.5 - 10.0)
	_panel_root.position = Vector2(roundf(cx - drawn_w * 0.5), roundf(cy - drawn_h * 0.5))
	if _frame_bg != null:
		_frame_bg.queue_redraw()
	queue_redraw()


func _get_virtual_keyboard_logical_height(vp_h: float) -> float:
	if DisplayServer.get_name() == "headless" or not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return 0.0
	var kb_px := float(DisplayServer.virtual_keyboard_get_height())
	if kb_px <= 0.0:
		return 0.0
	var win_h := float(maxi(1, DisplayServer.window_get_size().y))
	return kb_px * (vp_h / win_h)


func _process(_delta: float) -> void:
	if not visible:
		return
	var vp := get_viewport_rect().size
	if vp.x > 1.0 and vp.y > 1.0 and (absf(vp.x - _last_vp_size.x) > 1.0 or absf(vp.y - _last_vp_size.y) > 1.0):
		_layout_panel()
	var vp_h := maxf(1.0, vp.y)
	var kb := _get_virtual_keyboard_logical_height(vp_h)
	if absf(kb - _last_kb_height) > 2.0:
		_last_kb_height = kb
		_layout_panel()


func _submit() -> void:
	if _submitting:
		return
	var uname := _username_edit.text.strip_edges() if _username_edit != null else ""
	var pwd := _password_edit.text if _password_edit != null else ""
	if uname.is_empty() or pwd.is_empty():
		set_error("Vui lòng nhập đầy đủ tên đăng nhập và mật khẩu.")
		return
	set_submitting(true, "Đang gửi yêu cầu đăng nhập...")
	login_submitted.emit(uname, pwd)


func submit_credentials_programmatic(username: String, password: String) -> void:
	if _username_edit != null:
		_username_edit.text = username
	if _password_edit != null:
		_password_edit.text = password
	_submit()


func set_submitting(busy: bool, msg: String = "") -> void:
	_submitting = busy
	if _login_btn != null:
		_login_btn.disabled = busy
	if _username_edit != null:
		_username_edit.editable = not busy
	if _password_edit != null:
		_password_edit.editable = not busy
	if _status_label != null and not msg.is_empty():
		_status_label.add_theme_color_override("font_color", Color(0.68, 0.90, 1.0, 1.0))
		_status_label.text = msg


func set_error(msg: String) -> void:
	_submitting = false
	if _login_btn != null:
		_login_btn.disabled = false
	if _username_edit != null:
		_username_edit.editable = true
	if _password_edit != null:
		_password_edit.editable = true
	if _status_label != null:
		_status_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.38, 1.0))
		_status_label.text = msg


func reset_for_logout(notice: String = "") -> void:
	_submitting = false
	if _password_edit != null:
		_password_edit.text = ""
	if _login_btn != null:
		_login_btn.disabled = false
	if _username_edit != null:
		_username_edit.editable = true
	if _password_edit != null:
		_password_edit.editable = true
	if _status_label != null:
		_status_label.add_theme_color_override("font_color", Color(0.75, 0.92, 1.0, 1.0))
		_status_label.text = notice


func compute_cover_rect(vp_size: Vector2, tex_size: Vector2) -> Rect2:
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return Rect2(Vector2.ZERO, vp_size)
	var sc := maxf(vp_size.x / tex_size.x, vp_size.y / tex_size.y)
	var w := tex_size.x * sc
	var h := tex_size.y * sc
	return Rect2((vp_size.x - w) * 0.5, (vp_size.y - h) * 0.5, w, h)


func _draw() -> void:
	var vp := get_viewport_rect().size
	if vp.x <= 1.0 or vp.y <= 1.0:
		vp = size
	if vp.x <= 1.0 or vp.y <= 1.0:
		return
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.03, 0.05, 0.09, 1.0), true)
	if _bg_tex != null:
		var cover := compute_cover_rect(vp, _bg_tex.get_size())
		draw_texture_rect(_bg_tex, cover, false, Color(1.0, 1.0, 1.0, 1.0))
	# Gentle dark vignette so frosted glass panel pops while keeping artwork crisp
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.02, 0.04, 0.08, 0.20), true)


func _on_frame_draw() -> void:
	if _frame_bg == null:
		return
	var r := Rect2(Vector2.ZERO, _frame_bg.size)
	var body_rect := Rect2(8.0, 8.0, r.size.x - 16.0, r.size.y - 36.0)
	# Lightweight frosted dark-glass interior so background shines through
	_frame_bg.draw_rect(body_rect, Color(0.04, 0.08, 0.14, 0.56), true)
	# Subtle frost sheen diagonal stripes inside glass
	_frame_bg.draw_colored_polygon(PackedVector2Array([
		Vector2(body_rect.position.x + 12.0, body_rect.position.y + 62.0),
		Vector2(body_rect.position.x + 150.0, body_rect.position.y + 62.0),
		Vector2(body_rect.position.x + 65.0, body_rect.end.y - 12.0),
		Vector2(body_rect.position.x + 12.0, body_rect.end.y - 12.0),
	]), Color(0.82, 0.92, 1.0, 0.06))
	# Cyan metallic header bar (matching image.png top bar)
	var hdr := Rect2(body_rect.position.x + 4.0, body_rect.position.y + 4.0, body_rect.size.x - 8.0, 56.0)
	_frame_bg.draw_rect(hdr, Color(0.04, 0.45, 0.72, 0.90), true)
	_frame_bg.draw_rect(Rect2(hdr.position.x, hdr.position.y, hdr.size.x, 10.0), Color(0.55, 0.88, 1.0, 0.35), true)
	# Silver metallic outer + inner bevel borders
	_frame_bg.draw_rect(body_rect, Color(0.10, 0.14, 0.20, 0.95), false, 8.0)
	_frame_bg.draw_rect(body_rect, Color(0.76, 0.82, 0.90, 0.95), false, 4.0)
	_frame_bg.draw_rect(body_rect.grow(-4.0), Color(0.94, 0.97, 1.0, 0.55), false, 1.5)
	_frame_bg.draw_line(Vector2(hdr.position.x, hdr.end.y), Vector2(hdr.end.x, hdr.end.y), Color(0.78, 0.86, 0.94, 0.90), 3.0)
	# Four silver corner steel brackets with rivets (image.png signature silhouette)
	var corners := [
		Vector2(body_rect.position.x, body_rect.position.y),
		Vector2(body_rect.end.x, body_rect.position.y),
		Vector2(body_rect.position.x, body_rect.end.y),
		Vector2(body_rect.end.x, body_rect.end.y),
	]
	for idx in range(corners.size()):
		var c: Vector2 = corners[idx]
		var sx := 1.0 if (idx == 0 or idx == 2) else -1.0
		var sy := 1.0 if (idx == 0 or idx == 1) else -1.0
		var arm := PackedVector2Array([
			c + Vector2(-8.0 * sx, -8.0 * sy),
			c + Vector2(36.0 * sx, -8.0 * sy),
			c + Vector2(36.0 * sx, 10.0 * sy),
			c + Vector2(10.0 * sx, 10.0 * sy),
			c + Vector2(10.0 * sx, 36.0 * sy),
			c + Vector2(-8.0 * sx, 36.0 * sy),
		])
		_frame_bg.draw_colored_polygon(arm, Color(0.74, 0.78, 0.84, 0.98))
		var poly_close := PackedVector2Array(arm)
		poly_close.append(arm[0])
		_frame_bg.draw_polyline(poly_close, Color(0.14, 0.18, 0.24, 0.98), 2.5)
		_frame_bg.draw_circle(c + Vector2(2.0 * sx, 2.0 * sy), 3.5, Color(0.32, 0.36, 0.42, 1.0))
		_frame_bg.draw_circle(c + Vector2(24.0 * sx, 1.0 * sy), 2.5, Color(0.32, 0.36, 0.42, 1.0))
		_frame_bg.draw_circle(c + Vector2(1.0 * sx, 24.0 * sy), 2.5, Color(0.32, 0.36, 0.42, 1.0))


func get_background_texture() -> Texture2D:
	return _bg_tex
