shader_type canvas_item;
uniform bool clip_enabled = false;
uniform float clip_y = 0.0;
varying float pose_y;
varying vec4 v_modulate;
void vertex() {
	pose_y = VERTEX.y;
	v_modulate = COLOR;
}
void fragment() {
	if (clip_enabled && pose_y > clip_y) { discard; }
	COLOR = texture(TEXTURE, UV) * v_modulate;
}
