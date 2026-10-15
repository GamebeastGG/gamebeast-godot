## Shared state for one SDK session (from setup() to shutdown()). Internal.

const ApiClient := preload("api_client.gd")
const Constants := preload("constants.gd")
const Identity := preload("identity.gd")
const Storage := preload("storage.gd")
const Uuid := preload("uuid.gd")

var options: GamebeastOptions
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
	environment_alias = alias
	storage = store
	identity = Identity.new(store, setup_options.distinct_id)
	api = ApiClient.new(transport, setup_options.api_key, alias, setup_options.api_url)
	rotate_session()


func rotate_session() -> void:
	session_id = Constants.SESSION_PREFIX + Uuid.v4()
	api.session_id = session_id


func distinct_id() -> String:
	return identity.distinct_id
