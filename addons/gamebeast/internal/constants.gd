## SDK-wide constants. Internal: not part of the public API.

const SDK_VERSION := "0.1.0"
const SDK_NAME := "gamebeast-godot"
const SDK_VERSION_HEADER := SDK_NAME + "/" + SDK_VERSION
const DEFAULT_API_URL := "https://api.gamebeast.gg"
const STORAGE_DIR := "user://gamebeast"
const SESSION_PREFIX := "godot-"

const PRODUCTION := "production"
const DEVELOPMENT := "development"

# Marker delivery. Batch size and flush interval are settings (see GamebeastOptions).
const MARKER_DEFAULT_BATCH_SIZE := 100
const MARKER_MAX_BATCH_SIZE := 500
## Flush interval when the setting is "auto" (-1): quick in the editor and debug exports so
## markers show up while testing, like the Roblox SDK's Studio default.
const MARKER_FLUSH_INTERVAL_DEV_SEC := 2.0
const MARKER_FLUSH_INTERVAL_RELEASE_SEC := 10.0
const MARKER_MIN_FLUSH_INTERVAL_SEC := 1.0
## Browsers cap the combined body size of in-flight keepalive requests at 64 KiB.
const KEEPALIVE_MAX_BYTES := 60000
const MARKER_MAX_SEND_ATTEMPTS := 5
const MARKER_RETRY_BASE_DELAY_SEC := 2.0
const MARKER_MAX_BUFFERED := 500

# Change detection. "auto" (-1) intervals are quick in the editor and debug exports, like the
# Roblox SDK's Studio default (statusPollRate 5 s).
const STATUS_POLL_DEV_SEC := 5.0
## Roblox polls every 30 s, but Godot's HTTPRequest opens a new TLS connection per request, so
## each poll costs a ~5 KB handshake. 60 s until requests reuse a connection.
const STATUS_POLL_RELEASE_SEC := 60.0
const STATUS_POLL_MIN_SEC := 5.0
## Full re-evaluation. With status polling it only has to catch per-player assignment changes, so
## release builds run it rarely; without status it is the only change detection.
const CONFIG_REFRESH_DEV_SEC := 15.0
const CONFIG_REFRESH_RELEASE_SEC := 120.0
const CONFIG_REFRESH_RELEASE_NO_STATUS_SEC := 60.0
const CONFIG_MIN_REFRESH_SEC := 10.0
const CONFIG_UNLOADED_RETRY_SEC := 10.0

# Cohorts.
const COHORT_CACHE_TTL_SEC := 60.0

# HTTP.
const HTTP_TIMEOUT_SEC := 15.0

# Contract limits (packages/sdk-contract core/limits.ts).
const MARKER_SERVER_ID_MAX_LENGTH := 100
const CONTEXT_MAX_PROPERTIES := 100
const EVALUATION_CONTEXT_SCHEMA_VERSION := 1
