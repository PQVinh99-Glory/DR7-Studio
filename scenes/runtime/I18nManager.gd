class_name I18nManager
extends RefCounted
## Locked 5-language i18n runtime loader reading `res://assets/i18n/languages.json`.
## Owner policy (2026-11-19):
## - Default locale is strictly "en" (never auto-detects OS locale).
## - Locale can ONLY be changed explicitly via in-game Settings.
## - Supported locales: ["en", "zh-CN", "vi", "es", "pt-BR"].

const LANGUAGES_JSON_PATH := "res://assets/i18n/languages.json"

var default_locale: String = "en"
var fallback_locale: String = "en"
var auto_detect_os_locale: bool = false
var change_only_in_settings: bool = true
var current_locale: String = "en"
var supported_locales: Array[Dictionary] = []
var supported_codes: PackedStringArray = PackedStringArray(["en", "zh-CN", "vi", "es", "pt-BR"])

const STRINGS := {
	"en": {
		"settings.language": "Language",
		"hud.settings": "Settings",
		"hud.spawn_boss": "Spawn Boss Drum",
		"hud.hide_ui": "Hide UI",
		"hud.show_ui": "Show UI",
		"hud.immortal_on": "Immortal: ON",
		"hud.immortal_off": "Immortal: OFF",
	},
	"zh-CN": {
		"settings.language": "语言",
		"hud.settings": "设置",
		"hud.spawn_boss": "召唤 Boss Drum",
		"hud.hide_ui": "隐藏界面",
		"hud.show_ui": "显示界面",
		"hud.immortal_on": "无敌: 开",
		"hud.immortal_off": "无敌: 关",
	},
	"vi": {
		"settings.language": "Ngôn ngữ",
		"hud.settings": "Cài đặt",
		"hud.spawn_boss": "Gọi Boss Drum",
		"hud.hide_ui": "Ẩn UI",
		"hud.show_ui": "Hiện UI",
		"hud.immortal_on": "Bất tử: BẬT",
		"hud.immortal_off": "Bất tử: TẮT",
	},
	"es": {
		"settings.language": "Idioma",
		"hud.settings": "Ajustes",
		"hud.spawn_boss": "Invocar Boss Drum",
		"hud.hide_ui": "Ocultar UI",
		"hud.show_ui": "Mostrar UI",
		"hud.immortal_on": "Inmortal: SÍ",
		"hud.immortal_off": "Inmortal: NO",
	},
	"pt-BR": {
		"settings.language": "Idioma",
		"hud.settings": "Configurações",
		"hud.spawn_boss": "Invocar Boss Drum",
		"hud.hide_ui": "Ocultar UI",
		"hud.show_ui": "Mostrar UI",
		"hud.immortal_on": "Imortal: LIG",
		"hud.immortal_off": "Imortal: DES",
	},
}


func _init() -> void:
	load_config()


func load_config(res_path: String = LANGUAGES_JSON_PATH) -> bool:
	if not FileAccess.file_exists(res_path):
		current_locale = default_locale
		return false
	var raw := FileAccess.get_file_as_string(res_path)
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		current_locale = default_locale
		return false
	var cfg: Dictionary = parsed
	default_locale = str(cfg.get("default_locale", "en"))
	fallback_locale = str(cfg.get("fallback_locale", "en"))
	auto_detect_os_locale = bool(cfg.get("auto_detect_os_locale", false))
	change_only_in_settings = bool(cfg.get("change_only_in_settings", true))
	supported_locales.clear()
	var next_codes := PackedStringArray()
	var raw_list: Variant = cfg.get("supported_locales", [])
	if raw_list is Array:
		for item in raw_list:
			if item is Dictionary and item.has("code"):
				supported_locales.append(item)
				next_codes.append(str(item["code"]))
	if not next_codes.is_empty():
		supported_codes = next_codes
	# Strictly lock initial locale to default_locale ("en"), ignoring OS locale.
	current_locale = default_locale
	return true


func is_supported(code: String) -> bool:
	return supported_codes.has(code)


func set_locale(code: String) -> bool:
	if not is_supported(code):
		return false
	current_locale = code
	return true


func get_locale() -> String:
	return current_locale


func cycle_locale() -> String:
	if supported_codes.is_empty():
		return current_locale
	var idx := supported_codes.find(current_locale)
	var next_idx := (idx + 1) % supported_codes.size()
	current_locale = supported_codes[next_idx]
	return current_locale


func tr_key(key: String, fallback_text: String = "") -> String:
	var table: Dictionary = STRINGS.get(current_locale, {})
	if table.has(key):
		return str(table[key])
	var fb_table: Dictionary = STRINGS.get(fallback_locale, {})
	if fb_table.has(key):
		return str(fb_table[key])
	return fallback_text if not fallback_text.is_empty() else key
