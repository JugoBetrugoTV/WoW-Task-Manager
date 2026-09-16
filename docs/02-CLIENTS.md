# Die vier Ziel-Clients als getrennte Plattformen

## Identifikation

Die Erkennung erfolgt **primär über die TOC-/Interface-Nummer**
(`select(4, GetBuildInfo())`), weil sie in jedem Client existiert und eindeutig ist.
`WOW_PROJECT_ID` wird nur als Kreuzcheck genutzt, weil die Projekt-Konstanten je nach
Client teilweise gar nicht definiert sind.

| Client | Version | Interface | Flavor-Key | TOC-Suffix |
|---|---|---|---|---|
| Retail / Midnight | 12.1.0 | `120100` | `retail` | `_Mainline` |
| MoP Classic | 5.5.4 | `50504` | `mop` | `_Mists` |
| TBC Anniversary | 2.5.6 | `20506` | `tbc` | `_TBC` |
| Classic Era | 1.15.9 | `11509` | `classic` | `_Vanilla` |

Interface-Nummer = `major * 10000 + minor * 100 + patch`.

Die Erkennung ist bewusst **bereichsbasiert** (`>= 110000` → retail,
`50000..59999` → mop, …), damit ein Patch auf 12.1.1 oder 5.5.5 das Addon nicht bricht.

## Lua-Sprachstand

Alle vier Clients laufen auf **Lua 5.1** mit Blizzard-Erweiterungen. Es gibt keinen
Unterschied im Sprachkern. Konsequenzen für den Code:

* Kein `goto`, kein `::label::` (Lua 5.2).
* Kein Integer-Divisionsoperator `//`, kein Bitoperator-Syntax `&`/`|` — stattdessen
  die `bit`-Library (`bit.band`, `bit.bor`, …), die in allen vier Clients existiert.
* `#` auf Tabellen mit Löchern ist undefiniert → wir halten Arrays immer dicht.
* `table.getn`/`setn` sind entfernt.
* `string.gmatch` statt `string.gfind`.
* Kein `os.*`, kein `io.*`, kein `require`, kein `loadstring` (in WoW entfernt bzw.
  gesperrt). `date()` und `time()` sind als WoW-Globals verfügbar.
* Coroutinen sind überall verfügbar.
* **`securecall`, `issecurevariable`, `hooksecurefunc`** existieren in allen vier
  Clients (Classic Era 1.15 läuft auf der modernen Engine).

## API-Namespaces

Der wichtigste Bruch: mit Retail 11.0 sind die Addon-Funktionen nach `C_AddOns.*`
gewandert; die alten Globals wurden dort entfernt. In den Classic-Clients existieren
je nach Version **beide** oder nur die Globals.

| Funktion | Modern (`C_AddOns`) | Legacy Global |
|---|---|---|
| `GetNumAddOns` | ✓ | ✓ |
| `GetAddOnInfo` | ✓ | ✓ |
| `GetAddOnMetadata` | ✓ | ✓ |
| `IsAddOnLoaded` | ✓ | ✓ |
| `LoadAddOn` | ✓ | ✓ |
| `EnableAddOn` / `DisableAddOn` | ✓ | ✓ |
| `IsAddOnLoadOnDemand` | ✓ | ✓ |
| `GetAddOnDependencies` | ✓ | ✓ |
| `GetAddOnOptionalDependencies` | ✓ | ✓ |
| `GetAddOnEnableState` | ✓ **(Argumentreihenfolge geändert!)** | ✓ |

**Falle `GetAddOnEnableState`:** Legacy ist `GetAddOnEnableState(character, index)`,
modern ist `C_AddOns.GetAddOnEnableState(addonNameOrIndex, character)`. Die Compat-Layer
probiert beide Reihenfolgen und akzeptiert nur ein Ergebnis in `{0,1,2}`.

Die CPU-/Memory-Messfunktionen (`UpdateAddOnCPUUsage`, `GetAddOnCPUUsage`,
`UpdateAddOnMemoryUsage`, `GetAddOnMemoryUsage`, `ResetCPUUsage`, `GetScriptCPUUsage`,
`GetEventCPUUsage`, `GetFrameCPUUsage`, `GetFunctionCPUUsage`) sind **Globals** und
wurden nicht in `C_AddOns` verschoben. Trotzdem prüft die Compat-Layer **beide** Orte,
weil ein künftiger Patch das ändern kann — das kostet einmalig beim Laden nichts.

Analog: `GetCVar`/`SetCVar` vs. `C_CVar.GetCVar`/`C_CVar.SetCVar`.

## Events

Events sind der zweite große Unterschied. Ein `RegisterEvent` auf ein Event, das der
Client nicht kennt, wirft in modernen Clients einen **Lua-Fehler**. Deshalb registriert
das Addon jedes optionale Event ausschließlich über
`Compat.SafeRegisterEvent(frame, event)` (pcall-gekapselt, Ergebnis wird gecacht).

| Event | Retail | MoP | TBC | Classic Era |
|---|---|---|---|---|
| `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD` | ✓ | ✓ | ✓ | ✓ |
| `PLAYER_REGEN_DISABLED` / `_ENABLED` | ✓ | ✓ | ✓ | ✓ |
| `ADDON_LOADED`, `PLAYER_LOGOUT` | ✓ | ✓ | ✓ | ✓ |
| `ZONE_CHANGED_NEW_AREA` | ✓ | ✓ | ✓ | ✓ |
| `ENCOUNTER_START` / `ENCOUNTER_END` | ✓ | ✓ | ✕ | ✕ |
| `CHALLENGE_MODE_START` | ✓ | ✓ | ✕ | ✕ |
| `COMBAT_LOG_EVENT_UNFILTERED` | ✓ | ✓ | ✓ | ✓ |
| `LOADING_SCREEN_ENABLED` / `_DISABLED` | ✓ | ✓ | ? | ? |
| `ADDONS_UNLOADING` | ✓ | ? | ? | ? |

Alles mit `?` wird nicht angenommen, sondern zur Laufzeit geprobt.

## Sonstige Client-Unterschiede, die das Addon betreffen

* **`GetInstanceInfo()`** existiert überall, liefert aber in Classic Era für die offene
  Welt andere `instanceType`-Werte. Wir werten nur `"none"` vs. Rest aus.
* **`IsEncounterInProgress()`** ist in Classic Era nicht verlässlich → Feature-Detection.
* **`GetPhysicalScreenSize()`** existiert in Retail und den modernen Classic-Builds,
  aber nicht garantiert in Classic Era → Fallback auf `GetScreenWidth/Height` * UIScale.
* **CVars:** `renderScale`, `targetFPS`, `graphicsQuality` existieren nur in Retail.
  `maxFPS`, `maxFPSBk` existieren überall. Das Addon listet **nur CVars, die tatsächlich
  einen Wert zurückgeben**, und schreibt nur, wenn `GetCVarInfo` (falls vorhanden)
  weder `isLockedFromUser` noch `isReadonly` meldet.
* **VSync:** heißt in modernen Clients `vsync`, in alten `gxVSync`. Beide werden geprobt.
* **Combat Lockdown / Taint:** identisch in allen vier Clients. Das Addon berührt keine
  geschützten Frames, erbt keine Secure-Templates und ruft keine geschützte Funktion
  auf, also gibt es keinen Taint-Pfad. Trotzdem werden `SetCVar` und `ReloadUI` im
  Kampf in eine Queue gelegt (`PLAYER_REGEN_ENABLED`), weil das für den Nutzer das
  erwartbare Verhalten ist.
