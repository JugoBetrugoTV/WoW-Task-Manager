# Mock-Testbericht

Erzeugt am 2026-09-01 20:31 UTC gegen Addon-Version 0.2.0.

> **Alles hier ist MOCK VERIFIED, nichts ist REAL CLIENT VERIFIED.**
> Der Mock verhält sich so, wie ich glaube, dass der Client sich verhält. Wo
> diese Annahme falsch ist, ist auch der Test falsch — und trotzdem grün.
> Siehe [`07-API-VERIFICATION.md`](07-API-VERIFICATION.md).

## Was getestet wird

`tools/wowmock.lua` bildet Frames, Events, Texturen, FontStrings, die
Addon- und Profiling-APIs, CVars und die Uhr nach. Darauf laufen drei Suiten:

| Suite | Zweck |
|---|---|
| `tools/test.lua` | Verhaltens-Assertions über die volle Matrix |
| `tools/test-downsample.lua` | Spikes dürfen beim Downsampling nicht verschwinden |
| `tools/test-recorder.lua` | Flight-Recorder-Härtung, Coalescing, DB-Migrationen |

Gestartet mit `./tools/run-tests.sh` bzw. `./tools/release-check.sh`.

## Matrix: 4 Clients x Profiling an/aus x volle/abgeräumte API

```
  PASS  Retail-12.1.0      profiling=on  api=normal     137 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=degraded   150 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=normal     139 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=degraded   152 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=normal     137 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=degraded   150 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=normal     139 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=degraded   152 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=normal     137 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=degraded   150 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=normal     139 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=degraded   152 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=normal     137 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=degraded   150 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=normal     139 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=degraded   152 passed, 0 failed, 0 lua errors

syntax check:
  all 53 files parse

```

Die Variante **degraded** entfernt `RegisterAllEvents`, `GetNetStats`,
`EnumerateFrames`, `GetInstanceInfo`, `GetNumGroupMembers`,
`GetEventCPUUsage`, `GetFrameCPUUsage`, `GetScriptCPUUsage`,
`GetPhysicalScreenSize`, `GetCVarInfo`, `GetTimePreciseSec` und
`C_Timer` — und lässt `RegisterAllEvents` zusätzlich werfen. Das Addon muss
trotzdem laden, laufen und ehrlich berichten.

## Downsampling: der Fall aus dem Auftrag

```
== downsampling: spikes must survive ==
   34 passed, 0 failed, 0 lua errors
```

Enthält genau den beschriebenen Fall: ein Bucket mit 5 / 6 / 97 / 5 ms muss den
97-ms-Spike behalten. Zusätzlich wird die **Verdrahtung** geprüft — jeder Graph
und jede Sparkline auf Dashboard, Performance, Timeline und Topbar wird gegen
sein eigenes Feld geprüft.

**Das war ein echter Bug.** Die Richtung war an jeder Aufrufstelle invertiert:
Frame Time, Latenz, CPU, Events und Memory behielten das *Minimum* jeder Spalte,
also genau das Gegenteil. Jeder Spike wurde beim Zeichnen gelöscht. Der Test
schlägt fehl, wenn man den Fehler wieder einbaut (verifiziert).

## Flight Recorder, Coalescing, Migrationen

```
== schema migrations ==

== warm-up suppression ==

== incident coalescing ==

== flight recorder captures ==

== ring wrap-around ==

== session ending during a post-roll ==

== event monitoring modes ==

== simulated data is always marked ==

   62 passed, 0 failed, 0 lua errors
```

Abgedeckte Fälle:

* mehrere Spikes direkt hintereinander
* überlappende Captures (werden zu einem Incident zusammengefasst)
* Ringbuffer-Wrap-around, inklusive „Vorlauf war schon überschrieben" → `truncated`
* Loading Screens, Zonenwechsel, Login, `/reload` → unterdrückt statt gemeldet
* Session-Ende während der Post-Roll läuft → Flush statt Datenverlust
* Schema-Migration v1 → v2, unversionierte DB, DB aus einer *neueren* Version
* Event-Modi OFF / NORMAL / DETAILED
* injizierte Daten sind immer als `simulated` markiert

## Beim Härten gefundene und behobene Bugs

| # | Fund | Auswirkung |
|---|---|---|
| 1 | Downsampling-Richtung an allen Aufrufstellen invertiert | **Jeder Spike verschwand aus jedem Graphen.** Der Kern des Produkts. |
| 2 | Hot-Path-Vorfilter folgte der Baseline nicht | Bei 144 Hz waren relative Spikes zwischen ~14 und 33 ms unsichtbar |
| 3 | Baseline wurde vom allerersten Fenster geseedet | Ein Ruckler in der ersten Sekunde vergiftete die Baseline und machte sich selbst unsichtbar |
| 4 | Post-Roll wurde bei jedem Spike verlängert, ohne Deckel | Bei anhaltendem Ruckeln materialisierte **nie** ein Incident — genau dann, wenn man ihn braucht |
| 5 | `schemaVersion` stand in den Defaults | Die Defaults-Metatable beantwortete die Version für eine nie migrierte DB → **jede Migration wurde übersprungen** |
| 6 | Korrelations-Baseline war geschätzt (`avg/peak`) | Die einzige Zahl, die zählt, hing an einer erfundenen Größe. Jetzt vollständig gemessen. |
| 7 | Event-Zähler zählte über dem Distinct-Cap nicht mehr mit | Gesamtrate wurde bei > 400 verschiedenen Events zu niedrig gemeldet |
| 8 | Flush-Markierung prüfte auf den falschen Grund | Am Session-Ende abgeschnittene Incidents sahen vollständig aus |
| 9 | Sidebar berechnete die komplette Diagnose 2x/Sekunde | Das Monitoring-Tool wäre selbst zum Kostenfaktor geworden |

## Was der Mock nicht kann

* **Keine echten Rückgabewerte.** Ob `GetEventCPUUsage` ms oder s liefert,
  entscheidet der echte Client.
* **Keine echten Kosten.** Ob `RegisterAllEvents` im Schlachtzug tragbar ist,
  zeigt nur der Schlachtzug. Dafür gibt es `/wtm benchmark`.
* **Kein Taint.** Das Addon fasst nichts Geschütztes an, aber bewiesen ist das
  erst durch einen Kampf ohne Blocked-Action-Meldung.
* **Kein Rendering.** Ob Text abgeschnitten wird oder Graphen lesbar sind,
  sehe ich nur auf deinen Screenshots.
* **Nur enUS.** Deutsche Umlaute in Addon-Titeln sind ungetestet.
