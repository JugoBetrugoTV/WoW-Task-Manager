# Architektur, Datenmodell, Sampling- und Flight-Recorder-Konzept

## 1. Schichten

```
  UI            Pages + Widgets. Liest nur, rechnet nur wenn sichtbar.
  ---------------------------------------------------------------
  Analysis      Correlation, Diagnostics. Reine Auswertung, kein State.
  ---------------------------------------------------------------
  History       FlightRecorder (RAM-Ring), Recorder (Buckets), Sessions (DB)
  ---------------------------------------------------------------
  Monitoring    FrameTime, CPU, Memory, Network, Events, SpikeDetector, Overhead
  ---------------------------------------------------------------
  Core          Scheduler, Database, Capabilities, Ace-Bridge
  ---------------------------------------------------------------
  Compat        Compatibility/{Retail,Mists,TBC,Classic}.lua  +  Core/Compat.lua
```

Regel: **Nur `Core/Compat.lua` und `Compatibility/*.lua` kennen den Client.**
Alles darüber fragt ausschließlich `WTM.Compat.*` und `WTM.Caps.*`.

## 2. Dateibaum

```
WoWTaskManager/
  WoWTaskManager.toc            Fallback-TOC
  WoWTaskManager_Mainline.toc   Retail   12.1.0  (Interface 120100)
  WoWTaskManager_Mists.toc      MoP      5.5.4   (Interface 50504)
  WoWTaskManager_TBC.toc        TBC      2.5.6   (Interface 20506)
  WoWTaskManager_Vanilla.toc    Classic  1.15.9  (Interface 11509)
  Includes.xml                  einzige Dateiliste, von allen TOCs referenziert

  Libs/                         Ace3 (optional, siehe docs/05-LIBRARIES.md)

  Core/
    Compat.lua        Client-Erkennung, API-Bridge, SafeRegisterEvent, SafeCall
    Constants.lua     Schwellwerte, Farben, Enums, Defaults
    Capabilities.lua  Laufzeit-Feature-Detection -> Capability Matrix
    Ace.lua           Ace3-Bridge mit vollständigem internem Fallback
    Core.lua          Addon-Objekt, Modul-Registry, Slash-Commands
    Database.lua      Profile, Defaults, Migration, Pruning
    Scheduler.lua     der eine OnUpdate-Treiber + Task-Staffelung
  Compatibility/
    Retail.lua  Mists.lua  TBC.lua  Classic.lua
  Utils/
    RingBuffer.lua  Pool.lua  MathUtil.lua  Format.lua  Color.lua
  Monitoring/
    FrameTime.lua  Network.lua  Memory.lua  CPU.lua  Events.lua
    SpikeDetector.lua  Overhead.lua  Context.lua
  Analysis/
    Correlation.lua  Diagnostics.lua
  History/
    FlightRecorder.lua  Recorder.lua  Sessions.lua
  UI/
    Theme.lua  MainWindow.lua  Sidebar.lua  AddonDetail.lua
    Widgets/  Base.lua Graph.lua Table.lua MetricCard.lua ScrollList.lua Tooltip.lua
    Pages/    Dashboard.lua Processes.lua Performance.lua Timeline.lua
              Events.lua Memory.lua Diagnostics.lua Sessions.lua
              System.lua Settings.lua
```

Alle TOCs referenzieren dieselbe `Includes.xml`. Die Dateiliste existiert damit
**genau einmal** — kein Drift zwischen vier Clients.

## 3. Datenmodell

### 3.1 Laufzeit (RAM, nie persistiert)

```lua
-- Ein Slot des Flight Recorders. Wird EINMAL allokiert und danach nur überschrieben.
slot = {
  t          = 0,   -- GetTime() des Samples
  fps        = 0,   -- Frames im Intervall / Intervalldauer
  frameAvgMs = 0,   -- durchschnittliche Frametime im Intervall
  frameMaxMs = 0,   -- schlechteste Frametime im Intervall  <- Spike-Signal
  frameMinMs = 0,
  latHome    = 0,
  latWorld   = 0,
  luaKB      = 0,   -- collectgarbage("count")
  events     = 0,   -- Events im Intervall
  cpuMs      = 0,   -- Summe Addon-CPU-Delta (nur mit scriptProfile)
  flags      = 0,   -- Bitfeld: combat / instance / loading / encounter
}
```

```lua
-- Pro Addon, laufend gepflegt (Monitoring/CPU.lua, Monitoring/Memory.lua)
proc = {
  name, title, version, loaded, lod, enableState,
  cpuTotalMs, cpuDeltaMs, cpuPct, cpuPeakPct, cpuAvgPct, cpuEma,
  memKB, memDeltaKB, memStartKB, memPeakKB, memGrowthKBPerMin,
  events, eventsPerSec,           -- nur bei zuordenbaren Frames
  frames, registeredEvents,       -- heuristisch
  spikes, lastSpikeAt,
  score,                          -- 0..100 Performance Score
  flagsText,                      -- "HIGH CPU" | "MEM GROWTH" | "Normal" | ...
  cpuRing, memRing,               -- RingBuffer für Detail-Graphen
}
```

### 3.2 Persistenz — `WoWTaskManagerDB`

```lua
WoWTaskManagerDB = {
  profileKeys = { ["Char - Realm"] = "Default" },
  profiles = { Default = { <settings> } },
  global = {
    version = 1,
    sessions = {                      -- Ringliste, max. N (Default 25)
      [1] = {
        id, startedAt, endedAt, duration,
        character, realm, class, flavor, build, tocVersion, locale,
        zone, avgFPS, minFPS, maxFPS, low1pct, low01pct, maxFrameMs,
        spikeCount = { minor, stutter, heavy, freeze },
        avgLatency, peakLatency,
        luaStartKB, luaEndKB, luaPeakKB,
        topCPU    = { {name, avgPct, peakPct}, ... },   -- max 10
        topMemory = { {name, growthKB, endKB}, ... },   -- max 10
        buckets   = { <siehe 3.3> },
        spikes    = { <siehe 3.4> },
      },
    },
    incidents = { ... },              -- gespeicherte Flight-Recorder-Ausschnitte
  },
}
```

### 3.3 Zeitreihen-Buckets (Aggregation)

Nicht jeder Sample wird gespeichert. Der `Recorder` schreibt in Buckets und
**verdichtet ältere Buckets im Hintergrund**:

| Alter | Auflösung | Speicherbedarf |
|---|---|---|
| 0 – 5 min | 1 s | 300 Buckets |
| 5 – 30 min | 5 s | 300 Buckets |
| 30 min – 3 h | 15 s | 600 Buckets |
| > 3 h | 60 s | ~ 60/h |

Ein Bucket ist ein **Array**, kein Hash — das spart in SavedVariables ca. 60 %:

```lua
bucket = { t, fps, frameAvgMs, frameMaxMs, latH, latW, luaKB, events, cpuMs }
```

Ein 3-Stunden-Session landet damit bei grob **1200 Buckets à 9 Zahlen** ≈ 120–200 KB
serialisiert. Das Pruning (`Database.Prune`) begrenzt zusätzlich hart auf
`maxSessions` und `maxIncidents`.

### 3.4 Spike-/Incident-Datensatz

```lua
spike = {
  t, kind,              -- "minor" | "stutter" | "heavy" | "freeze"
  frameMs, fps,
  latHome, latWorld, luaKB,
  context = { combat, instanceType, zone, groupSize, encounter, loading },
  cpu    = { {name, deltaMs, pct}, ... },   -- Top 5 Addon-CPU-Deltas im Fenster
  memory = { {name, deltaKB}, ... },        -- Top 3 Speicherzuwächse
  events = { {event, count}, ... },         -- Top 8 Events im Fenster
  correlation = { {name, score, label}, ...},
  recorderRef,          -- Index in global.incidents (Flight-Recorder-Ausschnitt)
}
```

## 4. Sampling- / Profiler-Konzept

### 4.1 Der einzige OnUpdate

```lua
-- Monitoring/FrameTime.lua, ~15 Operationen, null Allokationen
function OnUpdate(self, elapsed)
    local ms = elapsed * 1000
    frames  = frames + 1
    sumMs   = sumMs + ms
    if ms > maxMs then maxMs = ms end
    if ms < minMs then minMs = ms end
    hist[bucketOf(ms)] = hist[bucketOf(ms)] + 1     -- Perzentile ohne Speicherung
    if ms > spikeThresholdMs then pendingSpike = ms end
    acc = acc + elapsed
    if acc >= interval then Scheduler:Tick(acc) ; acc = 0 end
end
```

`bucketOf` ist eine reine Arithmetikfunktion ohne Verzweigungsketten
(64 Buckets, 0–500 ms, quadratisch verteilt für Auflösung im interessanten Bereich).

### 4.2 Task-Staffelung

| Task | Default-Intervall | Adaptiv (Spike-Burst) | Kosten |
|---|---|---|---|
| `frametime` | 0.25 s | 0.05 s | vernachlässigbar |
| `network` | 5 s | 5 s | vernachlässigbar (API updated eh nur 30 s) |
| `cpu` | 2 s | 0.5 s | O(#Addons), spürbar → gestaffelt |
| `memory` | 15 s | 5 s | **teuer** (Heap-Walk) |
| `events` | 1 s | 0.25 s | vernachlässigbar |
| `history` | 1 s | 1 s | vernachlässigbar |
| `ui` | 0.5 s | 0.5 s | nur wenn `IsShown()` |
| `metadata` | on demand | — | nur bei Öffnen der Prozessliste |

Der Scheduler verteilt Tasks über **verschiedene Frames** (Phase-Offset), damit nie
zwei teure Tasks im selben Frame laufen — das würde selbst einen Stutter erzeugen.

### 4.3 Adaptive Sampling

```
Normalbetrieb  ──spike erkannt──▶  BURST (höhere Raten)  ──nach burstDuration──▶  Normal
                                     │
                                     └─ weiterer Spike verlängert das Fenster
```

`burstDuration` Default 10 s. Während eines Bursts steigt der Eigen-Overhead bewusst;
das Overhead-Modul misst und deckelt ihn.

### 4.4 Selbstmessung (Overhead)

Jeder Scheduler-Task wird in `debugprofilestop()` geklammert. Daraus:
`samplingCostMsPerSec`. Zusätzlich `GetAddOnCPUUsage("WoWTaskManager")` und
`GetAddOnMemoryUsage("WoWTaskManager")`. Übersteigt `samplingCostMsPerSec` den
Grenzwert (Default 2 ms/s ≈ 0.2 % eines Kerns), verlängert der Scheduler automatisch
die Intervalle der teuersten Tasks und die UI zeigt eine Warnung.

## 5. Flight Recorder

Ziel: „Was ist in den 30 Sekunden **vor** dem Freeze passiert?"

```
                   Ringbuffer (RAM, vorallokiert)
  ────────────────────────────────────────────────────────────▶ t
  [ ][ ][ ][ ][ ][ ][ ][X][ ][ ][ ][ ][ ][ ][ ][ ][ ][ ][ ][ ]
                        ▲
                        Spike bei t0
        ├── preWindow ──┤── postWindow ──┤
        │   30 s        │    15 s        │
        └──────── Incident-Ausschnitt ───┘
```

* Ring: `preWindow + postWindow + Reserve` Slots bei `frametime`-Rate (Default 4 Hz)
  → 60 s Vorlauf ≈ 240 Slots. Alle Slots werden beim Start **einmal** allokiert.
* Zusätzlich läuft ein zweiter, gröberer Ring für **Event-Histogramme**
  (welche Events in welcher Sekunde) und einer für **Addon-CPU-Deltas**.
* Bei einem Spike wird nur ein Marker gesetzt. Erst `postWindow` Sekunden später wird
  der Ausschnitt herauskopiert — dadurch enthält der Incident auch die Erholungsphase.
* Ein Incident wird **flach kopiert in neue Tabellen**, damit der Ring weiterlaufen
  kann. Das ist der einzige Ort mit nennenswerter Allokation, und er läuft
  ereignisgesteuert, nicht periodisch.
* Persistiert werden maximal `maxIncidents` (Default 20) Incidents, jeweils
  downgesampled auf 1 Hz, damit SavedVariables nicht explodieren. Der volle
  4-Hz-Ausschnitt bleibt für die aktuelle Session im RAM.

## 6. Spike-Erkennung und Korrelation

**Erkennung** (Monitoring/SpikeDetector.lua):

```
baseline = EMA(frameMs, alpha=0.05)            -- adaptiv, passt sich an 30/60/144 Hz an
isSpike  = frameMs > max(absMs[kind], baseline * mult[kind])
```

Default-Schwellen (in Settings änderbar):

| Klasse | absolut | Faktor zur Baseline |
|---|---|---|
| Minor Stutter | 33 ms | 2.0× |
| Stutter | 50 ms | 3.0× |
| Heavy Stutter | 100 ms | 5.0× |
| Freeze | 250 ms | 8.0× |

Ein Debounce verhindert, dass ein 400-ms-Freeze vier Incidents erzeugt.

**Korrelation** (Analysis/Correlation.lua): über alle Spikes der Session wird pro Addon
der Phi-Koeffizient zwischen „Addon-CPU im Sample über eigenem Baseline+kσ" und
„Spike in diesem Sample" berechnet.

| Bedingung | Label in der UI |
|---|---|
| n < 3 Spikes | `Insufficient data` |
| φ < 0.30 | `Weak association` |
| 0.30 ≤ φ < 0.55 | `Possible contributor` |
| 0.55 ≤ φ < 0.75 | `Likely correlated` |
| φ ≥ 0.75 | `Strongly correlated` |

Die UI schreibt **nie** „Addon X verursacht". Jeder Befund trägt `n = <Anzahl Spikes>`
und einen Tooltip, der die Rechnung offenlegt.
