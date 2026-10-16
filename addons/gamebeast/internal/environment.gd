## Environment resolution. One setting: left blank (the default), the SDK resolves development in
## the editor and debug exports and production in release exports; "production" or "development"
## pins it.
## Aliases are normalized the way the backend does it (the JS SDK's `normalizeEnvironment`):
## "Production" and "production" are the same environment, and "studio" means development.
##
## TODO(post-release): custom environments. Custom environments are coming soon. Until then any
## other alias is unsupported: setup warns and resolves as if it were blank. When they ship, pass
## the alias through to v2 routes; the v1 routes (markers, cohorts) pick the environment from the
## `isstudio` boolean and can only address production and development.

const Constants := preload("constants.gd")

const _SYNONYMS := {"studio": "development"}


## The backend's alias slug (`toAliasSlug` in @gamebeast/sdk-contract), plus its synonyms.
static func normalize(input: String) -> String:
	var slug := input.to_lower()
	var spaces := RegEx.create_from_string("\\s+")
	slug = spaces.sub(slug, "-", true)
	var invalid := RegEx.create_from_string("[^a-z0-9-]")
	slug = invalid.sub(slug, "", true)
	var dashes := RegEx.create_from_string("-+")
	slug = dashes.sub(slug, "-", true)
	slug = slug.lstrip("-").rstrip("-")
	return _SYNONYMS.get(slug, slug)


## The environment alias sent to v2 routes in the `environment` header. Blank resolves from the
## runtime ([method runtime_default]); anything else is normalized. Returns "" for a value that
## normalizes to nothing (e.g. "!!"), which [method is_supported] rejects.
static func resolve_alias(environment: String, is_dev_runtime: bool) -> String:
	if environment.strip_edges() == "":
		return runtime_default(is_dev_runtime)
	return normalize(environment)


## The environment used when none is specified: development in the editor and debug exports,
## production in release exports.
static func runtime_default(is_dev_runtime: bool) -> String:
	return Constants.DEVELOPMENT if is_dev_runtime else Constants.PRODUCTION


## True when running in the editor or a debug export, where a blank environment is development.
static func is_dev_runtime() -> bool:
	return OS.has_feature("editor") or OS.is_debug_build()


## The v1 `isstudio` header for an alias: development is `true`, production `false`. This is the
## JS SDK's `toLegacyEnvironment`; the Unity SDK sends `false` for development, which lands
## development markers in production.
static func is_studio(alias: String) -> bool:
	return alias != Constants.PRODUCTION


## Whether the SDK supports this alias: production or development until custom environments ship.
static func is_supported(alias: String) -> bool:
	return alias == Constants.PRODUCTION or alias == Constants.DEVELOPMENT
