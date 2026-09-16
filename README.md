# WoW Task Manager

A performance, diagnostics and addon-profiling tool for World of Warcraft.

Think Windows Task Manager plus Resource Monitor plus a profiler's timeline - but
for the WoW client, and built only out of things the addon API can actually
measure.

![status](https://img.shields.io/badge/status-v0.7.1-blue)
![mock](https://img.shields.io/badge/mock-32%2F32%20scenarios-brightgreen)
![real client](https://img.shields.io/badge/real%20client-Retail%20verified-brightgreen)

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

### Verification status

| Client | Mock | Real client |
|---|:--:|:--:|
| Retail / Midnight 12.1.0 | MOCK VERIFIED | **VERIFIED** (12.1.0 build 69497, 2026-09-01) |
| MoP Classic 5.5.4 | MOCK VERIFIED | **NOT TESTED** |
| TBC Anniversary 2.5.6 | MOCK VERIFIED | **NOT TESTED** |
| Classic Era 1.15.9 | MOCK VERIFIED | **NOT TESTED** |

**A passing mock suite is not client support.** `tools/wowmock.lua` behaves the
way the author believes the client behaves; where that assumption is wrong the
mock is wrong too, and the test still passes. Nothing moves to REAL CLIENT
VERIFIED until it has been run in the game. See
[`docs/07-API-VERIFICATION.md`](docs/07-API-VERIFICATION.md).

## The one rule

**No measurement is invented.** Every number in the UI comes from a documented WoW
API. Where the sandbox cannot answer a question, the addon says so:

* Per-addon CPU needs the client's `scriptProfile` CVar. Without it, every CPU
  figure is a dash and a panel explains why - not a row of zeroes. The addon
  starts and works normally either way, and it never reloads your UI without a
  click.
* `GetAddOnCPUUsage` is **cumulative** and sampled on an interval, so CPU
  attached to a spike is always worded as *"31 ms within a 1.4 s observation
  window"* - never *"31 ms of this 84 ms frame"*. The API cannot attribute CPU
  to a single frame and this addon does not pretend otherwise.
* **Phi is not a probability.** Phi 0.67 does not mean "67% likely"; it is a
  correlation coefficient shown with its sample count. A release check fails the
  build if it is ever formatted as a percentage.
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
| **Incidents** | Spikes close together are coalesced into one *stutter cluster* with its peak, duration and affected frame count. Each opens a full record: timestamp, severity, frame time, FPS equivalent, baseline, latencies, CPU observation window, event rate, storms, memory, combat, zone, instance. |
| **Diagnostics** | Automatic session verdict with findings, each carrying its evidence and its correlation strength. |
| **False positives** | Loading screens, the first seconds after login, `/reload` and zone changes are counted as *suppressed*, not reported as freezes - and the suppressed count stays visible so nothing is quietly swallowed. |
| **Lua errors** | An integrated error monitor: errors are grouped by fingerprint, counted, attributed to an addon from the file path, and shown with the stack, the context they arrived in and the frame times around them. It installs **in front of** whatever handler was already there and passes every error on unchanged, so BugGrabber, BugSack or any other error addon keeps working. |
| **Problem reports** | Paste-ready text for a bug tracker: one error, every error, the whole session, or "this moment" with a marker dropped on the timeline at the same time. |
| **Dev mode** | `/wtm dev` injects spikes, storms and memory growth for testing. Everything injected is flagged `simulated` and rendered as **SIMULATED**. |
| **Live monitor** | `/wtm mini` — a small movable always-on panel with FPS, frame time, latency, CPU, memory and event rate. Sparklines are opt-in because they are the expensive part. |
| **Benchmark** | `/wtm benchmark` measures this addon's own cost and reports it. It never generates artificial load. |
| **Sessions** | Every login is recorded with summary statistics and aggregated time series. |

## Not becoming the problem

A monitor that costs more than what it measures is worse than no monitor, so:

* **One `OnUpdate` in the whole addon**, with an allocation-free hot path: no
  table constructor, no string building, no `pairs()`, and no loop whose length
  depends on how many addons or samples exist. Bounded and constant, not free —
  and its real cost is measured and shown, never asserted.
* **One scheduler** staggers every periodic task with phase offsets, so two
  expensive samples never land in the same frame.
* **Pre-allocated ring buffers.** After startup the flight recorder allocates
  nothing while idling; slots are overwritten in place.
* **Graphs are bound to pixel width, not data volume**, and downsample by keeping
  each column's extreme rather than its mean - so a 200 ms freeze survives being
  squeezed into one pixel instead of being averaged away.
* **The UI computes only while visible.**
* **Event monitoring is a choice**: OFF registers no listener at all, NORMAL
  counts and rates, DETAILED adds per-event CPU and rate history. The measured
  cost of whichever is active is on the dashboard.
* **It measures itself**, broken down into frame accounting, sampling, event
  monitoring and UI - each measured with `debugprofilestop`, none modelled or
  apportioned. If it stays over budget the addon stretches its own intervals and
  says so.

## Installation

Copy the `WoWTaskManager` folder into `World of Warcraft/<flavor>/Interface/AddOns/`.

Ace3 is optional. If `Libs/` contains it (see `Libs/embeds.xml`) it is used; if
not, `Core/Ace.lua` provides an API-compatible internal implementation of the
five Ace3 modules the addon relies on. Nothing else in the codebase branches on
which one is active.

## Opening it

Three equivalent ways, none of which requires typing anything:

- the **minimap button** — left click opens the window, right click toggles the
  live monitor, drag moves it around the minimap; it shows the current FPS
- **ESC → Options → AddOns → WoW Task Manager** — deliberately just a short
  description and a button, because duplicating the settings there would mean
  two lists that disagree the first time one of them is edited
- `/wtm` in chat

A four-step introduction runs once on first login (what this measures, how to
open it, why per-addon CPU needs a client setting, and how to read the results).
It is skippable and can be replayed from the Settings page.

## Commands

Every command below also exists as a **button on the Settings page**, under
`COMMANDS`. The buttons and `/wtm help` are both generated from one catalogue
(`WTM.COMMANDS` in `Core/Core.lua`), so a command with no button, or a button
firing something the help text has never heard of, is not possible.

```
/wtm                 open the window
/wtm <page>          dashboard | processes | performance | timeline | incidents
                     events | memory | errors | reports | diagnostics | sessions
                     system | settings
/wtm hide            close the window
/wtm mini            toggle the compact always-on monitor
/wtm profiling       toggle the scriptProfile CVar (takes effect after /reload)
/wtm caps            print the runtime capability report
/wtm overhead        print this addon's own cost
/wtm reset           reset runtime counters
/wtm help            print the command list
/wtm dev             developer tools (all injection marked SIMULATED)
/wtm benchmark [s]   measure this addon's own overhead and report it
/wtm safemode [off]  show safe mode, or turn it off again
```

The live monitor can be **collapsed to a single line** that keeps the frame time
and FPS, from its own `-` button or from the Settings page. Its header also
carries `cfg` (settings) and `open` (full window).

Developer commands live in their own `DEVELOPER / ADVANCED` section behind a
switch, because they write simulated samples into the real history. Everything
they produce is marked `SIMULATED` wherever it appears, and the destructive
buttons ask for a second click.

## The pages

| Group | Page | What it answers |
|---|---|---|
| Overview | **Dashboard** | What is happening right now. Twelve live metrics, six graphs, health, top consumers, recent incidents, and this addon's own cost. Blocks can be hidden or resized from Settings. |
| | **Session overview** | What happened. Settled totals and observations in sentences, each carrying the numbers it rests on. |
| Live | **Processes** | The addon list, with CPU, memory, events, spike association, dependencies and load state. Sortable, filterable, right-clickable. |
| | **Live resources** | Every live signal at once - current, average, peak, sparkline and status per module. |
| | **Performance** | Frame time and FPS over the session, with the histogram. |
| | **Frame analysis** | The distribution: percentiles, pacing bands, and the stutter clusters a player experiences as one hitch. |
| | **Network** | Latency and bandwidth, with a latency-and-frame-time overlay and an explicit list of what no WoW client exposes. |
| | **Events** | Event rate, top events, storms, and which addons appear to listen (heuristic). |
| | **Memory** | Lua heap, per-addon memory, growth ranking, observed heap decreases. |
| Analysis | **Incidents** | Recorded stutters with the seconds before and after them. |
| | **Timeline** | Ten tracks on one shared axis, markers, and a range inspector: drag to select a span and get its summary. |
| | **Diagnostics** | Findings, each with a category and what kind of evidence is under it. |
| | **Addon impact** | Rankings, and one combined score with its formula on the page. |
| | **Compare** | Two sessions side by side, with the change spelled out and the caveat next to it. |
| | **Lua errors** | Every captured error, grouped and counted, with a search box and filters for repeating, in-combat, near-a-stutter, ignored and internal. Clicking one opens Overview / Stack Trace / Context / Timeline / Related Incidents / Related Errors. |
| | **Reports** | Paste-ready problem reports, and a "report a problem now" button that marks the timeline as it writes one. |
| History | **Sessions** | Saved sessions and their summaries. |
| | **Recording** | What is being recorded, how much of it there is, and buttons to mark a moment on the timeline. |
| System | **System** | Client, hardware and the capability report. |
| | **Alerts** | Thresholds you set, and what has tripped them. |
| | **Settings** | Everything configurable, plus a button for every chat command. |

## Text has to stay inside its box

The headless harness resolves real widths from anchors, so two questions that
previously needed a screenshot are now assertions, run over every page at the
default size **and** at the smallest size the window can be dragged to:

- **Nothing escapes its panel.** A font string with no width of its own does not
  get clipped by WoW - it draws over whatever is beside it. The budget for that
  is zero.
- **No two labels on a row collide.** A label anchored left and a value anchored
  right, neither bounded, grow towards each other until they meet. Both halves
  are bounded and fitted, and over-long text is shortened with an ellipsis
  rather than cut mid-word.

Both are also run against deliberately long addon names and long localisation
strings, since a layout that just fits in English does not fit in German.

## Development

```
apt-get install lua5.1      # the addon targets Lua 5.1, same as WoW
./tools/run-tests.sh        # 32 scenarios
./tools/test-scale.lua      # 220 addons, 140 incidents, and an empty session
./tools/release-check.sh    # TOCs, includes, versions, wording rules, tests
```

CI runs both on every push and pull request, plus a Lua 5.1 syntax gate over
every file (the same version the client runs, so it is a real compatibility
check) and an advisory luacheck pass.

`tools/wowmock.lua` is a small mock of the WoW API - frames, events, the addon
and profiling functions, CVars. `tools/test.lua` loads the real addon against it
and asserts on behaviour; `tools/run.lua` drives a simulated play session and
prints what the addon concluded.

The suite runs 32 scenarios: four clients, with CPU profiling on and off, with
every optional API present or stripped away, and with Ace3 present or absent -
whether Ace3 is loaded is decided by the player's other addons, so both backends
are part of the matrix rather than an extra. The stripped variant is the one
that proves the feature-detection promise - `RegisterAllEvents`, `GetNetStats`,
`EnumerateFrames`, `GetInstanceInfo` and the rest are all removed, and the addon
has to load, run and report honestly without them.

Two focused suites sit alongside it:

* `tools/test-downsample.lua` - spikes must survive being squeezed into a pixel
  column, including the exact case of a 5 / 6 / 97 / 5 ms bucket, and every
  graph and sparkline on every page is checked against its own field.
* `tools/test-recorder.lua` - flight recorder hardening (spike bursts,
  overlapping captures, ring wrap-around, logout mid-post-roll), incident
  coalescing, suppression, event modes and schema migrations.
* `tools/test-errors.lua` - the error handler contract, which is the one place
  where a bug in this addon can break a *different* addon. It arranges the five
  chaining cases (nothing installed before us, a handler installed before us,
  capture switched off, a fault inside our own bookkeeping, a handler installed
  after us), proves the previous handler receives every error exactly once with
  the message and extra arguments unchanged, that a nested error does not
  recurse, and that ten thousand duplicates produce one stored group, one saved
  row, and no heap growth.
* `tools/test-scale.lua` - 220 addons, 140 incidents, 300 distinct errors and a
  five-thousand-strong storm of one, rendered through every page.

## Documentation

| | |
|---|---|
| [`docs/01-FEASIBILITY.md`](docs/01-FEASIBILITY.md) | What the API can and cannot measure, and why |
| [`docs/02-CLIENTS.md`](docs/02-CLIENTS.md) | The four clients as separate platforms |
| [`docs/03-CAPABILITY-MATRIX.md`](docs/03-CAPABILITY-MATRIX.md) | Feature availability per client |
| [`docs/04-ARCHITECTURE.md`](docs/04-ARCHITECTURE.md) | Layers, data model, sampling and flight recorder design |
| [`docs/05-LIBRARIES.md`](docs/05-LIBRARIES.md) | Libraries used, and the ones deliberately not used |
| [`docs/06-UI-CONCEPT.md`](docs/06-UI-CONCEPT.md) | Design system, layout and the graph engine |
| [`docs/07-API-VERIFICATION.md`](docs/07-API-VERIFICATION.md) | MOCK VERIFIED vs REAL CLIENT VERIFIED, per API |
| [`docs/08-INSTALL-AND-TEST.md`](docs/08-INSTALL-AND-TEST.md) | Installation and the in-game test checklist, per client |
| [`docs/09-MOCK-TEST-REPORT.md`](docs/09-MOCK-TEST-REPORT.md) | What the mock suite covers, and the bugs it found |
