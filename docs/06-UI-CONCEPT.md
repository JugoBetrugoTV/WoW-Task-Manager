# UI-Konzept

## Haltung

Kein WoW-Addon-Look von 2012. Kein Blizzard-Backdrop mit Goldrahmen, keine
`UIPanelButtonTemplate`-Reihen, keine Neonfarben. Ziel ist die Anmutung eines
**modernen Desktop-Diagnosewerkzeugs**: ruhiges Dunkelgrau, viel Weißraum, eine einzige
Akzentfarbe, Typografie als Struktur statt Rahmen als Struktur.

## Farbsystem

Alles kommt aus `UI/Theme.lua`, nichts wird lokal hartkodiert.

| Token | Hex | Verwendung |
|---|---|---|
| `bg.window` | `#0F1115` | Fensterhintergrund |
| `bg.sidebar` | `#0B0D11` | Navigationsspalte |
| `bg.panel` | `#161A21` | Karten, Tabellen |
| `bg.panelAlt` | `#1B2029` | Zebrastreifen, Hover |
| `bg.elevated` | `#212733` | Tooltip, Popover |
| `border.subtle` | `#252B36` | 1-px-Trennlinien |
| `text.primary` | `#E6E9EF` | Werte, Überschriften |
| `text.secondary`| `#9AA4B5` | Labels |
| `text.muted` | `#5D6675` | Einheiten, deaktiviert |
| `accent` | `#4C8DFF` | Auswahl, Primärlinie |
| `ok` | `#3FB950` | GOOD |
| `warn` | `#D29922` | WARNING |
| `crit` | `#F0533F` | CRITICAL |
| `series[1..8]` | dezente Blau/Teal/Violett/Bernstein-Reihe | Graph-Serien |

Die Serienfarben sind bewusst entsättigt und in der Helligkeit gestaffelt, damit sie
auch nebeneinander unterscheidbar bleiben und nicht nach RGB-Gaming aussehen.

## Layout

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ●  WoW Task Manager        FPS 118 │ 8.4 ms │ 31 ms │ 621 MB │ 1,240 ev/s  ─ ×│  56 px Topbar
├────────────────┬─────────────────────────────────────────────────────────────┤
│                │                                                             │
│  Dashboard     │                                                             │
│  Processes     │                     Main Area                               │
│  Performance   │                                                             │
│  Timeline      │                                                             │
│  Events        │                                                             │
│  Memory        │                                                             │
│  Diagnostics   │                                                             │
│  Sessions      │                                                             │
│  System        │                                                             │
│  ──────────    │                                                             │
│  Settings      │                                                             │
│                │                                                             │
│  ● Recording   │                                                             │
│  overhead 0.4% │                                                             │
└────────────────┴─────────────────────────────────────────────────────────────┘
   200 px Sidebar
```

* **Topbar** ist immer live — sie ist zugleich der „Live Resource Monitor" (Hauptbereich 7).
  Jede Zahl hat eine 40 px breite Mini-Sparkline darunter.
* **Sidebar** mit 4-px-Akzentbalken links am aktiven Eintrag, kein Rahmen, kein Highlight-Kasten.
* **Kein Blizzard-Backdrop.** Panels sind schlichte `Texture`-Flächen; die „runden Ecken"
  entstehen über vier kleine Eck-Texturen (`UI/Widgets/Base.lua`), die aus einer
  prozedural gefärbten `Texture` mit `SetTexCoord` gebaut werden — kein externes Artwork nötig.

## Die Seiten

| Seite | Kern |
|---|---|
| **Dashboard** | 6 Metric-Cards (FPS, Frametime, Latenz, Lua-Speicher, Addon-CPU, Events/s), Health-Badge GOOD/WARNING/CRITICAL, Top-3-CPU- und Top-3-Memory-Liste, letzte 3 Incidents, eigener Overhead |
| **Processes** | Sortierbare, durchsuchbare Tabelle aller Addons. Spalten: Addon, CPU, CPU %, Memory, Δ Memory, Events/s, Spikes, Status. Klick öffnet Detail-Overlay mit Tabs Overview / Performance / Memory / Events / Dependencies / History / Diagnostics |
| **Performance** | Große Live-Graphen mit Zeitbereichswahl 60 s / 5 m / 15 m / 30 m / 1 h / Session. Frametime-Analyzer mit Stutter-Klassifikation und Perzentilen (avg, 1 % low, 0.1 % low, max) |
| **Timeline** | Profiler-artige Spuren (FPS, Frametime, Latenz, CPU, Events, Memory) auf gemeinsamer Zeitachse + Marker-Leiste. Klick auf Marker öffnet den Incident |
| **Events** | Tabelle Event / Calls per s / Total / Peak per s / Last / CPU-Anteil. Storm-Detektor-Banner. Optionale heuristische Addon-Zuordnung |
| **Memory** | Lua-Heap-Kurve mit erkannten GC-Abfällen, Tabelle Start / Current / Growth / Growth per min, Badge `Potential sustained memory growth` |
| **Diagnostics** | Automatischer Session-Report: Health, Findings mit Korrelationsgrad, Empfehlungen |
| **Sessions** | Liste vergangener Sessions mit Kennzahlen, Öffnen zeigt deren Graphen und Spikes |
| **System** | Client, Build, Interface, Locale, Auflösung, CVars (nur die real existierenden), Addon-Anzahl, Capability-Matrix |
| **Settings** | Schwellwerte, Sampling-Raten, Flight-Recorder-Fenster, Datenhaltung, Capability-Übersicht |

## Graph-Engine (`UI/Widgets/Graph.lua`)

* Linien aus gepoolten `Texture`-Segmenten; die Anzahl ist an die **Pixelbreite**
  gebunden, nicht an die Datenmenge (Downsampling per Min/Max je Spalte, damit Spitzen
  nicht wegfallen).
* Adaptive Y-Skalierung mit Hysterese, damit die Achse nicht bei jedem Sample springt.
* Grid mit „schönen" Schrittweiten (1/2/5·10ⁿ), Zeitachse mit relativen Labels.
* Hover: Fadenkreuz + Tooltip mit exakten Werten aller Serien zum Zeitpunkt.
* Klick: Zeitpunkt auswählen → andere Seiten (Timeline/Diagnostics) springen dorthin.
* Peaks werden als kleine Punkte markiert, Min/Max/Avg als Fußzeile.
* Alle Texturen kommen aus `Utils/Pool.lua` und werden beim Neuzeichnen recycelt.

## Combat-Verhalten

Das Fenster selbst ist nicht geschützt und funktioniert im Kampf normal. Aktionen, die
im Kampf unangenehm oder riskant wären (`SetCVar`, `ReloadUI`, Enable/Disable), werden
in eine Queue gelegt; der Button zeigt dann `Unavailable during combat — queued` und
löst nach `PLAYER_REGEN_ENABLED` aus.
