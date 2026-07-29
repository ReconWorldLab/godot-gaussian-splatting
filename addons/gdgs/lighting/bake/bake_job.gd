extends RefCounted

## WorkerThreadPool job wrapper for a lighting-proxy bake. Mirrors the
## collision module's `pipeline_job.gd`: mutex-guarded stage/progress/result,
## cooperative cancellation, and no contact with Resources, Nodes or editor
## objects from the worker side.

const BUILDER_SCRIPT := preload("res://addons/gdgs/lighting/bake/proxy_builder.gd")

var _mutex := Mutex.new()
var _snapshot: Dictionary
var _settings: Dictionary
var _cancel_requested := false
var _stage := "Waiting for worker"
var _progress := 0.0
var _result: Dictionary = {}


func _init(data_snapshot: Dictionary, settings: Dictionary = {}) -> void:
	_snapshot = data_snapshot
	_settings = settings.duplicate(true)


func run() -> void:
	report_progress("Starting lighting proxy bake", 0.0)
	var result: Dictionary = BUILDER_SCRIPT.bake(_snapshot, _settings, self)
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
