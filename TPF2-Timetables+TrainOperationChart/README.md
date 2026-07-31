[![CI](https://github.com/1122Q-Q/Railway-Timetable-with-Transport-Fever-2/actions/workflows/blank.yml/badge.svg)](https://github.com/1122Q-Q/Railway-Timetable-with-Transport-Fever-2/actions/workflows/blank.yml)

# TPF2 Timetables & Train Operation Chart

A Transport Fever 2 mod that adds **timetables** and a **train operation chart** (running diagram / 运行图 / Bildfahrplan) to the game.

This is a fork of [IncredibleHannes/TPF2-Timetables](https://github.com/IncredibleHannes/TPF2-Timetables) that keeps all original timetable functionality and adds a new *Train Operation Chart* feature on top.

## Features

### Timetables (from the original mod)
- Configure timetables individually for every line and every station.
- **Arrival/Departure**: add arrival/departure timeslots; the train picks the closest arrival slot on entering a station and waits until its departure time.
- **Unbunch**: set a departure frequency and the mod enforces it at the station.
- **Waypoint passing times**: set passing times for intermediate waypoints, rename them, and manage them per line.
- Trains depart immediately when late. The mod builds on the in-game stop command, so it can only enforce longer waits — it cannot make trains faster or speed up loading.
- Timetables only work when the checkbox on the line overview is enabled.

### Train Operation Chart (new)
- **Railway line presets**: create named presets (e.g. "Beijing-Shanghai HSR") and configure which stations/waypoints to display.
- **Station sorting**: assign sort numbers (1-256) to stations and waypoints; stations sharing the same number are merged onto one horizontal reference line.
- **Search & filter**: quickly find stations by typing a name or keyword.
- **Line selection & colors**: tick the train lines you want to show, click a line to select it, then pick a custom color (all selected lines at once) for easy visual distinction.
- **Auto-drawing**: expanding a preset instantly draws its operation chart. Every change (station checks, sort numbers, line checks) is saved automatically; use **Refresh** to reload timetable data and redraw.
- **Cross-line trains**: through-running services are drawn as broken polylines on each line's chart, so a train that passes stations outside the current preset's axis never gets a straight connecting line.
- **Rail-focused**: the chart only shows railway stations and waypoints (bus/tram/cargo stops are filtered out).
- **Multi-cycle wrapping**: trips spanning more than one 60-minute period are drawn correctly across the period boundary.

## Project setup

The project is split into 4 parts:

| Part | File | Description |
| --- | --- | --- |
| Timetable logic | `/res/scripts/celmi/timetables/timetable.lua` | Stores and alters the timetable data (a big Lua table, see the [original wiki](https://github.com/IncredibleHannes/TPF2-Timetables/wiki/Timetable-object)). Read-only on the engine thread, read/write on the GUI thread. |
| UI logic | `/res/config/game_script/timetable_gui.lua` | Creates all menus, holds an instance of the timetable and modifies it on user input. |
| Game API requests | `/res/scripts/celmi/timetables/timetable_helper.lua` | All Game API calls and useful utility functions (station/waypoint lookups, line filtering, colours). |
| Train operation chart | `/res/scripts/celmi/timetables/diagram_gui.lua` + `/res/config/game_script/diagram_gui.lua` | The running-diagram window: presets, station sorting, line list, and the time-distance polyline drawing. |

## Building / running tests

No build step is required — the mod is plain Lua that the game loads directly.

The CI runs luacheck linting and a small unit-test suite:

```sh
lua ./tests/main_tests.lua
```

## How to contribute

Open an issue to discuss what you want to change, then create a branch, implement your work, and open a pull request. The PR will be merged after a review.

When you contribute, please:
- Run the existing tests and `luacheck` before opening the PR.
- Keep the shared helpers (`timetable_helper.lua`) free of UI-specific filtering — both the timetable and the diagram use them.
- Note the pitfalls collected in `AGENTS.md` (C++ asserts can't be caught by `pcall`, `setLayout()` is one-shot, component names must stay unique across refresh cycles, etc.).

## Reporting bugs / feature requests

Please use the GitHub Issues tab. When reporting a bug, describe the steps to reproduce it and attach your `stdout.txt` whenever possible.

## Credits

- Original mod: [IncredibleHannes/TPF2-Timetables](https://github.com/IncredibleHannes/TPF2-Timetables) — timetable logic, UI and game API layers.
- Train Operation Chart feature and further development by the author of this repository.

## License

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE). As a fork it remains free software; any derivative work must be released under the same license and credit the original authors.
