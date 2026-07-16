extends RefCounted

const BLOCK_SIZE := 4
const SOLID_BLOCK_MASK := -1

var origin: Vector3
var voxel_size: float
var nx: int
var ny: int
var nz: int
var nbx: int
var nby: int
var nbz: int
var block_stride: int
var _blocks: Dictionary = {}


func _init(p_origin: Vector3, p_voxel_size: float, p_nx: int, p_ny: int, p_nz: int) -> void:
	origin = p_origin
	voxel_size = p_voxel_size
	nx = p_nx
	ny = p_ny
	nz = p_nz
	nbx = nx / BLOCK_SIZE
	nby = ny / BLOCK_SIZE
	nbz = nz / BLOCK_SIZE
	block_stride = nbx * nby


func block_index(bx: int, by: int, bz: int) -> int:
	return bx + by * nbx + bz * block_stride


func decode_block_index(index: int) -> Vector3i:
	var bx := index % nbx
	var by_bz := index / nbx
	var by := by_bz % nby
	var bz := by_bz / nby
	return Vector3i(bx, by, bz)


func set_block_mask(index: int, mask: int) -> void:
	if mask == 0:
		_blocks.erase(index)
	else:
		_blocks[index] = mask


func get_block_mask(index: int) -> int:
	return int(_blocks.get(index, 0))


func get_occupied_block_indices() -> Array:
	return _blocks.keys()


func get_blocks_snapshot() -> Dictionary:
	return _blocks.duplicate()


func replace_blocks(blocks: Dictionary) -> void:
	_blocks = blocks


func is_voxel_solid(ix: int, iy: int, iz: int) -> bool:
	return is_voxel_solid_in(_blocks, ix, iy, iz)


func set_voxel_solid(ix: int, iy: int, iz: int, solid: bool = true) -> void:
	if ix < 0 or iy < 0 or iz < 0 or ix >= nx or iy >= ny or iz >= nz:
		return
	var index := block_index(ix >> 2, iy >> 2, iz >> 2)
	var mask := int(_blocks.get(index, 0))
	var bit_index := (ix & 3) + ((iy & 3) << 2) + ((iz & 3) << 4)
	if solid:
		mask |= 1 << bit_index
	else:
		mask &= ~(1 << bit_index)
	set_block_mask(index, mask)


func is_voxel_solid_in(blocks: Dictionary, ix: int, iy: int, iz: int) -> bool:
	if ix < 0 or iy < 0 or iz < 0 or ix >= nx or iy >= ny or iz >= nz:
		return false
	var index := block_index(ix >> 2, iy >> 2, iz >> 2)
	var mask := int(blocks.get(index, 0))
	if mask == 0:
		return false
	if mask == SOLID_BLOCK_MASK:
		return true
	var bit_index := (ix & 3) + ((iy & 3) << 2) + ((iz & 3) << 4)
	return (mask & (1 << bit_index)) != 0


func occupied_voxel_count() -> int:
	var count := 0
	for mask_value: Variant in _blocks.values():
		var mask := int(mask_value)
		if mask == SOLID_BLOCK_MASK:
			count += 64
		else:
			for bit_index in 64:
				if (mask & (1 << bit_index)) != 0:
					count += 1
	return count


func world_to_voxel_floor(position: Vector3) -> Vector3i:
	var local := (position - origin) / voxel_size
	return Vector3i(floori(local.x), floori(local.y), floori(local.z))
