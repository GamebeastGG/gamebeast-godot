## SDK-wide constants. Internal: not part of the public API.

const SDK_VERSION := "0.1.0"
const SDK_NAME := "gamebeast-godot"
const SDK_VERSION_HEADER := SDK_NAME + "/" + SDK_VERSION
const DEFAULT_API_URL := "https://api.gamebeast.gg"
const STORAGE_DIR := "user://gamebeast"
const SESSION_PREFIX := "godot-"

const PRODUCTION := "production"
const DEVELOPMENT := "development"

# Marker delivery (matches the Unity SDK).
const MARKER_BATCH_SIZE := 10
const MARKER_FLUSH_INTERVAL_SEC := 10.0
const MARKER_MAX_SEND_ATTEMPTS := 5
const MARKER_RETRY_BASE_DELAY_SEC := 2.0
const MARKER_MAX_BUFFERED := 500

# Configurations.
const CONFIG_UNLOADED_RETRY_SEC := 10.0

# Cohorts.
const COHORT_CACHE_TTL_SEC := 60.0

# HTTP.
const HTTP_TIMEOUT_SEC := 15.0

# Contract limits (packages/sdk-contract core/limits.ts).
const MARKER_SERVER_ID_MAX_LENGTH := 100
const CONTEXT_MAX_PROPERTIES := 100
const EVALUATION_CONTEXT_SCHEMA_VERSION := 1
