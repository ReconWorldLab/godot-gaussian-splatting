@tool
extends RefCounted

# Generation settings are persisted as node metadata on the GaussianSplatNode
# so the inspector panel can restore them the next time the node is selected.
# This file owns the meta keys, the UI defaults, and the mapping between the
# metadata namespace and the plain settings keys used by the pipeline/UI.

const AUTO_VOXEL := &"_gdgs_collision_auto_voxel"
const VOXEL_SIZE := &"_gdgs_collision_voxel_size"
const OPACITY_CUTOFF := &"_gdgs_collision_opacity_cutoff"
const MESH_MODE := &"_gdgs_collision_mesh_mode"
const COMPUTE_BACKEND := &"_gdgs_collision_compute_backend"
const SCENE_MODE := &"_gdgs_collision_scene_mode"
const DILATION := &"_gdgs_collision_dilation"
const CARVE := &"_gdgs_collision_carve"
const CAPSULE_HEIGHT := &"_gdgs_collision_capsule_height"
const CAPSULE_RADIUS := &"_gdgs_collision_capsule_radius"

# meta key → [settings key, default value]
const FIELDS := {
	AUTO_VOXEL: ["auto_voxel", true],
	VOXEL_SIZE: ["voxel_size", 0.05],
	OPACITY_CUTOFF: ["opacity_cutoff", 0.1],
	MESH_MODE: ["mesh_mode", "faces"],
	COMPUTE_BACKEND: ["compute_backend", "auto"],
	SCENE_MODE: ["scene_mode", "object"],
	DILATION: ["dilation", 1.6],
	CARVE: ["carve", false],
	CAPSULE_HEIGHT: ["capsule_height", 1.6],
	CAPSULE_RADIUS: ["capsule_radius", 0.2],
}


# Settings for the inspector UI: stored metadata where present, defaults otherwise.
static func settings_from_node(node: Node) -> Dictionary:
	var settings: Dictionary = {}
	for meta_key: StringName in FIELDS:
		var field: Array = FIELDS[meta_key]
		settings[field[0]] = node.get_meta(meta_key, field[1])
	return settings


# Metadata dictionary recording the settings of a successful generation.
static func metadata_from_settings(settings: Dictionary) -> Dictionary:
	var metadata: Dictionary = {}
	for meta_key: StringName in FIELDS:
		var field: Array = FIELDS[meta_key]
		metadata[meta_key] = settings[field[0]]
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
