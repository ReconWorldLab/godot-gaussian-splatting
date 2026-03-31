@tool
@icon("res://addons/gdgs/editor/icons/gaussian_resource.svg")
extends Resource
class_name GaussianResource

# GPU-ready std430 layout.
# Each splat occupies 60 float32 values (240 bytes).
@export var point_count: int = 0
@export var point_data_float: PackedFloat32Array
@export var point_data_byte: PackedByteArray
@export var xyz: PackedVector3Array
@export var aabb: AABB = AABB()
