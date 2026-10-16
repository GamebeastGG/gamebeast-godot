## Shared state for one SDK session (from setup() to shutdown()). Internal.

const ApiClient := preload("api_client.gd")
const Constants := preload("constants.gd")
const GbEnvironment := preload("environment.gd")
const Identity := preload("identity.gd")
const ResolvedSettings := preload("resolved_settings.gd")
const Storage := preload("storage.gd")
const Uuid := preload("uuid.gd")

var options: GamebeastOptions
## Effective intervals and sizes ("auto" resolved, out-of-range values clamped).
var settings: ResolvedSettings
var environment_alias: String
var api: ApiClient
var identity: Identity
var storage: Storage
var session_id: String
## Session attribution stamped on every marker: {"utm"?: {...}, "deeplinkData"?: {...}}.
var attribution: Dictionary = {}


func _init(
	setup_options: GamebeastOptions, alias: String, transport: Variant, store: Storage
) -> void:
	options = setup_options
	resolve_settings()
	environment_alias = alias
	storage = store
	identity = Identity.new(store, setup_options.distinct_id)
	api = ApiClient.new(transport, setup_options.api_key, alias, setup_options.api_url)
	rotate_session()


## Re-derive [member settings] from [member options] (after update_settings).
func resolve_settings() -> void:
	settings = ResolvedSettings.resolve(options, GbEnvironment.is_dev_runtime())


func rotate_session() -> void:
	session_id = Constants.SESSION_PREFIX + Uuid.v4()
	api.session_id = session_id


func distinct_id() -> String:
	return identity.distinct_id
