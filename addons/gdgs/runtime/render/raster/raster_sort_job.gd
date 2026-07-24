@tool
extends RefCounted

## WorkerThreadPool job wrapper with a double-buffered order handoff for one
## splat node. The sort runs off the main thread on an immutable position
## snapshot and writes the back buffer; the main thread keeps rendering from the
## front buffer until the task completes, then swaps. This is what lets the
## per-frame sort lag the camera by a frame or two without stalling rendering.

const Sorter := preload("res://addons/gdgs/runtime/render/raster/raster_sorter.gd")

var _xyz: PackedVector3Array = PackedVector3Array()
var _buffers := [PackedInt32Array(), PackedInt32Array()]
var _front := 0
var _task_id := -1
var _pending_dir := Vector3.ZERO

func set_positions(xyz: PackedVector3Array) -> void:
	_xyz = xyz

func point_count() -> int:
	return _xyz.size()

func is_running() -> bool:
	return _task_id != -1

## Front (currently renderable) order buffer.
func front_order() -> PackedInt32Array:
	return _buffers[_front]

## Start a sort into the back buffer for the given local-space view direction.
## No-op if a task is already in flight. Returns true if a task was started.
func kick(view_dir_local: Vector3) -> bool:
	if _task_id != -1:
		return false
	_pending_dir = view_dir_local
	_task_id = WorkerThreadPool.add_task(Callable(self, "_run"), false, "gdgs raster sort")
	return true

func _run() -> void:
	var back := 1 - _front
	Sorter.sort_into(_xyz, _pending_dir, _buffers[back])

## Called each frame on the main thread. If the in-flight task has finished,
## collect it, swap buffers and return true (front_order() now holds the fresh
## order). Returns false if nothing was running or it is not done yet.
func poll() -> bool:
	if _task_id == -1:
		return false
	if not WorkerThreadPool.is_task_completed(_task_id):
		return false
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_front = 1 - _front
	return true

## Block until any in-flight task finishes. Call before freeing the job so the
## worker never touches freed state.
func flush() -> void:
	if _task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
