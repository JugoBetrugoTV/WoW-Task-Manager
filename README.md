# WoW Task Manager

A performance, diagnostics and addon-profiling tool for World of Warcraft.

Think Windows Task Manager plus Resource Monitor plus a profiler's timeline - but
for the WoW client, and built only out of things the addon API can actually
measure.

![status](https://img.shields.io/badge/status-v0.1.0%20foundation-blue)

---

## Supported clients

| Client | Version | Interface | TOC |
|---|---|---|---|
| Retail / Midnight | 12.1.0 | `120100` | `WoWTaskManager_Mainline.toc` |
| Mists of Pandaria Classic | 5.5.4 | `50504` | `WoWTaskManager_Mists.toc` |
| Burning Crusade Anniversary | 2.5.6 | `20506` | `WoWTaskManager_TBC.toc` |
| Classic Era | 1.15.9 | `11509` | `WoWTaskManager_Vanilla.toc` |

These are treated as four different platforms. Every optional API is probed at
runtime rather than assumed from the version number, and anything the client does
not support is shown as **Unavailable on this client** with the reason - never as a
zero, and never as an estimate.

## The one rule

**No measurement is invented.** Every number in the UI comes from a documented WoW
API. Where the sandbox cannot answer a question, the addon says so:

* Per-addon CPU needs the client's `scriptProfile` CVar. Without it, every CPU
  figure is a dash and a panel explains why - not a row of zeroes.
* Mapping an event or a frame to the addon that owns it has **no API**. What the
  addon does instead (name-prefix matching over `EnumerateFrames`) is labelled
  `heuristic` everywhere it appears, and it reports how many frames it could not
  attribute.
* Garbage collection is described as *inferred from the Lua heap curve*, because
  that is what it is. WoW exposes no GC statistics.
* The word "caused" does not appear anywhere in the diagnosis. The strongest
  phrase available is **Strongly correlated**, and every finding carries its
  sample count.

`docs/03-CAPABILITY-MATRIX.md` lists what is and is not possible, per client.
The same matrix is generated live from API probes and shown under **System**.

## What it does

| Area | |
|---|---|
| **Frame time** | Exact per-frame deltas from `OnUpdate`, not the smoothed `GetFramerate`. Percentiles, 1% and 0.1% lows, stutter distribution. |
| **Spike detection** | Four severity classes, each gated on *both* an absolute floor and a multiple of a rolling baseline, so it works at 25 FPS and at 240 FPS. |
| **Flight recorder** | A pre-allocated ring continuously holds the last minute. On a spike it captures the 30 s before and 15 s after - so you can see what led up to a freeze, not just that one happened. |
| **Processes** | Every addon: CPU %, CPU ms, memory, growth, spikes, status, performance score. Sortable, searchable, with a seven-tab detail view. |
| **Events** | Global event rates via `RegisterAllEvents`, storm detection against a rolling per-event baseline, and per-event handler CPU. |
| **Memory** | Lua heap curve with observed collections, per-addon growth ranking, sustained-growth flagging. |
| **Timeline** | Six stacked tracks on a shared axis with a marker lane; click a marker to open its incident. |
| **Diagnostics** | Automatic session verdict with findings, each carrying its evidence and its correlation strength. |
| **Sessions** | Every login is recorded with summary statistics and aggregated time series. |

## Not becoming the problem

A monitor that costs more than what it measures is worse than no monitor, so:

* **One `OnUpdate` in the whole addon.** Its body is a handful of float
  operations and one array increment. No allocation, no strings, no `pairs()`.
* **One scheduler** staggers every periodic task with phase offsets, so two
  expensive samples never land in the same frame.
* **Pre-allocated ring buffers.** After startup the flight recorder allocates
  nothing while idling; slots are overwritten in place.
* **Graphs are bound to pixel width, not data volume**, and downsample by keeping
  each column's extreme rather than its mean - so a 200 ms freeze survives being
  squeezed into one pixel instead of being averaged away.
* **The UI computes only while visible.**
* **It measures itself.** Sampling cost per second is shown in the sidebar, and if
  it stays over budget the addon stretches its own intervals and says so.

## Installation

Copy the `WoWTaskManager` folder into `World of Warcraft/<flavor>/Interface/AddOns/`.

Ace3 is optional. If `Libs/` contains it (see `Libs/embeds.xml`) it is used; if
not, `Core/Ace.lua` provides an API-compatible internal implementation of the
five Ace3 modules the addon relies on. Nothing else in the codebase branches on
which one is active.

## Commands

```
/wtm                 open the window
/wtm <page>          dashboard | processes | performance | timeline | events
                     memory | diagnostics | sessions | system | settings
/wtm profiling       toggle the scriptProfile CVar (takes effect after /reload)
/wtm caps            print the runtime capability report
/wtm overhead        print this addon's own cost
/wtm reset           reset runtime counters
```

## Development

```
apt-get install lua5.1      # the addon targets Lua 5.1, same as WoW
./tools/run-tests.sh
```

`tools/wowmock.lua` is a small mock of the WoW API - frames, events, the addon
and profiling functions, CVars. `tools/test.lua` loads the real addon against it
and asserts on behaviour; `tools/run.lua` drives a simulated play session and
prints what the addon concluded.

The suite runs 16 scenarios: four clients, with CPU profiling on and off, and
with every optional API present or stripped away. The stripped variant is the one
that proves the feature-detection promise - `RegisterAllEvents`, `GetNetStats`,
`EnumerateFrames`, `GetInstanceInfo` and the rest are all removed, and the addon
has to load, run and report honestly without them.

## Documentation

| | |
|---|---|
| [`docs/01-FEASIBILITY.md`](docs/01-FEASIBILITY.md) | What the API can and cannot measure, and why |
| [`docs/02-CLIENTS.md`](docs/02-CLIENTS.md) | The four clients as separate platforms |
| [`docs/03-CAPABILITY-MATRIX.md`](docs/03-CAPABILITY-MATRIX.md) | Feature availability per client |
| [`docs/04-ARCHITECTURE.md`](docs/04-ARCHITECTURE.md) | Layers, data model, sampling and flight recorder design |
| [`docs/05-LIBRARIES.md`](docs/05-LIBRARIES.md) | Libraries used, and the ones deliberately not used |
| [`docs/06-UI-CONCEPT.md`](docs/06-UI-CONCEPT.md) | Design system, layout and the graph engine |
