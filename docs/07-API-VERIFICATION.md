# API-Verifikation: MOCK VERIFIED vs REAL CLIENT VERIFIED

## Die Regel

Es gibt in diesem Projekt **zwei völlig getrennte Verifikationsstufen**, und
die eine impliziert die andere nicht:

| Stufe | Bedeutung |
|---|---|
| **MOCK VERIFIED** | Der Code-Pfad läuft im Test-Harness gegen `tools/wowmock.lua` fehlerfrei durch. Das beweist, dass die *Logik* funktioniert und dass Feature-Detection, Fallbacks und Fehlerbehandlung greifen. **Es beweist nichts über den echten Client.** |
| **REAL CLIENT VERIFIED** | Die Funktion wurde von einem Menschen im laufenden Spiel auf genau diesem Client getestet und liefert plausible Werte. |

> **Ein Mock ist eine Annahme, kein Beweis.**
> `tools/wowmock.lua` verhält sich so, wie *ich* glaube, dass der Client sich
> verhält. Wo diese Annahme falsch ist, ist der Mock genauso falsch — und der
> Test wird trotzdem grün. Deshalb darf eine bestandene Mock-Suite niemals als
> Client-Unterstützung gewertet werden.

**Retail 12.1.0 ist seit dem ersten In-Game-Test teilweise REAL CLIENT VERIFIED.**
Die drei Classic-Clients sind weiterhin ausschliesslich MOCK VERIFIED.

---

## Gesamtstatus

| Client | Version | Interface | Mock | Real Client |
|---|---|---|:--:|:--:|
| Retail / Midnight | 12.1.0 | `120100` | ✅ MOCK VERIFIED | ✅ **REAL CLIENT VERIFIED** (2026-09-01, Build 69497) |
| MoP Classic | 5.5.4 | `50504` | ✅ MOCK VERIFIED | ⬜ **NOT TESTED** |
| TBC Anniversary | 2.5.6 | `20506` | ✅ MOCK VERIFIED | ⬜ **NOT TESTED** |
| Classic Era | 1.15.9 | `11509` | ✅ MOCK VERIFIED | ⬜ **NOT TESTED** |

### Test 1 — Retail 12.1.0 (Build 69497), 2026-09-01

Das Addon lädt, `/wtm` öffnet, das Dashboard funktioniert, Spike-Erkennung,
Suppression, Sessions und Diagnostics laufen. 182 Addons erkannt, 3 geladen,
`scriptProfile` an, alle CPU-Spalten gefüllt.

**Bestätigt korrekt gemessen:** FPS 123 bei 8.1 ms Frametime (1000/123 = 8.13 —
konsistent), Home/World Latency 13 ms, Lua-Heap 113.6 MB, Addon-Speicher 5.8 MB,
Event-Rate mit 111 verschiedenen Events, 1 % Low 65.6 fps, 0.1 % Low 35.3 fps,
schlechtester Frame 1252 ms.

**Vier Befunde, alle behoben:**

| Befund | Ursache |
|---|---|
| `SetTextColor`-Fehler, **220×** | `a and f() or g()` schneidet in Lua einen Mehrfach-Return auf **einen** Wert ab — `SetTextColor` bekam eine Zahl statt r,g,b,a. Betraf praktisch jeden Tooltip. |
| `ScanFrames` stürzt ab | `EnumerateFrames` liefert auf Retail auch **FontStrings und Texturen**, und deren `GetName` gibt nicht zuverlässig einen String zurück. Der Walk lief in eine FontString aus fremdem XML. |
| Eigen-Overhead **51.68 ms/s** (5.17 % eines Frames) | Sechs Graphen zweimal pro Sekunde neu zeichnen = ein komplettes 60-fps-Frame-Budget pro Redraw. Dazu Memory-Scan im Burst mit 182 installierten Addons. |
| Texte überlappen, Resizing bricht Layout | Graph-Fusszeile lag auf der Zeitachse, Achsenlabels an den Rändern zentriert, Sidebar-Fusszeile zweizeilig, Layout nur bei Maus-Loslassen aktualisiert. |

Zusätzlich beim Nachtesten gefunden: der **X-Button** der Titelleiste rief
`Close()` auf dem Frame statt auf dem Fenster-Modul — er warf einen Fehler
statt zu schliessen.

---

## Wie jede API abgesichert ist

Keine dieser Funktionen wird direkt aufgerufen. Jede geht durch
`Core/Compat.lua`, wird zur Laufzeit geprobt und ist in `pcall` gekapselt.
Wenn eine davon auf deinem Client anders heißt, anders zurückgibt oder gar
nicht existiert, **fällt das Addon nicht aus** — das Feature meldet sich als
`Unavailable` mit Begründung.

### Zeitmessung

> `Real` = Retail 12.1.0. Die drei Classic-Clients stehen überall auf ⬜.

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `OnUpdate(self, elapsed)` | exakte Frametime | keins — Kern-API seit jeher | ✅ | ✅ |
| `debugprofilestop()` | ms-Timer, Overhead-Messung | keins | ✅ | ✅ |
| `GetFramerate()` | Vergleichswert (geglättet) | keins | ✅ | ✅ |
| `GetTimePreciseSec()` | Fallback-Timer | **optional**, wird geprobt | ✅ | ✅ |

### Netzwerk

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `GetNetStats()` | Home/World Latenz, Bandbreite | Reihenfolge `bwIn, bwOut, latHome, latWorld` **bestätigt** | ✅ | ✅ |

### Speicher

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `collectgarbage("count")` | Lua-Heap in KB | keins | ✅ | ✅ |
| `UpdateAddOnMemoryUsage()` | Voraussetzung für Per-Addon-Speicher | **teuer, im Test bestätigt** — Intervall auf 20 s erhöht, kein Burst mehr | ✅ | ✅ |
| `GetAddOnMemoryUsage(index)` | Speicher pro Addon in KB | keins | ✅ | ✅ |

### CPU-Profiling (alle erfordern `scriptProfile=1` + Reload)

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `UpdateAddOnCPUUsage()` | Voraussetzung | keins | ✅ | ✅ |
| `GetAddOnCPUUsage(index)` | **kumulative** ms pro Addon | Kumulativ! Nur Deltas sind sinnvoll | ✅ | ✅ |
| `GetScriptCPUUsage()` | Lua-CPU gesamt | | ✅ | ✅ |
| `GetEventCPUUsage([event])` | Handler-Zeit pro Event | existiert; Einheit noch nicht gegen eine Referenz geprüft | ✅ | ◐ |
| `GetFrameCPUUsage(frame, bool)` | Handler-Zeit + Aufrufzahl pro Frame | | ✅ | ✅ |
| `ResetCPUUsage()` | Zähler zurücksetzen | nur manuell, nie automatisch | ✅ | ⬜ |

### Events

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `frame:RegisterAllEvents()` | globale Event-Rate | funktioniert; 111 Events beobachtet | ✅ | ✅ |
| `frame:IsEventRegistered(e)` | exakte Prüfung pro Frame | keins | ✅ | ✅ |
| `EnumerateFrames([frame])` | Frame-Walk für Zuordnung | **liefert auch FontStrings/Texturen** — deren `GetName` gibt keinen String zurück. Guard eingebaut. | ✅ | ✅ |

### Addon-Verwaltung

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `C_AddOns.*` bzw. Globals | Metadaten, Laden, Aktivieren | 182 Addons korrekt erkannt | ✅ | ✅ |
| `GetAddOnEnableState` | Enable-Status | Probe funktioniert auf Retail | ✅ | ✅ |
| `EnableAddOn` / `DisableAddOn` | erst nach Reload wirksam | Argumentform variiert; beide werden versucht | ✅ | ⬜ |
| `ReloadUI()` | Reload | ungeschützt, nie ohne Klick | ✅ | ⬜ |

### CVars

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `GetCVar` / `SetCVar` | u. a. `scriptProfile` | `scriptProfile` erfolgreich gesetzt und gelesen | ✅ | ✅ |
| `GetCVarInfo(name)` | Schreibbarkeit prüfen | existiert; Positionen noch nicht gegen einen geschützten CVar geprüft | ✅ | ◐ |

### Kontext

| API / Event | Risiko | Mock | Real |
|---|---|:--:|:--:|
| `GetInstanceInfo()` | Rückgabe variiert je Client, nur `instanceType` wird ausgewertet | ✅ | ✅ |
| `GetNumGroupMembers()` | | ✅ | ✅ |
| `PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)` | Argumente vorhanden: „2 spikes not reported: 2 initial login" | ✅ | ✅ |
| `ENCOUNTER_START` / `_END` | auf Retail vorhanden (Capability-Report) | ✅ | ✅ |
| `LOADING_SCREEN_ENABLED` / `_DISABLED` | auf Retail vorhanden | ✅ | ✅ |
| `CHALLENGE_MODE_START` | auf Retail vorhanden | ✅ | ✅ |

---

## Was der Mock ausdrücklich NICHT beweist

1. **Rückgabewerte.** Der Mock gibt zurück, was ich erwarte. Ob
   `GetEventCPUUsage` wirklich Millisekunden liefert oder Sekunden, sieht man
   erst im Spiel.
2. **Kosten.** Der Mock hat keine echten Kosten. Ob `RegisterAllEvents` im
   Schlachtzug erträglich ist, entscheidet sich nur im Schlachtzug. Genau
   dafür gibt es `/wtm benchmark`.
3. **Taint.** Im Mock gibt es kein Taint-System. Das Addon berührt keine
   geschützten Frames und ruft keine geschützte Funktion auf, aber
   *bewiesen* ist das erst durch einen Kampf im echten Client ohne
   Blocked-Action-Meldung.
4. **Rendering.** Der Mock zeichnet nichts. Ob das UI gut aussieht, ob Text
   abgeschnitten wird, ob Graphen lesbar sind — dafür brauche ich deine
   Screenshots.
5. **Locale.** Getestet wird `enUS`. Deutsche Fonts und Umlaute in
   Addon-Titeln sind ungetestet.

---

## Noch offen auf Retail

| Punkt | Warum noch nicht bestätigt |
|---|---|
| `GetEventCPUUsage` Einheit | Der Wert existiert, aber ob er Millisekunden meint, ist nur gegen eine Referenz prüfbar |
| `GetCVarInfo` Positionen 5/6/7 | Nur an einem geschützten CVar prüfbar; keiner der gelesenen ist geschützt |
| `ResetCPUUsage` | Nie ausgelöst worden (nur manuell) |
| `EnableAddOn` / `DisableAddOn` | Nie ausgelöst worden |
| Taint / Blocked Action | Kein Kampf getestet |
| Ladebildschirm-Suppression | Kein Zonenwechsel im Test |
| Alt-Tab-Heuristik | Nicht getestet |
| Nicht-enUS-Locale | Nicht getestet |

## Wie die Spalte auf PASS kommt

1. Du schickst mir Lua-Errors, Screenshots und Beobachtungen.
2. Ich trage pro Zeile ein: `✅ REAL CLIENT VERIFIED (Version, Datum)` —
   oder `❌ FAILED` mit dem konkreten Befund.
3. Fehlgeschlagene Zeilen werden gefixt, bevor irgendetwas anderes gebaut wird.

Die Checkliste dafür steht in [`08-INSTALL-AND-TEST.md`](08-INSTALL-AND-TEST.md).
