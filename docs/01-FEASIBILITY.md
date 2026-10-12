# WoW Task Manager — Technische Machbarkeitsanalyse

> Stand: Ziel-Clients **Retail/Midnight 12.1.0**, **MoP Classic 5.5.4**,
> **Classic Era 1.15.9**, **TBC Anniversary 2.5.6**.
>
> Grundregel dieses Projekts: **Es wird kein Messwert erfunden.** Jede Zahl in der UI
> stammt aus einer dokumentierten WoW-API. Was die Sandbox nicht hergibt, wird als
> `Unavailable on this client` bzw. `Requires CPU profiling` angezeigt — nicht geschätzt
> und nicht simuliert.

---

## 1. Was ein Addon messen kann — und was nicht

### 1.1 Sicher und exakt messbar

| Größe | API | Anmerkung |
|---|---|---|
| FPS | `GetFramerate()` | vom Client geglättet, nicht der Momentanwert |
| **Frametime (exakt)** | `OnUpdate(self, elapsed)` | `elapsed` ist das echte Delta des letzten Frames in Sekunden. Das ist die genaueste Frame-Messung, die ein Addon hat — besser als `GetFramerate()` |
| Hochauflösende Zeit | `debugprofilestop()` | ms seit Client-Start, in **allen vier** Clients vorhanden |
| Latenz Home/World | `GetNetStats()` | **wird nur ca. alle 30 s aktualisiert** — häufigeres Pollen liefert identische Werte |
| Bandbreite in/out | `GetNetStats()` | dito |
| Gesamter Lua-Speicher | `collectgarbage("count")` | KB, sofort, sehr billig |
| Speicher pro Addon | `UpdateAddOnMemoryUsage()` + `GetAddOnMemoryUsage(i)` | **teuer** (Heap-Walk). Nur mit niedriger Frequenz |
| Addon-Metadaten | `GetAddOnInfo` / `GetAddOnMetadata` / `GetAddOnDependencies` | in Retail unter `C_AddOns.*` |
| Addon aktivieren/deaktivieren (ab Reload) | `EnableAddOn` / `DisableAddOn` | nicht protected, wirkt erst nach `/reload` |
| Zone / Instanz / Gruppengröße | `GetInstanceInfo`, `GetRealZoneText`, `GetNumGroupMembers` | |
| Combat-Status | `InCombatLockdown()`, `PLAYER_REGEN_*` | |
| Event-Aufkommen (global) | `frame:RegisterAllEvents()` | siehe 1.3 |

### 1.2 Nur mit aktiviertem `scriptProfile` messbar

Der CVar `scriptProfile` schaltet den Lua-Profiler des Clients ein. Er **erfordert einen
`/reload`** und kostet selbst dauerhaft Performance (Blizzard schätzt den Overhead
spürbar ein). Ohne ihn liefern alle folgenden Funktionen `0`:

| Größe | API |
|---|---|
| CPU-Zeit pro Addon (kumulativ, ms) | `UpdateAddOnCPUUsage()` + `GetAddOnCPUUsage(i)` |
| CPU-Zeit gesamt (Lua) | `GetScriptCPUUsage()` |
| CPU-Zeit **pro Event** + Aufrufzahl | `GetEventCPUUsage([event])` |
| CPU-Zeit **pro Frame** + Handler-Aufrufzahl | `GetFrameCPUUsage(frame, includeChildren)` |
| CPU-Zeit pro Funktion | `GetFunctionCPUUsage(func, includeSubroutines)` |
| Zähler zurücksetzen | `ResetCPUUsage()` |

Konsequenz für das Addon: **Der komplette Bereich „Processes/CPU" ist zweistufig.**
Ist `scriptProfile` aus, zeigt die UI eine Karte
`CPU profiling disabled — enable & reload` mit Aktion, statt Nullen als Messwerte zu
verkaufen.

> `GetAddOnCPUUsage` liefert **kumulative Millisekunden** seit dem letzten
> `ResetCPUUsage()`. Sinnvoll ist ausschließlich das **Delta zwischen zwei Samples**,
> geteilt durch die verstrichene Wall-Clock-Zeit → „% eines Kerns".

### 1.3 Eingeschränkt / heuristisch messbar

**Event-Aufkommen** — `frame:RegisterAllEvents()` ist eine reguläre, dokumentierte API
(Blizzards eigener `/etrace` nutzt sie). Damit bekommt man *jedes* gefeuerte Event.
Was man damit **nicht** bekommt: welches Addon darauf reagiert. Die Zuordnung
Event → Addon ist über die öffentliche API **nicht** exakt lösbar.

Was legitim möglich ist:
* `GetEventCPUUsage(event)` → wie teuer ein Event **insgesamt** über alle Addons ist.
* `EnumerateFrames()` + `frame:IsEventRegistered(event)` → welche *Frames* auf ein Event
  hören. Die Zuordnung Frame → Addon ist danach nur noch über den **Frame-Namen**
  (Präfix-Heuristik gegen die Liste geladener Addons) möglich, und anonyme Frames
  (`CreateFrame("Frame")` ohne Namen) lassen sich gar nicht zuordnen.

→ Das Addon zeigt diese Spalte deshalb **explizit als `heuristic`** an, mit Angabe wie
viele Frames zugeordnet werden konnten und wie viele anonym blieben. Kein Ratespiel,
das als Messung verkauft wird.

**OnUpdate-Aktivität pro Addon** — es gibt keine API „Anzahl OnUpdate-Aufrufe von Addon X".
Näherung: `GetFrameCPUUsage(frame)` liefert als zweiten Rückgabewert die **Anzahl der
Script-Handler-Aufrufe** dieses Frames. Über die (heuristische) Frame→Addon-Zuordnung
lässt sich daraus eine Untergrenze bilden. Wird als `~ estimated` gekennzeichnet.

**Garbage Collection** — WoW gibt keine GC-Statistik heraus. Was messbar ist: der
*Verlauf* von `collectgarbage("count")`. Ein Abfall der Kurve **ist** ein GC-Durchlauf.
Daraus lassen sich GC-Frequenz und freigegebene Menge rekonstruieren — das ist eine
Beobachtung, keine API. Wird als „GC events (derived from Lua heap curve)" beschriftet.
Das Addon ruft **niemals** selbst `collectgarbage("collect")` auf.

**1% Low FPS** — aus den per-Frame-Frametimes über ein Histogramm berechenbar
(99. Perzentil der Frametime). Exakt genug, ohne jeden Frame speichern zu müssen.

### 1.4 Technisch unmöglich (wird nicht gebaut)

| Wunsch | Warum nicht |
|---|---|
| CPU-/GPU-Last des Betriebssystems | Sandbox hat keinen OS-Zugriff |
| RAM-Verbrauch des Prozesses (nicht-Lua) | keine API |
| Netzwerk-Paketinspektion | keine API |
| Laufendes Addon entladen | Lua-State ist nicht partiell abbaubar; `DisableAddOn` wirkt erst nach Reload |
| Fremden Lua-Code beenden / Thread killen | kein Preemption-Modell |
| Protected Functions aufrufen | Hardware-Event-Bindung, wird nicht umgangen |
| Exakte Zuordnung Event → Addon | siehe 1.3 |
| Disk-I/O / Dateigrößen von Addons | kein Dateisystemzugriff |
| Echte Stacktraces fremder Addons zur Spike-Zeit | kein Sampling-Profiler in der API |

---

## 2. Warum das Diagnose-Addon selbst nicht zum Problem wird

Der teuerste denkbare Fehler wäre ein Monitor, der mehr kostet als das, was er misst.
Die Gegenmaßnahmen sind Architektur, nicht Kosmetik:

1. **Genau ein `OnUpdate`** im ganzen Addon. Es macht pro Frame nur Integer-/Float-Arithmetik
   auf Upvalues und einen Histogramm-Index. Keine Tabellenerzeugung, keine String-Operation,
   keine `pairs()`-Schleife.
2. **Gestaffeltes Sampling** über einen zentralen Scheduler (Frametime 4 Hz, CPU 0.5 Hz,
   Memory 0.1 Hz, Metadaten nur on demand).
3. **Ringbuffer mit vorallokierten Slots.** Nach dem Start allokiert der Flight Recorder
   keine Tabelle mehr — die Slots werden überschrieben.
4. **UI rechnet nur, wenn sie sichtbar ist.** Unsichtbare Seiten bekommen kein Update.
5. **Graphen mit Downsampling + Texture-Pooling.** Ein Graph hat maximal so viele
   Liniensegmente wie Pixelspalten, nicht wie Datenpunkte.
6. **Selbstmessung.** Das Addon misst seine eigenen Sampling-Kosten mit
   `debugprofilestop()` und zeigt sie im Dashboard. Übersteigt der Eigen-Overhead die
   konfigurierte Grenze, warnt es und reduziert automatisch die Sampling-Rate.
7. **Adaptive Sampling.** Hohe Auflösung nur in den Sekunden rund um einen Spike.

---

## 3. Bewertung der Kernfunktionen

| Feature | Machbar? | Basis |
|---|---|---|
| FPS-/Frametime-Monitoring | **Ja, exakt** | `OnUpdate` elapsed |
| Stutter-/Freeze-Erkennung | **Ja, exakt** | Frametime vs. adaptiver Baseline |
| Flight Recorder (30–60 s Ringbuffer) | **Ja** | eigener Ringbuffer |
| Addon-CPU-Analyse | **Ja, mit `scriptProfile`** | `GetAddOnCPUUsage` |
| Event-Rate / Event-Storm | **Ja** | `RegisterAllEvents` |
| Event → Addon | **Nur heuristisch** | `EnumerateFrames` + Namensheuristik |
| Memory pro Addon / Wachstum | **Ja** | `GetAddOnMemoryUsage` |
| Performance-Timeline | **Ja** | aggregierte History |
| Spike-Korrelation | **Ja, als Korrelation** | Statistik über Samples, nie „Ursache" |
| Session-History | **Ja** | SavedVariables + Aggregation |
| Addon enable/disable | **Ja, ab nächstem Reload** | `EnableAddOn`/`DisableAddOn` |
| Laufendes Addon stoppen | **Nein** | — |
