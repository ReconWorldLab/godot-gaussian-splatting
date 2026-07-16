extends RefCounted

const PIPELINE_SCRIPT := preload("res://addons/gdgs/collision/pipeline/collision_pipeline.gd")

var _mutex := Mutex.new()
var _snapshot: Dictionary
var _settings: Dictionary
var _cancel_requested := false
var _stage := "Waiting for worker"
var _progress := 0.0
var _result: Dictionary = {}


func _init(
	data_snapshot: Dictionary,
	requested_voxel_size: float = 0.0,
	opacity_cutoff: float = 0.1,
	settings: Dictionary = {}
) -> void:
	_snapshot = data_snapshot
	_settings = settings.duplicate(true)
	_settings["voxel_size"] = requested_voxel_size
	_settings["opacity_cutoff"] = opacity_cutoff


# WorkerThreadPool entry point. It only touches the immutable value snapshot,
# local pipeline data, and mutex-protected job state.
func run() -> void:
	report_progress("Starting collision pipeline", 0.0)
	var result := PIPELINE_SCRIPT.generate_from_snapshot_settings(_snapshot, _settings, self)
	_snapshot.clear()
	_settings.clear()
	_mutex.lock()
	_result = result
	_mutex.unlock()


func request_cancel() -> void:
	_mutex.lock()
	_cancel_requested = true
	_mutex.unlock()


func is_cancel_requested() -> bool:
	_mutex.lock()
	var requested := _cancel_requested
	_mutex.unlock()
	return requested


func report_progress(stage: String, progress: float) -> void:
	_mutex.lock()
	_stage = stage
	_progress = clampf(progress, 0.0, 1.0)
	_mutex.unlock()


func get_status() -> Dictionary:
	_mutex.lock()
	var status := {
		"stage": _stage,
		"progress": _progress,
		"cancel_requested": _cancel_requested,
	}
	_mutex.unlock()
	return status


func get_result() -> Dictionary:
	_mutex.lock()
	var result := _result.duplicate(false)
	_mutex.unlock()
	return result
