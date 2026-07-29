@tool
extends RefCounted

# Bake settings are persisted as node metadata on the GaussianSplatNode so the
# inspector panel can restore them the next time the node is selected. Same
# shape and contract as the collision module's generation_metadata.gd, with a
# separate `_gdgs_lighting_` namespace so the two never collide.

const BUILDER_SCRIPT := preload("res://addons/gdgs/lighting/bake/proxy_builder.gd")

const AUTO_VOXEL := &"_gdgs_lighting_auto_voxel"
const VOXEL_SIZE := &"_gdgs_lighting_voxel_size"
const OPACITY_CUTOFF := &"_gdgs_lighting_opacity_cutoff"
const COMPUTE_BACKEND := &"_gdgs_lighting_compute_backend"
const NORMAL_SMOOTHING := &"_gdgs_lighting_normal_smoothing"
const AO_RADIUS := &"_gdgs_lighting_ao_radius"
const AO_STRENGTH := &"_gdgs_lighting_ao_strength"

# meta key → settings key. Defaults come from the builder so there is one
# source of truth for what an unbaked node starts with.
const FIELDS := {
	AUTO_VOXEL: "auto_voxel",
	VOXEL_SIZE: "voxel_size",
	OPACITY_CUTOFF: "opacity_cutoff",
	COMPUTE_BACKEND: "compute_backend",
	NORMAL_SMOOTHING: "normal_smoothing",
	AO_RADIUS: "ao_radius",
	AO_STRENGTH: "ao_strength",
}


static func settings_from_node(node: Node) -> Dictionary:
	var defaults: Dictionary = BUILDER_SCRIPT.default_settings()
	var settings: Dictionary = {}
	for meta_key: StringName in FIELDS:
		var settings_key: String = FIELDS[meta_key]
		settings[settings_key] = node.get_meta(meta_key, defaults[settings_key])
	return settings


static func metadata_from_settings(settings: Dictionary) -> Dictionary:
	var metadata: Dictionary = {}
	for meta_key: StringName in FIELDS:
		metadata[meta_key] = settings[FIELDS[meta_key]]
	return metadata


static func capture(node: Node) -> Dictionary:
	var metadata: Dictionary = {}
	for meta_key: StringName in FIELDS:
		if node.has_meta(meta_key):
			metadata[meta_key] = node.get_meta(meta_key)
	return metadata


static func apply(node: Node, metadata: Dictionary) -> void:
	for meta_key: StringName in FIELDS:
		if node.has_meta(meta_key):
			node.remove_meta(meta_key)
	for key: Variant in metadata:
		node.set_meta(StringName(str(key)), metadata[key])
