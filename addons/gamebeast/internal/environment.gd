## Environment resolution. Mirrors the Unity SDK's model: an Auto/Production/Development choice,
## overridden by a custom environment alias when one is set.
##
## TODO(post-release): custom environments. Custom environments are coming soon. Until then, the
## v1 routes (markers, cohorts) pick the environment from the `isstudio` boolean and can only
## address production and development; any other alias is sent to v1 routes as development.

enum Mode { AUTO = 0, PRODUCTION = 1, DEVELOPMENT = 2 }

const Constants := preload("constants.gd")


## The environment alias sent to v2 routes in the `environment` header.
static func resolve_alias(mode: int, custom_environment: String, is_dev_runtime: bool) -> String:
	# TODO(post-release): custom environments. The override is passed through as-is, like Unity.
	var custom := custom_environment.strip_edges()
	if custom != "":
		return custom
	match mode:
		Mode.PRODUCTION:
			return Constants.PRODUCTION
		Mode.DEVELOPMENT:
			return Constants.DEVELOPMENT
		_:
			return Constants.DEVELOPMENT if is_dev_runtime else Constants.PRODUCTION


## True when running in the editor or a debug export: `Auto` resolves to development there.
static func is_dev_runtime() -> bool:
	return OS.has_feature("editor") or OS.is_debug_build()


## The v1 `isstudio` header for an alias: development is `true`, production `false`. This is the
## JS SDK's `toLegacyEnvironment`; the Unity SDK sends `false` for development, which lands
## development markers in production. Unsupported aliases fall back to development.
static func is_studio(alias: String) -> bool:
	return alias != Constants.PRODUCTION


## Whether the v1 routes can address this alias at all.
static func supported_by_v1(alias: String) -> bool:
	return alias == Constants.PRODUCTION or alias == Constants.DEVELOPMENT
