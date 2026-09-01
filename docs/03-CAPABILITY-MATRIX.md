# Capability Matrix

Legende:
`✓` verfügbar · `◐` eingeschränkt/heuristisch · `⚙` nur mit `scriptProfile=1` (+ Reload)
· `✕` nicht möglich

Diese Matrix ist **nicht nur Dokumentation** — sie wird zur Laufzeit von
`Core/Capabilities.lua` durch echte Feature-Detection erzeugt und ist im Addon unter
*Settings → Capabilities* einsehbar. Die Tabelle hier ist der Erwartungswert; maßgeblich
ist immer die Laufzeitprüfung.

| Feature | Retail 12.1.0 | MoP 5.5.4 | TBC 2.5.6 | Classic 1.15.9 | Quelle |
|---|:--:|:--:|:--:|:--:|---|
| **Frametime pro Frame (exakt)** | ✓ | ✓ | ✓ | ✓ | `OnUpdate` elapsed |
| FPS | ✓ | ✓ | ✓ | ✓ | `GetFramerate` |
| Hochauflösender Timer | ✓ | ✓ | ✓ | ✓ | `debugprofilestop` |
| 1% Low / Perzentile | ✓ | ✓ | ✓ | ✓ | eigenes Histogramm |
| Stutter-/Freeze-Erkennung | ✓ | ✓ | ✓ | ✓ | abgeleitet |
| Flight Recorder | ✓ | ✓ | ✓ | ✓ | eigener Ringbuffer |
| Latenz Home/World | ✓ | ✓ | ✓ | ✓ | `GetNetStats` (≈30 s Takt) |
| Bandbreite in/out | ✓ | ✓ | ✓ | ✓ | `GetNetStats` |
| Gesamter Lua-Speicher | ✓ | ✓ | ✓ | ✓ | `collectgarbage("count")` |
| **Speicher pro Addon** | ✓ | ✓ | ✓ | ✓ | `GetAddOnMemoryUsage` |
| Speicherwachstum / Leak-Indikator | ✓ | ✓ | ✓ | ✓ | abgeleitete Trendanalyse |
| GC-Ereignisse | ◐ | ◐ | ◐ | ◐ | aus Heap-Kurve abgeleitet, keine API |
| GC erzwingen | ✕ | ✕ | ✕ | ✕ | bewusst nicht implementiert |
| **CPU-Zeit pro Addon** | ⚙ | ⚙ | ⚙ | ⚙ | `GetAddOnCPUUsage` |
| CPU gesamt (Lua) | ⚙ | ⚙ | ⚙ | ⚙ | `GetScriptCPUUsage` |
| CPU pro Event | ⚙ | ⚙ | ⚙ | ⚙ | `GetEventCPUUsage` |
| CPU pro Frame + Handler-Count | ⚙ | ⚙ | ⚙ | ⚙ | `GetFrameCPUUsage` |
| CPU pro Funktion | ⚙ | ⚙ | ⚙ | ⚙ | `GetFunctionCPUUsage` |
| `scriptProfile` per Addon setzbar | ✓ | ✓ | ✓ | ✓ | `SetCVar`, wirkt nach Reload |
| **Event-Rate global** | ✓ | ✓ | ✓ | ✓ | `RegisterAllEvents` |
| Event-Storm-Erkennung | ✓ | ✓ | ✓ | ✓ | abgeleitet |
| Event → Addon-Zuordnung | ◐ | ◐ | ◐ | ◐ | `EnumerateFrames` + Namensheuristik |
| OnUpdate-Aufrufe pro Addon | ◐⚙ | ◐⚙ | ◐⚙ | ◐⚙ | `GetFrameCPUUsage` Count + Heuristik |
| Anzahl Frames pro Addon | ◐ | ◐ | ◐ | ◐ | `EnumerateFrames` + Namensheuristik |
| Registrierte Events pro Frame | ✓ | ✓ | ✓ | ✓ | `frame:IsEventRegistered` |
| **Addon-Metadaten (Titel/Version/Notes)** | ✓ | ✓ | ✓ | ✓ | `GetAddOnMetadata` |
| Abhängigkeiten / optionale Deps | ✓ | ✓ | ✓ | ✓ | `GetAddOnDependencies` |
| LoadOnDemand-Status | ✓ | ✓ | ✓ | ✓ | `IsAddOnLoadOnDemand` |
| Enable-State (Char/Account) | ✓ | ✓ | ✓ | ✓ | `GetAddOnEnableState` |
| **Addon für nächsten Reload deaktivieren** | ✓ | ✓ | ✓ | ✓ | `DisableAddOn` |
| Addon für nächsten Reload aktivieren | ✓ | ✓ | ✓ | ✓ | `EnableAddOn` |
| LoadOnDemand-Addon jetzt laden | ✓ | ✓ | ✓ | ✓ | `LoadAddOn` |
| **Laufendes Addon entladen** | ✕ | ✕ | ✕ | ✕ | kein API-Pfad |
| Laufendes Addon „beenden"/killen | ✕ | ✕ | ✕ | ✕ | keine Preemption in Lua |
| Fremden Lua-Code inspizieren | ◐ | ◐ | ◐ | ◐ | nur was global exponiert ist |
| SavedVariables-Größe eines Addons | ◐ | ◐ | ◐ | ◐ | nur schätzbar via Global-Table-Walk, opt-in |
| **`ReloadUI()`** | ✓ | ✓ | ✓ | ✓ | ungeschützt |
| Zone / Instanz / Difficulty | ✓ | ✓ | ✓ | ✓ | `GetInstanceInfo` |
| Boss-Encounter-Marker | ✓ | ✓ | ✕ | ✕ | `ENCOUNTER_START` |
| Mythic+/Challenge-Marker | ✓ | ◐ | ✕ | ✕ | `CHALLENGE_MODE_START` |
| Ladebildschirm-Marker | ✓ | ✓ | ◐ | ◐ | `LOADING_SCREEN_*`, geprobt |
| Combat-Marker | ✓ | ✓ | ✓ | ✓ | `PLAYER_REGEN_*` |
| Gruppengröße | ✓ | ✓ | ✓ | ✓ | `GetNumGroupMembers` |
| **Auflösung (physisch)** | ✓ | ✓ | ◐ | ◐ | `GetPhysicalScreenSize`, sonst Fallback |
| Render Scale | ✓ | ✕ | ✕ | ✕ | CVar `renderScale` |
| Target FPS | ✓ | ✕ | ✕ | ✕ | CVar `targetFPS` |
| maxFPS / maxFPSBk | ✓ | ✓ | ✓ | ✓ | CVar |
| VSync | ✓ | ✓ | ✓ | ✓ | CVar `vsync` bzw. `gxVSync` |
| Graphics API / GPU-Name | ✕ | ✕ | ✕ | ✕ | keine API |
| **OS-CPU-/GPU-Auslastung** | ✕ | ✕ | ✕ | ✕ | Sandbox |
| Prozess-RAM (nicht-Lua) | ✕ | ✕ | ✕ | ✕ | Sandbox |
| Netzwerk-Paketinspektion | ✕ | ✕ | ✕ | ✕ | keine API |
| Festplatten-/Datei-Zugriff | ✕ | ✕ | ✕ | ✕ | Sandbox |
| Protected Functions aufrufen | ✕ | ✕ | ✕ | ✕ | bewusst nicht umgangen |

## Was daraus für die UI folgt

Jede Zelle mit `⚙`, `◐` oder `✕` hat in der UI eine feste Entsprechung:

* `⚙` → Karte mit `CPU profiling is disabled` + Button *Enable & Reload*.
* `◐` → Wert wird angezeigt, aber mit `~` bzw. Badge `heuristic` und Tooltip, der
  erklärt wie er zustande kommt.
* `✕` → Zeile/Spalte ist sichtbar, aber grau und beschriftet
  `Unavailable on this client`. Sie verschwindet **nicht**, damit klar ist, dass die
  Grenze bekannt ist und nicht vergessen wurde.
