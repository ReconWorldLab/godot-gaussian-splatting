@tool
extends Window

signal generation_completed(result: Dictionary)

var _job: RefCounted
var _task_id := -1
var _stage_label: Label
var _progress_bar: ProgressBar
var _cancel_button: Button


func _init(job: RefCounted) -> void:
	_job = job
	title = "GDGS Collision"
	size = Vector2i(520, 180)
	min_size = Vector2i(420, 160)
	exclusive = true
	transient = true
	close_requested.connect(request_cancel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	margin.add_child(content)

	_stage_label = Label.new()
	_stage_label.text = "Waiting for worker…"
	_stage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_stage_label)
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.value = 0.0
	_progress_bar.show_percentage = true
	content.add_child(_progress_bar)
	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.pressed.connect(request_cancel)
	content.add_child(_cancel_button)
	set_process(false)


func start() -> void:
	if _task_id >= 0:
		return
	_task_id = WorkerThreadPool.add_task(_job.run, false, "Generate GDGS collision")
	set_process(true)
	popup_centered()


func request_cancel() -> void:
	if _job == null:
		return
	_job.request_cancel()
	_cancel_button.disabled = true
	_cancel_button.text = "Cancelling…"
	_stage_label.text = "Waiting for the worker to reach a safe cancellation point…"


func cancel_and_wait() -> void:
	request_cancel()
	if _task_id >= 0:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
	set_process(false)
	hide()


func _process(_delta: float) -> void:
	if _task_id < 0:
		return
	var status: Dictionary = _job.get_status()
	_stage_label.text = status.get("stage", "Working…")
	_progress_bar.value = 100.0 * float(status.get("progress", 0.0))
	if not WorkerThreadPool.is_task_completed(_task_id):
		return
	set_process(false)
	var wait_error := WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	var result: Dictionary
	if wait_error == OK:
		result = _job.get_result()
	else:
		result = {
			"ok": false,
			"error": "Worker task cleanup failed with error %d." % wait_error,
			"cancelled": false,
			"mesh": null,
			"stats": {},
		}
	generation_completed.emit(result)
	queue_free()
