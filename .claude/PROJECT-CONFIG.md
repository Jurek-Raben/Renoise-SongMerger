# Project Config – SongMerger

Renoise tool (Lua) that merges selected tracks of a second song (the "merge song") into the currently loaded song
(the "target song"), including send routings, meta-device routings, used instruments and selected master FX.

## Environment

- Target host: **Renoise 3.5.4**, Lua API version **6.2** (`renoise.API_VERSION`).
- Language: **Lua 5.1 (LuaJIT)** as embedded in Renoise. No external runtimes (Node, Python, …) may be required at
  runtime. The tool must work on macOS, Windows and Linux.
- Tool bundle: `ai.claude.SongMerger.xrnx/` (symlinked into the Renoise tools folder by the user). Renoise expects
  tool folders to end in `.xrnx`; the tool id in `manifest.xml` stays `ai.claude.SongMerger`.
  - `manifest.xml` – tool metadata (`<ApiVersion>6.2</ApiVersion>`, id `ai.claude.SongMerger`).
  - `main.lua` – entry point (menu entries, keybindings, tool lifecycle).
  - Further modules live in subfolders and are loaded with `require`.

## API reference

- Online: https://renoise.github.io/xrnx/API/index.html
- Local LuaCATS definitions (authoritative for autocompletion and signatures):
  `~/Workdocs/renoise/definitions/library/renoise/` (configured in `.vscode/settings.json`).
- Before using an API function or property, verify it exists in the definitions. Do not invent API calls.
- Mark every assumption about undocumented behavior (e.g. parameter value semantics of meta devices, XML layout of
  `active_preset_data`) with a `-- ASSUMPTION:` comment so it can be verified in Renoise.

## Working rules for Claude

- **Never** run `git commit`, `git push`, `git add`, `git reset`, `git checkout`, `git rebase`, `git merge`,
  `git stash` or any other git command that changes repository state. The user does all version control.
  Read-only git commands (`git status`, `git diff`, `git log`) are fine.
- **Never** start Renoise or test the tool on your own. The user tests. When a change needs testing, describe
  briefly what to test and what to look for.
- Static checks are allowed (they never execute tool code) and should be run after code changes. `luajit` and
  `luacheck` may only be used for this project:
  - Run `sh scripts/check.sh` (LuaJIT syntax check + luacheck with `.luacheckrc`). The script runs luacheck under
    LuaJIT because the Homebrew luacheck build for Lua 5.5 does not start.
- Development-only code is wrapped in `-- @build:skip-start` / `-- @build:skip-end` lines. The release workflow
  removes these blocks (markers included) before packaging the .xrnx.
- All rules, documentation in this repo and code comments are written in **English**.
- Code follows [CODE-FORMATTING.md](CODE-FORMATTING.md).
- Keep the tool free of global state leaks: one module table per file, `local` everywhere.
- Song objects (`renoise.song()` and everything derived from it) become invalid when another song is loaded.
  Never keep references to song objects across song loads; store plain Lua data instead.

## Architecture

No XML parsing: the tool's Lua state survives song changes, so the merge song is loaded temporarily and read via the
API.

1. `controller.lua` – workflow: target song must be saved → pick merge song → load it (`song_loader.lua`) →
   `analyzer.lua` → track dialog → master FX dialog → `selection.lua` resolves the plan → `exporter.lua` captures
   plain data + temp `.xrni` files → target song is reloaded → `importer.lua` inserts and remaps everything.
2. `routing.lua` – the only place that knows parameter names/value semantics of send and meta devices.
3. `ui/widgets.lua` – shared look (header, sections, colored buttons, key handling, close detection).
   `ui/start_dialog.lua` – first confirmation (red Continue; Return/Esc cancel). `ui/track_dialog.lua` – tree view
   drawn with `vb:canvas` (guide lines, track colors, collapse triangles), virtualized rows with scrollbar and mouse
   wheel, live import preview; `ui/master_dialog.lua`; `ui/confirm_dialog.lua`; `ui/summary_dialog.lua` – final
   report; `ui/options_dialog.lua` – options (Tools → Merge Song → Options...), stored via `preferences.lua` in the
   tool's `preferences.xml` (excluded from the release package). "Show debug info" adds temp file paths and the
   duration to the summary.
4. `debug.lua` – menu entry that dumps device parameters to the console to verify routing assumptions.
5. `process_slicer.lua` – runs analysis, export and import as coroutines over idle calls with a progress dialog.
   Long loops call `ProcessSlicer.step(status)`; it yields only when the time slice is used up. Analysis and export
   are cancellable, the import is not (it must never leave a half-remapped target song).

## Product decisions

- Merge song patterns are **appended** to the target sequence as new patterns with their original lengths.
  Importing song data is an option and **off by default** (then only tracks, devices, instruments are imported).
- Tempo (BPM/LPB/TPL) of the merge song is ignored.
- Groups are imported 1:1. The track dialog shows the group tree (group first, children indented). Selecting a group
  selects all children by default (cascading into subgroups); children can be deselected individually. Selecting a
  member always imports its parent groups.
- Send tracks are imported once and stay shared by all imported tracks that use them. Tracks with "keep sends" off get
  their send devices bypassed (device indices stay stable for meta devices).
- Tracks targeted by instrument FX chain routings are imported automatically.
- Selected master FX are appended to the target master track.
- Imported instruments are appended after a separator instrument named `----- MERGE: <song> -----`. No blank
  instruments are created: empty instruments of the merge song are not exported and their pattern references point
  to the (silent) separator; blank placeholders left by `load_instrument` are deleted.
- Appended song data starts with a sequence section named like the separator instrument.

## Domain notes

- Track types: sequencer, group, send, master (`renoise.Track.TRACK_TYPE_*`). Order in a song is always
  sequencer/group tracks → master → send tracks.
- Routings that must be remapped when tracks/instruments get new indices:
  - Track `output_routing` (by name).
  - `#Send` / `#Multiband Send` devices: receiver parameter = send track index.
  - `#Sidechain` devices: parameters `Dest. Track` (0-based track index, -1 = none) and `Dest. Effect` (0-based
    device index incl. mixer, -1 = none) – verified with the debug dump.
  - Meta devices (`*Hydra`, `*Instr. Automation`, `*Instr. MIDI Control`, `*Key Tracker`, `*LFO`, `*Meta Mixer`,
    `*Signal Follower`, `*Velocity Tracker`, `*XY Pad`, `*Formula`, …): destination track / device / parameter
    parameters.
  - Instrument `sample_device_chains[].output_routing`, instrument plugin and MIDI output routings.
  - Pattern effect commands that address tracks/instruments/devices (e.g. instrument column values, `-Zxx` etc.).
- Shared send tracks in the merge song must stay shared after the merge (one send track per source send track).
- Goal: merged tracks soloed in the target song sound the same as in the merge song.
