# [Gamebeast](https://gamebeast.gg/) Godot SDK

_Documentation: https://docs.gamebeast.gg/_

Client SDK for Godot 4.3+. It ships **Engagement Markers**, **Remote Configurations**, **Experiments**, **Cohorts** and an editor dock for **Heatmaps**, the same feature set as the Unity SDK.

It is written in pure GDScript, so it works on every platform Godot exports to (desktop, mobile, Web) and in both the standard and .NET editions of the engine.

## Installation

1. Sign up at https://dashboard.gamebeast.gg/ and create an SDK key for your project. Until the dashboard lists Godot as a platform, choose **Other** for the key.
2. Copy `addons/gamebeast/` into your project's `addons/` folder (or install it from the Godot Asset Library once it's listed there).
3. Enable **Gamebeast** in _Project → Project Settings → Plugins_. This registers the `Gamebeast` autoload, adds the _Gamebeast_ section to Project Settings, and adds the heatmap dock.

## Quick start

**No-code setup:** open _Project Settings → Gamebeast_, paste your SDK key into **API Key**, and leave **Auto Initialize** on. The SDK sets itself up at startup.

**Code setup** is needed to pass a distinct id or user properties at startup. Turn **Auto Initialize** off, then:

```gdscript
func _ready() -> void:
	var options := GamebeastOptions.with_api_key("your-sdk-key")
	options.distinct_id = "player-123"            # optional: omit for an anonymous persisted id
	options.configurations = ["GameSettings"]      # optional: preload, gates configs_ready
	options.user_properties = {"vip": true}       # optional: targeting context
	Gamebeast.setup(options)

	# Markers: batched analytics events attributed to the local player.
	Gamebeast.markers.send_marker("level_completed", {"level": 3, "time": 42.5})

	# Configs: "<ConfigurationAlias>.<Key>".
	Gamebeast.configs.configs_ready.connect(func():
		speed = Gamebeast.configs.get_float("GameSettings.PlayerSpeed", 16.0))

	# Or react to the value as soon as it's available and on every change:
	Gamebeast.configs.observe("GameSettings.PlayerSpeed", _on_speed_changed)
```

`Gamebeast.setup()` also accepts a bare key (`Gamebeast.setup("your-sdk-key")`) or a Dictionary (`{"api_key": "...", "configurations": ["GameSettings"]}`).

### From C#

The SDK is GDScript, so call it from C# through the autoload node:

```csharp
var gamebeast = GetNode("/root/Gamebeast");
var markers = gamebeast.Get("markers").AsGodotObject();
markers.Call("send_marker", "level_completed", new Godot.Collections.Dictionary { { "level", 3 } });

var configs = gamebeast.Get("configs").AsGodotObject();
float speed = configs.Call("get_float", "GameSettings.PlayerSpeed", 16.0f).AsSingle();
configs.Connect("configuration_updated", Callable.From<string>(alias => GD.Print($"{alias} updated")));
```

## Settings

| Project Setting | Option | Default | |
| --- | --- | --- | --- |
| `gamebeast/general/api_key` | `api_key` | | Your SDK key. Required. |
| `gamebeast/general/environment` | `environment` | Auto | Auto resolves to development in the editor and debug exports, and to production in release exports. |
| `gamebeast/general/custom_environment` | `custom_environment` | | Target an environment by alias. Overrides `environment`. |
| `gamebeast/general/configurations` | `configurations` | | Configuration aliases to preload. |
| `gamebeast/general/auto_initialize` | | on | Set up from Project Settings at startup. |
| `gamebeast/advanced/config_refresh_interval_sec` | `config_refresh_interval_sec` | 60 | Background configuration refresh. 0 disables it. |
| `gamebeast/advanced/session_timeout_sec` | `session_timeout_sec` | 1800 | Start a new session after the game was backgrounded this long. |
| `gamebeast/advanced/debug_logging` | `debug_logging` | off | Verbose logs. |
| `gamebeast/advanced/api_url` | `api_url` | | Override the API base URL. |
| | `distinct_id` | | Identify the player at startup. |
| | `user_properties` | | Targeting properties sent with every configuration evaluation. |

**Custom environments are coming soon.** You can set `custom_environment` now: configurations and experiments will use it, but markers and cohorts can only target production or development until custom environments ship, and are sent to development.

## User identity

The SDK identifies the local player by a **distinct id**: the one you supply (in options or with `identify`), or an anonymous id generated on first launch and saved under `user://gamebeast/`. Configurations are evaluated and experiments assigned per distinct id.

- `Gamebeast.identify("player-123")`: switch identity after login. Configurations re-evaluate right away. The id isn't saved, so call it again on the next launch.
- `Gamebeast.reset_identity()`: go back to the anonymous id after logout.
- `Gamebeast.get_distinct_id()`: the current id. The `identity_changed(distinct_id)` signal fires on every change.

`Gamebeast.shutdown()` flushes pending data and tears the SDK down; `setup()` may be called again afterwards.

## Markers: `Gamebeast.markers`

- `send_marker(type, properties := {})`: send an event. Properties can contain Godot types: `Vector2`, `Vector3`, `Color`, `Quaternion` and friends are sent as arrays.
- `send_position(type, position, properties := {})`: send an event with a world position for heatmaps. A `Vector3` is sent as `[x, y, z]`; a `Vector2` from a 2D game is sent as `[x, 0, y]`, so it lands on the heatmap's XZ plane.
- `flush()`: send the current batch now.

Markers are batched and sent automatically: when 10 are waiting, every 10 seconds, on quit, and when the game goes to the background. Failed sends retry with exponential backoff (2, 4, 8, 16 s, or longer if the server sends `retry-after`); markers the server rejects are dropped. Anything unsent on quit or backgrounding is saved under `user://` and delivered on the next launch. The backend dedupes by marker id, so nothing is counted twice.

Sessions last one run, and rotate when the game returns from the background after `session_timeout_sec`.

## Configs: `Gamebeast.configs`

Values are addressed by dot-path. The first segment is the configuration alias and the rest walks into the document: `"GameSettings.UI.ButtonColor"`, or `"GameSettings.Levels.0"` for array items. A bare alias returns the whole document.

Configurations load on demand: the first read fetches the configuration. Listing aliases in `configurations` also preloads them at startup and makes `configs_ready` wait for them.

- `get_value(path, default := null)`, `get_int`, `get_float`, `get_bool`, `get_string`, `get_dict`, `get_array`, `try_get(path)` (returns `{found, value}`), `has_value(path)`
- `is_ready()` / `configs_ready` signal / `on_ready(callable)`: every preloaded configuration is available.
- `on_changed(path, callable)`: called with the new value when the value at `path` changes.
- `observe(path, callable)`: called with the value as soon as it's available, then on every change. This is the best fit for lazily loaded configurations.
- `configuration_updated(alias)` signal: a configuration's values changed.
- `await refresh()`: re-check every known configuration now.

`on_changed`, `observe` and `on_ready` return a `GamebeastSubscription`; call `cancel()` to stop it. A subscription to a method of a node is dropped automatically once that node is freed.

Godot's JSON parser reads every number as a float. `get_int` converts it for you, and `get_value` returns the raw float. Integers above 2^53 lose precision.

Configurations are cached on the device, so values are available instantly at launch (and offline). The cache is tied to your project's `application/config/version`: after a game update, the cached values from the old build are discarded and the SDK waits for fresh ones. Background refresh uses hash-based caching, so unchanged configurations cost almost nothing.

## Experiments: `Gamebeast.experiments`

Experiments run on remote configurations, and enrollment is automatic: evaluating a configuration enrolls the player in active experiments on the backend, and the values `Gamebeast.configs` returns already include the assigned group's changes. There's nothing to opt into. This service is for display, analytics and debugging.

- `get_assignments()`: `Array[GamebeastExperimentAssignment]` with `experiment_id`, `experiment_name`, `group_id`, `group_label`, `configuration_alias`, `source`.
- `get_assignment(experiment_id)`
- `assignments_changed(assignments)` signal

## Cohorts: `Gamebeast.cohorts`

```gdscript
if await Gamebeast.cohorts.is_member("high_spenders"):
	show_vip_offer()
```

Results are cached for 60 seconds, and concurrent checks of the same cohort share one request. A cohort that doesn't exist, or a failed check, returns `false` and logs a warning.

## Web exports

- Before the tab is hidden or closed, markers are saved and sent with `fetch(..., {keepalive: true})`, which the browser completes after the page unloads.
- UTM parameters on the page URL are attached to every marker, and a `utm_id=gb_<slug>` link is recorded as a Gamebeast deeplink.
- On the Web, `user://` is stored in IndexedDB and saved asynchronously, so the save made while the page closes is best-effort. The keepalive request is the primary delivery path.

## Heatmaps (editor)

The **Gamebeast** dock (right side of the editor) manages heatmaps and uploads the image they're drawn over:

1. Enter an SDK key with the heatmaps permissions and press **Fetch heatmaps**, then pick one or press **New**.
2. Select a node at one corner of the area in your scene and press **Use selected** for corner A, then do the same for corner B. Use `Node3D`s in 3D scenes and `Node2D`s in 2D scenes.
3. Press **Render preview**, then **Upload**. This saves the region and uploads the top-down image.

At runtime, send positions with `Gamebeast.markers.send_position("player_died", global_position)` and build a heatmap query on the dashboard.

The key is saved in this project's editor metadata (`.godot/`), not in `project.godot`.

## Development

```bash
godot --headless --path . --import            # once, builds the class cache
godot --headless --path . -s tests/run_tests.gd
gdformat --check --line-length 100 addons tests demo && gdlint addons tests demo
```

`GB_TEST_FILTER=<name>` runs matching tests only, and `GB_TEST_LOGS=1` shows SDK logs. `tests/smoke_http.gd` exercises the real HTTP transport against a local server on port 8765. `demo/demo.tscn` is a small playground.

## License

Apache 2.0. See [LICENSE](LICENSE).
