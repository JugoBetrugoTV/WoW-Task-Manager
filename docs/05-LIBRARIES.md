# Libraries

## Hinweis zum Repository-Zustand

Das Repository war beim Start dieser Arbeit **leer** — es waren keine Libraries
eingebunden. Das Addon ist deshalb so gebaut, dass es **mit und ohne Ace3 lauffähig**
ist:

`Core/Ace.lua` sucht über `LibStub` nach den Ace3-Modulen. Findet es sie, werden sie
benutzt. Findet es sie nicht, aktiviert es eine **interne, API-kompatible
Minimal-Implementierung** derselben Konzepte. Kein Modul im Addon muss wissen, welcher
Fall vorliegt.

Um Ace3 zu benutzen, genügt es, die Ordner nach `WoWTaskManager/Libs/` zu legen und
`Libs/embeds.xml` (liegt bereits bei) zu aktivieren — `Includes.xml` lädt sie
automatisch, wenn vorhanden.

## Genutzte Ace3-Module

| Library | Version | Lizenz | Wofür | Fallback vorhanden |
|---|---|---|---|---|
| `LibStub` | 1.0.2-ish | Public Domain | Library-Registry | ja |
| `CallbackHandler-1.0` | r7+ | BSD-artig (Ace3) | Basis für AceEvent | ja |
| `AceAddon-3.0` | r13+ | BSD-artig (Ace3) | Addon-/Modul-Lebenszyklus (`OnInitialize`, `OnEnable`) | ja |
| `AceEvent-3.0` | r4+ | BSD-artig (Ace3) | Event-Registrierung + interne Messages | ja |
| `AceConsole-3.0` | r7+ | BSD-artig (Ace3) | Slash-Commands, `Print` | ja |
| `AceDB-3.0` | r28+ | BSD-artig (Ace3) | SavedVariables, Profile, Defaults, Migration | ja |
| `AceTimer-3.0` | r17+ | BSD-artig (Ace3) | Timer für seltene Tasks | ja (`C_Timer` bzw. eigener Scheduler) |

**AceGUI-3.0 wird bewusst nicht verwendet.** Das geforderte Design (Sidebar-Navigation,
Dashboard-Kacheln, eigene Graphen) lässt sich mit AceGUI nicht ohne Kämpfe umsetzen und
würde nach „Ace3-Konfigurationsfenster" aussehen. Das Hauptfenster ist ein eigenes,
schlankes Widget-Framework direkt auf WoW-Frames (`UI/Widgets/`).

**AceConfig / AceConfigDialog wird ebenfalls nicht verwendet** — die Settings-Seite ist
Teil des eigenen UI, damit sie sich nicht vom Rest abhebt.

## Zusätzlich vorgeschlagene, aber NICHT eingebundene Libraries

Der Auftrag war, sinnvolle Kandidaten zu nennen und trotzdem intern zu lösen. Das ist
geschehen — folgende hätte man nehmen können, wurden aber durch eigene, kleinere
Implementierungen ersetzt:

| Kandidat | Lizenz | Wofür man sie nähme | Warum stattdessen intern |
|---|---|---|---|
| `LibSharedMedia-3.0` | LGPL-2.1 | Fonts/Texturen austauschbar machen | Das Design ist bewusst festgelegt; eine Media-Registry würde die visuelle Konsistenz aufweichen. Fonts kommen direkt aus den Blizzard-Fontobjekten. |
| `LibDataBroker-1.1` | Public Domain | Minimap-/Broker-Anzeige | `UI/Widgets/` hat einen eigenen kompakten Live-Monitor; ein Broker-Plugin wäre ein späteres Add-on-Feature, keine Abhängigkeit. |
| `LibDBIcon-1.0` | Public Domain | Minimap-Button | siehe oben |
| `LibSerialize` + `LibDeflate` | LGPL / MIT | Incidents komprimiert exportieren/teilen | `Utils/Format.lua` erzeugt einen lesbaren Text-Report; Kompression wäre nur für Cross-Client-Sharing nötig und ist kein Kernziel. |
| `LibGraph-2.0` | ARR/unklar | Graphen | Lizenz unklar und die Engine ist für dieses Projekt zu unflexibel. `UI/Widgets/Graph.lua` ist eine eigene Engine mit Texture-Pooling und Downsampling. |

Sollte eine davon später doch gewünscht sein, ist der Einbau jeweils lokal: Graph-Engine,
Report-Export und Broker-Anzeige sind hinter je einer Datei gekapselt.
