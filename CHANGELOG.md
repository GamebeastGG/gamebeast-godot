# Changelog

## 0.1.0

First release.

- `Gamebeast` autoload with `setup`, `identify`, `reset_identity` and `shutdown`. It can also set itself up from Project Settings.
- Markers: batching, retries with backoff and `retry-after`, saving to disk and replaying on the next launch, Godot type conversion, and a `send_position` helper for heatmaps.
- Remote configurations: typed getters, `observe` / `on_changed` / `on_ready`, hash-based refresh and an on-device cache.
- Experiments: assignment list with names and group labels from the active experiment catalog.
- Cohorts: `await is_member(name)` with a 60-second cache.
- Web exports: keepalive flush when the page is hidden, plus UTM and deeplink attribution.
- Editor heatmap dock: create, rename and delete heatmaps, render top-down 3D or 2D images, and upload them.
