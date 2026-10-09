# UI-Konzept

## Haltung

Kein WoW-Addon-Look von 2012. Kein Blizzard-Backdrop mit Goldrahmen, keine
`UIPanelButtonTemplate`-Reihen, keine Neonfarben. Ziel ist die Anmutung eines
**modernen Desktop-Diagnosewerkzeugs**: ruhiges Dunkelgrau, viel Weißraum, eine einzige
Akzentfarbe, Typografie als Struktur statt Rahmen als Struktur.

## Farbsystem

Alles kommt aus `UI/Theme.lua`, nichts wird lokal hartkodiert.

| Token | WTM Dark (Standard) | Verwendung |
|---|---|---|
| `windowBg` | `#0F1115` | Fensterhintergrund |
| `sidebarBg` | `#0B0D11` | Navigationsspalte |
| `panelBg` | `#161A21` | Karten, Tabellen |
| `panelAlt` | `#1B2029` | Zebrastreifen, Hover |
| `elevated` | `#212733` | Tooltip, Popover |
| `hover` / `selected` | `#222834` / `#1D2634` | Hover- und Auswahlzustand |
| `borderSubtle` / `borderStrong` | `#252B36` / `#323A48` | Trennlinien |
| `textPrimary` / `textSecondary` / `textMuted` | `#E6E9EF` / `#9AA4B5` / `#5D6675` | Werte / Labels / Einheiten |
| `accent` / `accentDim` / `accentSoft` | `#4C8DFF` / `#2E5DAA` / `#1C2B45` | Auswahl, Primärlinie (siehe Accent-Picker) |
| `accentSecondary` | `#38B2AC` | zweite Akzentfarbe, unabhängig vom Accent-Picker |
| `ok` / `warn` / `crit` / `info` | `#3FB950` / `#D29922` / `#F0533F` / `#5AB0C9` | Status |
| `gridMinor` | `#1B2029` | Nebenlinien im Graph-Grid |
| `series[1..8]` | dezente Blau/Teal/Violett/Bernstein-Reihe | Graph-Serien |

Die Serienfarben sind bewusst entsättigt und in der Helligkeit gestaffelt, damit sie
auch nebeneinander unterscheidbar bleiben und nicht nach RGB-Gaming aussehen.

### Theme-Presets, Accent, Density (seit 0.8.0)

Die Werte oben sind nur das Standard-Preset. `Theme.PALETTES` definiert vier
vollständige Paletten (**WTM Dark**, **Graphite**, **Midnight**, **High
Contrast**) — jede legt **alle** Oberflächen-/Text-/Status-Token neu fest, kein
Preset ändert Layout oder Abstände. `Theme.ACCENTS` ist eine zweite,
unabhängige Achse (**Blue**, **Cyan**, **Green**, **Orange**, **Purple**), die
ausschliesslich `accent`/`accentDim`/`accentSoft` ersetzt — jede Palette lässt
sich mit jedem Accent kombinieren.

`Theme:ApplyPreset(palette, accent)` schreibt die Werte in die lebende
`HEX`-Tabelle und leert den Farb-Cache. Das färbt **nichts live um** — die
meisten Widgets backen ihre Farbe bei `Build()` in eine Textur, nicht bei
jedem Frame neu. Genau wie beim scriptProfile-CVar-Umschalter gilt: **Änderung
wirkt nach `/reload`.**

`Theme:ApplyDensity("comfortable"|"compact")` setzt `rowHeight`, `padding`,
`cardHeight`, `cardGap` und `navItemHeight` auf einen zweiten, engeren Satz
zurück — spürbar vor allem auf Listenseiten (Processes, Events, Errors,
Sessions). Auch das wirkt erst nach `/reload`.

Einstellbar unter **Settings → APPEARANCE**: Theme, Accent, Density, Graph
Style, Threshold-Zonen, Graph Quality, Reduce Motion.

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
  Jede Zahl hat eine Mini-Sparkline darunter, seit 0.8.0 inklusive einer `ERRORS`-Zelle
  (Zahl, farbig nach Schweregrad, bewusst ohne eigene Sparkline — dafür gibt es keinen
  Ring-Buffer, und einen nur für eine Topbar-Zelle neu einzuführen wäre ein permanenter
  Zähler für eine Zahl, die meistens null ist).
* **Sidebar** mit 3-px-Akzentbalken links am aktiven Eintrag, kein Rahmen, kein
  Highlight-Kasten, seit 0.8.0 zusätzlich mit einem kleinen geometrischen Icon pro
  Eintrag (`UI/Widgets/Icons.lua`) — verwandte Seiten teilen sich bewusst eine Silhouette
  (z. B. zeigen Processes, Live-Resources, Performance und Frame-Analysis alle das
  gleiche „aufsteigende Balken"-Icon), weil bei 12 px Kantenlänge aus reinen Rechtecken
  keine 20 wirklich unterscheidbaren Piktogramme herauskommen — ein erfundenes
  Alleinstellungsmerkmal pro Icon wäre bei dieser Grösse nicht lesbar, sondern geraten.
* **Kein Blizzard-Backdrop, und keine runden Ecken.** Panels sind schlichte
  `Texture`-Flächen mit Haarlinien-Rahmen (`UI.Border`, 1 px) statt Eck-Texturen — WoW
  kann einen echten Corner-Radius ohne mitgeliefertes Artwork nicht zeichnen, und eine
  imitierte Rundung sieht schlechter aus als ein sauberer rechter Winkel. Tiefe entsteht
  über Abstufungen in der Flächenhelligkeit, einen 1 px „von oben beleuchteten" Highlight
  am oberen Rand jedes Panels, und seit 0.8.0 optional über einen 2 px breiten
  Akzentbalken am linken Rand (`Panel:SetAccent(tone)`), der eine Karte nach Schweregrad
  einfärbt, ohne Hintergrund oder Rahmen zu verändern.

## Die Seiten

| Seite | Kern |
|---|---|
| **Dashboard** | 6 Metric-Cards (FPS, Frametime, Latenz, Lua-Speicher, Addon-CPU, Events/s), Health-Badge GOOD/WARNING/CRITICAL, Top-3-CPU- und Top-3-Memory-Liste, letzte 3 Incidents, eigener Overhead |
| **Processes** | Sortierbare, durchsuchbare Tabelle aller Addons. Spalten: Addon, CPU, CPU %, Memory, Δ Memory, Events/s, Spikes, Status. Status, Errors und Spikes sind seit 0.8.1 Pills (`UI.Badge`) statt reiner Farbtext, mit eingebetteten CPU/Memory-Balken (`UI.MiniBar`) hinter den Zahlen. Klick öffnet Detail-Overlay mit Tabs Overview / Performance / Memory / Events / Dependencies / History / Diagnostics |
| **Performance** | Große Live-Graphen mit Zeitbereichswahl 60 s / 5 m / 15 m / 30 m / 1 h / Session. Frametime-Analyzer mit Stutter-Klassifikation und Perzentilen (avg, 1 % low, 0.1 % low, max) |
| **Timeline** | Profiler-artige Spuren (FPS, Frametime, Latenz, CPU, Events, Memory) auf gemeinsamer Zeitachse + Marker-Leiste. Klick auf Marker öffnet den Incident |
| **Incidents** | Liste der Stutter-Cluster links, volles Diagnosebild rechts. Seit 0.8.1 mit einer visuellen Timeline-Leiste über der Liste: ein anklickbarer Tick pro Cluster, positioniert nach Zeit, Höhe und Farbe nach Schweregrad (`C.SPIKE_ORDER`) — Cluster-Häufungen sind damit vor dem Scrollen sichtbar |
| **Events** | Tabelle Event / Calls per s / Total / Peak per s / Last / CPU-Anteil. Storm-Detektor-Banner. Optionale heuristische Addon-Zuordnung |
| **Memory** | Lua-Heap-Kurve mit erkannten GC-Abfällen, Tabelle Start / Current / Growth / Growth per min, Badge `Potential sustained memory growth` |
| **Diagnostics** | Automatischer Session-Report: Health, Findings mit Korrelationsgrad, Empfehlungen |
| **Sessions** | Liste vergangener Sessions mit Kennzahlen, Öffnen zeigt deren Graphen und Spikes |
| **System** | Client, Build, Interface, Locale, Auflösung, CVars (nur die real existierenden), Addon-Anzahl, Capability-Matrix |
| **Settings** | Schwellwerte, Sampling-Raten, Flight-Recorder-Fenster, Datenhaltung, Capability-Übersicht |

## Graph-Engine (`UI/Widgets/Graph.lua`)

* Linien aus gepoolten `Texture`-Segmenten (oder `frame:CreateLine`, wo verfügbar); die
  Anzahl ist an die **Pixelbreite** gebunden, nicht an die Datenmenge (Downsampling per
  Min/Max je Spalte, damit Spitzen nicht wegfallen).
* Adaptive Y-Skalierung mit Hysterese, damit die Achse nicht bei jedem Sample springt.
* Grid mit Haupt- **und seit 0.8.0 Nebenlinien** (je eine pro Intervallmitte, `gridMinor`,
  abschaltbar über Graph Quality), Zeitachse mit relativen Labels.
* **Threshold-Zonen (0.8.0):** dezente Hintergrundbänder für ELEVATED/POOR/STUTTER auf
  Frame-Time-Graphen, an denselben realen Schwellen, gegen die der Spike-Detector selbst
  klassifiziert (33/50/100 ms aus `C.SPIKE_DEFAULTS`) — keine zweite, erfundene
  Zahlenreihe. Standardmässig aus (Settings → Appearance → „Threshold zones").
* **Schweregestufte Incident-Marker (0.8.0):** ein Marker trägt jetzt seine
  Spike-Klasse (minor/stutter/heavy/freeze) als `ref`; ein Freeze-Marker ist sichtbar
  breiter, höher und deckender als ein Minor-Marker, ohne dass dafür ein zweites
  Glyphen-System nötig wäre.
* Hover: Fadenkreuz + Tooltip mit exakten Werten aller Serien zum Zeitpunkt.
* Klick: Zeitpunkt auswählen → andere Seiten (Timeline/Diagnostics) springen dorthin.
* Peaks werden als kleine Punkte markiert, Min/Max/Avg **und jetzt „now" (0.8.0)** als
  Fußzeile — der letzte Sample-Wert ist ohnehin schon geladen, kostet also nichts extra.
* **Graph Style (0.8.0):** Line / Area / Auto. Auto füllt nur, wenn genau eine Serie
  aktiv ist — zwei überlappende Flächenfüllungen (z. B. Home- + World-Latenz) lesen sich
  als Matsch, nicht als zwei Kurven, daher bleibt ein Mehrserien-Graph bei Auto immer
  linienbasiert.
* **Graph Quality (0.8.0):** Performance / Balanced / High steuert die Spaltenbreite
  (9 / 5 / 3 px) und damit direkt, wie viele Texturen ein Redraw anfasst; Performance
  schaltet zusätzlich die Nebenlinien und jede Flächenfüllung ab.
* Alle Texturen kommen aus `Utils/Pool.lua` und werden beim Neuzeichnen recycelt.
  `UI.GetGraphPoolStats()` (0.8.0) summiert das über jeden je gebauten Graphen und ist
  über `/wtm benchmark` sichtbar.

## Icon-System (`UI/Widgets/Icons.lua`, seit 0.8.0)

Kein Unicode, keine Icon-Fonts, kein Blizzard-Atlas — nur `Interface\Buttons\WHITE8X8`,
dieselbe Textur, aus der jede Fläche in diesem Addon schon besteht. Ein Icon ist 2–4
gefärbte Rechtecke in einer festen Box; elf Formen (`grid`, `bars`, `network`, `pulse`,
`stack`, `diamond`, `timeline`, `target`, `document`, `history`, `cog`) decken die 20
Sidebar-Einträge ab, mit bewusster Wiederverwendung zwischen inhaltlich verwandten
Seiten. `icon:SetColor(key)` färbt alle Teile eines Icons auf einmal um, z. B. beim
Seitenwechsel in der Sidebar.

## Animations-System (`UI.Animate`, `UI.PulseOnce` in `UI/Widgets/Base.lua`, seit 0.8.0)

Ein einziger Treiber-Frame mit **einem** `OnUpdate`-Handler für die gesamte Adresse,
nicht einer pro animiertem Widget — dieselbe Regel wie beim Redraw-Budget der Graphen.
`UI.Animate(duration, onUpdate, onComplete)` ist die einzige Primitve; erlaubt sind laut
Vorgabe nur kurze, nicht wiederholende Effekte. Umgesetzt ist aktuell **ein** konkreter
Fall: `UI.PulseOnce`, der einmalige Alert-Puls auf einem Sidebar-Badge, wenn dessen
Zähler seit dem letzten Refresh gestiegen ist (nicht bei jedem Refresh, nicht beim
ersten Login). Die Animation läuft **synchron sofort ab** (Fraction 1, kein Tick
Verzögerung), sobald „Reduce motion" aktiv ist oder die gemessene Eigenlast über dem
Overhead-Budget liegt (`WTM.Overhead.current.totalMsPerSec >= profile.sampling.overheadBudgetMs`)
— automatische Reduktion unter Last, wie in Punkt 32/33 des Briefings gefordert, ohne
dass dafür eine eigene Einstellung nötig wäre.

Bewusst **nicht** umgesetzt in dieser Runde: Page-Transitions, Number-Transitions,
Card-Highlight-Fades. Die Infrastruktur (`UI.Animate`) trägt sie, aber ein Rollout über
17 Seiten hinweg ist eine eigene Aufgabe mit eigenem Visual-Audit, nicht ein Nebenprodukt
dieser Änderung.

## Addon-Detail-Header (seit 0.8.1)

Der Header des Addon-Detail-Overlays (`UI/AddonDetail.lua`) ist jetzt ein "Hero": Name, Status-Pill
und Akzentbalken oben, darunter vier kompakte Kacheln — CPU, Memory (je mit einer Trend-Sparkline
aus demselben Ringpuffer, aus dem der CPU-/Memory-Tab seinen vollen Graphen zeichnet), Errors und
Spikes — bevor überhaupt ein Tab gewählt ist. Die zusammengefasste Score-Zahl bleibt daneben stehen,
jetzt als zweite, nicht als einzige Kennzahl. Der Header wuchs dafür von 64 auf 100 px; alles darunter
(Tab-Leiste, Inhalt) folgt automatisch, weil es relativ zum Header verankert ist.

## Table-Pills (seit 0.8.1)

`UI/Widgets/Table.lua` unterstützt jetzt `column.pill = true`: die Zelle rendert einen `UI.Badge`
statt einfachen Farbtext, versteckt sich selbst, wenn der Wert leer ist (kein leerer Pill für
"0 Fehler"), und lässt Balken-Spalten (`column.bar`) unverändert daneben bestehen. Auf der
Processes-Seite tragen Status, Errors und Spikes diese Pills; jede andere Tabelle (Events, Memory,
Errors, Impact) verhält sich unverändert, weil das Flag rein additiv ist.

## Combat-Verhalten

Das Fenster selbst ist nicht geschützt und funktioniert im Kampf normal. Aktionen, die
im Kampf unangenehm oder riskant wären (`SetCVar`, `ReloadUI`, Enable/Disable), werden
in eine Queue gelegt; der Button zeigt dann `Unavailable during combat — queued` und
löst nach `PLAYER_REGEN_ENABLED` aus.
