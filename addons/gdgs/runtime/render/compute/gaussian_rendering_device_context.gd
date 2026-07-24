class_name GdgsRenderingDeviceContext
extends Object

# Thin wrapper around RenderingDevice with basic allocation helpers.
class DeletionQueue:
	var queue: Array[RID] = []

	func push(rid: RID) -> RID:
		queue.push_back(rid)
		return rid

	func flush(device: RenderingDevice) -> void:
		for i in range(queue.size() - 1, -1, -1):
			if not queue[i].is_valid():
				continue
			device.free_rid(queue[i])
		queue.clear()

	func free_rid(device: RenderingDevice, rid: RID) -> void:
		var rid_idx := queue.find(rid)
		assert(rid_idx != -1, "RID was not found in deletion queue.")
		device.free_rid(queue.pop_at(rid_idx))

class Descriptor:
	var rid: RID
	var type: RenderingDevice.UniformType

	func _init(rid_: RID, type_: RenderingDevice.UniformType) -> void:
		rid = rid_
		type = type_

var device: RenderingDevice
var deletion_queue := DeletionQueue.new()
var shader_cache: Dictionary = {}

static func create(device_: RenderingDevice = null) -> GdgsRenderingDeviceContext:
	var context := GdgsRenderingDeviceContext.new()
	context.device = RenderingServer.create_local_rendering_device() if device_ == null else device_
	return context

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		deletion_queue.flush(device)
		shader_cache.clear()

func compute_list_begin() -> int:
	return device.compute_list_begin()

func compute_list_end() -> void:
	device.compute_list_end()

func load_shader(path: String) -> RID:
	if not shader_cache.has(path):
		var shader_file: RDShaderFile = load(path)
		var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
		shader_cache[path] = deletion_queue.push(device.shader_create_from_spirv(shader_spirv))
	return shader_cache[path]

func create_storage_buffer(size: int, data: PackedByteArray = PackedByteArray(), usage: int = 0) -> Descriptor:
	var buffer_data := data
	if size > buffer_data.size():
		var padding := PackedByteArray()
		padding.resize(size - buffer_data.size())
		buffer_data += padding
	return Descriptor.new(deletion_queue.push(device.storage_buffer_create(maxi(size, buffer_data.size()), buffer_data, usage)), RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)

func create_uniform_buffer(size: int, data: PackedByteArray = PackedByteArray()) -> Descriptor:
	var full_size := maxi(16, size)
	var buffer_data := data
	if full_size > buffer_data.size():
		var padding := PackedByteArray()
		padding.resize(full_size - buffer_data.size())
		buffer_data += padding
	return Descriptor.new(deletion_queue.push(device.uniform_buffer_create(full_size, buffer_data)), RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)

func create_texture(
	dimensions: Vector2i,
	format: RenderingDevice.DataFormat,
	usage: int = 0x18B,
	view: RDTextureView = RDTextureView.new(),
	data: Array[PackedByteArray] = []
) -> Descriptor:
	var texture_format := RDTextureFormat.new()
	texture_format.format = format
	texture_format.width = dimensions.x
	texture_format.height = dimensions.y
	texture_format.usage_bits = usage
	return Descriptor.new(deletion_queue.push(device.texture_create(texture_format, view, data)), RenderingDevice.UNIFORM_TYPE_IMAGE)

func create_descriptor_set(descriptors: Array, shader: RID, descriptor_set_index: int = 0) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in range(descriptors.size()):
		var descriptor: Descriptor = descriptors[i]
		var uniform := RDUniform.new()
		uniform.uniform_type = descriptor.type
		uniform.binding = i
		uniform.add_id(descriptor.rid)
		uniforms.push_back(uniform)
	return deletion_queue.push(device.uniform_set_create(uniforms, shader, descriptor_set_index))

func create_pipeline(block_dimensions: Array, descriptor_sets: Array, shader: RID) -> Callable:
	var pipeline := deletion_queue.push(device.compute_pipeline_create(shader))
	return func(
		context: GdgsRenderingDeviceContext,
		compute_list: int,
		push_constant: PackedByteArray = PackedByteArray(),
		descriptor_set_overwrites: Array = [],
		block_dimensions_overwrite_buffer: RID = RID(),
		block_dimensions_overwrite_buffer_byte_offset: int = 0
	) -> void:
		var sets := descriptor_sets if descriptor_set_overwrites.is_empty() else descriptor_set_overwrites
		assert(block_dimensions.size() == 3 or block_dimensions_overwrite_buffer.is_valid(), "Must specify block dimensions or use dispatch indirect.")
		assert(sets.size() >= 1, "Must specify at least one descriptor set.")

		var rd := context.device
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		if not push_constant.is_empty():
			rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		for i in range(sets.size()):
			rd.compute_list_bind_uniform_set(compute_list, sets[i], i)
		if block_dimensions_overwrite_buffer.is_valid():
			rd.compute_list_dispatch_indirect(compute_list, block_dimensions_overwrite_buffer, block_dimensions_overwrite_buffer_byte_offset)
		else:
			rd.compute_list_dispatch(compute_list, block_dimensions[0], block_dimensions[1], block_dimensions[2])
		rd.compute_list_add_barrier(compute_list)

static func create_push_constant(data: Array) -> PackedByteArray:
	var packed_size := data.size() * 4
	assert(packed_size <= 128, "Push constant size must be at most 128 bytes.")

	var padding := ceili(packed_size / 16.0) * 16 - packed_size
	var packed_data := PackedByteArray()
	packed_data.resize(packed_size + (padding if padding > 0 else 0))
	packed_data.fill(0)

	for i in range(data.size()):
		match typeof(data[i]):
			TYPE_INT, TYPE_BOOL:
				packed_data.encode_s32(i * 4, int(data[i]))
			TYPE_FLOAT:
				packed_data.encode_float(i * 4, float(data[i]))
	return packed_data
