extends RefCounted

# Shared result/progress helpers for the collision pipeline modules. Every
# stage returns the same result-dictionary shape and reports progress through
# the phase table below, which is the single source of truth for how the
# stages divide the progress bar (values must stay monotonic across phases).

const PHASES := {
	&"prepare": Vector2(0.02, 0.15),
	&"index": Vector2(0.16, 0.34),
	&"voxelize": Vector2(0.35, 0.64),
	&"cleanup": Vector2(0.65, 0.69),
	&"scene": Vector2(0.70, 0.79),
	&"mesh": Vector2(0.80, 0.99),
}


static func phase_progress(control: RefCounted, stage: String, phase_name: StringName, fraction: float) -> void:
	if control == null:
		return
	var span: Vector2 = PHASES[phase_name]
	control.report_progress(stage, clampf(span.x + (span.y - span.x) * clampf(fraction, 0.0, 1.0), 0.0, 1.0))


static func report_progress(control: RefCounted, stage: String, progress: float) -> void:
	if control != null:
		control.report_progress(stage, clampf(progress, 0.0, 1.0))


static func is_cancelled(control: RefCounted) -> bool:
	return control != null and control.is_cancel_requested()


static func cancelled_result() -> Dictionary:
	return {"ok": false, "error": "Generation cancelled.", "cancelled": true, "mesh": null, "grid": null, "stats": {}}


static func failure(message: String, was_cancelled: bool = false) -> Dictionary:
	return {"ok": false, "error": message, "cancelled": was_cancelled, "mesh": null, "grid": null, "stats": {}}


static func forward_failure(result: Dictionary, fallback: String) -> Dictionary:
	return failure(result.get("error", fallback), result.get("cancelled", false))
