@tool
extends Node

## Per-frame driver for the Raster backend.
##
## The backend interface has no tick (each backend drives its own frame work), so
## the Raster backend owns this small node at the scene root. Every frame it asks
## the backend to poll finished sorts and re-kick sorts whose camera direction
## moved. Kept as a thin shell so the sort bookkeeping lives in the backend.

var backend: RefCounted = null

func _process(_delta: float) -> void:
	if backend != null and backend.has_method("drive_sorts"):
		backend.drive_sorts()
