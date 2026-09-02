# Mock-Testbericht

Erzeugt am 2026-09-02 gegen Addon-Version 0.5.0.

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
| `tools/run.lua` | Kompletter Login-bis-Logout-Durchlauf, alle vier Clients |

### Seit 0.5.0: Text-Geometrie ist messbar

Der Mock zeichnet nichts, konnte aber bis 0.4.0 auch die Frage nicht
beantworten, die aus dem echten Client zurückkam: *passt dieser Text in seinen
Kasten?* `SetPoint` war ein No-Op.

Jetzt werden Anker aufgezeichnet und aufgelöst. Eine FontString hat damit eine
echte Breite, und zwei Prüfungen laufen über jede Seite — bei Standardgrösse und
bei der kleinstmöglichen Fenstergrösse:

| Prüfung | Was sie findet |
|---|---|
| `AuditText` | Text, der breiter ist als sein Kasten. Zwei Klassen: **unbounded** (die FontString hat gar keine eigene Breite, WoW schneidet also nichts ab — sie zeichnet über das, was daneben steht) und **clipped** (Breite vorhanden, Text wird am Rand abgeschnitten). Budget für *unbounded*: **null**. |
| `AuditTextOverlap` | Zwei FontStrings auf derselben Zeile, die sich überlappen. Genau der gemeldete Fall: ein Label links, ein Wert rechts, keins von beiden begrenzt, und irgendwann treffen sie sich in der Mitte. |

Beide werden zusätzlich mit langen Addon-Namen und langen Lokalisierungsstrings
gefüttert, weil ein Layout, das mit englischen Beschriftungen gerade so aufgeht,
mit deutschen nicht mehr aufgeht. Setzt man die Begrenzung in `UI.StatRow`
zurück, meldet die Suite sofort 132 px Überlappung — die Prüfung ist also keine,
die immer grün ist.

Gestartet mit `./tools/run-tests.sh` bzw. `./tools/release-check.sh`.

## Matrix: 4 Clients x Profiling an/aus x volle/abgeräumte API x Ace3 an/aus

```
  PASS  Retail-12.1.0      profiling=on  api=normal   no-ace3    290 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=normal   ace3       290 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=degraded no-ace3    298 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=degraded ace3       298 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=normal   no-ace3    289 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=normal   ace3       289 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=degraded no-ace3    297 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=degraded ace3       297 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=normal   no-ace3    290 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=normal   ace3       290 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=degraded no-ace3    298 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=degraded ace3       298 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=normal   no-ace3    289 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=normal   ace3       289 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=degraded no-ace3    297 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=degraded ace3       297 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=normal   no-ace3    290 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=normal   ace3       290 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=degraded no-ace3    298 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=degraded ace3       298 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=normal   no-ace3    289 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=normal   ace3       289 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=degraded no-ace3    297 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=degraded ace3       297 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=normal   no-ace3    290 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=normal   ace3       290 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=degraded no-ace3    298 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=degraded ace3       298 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=normal   no-ace3    289 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=normal   ace3       289 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=degraded no-ace3    297 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=degraded ace3       297 passed, 0 failed, 0 lua errors
syntax check:
  all 57 files parse
```

Die Variante **degraded** entfernt `RegisterAllEvents`, `GetNetStats`,
`EnumerateFrames`, `GetInstanceInfo`, `GetNumGroupMembers`,
`GetEventCPUUsage`, `GetFrameCPUUsage`, `GetScriptCPUUsage`,
`GetPhysicalScreenSize`, `GetCVarInfo`, `GetTimePreciseSec` und
`C_Timer` — und lässt `RegisterAllEvents` zusätzlich werfen. Das Addon muss
trotzdem laden, laufen und ehrlich berichten. Sie entfernt ausserdem
`Settings` und `InterfaceOptions_AddCategory`, sodass der Fall „dieser Client
bietet gar keinen Weg, einen Eintrag unter *Options → AddOns* anzulegen"
mitgetestet wird.

Die Variante **ace3** lädt vor dem Addon `tools/ace3stub.lua`, einen bewusst
minimalen Ace3-Ersatz. Er existiert, weil der Ace3-Zweig von `Core/Ace.lua`
vorher **von keinem einzigen Test ausgeführt wurde**: der Mock hatte kein Ace3,
also lief immer der interne Fallback. Auf einem echten Client entscheidet
darüber die Addon-Liste des Spielers — lädt *irgendein* installiertes Addon
Ace3, läuft der andere Zweig. Genau daran ist `/wtm` in Test 2 zerbrochen.

Der Stub bildet Ace3 nicht nach, sondern ist an genau den Stellen treu, an
denen Ace3 und der Fallback sich **widersprechen**. Der wichtigste Fall:
AceConsole ruft Slash-Handler als `func(msg, editBox)` auf, der interne
Fallback als `func(input)`. Der Widerspruch ist im Stub exakt reproduziert,
damit er als Testfehler auftaucht statt als Fehlermeldung im Spiel eines
Spielers.

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

## Was der erste echte Client-Test geändert hat

Der Mock war an zwei Stellen **zu nachsichtig** und hat dadurch echte Bugs
durchgelassen. Beides ist jetzt geschlossen:

| Lücke | Folge | Behoben durch |
|---|---|---|
| Farb-Setter waren No-Ops und akzeptierten alles | `SetTextColor(x)` mit **einer** Zahl statt r,g,b,a fiel nicht auf — im echten Client 220 Fehler | `checkColor` im Mock validiert Anzahl, Typ und Wertebereich |
| Nichts hat je etwas mit der Maus berührt | Tooltips und Hover-Handler waren komplett ungetestet — der Fehler steckte in genau so einem Pfad | `mock.FireScriptOnAll("OnEnter" / "OnLeave" / "OnClick")` feuert jeden Handler auf jedem Frame |
| `EnumerateFrames` lieferte nur Frames | Auf Retail kommen auch FontStrings zurück, deren `GetName` keinen String liefert → Absturz | `mock.AddHostileRegions()` baut genau solche Objekte ein; Frames und Regionen haben jetzt getrennte Metatables wie in WoW |

Der Hover-Sweep hat sofort einen **zweiten**, vorher unbemerkten Bug gefunden:
der X-Button der Titelleiste rief `Close()` auf dem Frame statt auf dem
Fenster-Modul und warf, statt zu schliessen.

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
