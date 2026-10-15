# Changelog

## 0.1.0

First release.

- `Gamebeast` autoload with `setup`, `identify`, `reset_identity`, `set_user_properties`, `update_settings` and `shutdown`. It can also set itself up from Project Settings.
- Markers: batching (100 per batch; every 2 s in the editor and debug builds, 10 s in release, both configurable), retries with backoff and `retry-after`, saving unsent markers to disk on quit or backgrounding without double-sending, Godot type conversion, and a `send_position` helper for heatmaps.
- Remote configurations: typed getters, `observe` / `on_changed` / `on_ready`, change detection through `/sdk/v2/status` polling (re-evaluating only what changed) and an on-device cache.
- Experiments: assignment list with names and group labels from the status snapshot.
- Cohorts: `await is_member(name)` with a 60-second cache.
- Web exports: keepalive flush when the page is hidden, plus UTM and deeplink attribution.
- Editor heatmap dock: create, rename and delete heatmaps, render top-down 3D or 2D images, and upload them.
