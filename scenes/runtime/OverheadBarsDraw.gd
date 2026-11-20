class_name OverheadBarsDraw
extends RefCounted
## Draws crisp rounded pill HP / Mana / Stamina bars matching the Owner's reference sample,
## plus the animated Target Pointer chevron above the selected monster / item / NPC.

const FLOATING_DAMAGE_FONT_SIZE := 24
const FLOATING_DAMAGE_OUTLINE_SIZE := 5
const DefaultHitImpactFrames: SpriteFrames = preload("res://assets/fx/hit_impact/hit_impact.tres")
const DEFAULT_HIT_IMPACT_MELEE_SIZE_PX := 144.0
const DEFAULT_HIT_IMPACT_HEAVY_SIZE_PX := 216.0

static var _cached_sb_track: StyleBoxFlat = null
static var _cached_sb_fill: StyleBoxFlat = null


static func draw_pill_bar(canvas: CanvasItem, rect: Rect2, ratio: float, fill_color: Color, track_color: Color) -> void:
	var r := clampf(ratio, 0.0, 1.0)
	var radius_i := int(ceilf(rect.size.y * 0.5))
	if _cached_sb_track == null:
		_cached_sb_track = StyleBoxFlat.new()
	_cached_sb_track.bg_color = track_color
	_cached_sb_track.set_corner_radius_all(radius_i)
	canvas.draw_style_box(_cached_sb_track, rect)
	if r > 0.005:
		var fill_w := minf(rect.size.x, maxf(rect.size.y, rect.size.x * r))
		if _cached_sb_fill == null:
			_cached_sb_fill = StyleBoxFlat.new()
		_cached_sb_fill.bg_color = fill_color
		_cached_sb_fill.set_corner_radius_all(radius_i)
		canvas.draw_style_box(_cached_sb_fill, Rect2(rect.position, Vector2(fill_w, rect.size.y)))


static func draw_player_bars(canvas: CanvasItem, center_x: float, top_y: float, hp: float, max_hp: float, mana: float, max_mana: float, display_name: String = "", is_remote: bool = false) -> void:
	var bar_w := 124.0
	var hp_h := 16.0
	var mana_h := 9.0
	var gap := 4.0
	var x0 := center_x - bar_w * 0.5
	var hp_rect := Rect2(x0, top_y - hp_h - mana_h - gap, bar_w, hp_h)
	var mana_rect := Rect2(x0, top_y - mana_h, bar_w, mana_h)
	var white_track := Color(0.98, 0.99, 1.0, 0.96)
	var hp_col := Color(0.12, 0.84, 0.98, 1.0) if is_remote else Color(0.0, 0.93, 0.04, 1.0)
	draw_pill_bar(canvas, hp_rect, hp / maxf(1.0, max_hp), hp_col, white_track)
	draw_pill_bar(canvas, mana_rect, mana / maxf(1.0, max_mana), Color(0.0, 0.68, 0.96, 1.0), white_track)
	var font := ThemeDB.fallback_font
	if font != null:
		var txt := "%d/%d" % [int(ceilf(maxf(0.0, hp))), int(round(max_hp))]
		canvas.draw_string(font, Vector2(x0, hp_rect.position.y - 4.0), txt, HORIZONTAL_ALIGNMENT_CENTER, bar_w, 15, Color(0.98, 1.0, 0.98, 0.98))
		if not display_name.is_empty():
			var name_pos := Vector2(x0 - 36.0, hp_rect.position.y - 24.0)
			var name_col := Color(0.42, 0.96, 1.0, 1.0) if is_remote else Color(1.0, 0.92, 0.36, 1.0)
			canvas.draw_string_outline(font, name_pos, display_name, HORIZONTAL_ALIGNMENT_CENTER, bar_w + 72.0, 18, 4, Color(0.03, 0.06, 0.12, 0.96))
			canvas.draw_string(font, name_pos, display_name, HORIZONTAL_ALIGNMENT_CENTER, bar_w + 72.0, 18, name_col)


static func draw_enemy_bars(canvas: CanvasItem, center_x: float, top_y: float, hp: float, max_hp: float, stamina: float, max_stamina: float, stunned: bool = false, label_txt: String = "", is_boss: bool = false) -> void:
	var bar_w := 152.0 if is_boss else 116.0
	var hp_h := 17.0 if is_boss else 14.0
	var stam_h := 9.0 if is_boss else 8.0
	var gap := 3.0
	var x0 := center_x - bar_w * 0.5
	var hp_rect := Rect2(x0, top_y - hp_h - stam_h - gap, bar_w, hp_h)
	var stam_rect := Rect2(x0, top_y - stam_h, bar_w, stam_h)
	var hp_col := Color(0.95, 0.08, 0.08, 1.0) if is_boss else Color(0.92, 0.15, 0.15, 1.0)
	draw_pill_bar(canvas, hp_rect, hp / maxf(1.0, max_hp), hp_col, Color(0.98, 0.99, 1.0, 0.95))
	var stam_fill := Color(0.98, 0.72, 0.18, 1.0) if stunned else Color(0.93, 0.94, 0.97, 0.96)
	var stam_track := Color(0.18, 0.22, 0.30, 0.85)
	draw_pill_bar(canvas, stam_rect, stamina / maxf(1.0, max_stamina), stam_fill, stam_track)
	var font := ThemeDB.fallback_font
	if font != null:
		if is_boss:
			var boss_name := label_txt if not label_txt.is_empty() else "Drum"
			if stunned:
				boss_name += " [STUN]"
			var name_pos := Vector2(x0 - 24.0, hp_rect.position.y - 6.0)
			canvas.draw_string_outline(font, name_pos, boss_name, HORIZONTAL_ALIGNMENT_CENTER, bar_w + 48.0, 18, 4, Color(0.05, 0.02, 0.03, 0.96))
			canvas.draw_string(font, name_pos, boss_name, HORIZONTAL_ALIGNMENT_CENTER, bar_w + 48.0, 18, Color(1.0, 0.14, 0.14, 1.0))
		else:
			var top_str := "%s %d" % [label_txt, int(ceilf(maxf(0.0, hp)))] if not label_txt.is_empty() else "%d/%d" % [int(ceilf(maxf(0.0, hp))), int(round(max_hp))]
			if stunned:
				top_str += " [STUN]"
			canvas.draw_string(font, Vector2(x0 - 24.0, hp_rect.position.y - 4.0), top_str, HORIZONTAL_ALIGNMENT_CENTER, bar_w + 48.0, 14, Color(1.0, 0.94, 0.82, 0.98))


static func _draw_brush_stroke(canvas: CanvasItem, p0: Vector2, p1: Vector2, prog: float, base_w: float, col: Color, outline_col: Color) -> void:
	var t := clampf(prog, 0.0, 1.0)
	if t <= 0.01:
		return
	var steps := 10
	var dir := p1 - p0
	var len_px := dir.length()
	if len_px <= 0.5:
		return
	var perp := Vector2(-dir.y, dir.x) / len_px
	var cur_steps := maxi(1, int(ceilf(float(steps) * t)))
	for i in range(cur_steps):
		var s0 := float(i) / float(steps)
		var s1 := minf(t, float(i + 1) / float(steps))
		if s1 <= s0:
			continue
		var a := p0.lerp(p1, s0) + perp * (sin(s0 * PI) * 1.4)
		var b := p0.lerp(p1, s1) + perp * (sin(s1 * PI) * 1.4)
		# Calligraphic taper: thicker at head/belly, sharp brush tip at tail
		var w := base_w * (1.18 - 0.52 * s0)
		canvas.draw_line(a, b, outline_col, w + 3.2, true)
	for i in range(cur_steps):
		var s0 := float(i) / float(steps)
		var s1 := minf(t, float(i + 1) / float(steps))
		if s1 <= s0:
			continue
		var a := p0.lerp(p1, s0) + perp * (sin(s0 * PI) * 1.4)
		var b := p0.lerp(p1, s1) + perp * (sin(s1 * PI) * 1.4)
		var w := base_w * (1.18 - 0.52 * s0)
		canvas.draw_line(a, b, col, w, true)


static func draw_calligraphic_red_x(canvas: CanvasItem, center_pos: Vector2, anim_progress: float, bob_phase_s: float, scale_boost: float = 1.0, alpha_mul: float = 1.0) -> void:
	var amul := clampf(alpha_mul, 0.0, 1.0)
	if amul <= 0.01:
		return
	var p := clampf(anim_progress, 0.0, 1.0)
	var bob := sin(bob_phase_s * 6.0) * 3.0 if p >= 0.95 else 0.0
	var c := center_pos + Vector2(0.0, bob)
	var r := 16.0 * scale_boost
	var stroke1_prog := clampf(p / 0.48, 0.0, 1.0)
	var stroke2_prog := clampf((p - 0.48) / 0.48, 0.0, 1.0)
	var ink_col := Color(0.96, 0.10, 0.12, 0.98 * amul)
	var outline_col := Color(0.14, 0.02, 0.03, 0.95 * amul)
	_draw_brush_stroke(canvas, c + Vector2(-r, -r), c + Vector2(r, r), stroke1_prog, 5.2 * scale_boost, ink_col, outline_col)
	_draw_brush_stroke(canvas, c + Vector2(r, -r), c + Vector2(-r, r), stroke2_prog, 5.2 * scale_boost, ink_col, outline_col)


static func draw_target_pointer(canvas: CanvasItem, target_pos: Vector2, bob_phase_s: float, kind: String = "enemy") -> void:
	var bob := sin(bob_phase_s * 6.0) * 4.0
	var tip := target_pos + Vector2(0.0, bob)
	var col := Color(1.0, 0.26, 0.26, 0.98)
	if kind == "item":
		col = Color(1.0, 0.84, 0.18, 0.98)
	elif kind == "npc":
		col = Color(0.24, 0.92, 0.98, 0.98)
	var pts := PackedVector2Array([
		tip,
		tip + Vector2(-12.0, -16.0),
		tip + Vector2(12.0, -16.0),
	])
	canvas.draw_colored_polygon(pts, col)
	canvas.draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]), Color(0.04, 0.06, 0.10, 0.95), 2.0)


static func draw_selection_ring(canvas: CanvasItem, body_rect: Rect2, progress: float, kind: String = "enemy") -> void:
	var p := clampf(progress, 0.0, 1.0)
	var col := Color(1.0, 0.30, 0.30, p * 0.95)
	if kind == "item":
		col = Color(1.0, 0.86, 0.20, p * 0.95)
	elif kind == "npc":
		col = Color(0.28, 0.92, 1.0, p * 0.95)
	var grow_px := (1.0 - p) * 14.0
	var r := body_rect.grow(grow_px)
	canvas.draw_rect(r, col, false, 2.5)


static func draw_hit_impact(canvas: CanvasItem, pos: Vector2, progress: float, kind: String = "melee", impact_dir: Vector2 = Vector2.RIGHT, custom_frames: SpriteFrames = null) -> void:
	var p := clampf(progress, 0.0, 1.0)
	var inv := 1.0 - p

	if kind == "melee" or kind == "heavy":
		# Canonical default melee/heavy hit impact sprite FX (Owner sample `image copy 2.png` + 6 dissipation frames).
		# Applies to all heroes, monsters, and bosses unless a character explicitly supplies `custom_frames`.
		var frames: SpriteFrames = custom_frames if (custom_frames != null and custom_frames.has_animation(&"hit") and custom_frames.get_frame_count(&"hit") > 0) else DefaultHitImpactFrames
		if frames != null and frames.has_animation(&"hit"):
			var fc := frames.get_frame_count(&"hit")
			if fc > 0:
				var fi := clampi(int(floor(p * float(fc))), 0, fc - 1)
				var tex := frames.get_frame_texture(&"hit", fi)
				if tex != null:
					var draw_sz := DEFAULT_HIT_IMPACT_HEAVY_SIZE_PX if kind == "heavy" else DEFAULT_HIT_IMPACT_MELEE_SIZE_PX
					var half_sz := draw_sz * 0.5
					var flip_x := -1.0 if impact_dir.x < -0.05 else 1.0
					canvas.draw_set_transform(pos, 0.0, Vector2(flip_x, 1.0))
					canvas.draw_texture_rect(tex, Rect2(-half_sz, -half_sz, draw_sz, draw_sz), false, Color.WHITE)
					canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
					return
		return

	var outer_col := Color(1.0, 0.78, 0.20, inv * 0.95)
	var core_col := Color(1.0, 0.98, 0.86, inv)
	var max_r := 28.0
	if kind == "skill":
		outer_col = Color(0.28, 0.86, 1.0, inv * 0.95)
		max_r = 44.0
	elif kind == "stun":
		outer_col = Color(1.0, 0.62, 0.12, inv)
		max_r = 48.0
	elif kind == "clash":
		outer_col = Color(1.0, 0.90, 0.36, inv)
		max_r = 46.0
	elif kind == "player_hit":
		outer_col = Color(1.0, 0.24, 0.24, inv * 0.95)
		max_r = 32.0

	var radius := lerpf(8.0, max_r, p)
	# Reduce hit-impact glare contrast by an additional 40% (0.64 * 0.60 = 0.384 on flash overlay glare).
	var lum := 0.384
	outer_col = Color(outer_col.r * lum, outer_col.g * lum, outer_col.b * lum, outer_col.a * lum)
	core_col = Color(core_col.r * lum, core_col.g * lum, core_col.b * lum, core_col.a * lum)
	# Crisp pixel shockbox + diagonal star sparks (zero blur/ellipse)
	var box := Rect2(pos.x - radius, pos.y - radius, radius * 2.0, radius * 2.0)
	canvas.draw_rect(box, outer_col, false, 2.5)
	var core_sz := maxf(4.0, (1.0 - p * 0.7) * 14.0)
	canvas.draw_rect(Rect2(pos.x - core_sz * 0.5, pos.y - core_sz * 0.5, core_sz, core_sz), core_col, true)
	for dir_vec in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1), Vector2(0.75, 0.75), Vector2(-0.75, 0.75), Vector2(0.75, -0.75), Vector2(-0.75, -0.75)]:
		var p0 := pos + (dir_vec as Vector2) * (radius * 0.45)
		var p1 := pos + (dir_vec as Vector2) * (radius * 1.25)
		canvas.draw_line(p0, p1, outer_col, 2.5)


static func draw_floating_damage(canvas: CanvasItem, pos: Vector2, text_str: String, progress: float, color: Color) -> void:
	var font := ThemeDB.fallback_font
	if font == null or text_str.is_empty():
		return
	var alpha := clampf(1.0 - maxf(0.0, progress - 0.35) / 0.65, 0.0, 1.0)
	var col := Color(color.r, color.g, color.b, alpha)
	var outline := Color(0.03, 0.04, 0.08, alpha * 0.96)
	var draw_pos := Vector2(pos.x - 72.0, pos.y)
	canvas.draw_string_outline(font, draw_pos, text_str, HORIZONTAL_ALIGNMENT_CENTER, 144.0, FLOATING_DAMAGE_FONT_SIZE, FLOATING_DAMAGE_OUTLINE_SIZE, outline)
	canvas.draw_string(font, draw_pos, text_str, HORIZONTAL_ALIGNMENT_CENTER, 144.0, FLOATING_DAMAGE_FONT_SIZE, col)
