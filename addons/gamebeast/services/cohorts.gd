class_name GamebeastCohorts
extends RefCounted
## Checks the local player's membership in cohorts defined on the Gamebeast dashboard (segments
## computed from analytics, e.g. "high_spenders"). Access through [code]Gamebeast.cohorts[/code].
##
## Results are cached for 60 seconds, and concurrent checks of the same cohort share one request.
## Membership is recomputed by the backend, so treat it as eventually consistent.

const Constants := preload("../internal/constants.gd")
const Context := preload("../internal/context.gd")
const Log := preload("../internal/log.gd")


class Lookup:
	extends RefCounted
	signal completed(is_member: bool)


var _context: Context
## "<distinct id>\n<cohort>" -> {"is_member": bool, "expires": float (ticks seconds)}
var _cache: Dictionary = {}
## same key -> Lookup
var _in_flight: Dictionary = {}


func _init(context: Context) -> void:
	_context = context


## Coroutine: [code]var vip: bool = await Gamebeast.cohorts.is_member("vip")[/code]. Returns
## false when the cohort doesn't exist or the check fails (failures are logged).
func is_member(cohort_name: String) -> bool:
	var name := cohort_name.strip_edges()
	if name == "":
		Log.error("is_member called without a cohort name.")
		return false
	var key := _context.distinct_id() + "\n" + name
	var cached: Dictionary = _cache.get(key, {})
	if not cached.is_empty() and cached["expires"] > _now():
		return cached["is_member"]
	if _in_flight.has(key):
		return await _in_flight[key].completed
	var lookup := Lookup.new()
	_in_flight[key] = lookup
	var result: Dictionary = await _context.api.get_cohort_membership(name, _context.distinct_id())
	_in_flight.erase(key)
	var member := false
	if result["ok"]:
		member = result["is_member"]
		_cache[key] = {"is_member": member, "expires": _now() + Constants.COHORT_CACHE_TTL_SEC}
		if not result["cohort_exists"]:
			Log.warn("Cohort '%s' does not exist; reporting non-member." % name)
	else:
		Log.warn("Cohort check for '%s' failed (%s)." % [name, result["error"]])
	lookup.completed.emit(member)
	return member


## Drop cached results, so the next is_member() call asks the backend.
func clear_cache() -> void:
	_cache.clear()


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
