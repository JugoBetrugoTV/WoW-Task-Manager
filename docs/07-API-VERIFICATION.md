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

**Stand heute ist jede Zeile in diesem Dokument MOCK VERIFIED und keine einzige
REAL CLIENT VERIFIED.** Die Spalte wird erst gesetzt, wenn du selbst im Spiel
getestet hast.

---

## Gesamtstatus

| Client | Version | Interface | Mock | Real Client |
|---|---|---|:--:|:--:|
| Retail / Midnight | 12.1.0 | `120100` | ✅ MOCK VERIFIED | ⬜ **NOT TESTED** |
| MoP Classic | 5.5.4 | `50504` | ✅ MOCK VERIFIED | ⬜ **NOT TESTED** |
| TBC Anniversary | 2.5.6 | `20506` | ✅ MOCK VERIFIED | ⬜ **NOT TESTED** |
| Classic Era | 1.15.9 | `11509` | ✅ MOCK VERIFIED | ⬜ **NOT TESTED** |

---

## Wie jede API abgesichert ist

Keine dieser Funktionen wird direkt aufgerufen. Jede geht durch
`Core/Compat.lua`, wird zur Laufzeit geprobt und ist in `pcall` gekapselt.
Wenn eine davon auf deinem Client anders heißt, anders zurückgibt oder gar
nicht existiert, **fällt das Addon nicht aus** — das Feature meldet sich als
`Unavailable` mit Begründung.

### Zeitmessung

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `OnUpdate(self, elapsed)` | exakte Frametime | keins — Kern-API seit jeher | ✅ | ⬜ |
| `debugprofilestop()` | ms-Timer, Overhead-Messung | keins | ✅ | ⬜ |
| `GetFramerate()` | Vergleichswert (geglättet) | keins | ✅ | ⬜ |
| `GetTimePreciseSec()` | Fallback-Timer | **optional**, wird geprobt | ✅ | ⬜ |

### Netzwerk

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `GetNetStats()` | Home/World Latenz, Bandbreite | Rückgabereihenfolge ist `bwIn, bwOut, latHome, latWorld` — **im Spiel gegenprüfen** | ✅ | ⬜ |

### Speicher

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `collectgarbage("count")` | Lua-Heap in KB | keins | ✅ | ⬜ |
| `UpdateAddOnMemoryUsage()` | Voraussetzung für Per-Addon-Speicher | **teuer** — Intervall bewusst langsam | ✅ | ⬜ |
| `GetAddOnMemoryUsage(index)` | Speicher pro Addon in KB | keins | ✅ | ⬜ |

### CPU-Profiling (alle erfordern `scriptProfile=1` + Reload)

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `UpdateAddOnCPUUsage()` | Voraussetzung | keins | ✅ | ⬜ |
| `GetAddOnCPUUsage(index)` | **kumulative** ms pro Addon | Kumulativ! Nur Deltas sind sinnvoll | ✅ | ⬜ |
| `GetScriptCPUUsage()` | Lua-CPU gesamt | | ✅ | ⬜ |
| `GetEventCPUUsage([event])` | Handler-Zeit pro Event | **Rückgabe `ms, count` im Spiel prüfen** | ✅ | ⬜ |
| `GetFrameCPUUsage(frame, bool)` | Handler-Zeit + Aufrufzahl pro Frame | | ✅ | ⬜ |
| `ResetCPUUsage()` | Zähler zurücksetzen | nur manuell, nie automatisch | ✅ | ⬜ |

### Events

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `frame:RegisterAllEvents()` | globale Event-Rate | **teuerste Stelle im Addon** — deshalb OFF/NORMAL/DETAILED | ✅ | ⬜ |
| `frame:IsEventRegistered(e)` | exakte Prüfung pro Frame | keins | ✅ | ⬜ |
| `EnumerateFrames([frame])` | Frame-Walk für Zuordnung | on demand, nie periodisch | ✅ | ⬜ |

### Addon-Verwaltung

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `C_AddOns.*` bzw. Globals | Metadaten, Laden, Aktivieren | in Retail 11.0 nach `C_AddOns` verschoben — **beide werden geprobt** | ✅ | ⬜ |
| `GetAddOnEnableState` | Enable-Status | **Argumentreihenfolge unterscheidet sich!** Beide werden probiert und das Ergebnis validiert | ✅ | ⬜ |
| `EnableAddOn` / `DisableAddOn` | erst nach Reload wirksam | Argumentform variiert; beide werden versucht | ✅ | ⬜ |
| `ReloadUI()` | Reload | ungeschützt, nie ohne Klick | ✅ | ⬜ |

### CVars

| API | Verwendet für | Risiko | Mock | Real |
|---|---|---|:--:|:--:|
| `GetCVar` / `SetCVar` | u. a. `scriptProfile` | Retail hat zusätzlich `C_CVar.*` — beide werden geprobt | ✅ | ⬜ |
| `GetCVarInfo(name)` | Schreibbarkeit prüfen | **Rückgabepositionen 5/6/7 = locked/secure/readonly — im Spiel prüfen** | ✅ | ⬜ |

### Kontext

| API / Event | Risiko | Mock | Real |
|---|---|:--:|:--:|
| `GetInstanceInfo()` | Rückgabe variiert je Client, nur `instanceType` wird ausgewertet | ✅ | ⬜ |
| `GetNumGroupMembers()` | | ✅ | ⬜ |
| `PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)` | **Argumente können fehlen** — dann greift der Zone-Fallback | ✅ | ⬜ |
| `ENCOUNTER_START` / `_END` | **existiert nicht in Classic Era / TBC** — geprobt | ✅ | ⬜ |
| `LOADING_SCREEN_ENABLED` / `_DISABLED` | auf alten Clients unsicher — geprobt | ✅ | ⬜ |
| `CHALLENGE_MODE_START` | nur Retail/MoP — geprobt | ✅ | ⬜ |

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

## Wie die Spalte auf PASS kommt

Nach deinem ersten echten Test:

1. Du schickst mir Lua-Errors, Screenshots und Beobachtungen.
2. Ich trage pro Zeile ein: `✅ REAL CLIENT VERIFIED (12.1.0, 2026-09-xx)` —
   oder `❌ FAILED` mit dem konkreten Befund.
3. Fehlgeschlagene Zeilen werden gefixt, bevor irgendetwas anderes gebaut wird.

Die Checkliste dafür steht in [`08-INSTALL-AND-TEST.md`](08-INSTALL-AND-TEST.md).
