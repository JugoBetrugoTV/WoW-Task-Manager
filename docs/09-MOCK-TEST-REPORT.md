# Mock-Testbericht

Erzeugt am 2026-09-12 gegen Addon-Version 0.7.4, aktualisiert am 2026-09-16 gegen 0.8.0.

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
| `tools/test-errors.lua` | Der Error-Handler-Vertrag und die Duplikat-Fast-Path |
| `tools/test-scale.lua` | 220 Addons, 140 Incidents, 300 Errors, leere Session |
| `tools/test-ui.lua` | Jede Seite bei drei Fenstergrössen, Maus, Scroll, Tooltips |
| `tools/test-longrun.lua` | Sechs simulierte Stunden durch den echten Scheduler |
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
  PASS  Retail-12.1.0      profiling=on  api=normal   no-ace3    453 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=normal   ace3       453 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=degraded no-ace3    463 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=degraded ace3       463 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=normal   no-ace3    454 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=normal   ace3       454 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=degraded no-ace3    464 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=degraded ace3       464 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=normal   no-ace3    453 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=normal   ace3       453 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=degraded no-ace3    463 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=degraded ace3       463 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=normal   no-ace3    454 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=normal   ace3       454 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=degraded no-ace3    464 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=degraded ace3       464 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=normal   no-ace3    453 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=normal   ace3       453 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=degraded no-ace3    463 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=degraded ace3       463 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=normal   no-ace3    454 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=normal   ace3       454 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=degraded no-ace3    464 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=degraded ace3       464 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=normal   no-ace3    453 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=normal   ace3       453 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=degraded no-ace3    463 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=degraded ace3       463 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=normal   no-ace3    454 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=normal   ace3       454 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=degraded no-ace3    464 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=degraded ace3       464 passed, 0 failed, 0 lua errors
syntax check:
  all 75 files parse
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

## Error-Monitor: der Handler-Vertrag (neu in 0.7.0)

```
== handler chaining ==
== fingerprinting ==
== this addon's own errors ==
== ignoring counts, it just does not shout ==
== scale: a storm of one bug ==
== caps ==
== storms and repeats ==
== safe mode ==
== correlation is never causation ==
== a client that cannot do this at all ==

   132 passed, 0 failed, 0 lua errors
```

Der Error-Handler ist die einzige Stelle im Addon, an der ein Bug **ein anderes
Addon** kaputtmachen kann. Deshalb hat er eine eigene Suite, und deshalb testet
sie den Vertrag statt der Oberfläche.

`tools/wowmock.lua` hatte bis 0.6.0 einen konstanten Error-Handler, den man
weder lesen noch ersetzen konnte — Verkettung war schlicht nicht testbar.
Jetzt sind `seterrorhandler` und `geterrorhandler` echt: der Mock hält einen
aktuellen Handler, gibt ihn heraus, nimmt einen neuen an, und
`mock.RaiseError(msg)` schickt eine Nachricht durch genau den Weg, den der
Client benutzt.

Fünf Anordnungen werden aufgebaut und einzeln geprüft:

| Anordnung | Was gelten muss |
|---|---|
| Nichts war vorher installiert | Handler ist drin, `hadPrevious` sagt die Wahrheit |
| Ein Handler war vorher da (der BugGrabber-Fall) | Er bekommt jeden Fehler, **genau einmal**, mit unveränderter Nachricht und unveränderten Zusatzargumenten |
| Aufzeichnung ist abgeschaltet | Es wird nichts gespeichert, der vorherige Handler bekommt trotzdem alles |
| Unsere eigene Buchhaltung wirft | Der vorherige Handler bekommt den Fehler trotzdem; unser Fehler wird gemerkt, nicht verschluckt |
| Jemand installiert **nach** uns | Wird erkannt, gemeldet, akzeptiert — wir erobern nichts zurück |

Dazu die Rekursion: der vorherige Handler wirft selbst einen Fehler, während
wir ihn gerade aufrufen. Der Test misst die Verschachtelungstiefe.

**Das hat einen echten Bug gefunden.** Die Wiedereintritts-Sperre wurde
freigegeben, *bevor* der vorherige Handler aufgerufen wurde. Ein Error-Addon,
das beim Behandeln selbst wirft, wäre damit in eine gegenseitige Rekursion
gelaufen. Die Sperre umschliesst jetzt auch die Weitergabe.

### Zehntausend Duplikate

Der Auftrag verlangte, dass 10 000 identische Callbacks nicht 10 000
SavedVariable-Einträge erzeugen. Sie erzeugen einen — und die Suite prüft
ausserdem, dass sie fast nichts kosten:

| Gemessen | Ergebnis |
|---|---|
| Gespeicherte Gruppen nach 10 000 Duplikaten | 1 |
| Gezählte Vorkommen | 10 000 |
| Zeilen in der Datenbank nach `Persist()` | 1 |
| Heap-Wachstum über 40 000 Duplikate (`tools/run.lua`) | **0 KB** |
| Kosten eines Duplikats gegen einen neuen Fehler | **7x billiger** |

**Zwei echte Bugs, beide von dieser Messung gefunden.**

Der erste: der Fingerabdruck wurde *vor* der Duplikat-Prüfung berechnet, und
Fingerprinting heisst `gsub`, und `gsub` heisst ein neuer String — pro Fehler,
auch beim zehntausendsten identischen. Jetzt wird zuerst der exakte
Nachrichtentext in einer Memo-Tabelle nachgeschlagen; ein Bug, der in
`OnUpdate` feuert, liefert jedes Mal denselben String, und das ist genau der
Fall, in dem es auf Geschwindigkeit ankommt.

Der zweite war schlimmer: das gleitende Fenster für Rate und Storm-Erkennung
war eine Liste von Zeitstempeln, getrimmt mit `table.remove(liste, 1)`. Bei
10 000 Fehlern in einer Minute ist das eine 10 000-Einträge-Liste, aus deren
Kopf 10 000-mal entfernt wird — O(n) pro Fehler, also O(n²) über den Storm.
Ausgerechnet in dem Zustand, für den das Feature existiert. Ersetzt durch 60
feste Zähler, einen pro Sekunde: O(1) pro Fehler, keine Allokation, keine
Vergrösserung.

### Was die Suite ausserdem festnagelt

* Ein ignorierter Fehler wird **weiter gezählt**. Die Suite prüft beide Seiten:
  der Zähler steigt, und nur die Anzeige schweigt.
* Eigene Fehler des Addons sind auch dann in der Liste, wenn man
  `WoWTaskManager` in die Ignorier-Liste schreibt.
* Safe Mode schaltet nach fünf internen Fehlern in zehn Sekunden **nur** die
  UI-Aufgabe ab; die Aufzeichnung läuft weiter, und der Test raised danach
  einen weiteren Fehler und prüft, dass er ankommt. Über die Zeit verteilte
  interne Fehler lösen ihn nicht aus.
* Kein erzeugter Berichtstext enthält *caused*, *because of*, *responsible
  for*, *due to* oder *led to*. Das ist eine Assertion, keine Absicht.

## Downsampling: der Fall aus dem Auftrag

```
== downsampling: spikes must survive ==
   41 passed, 0 failed, 0 lua errors
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

## Audit-Pass 0.7.1

Kein neues Feature. Ein Durchgang über den Stand, den du im Retail-Test
sauber laufen hattest, mit der Frage: *was ist hier falsch, und was kann der
Test hier gar nicht sehen?*

### Zwei echte Bugs im Code

| # | Fund | Auswirkung | Wie bewiesen |
|---|---|---|---|
| 1 | `ErrorMonitor:Record()` verliess sich darauf, dass `stack` ein String ist | Ein Aufrufer mit einer Zahl als Stack liess `TopFrames` eine Zahl indizieren — **das Aufzeichnen eines Fehlers erzeugte selbst einen Fehler**, in genau dem Pfad, der das nie tun darf | Test zuerst rot, dann Coercion an der Grenze, dann grün |
| 2 | Timeline-Marker hielten die Fehlergruppe als direkte Referenz | Nach dem Cap zeigten **399 von 400** Markern auf Gruppen, die es nicht mehr gibt: der Klick auf einen Marker führte ins Leere, ohne dass irgendwo etwas gemeldet wurde | Marker halten jetzt den Fingerabdruck und lösen über `byFingerprint` auf; baut man es zurück, meldet die Suite `(400)` |

### Zwei Bugs im Benchmark, mit einer Ursache

`/wtm benchmark 10` gab im echten Client `-- benchmark: 0.0 s, 0 frames --`
aus. Vier Symptome, eine Ursache: `Scheduler:Register(...)` nimmt die Phase
als **Bruchteil des Intervalls für den ersten Lauf**. `0` heisst damit nicht
„kein Versatz", sondern „beim nächsten Tick" — der Benchmark war fertig,
bevor er angefangen hatte.

Der zweite: die Zeile `per-frame callback: ... averaged over 0 timed frames`.
Ein Durchschnitt über null Messungen ist kein Durchschnitt. Er wurde
trotzdem gedruckt, in `Dev.lua` und in `Overhead:GetBreakdown()`, und sah
dabei aus wie eine frische Messung. Beide Stellen sagen jetzt, dass in
diesem Fenster nichts gemessen wurde.

### Die Lücke, die alle Timing-Aussagen vorher wertlos machte

`debugprofilestop()` im Mock gab `M.clock * 1000` zurück — die **simulierte**
Uhr, die sich nur bewegt, wenn der Test sie bewegt. Jede Messung der Form
„wie lange hat diese Aufgabe gebraucht" war damit im Test exakt null. Die
Suite war strukturell ausserstande, einen teuren Sampler zu finden, egal wie
teuer er ist.

Das ist wichtiger als es klingt: meine früheren Aussagen zur *Laufzeit*
einzelner Aufgaben stammen aus dieser kaputten Messung und waren wertlos.
Die Aussagen zur *Allokation* nicht — die kamen aus `collectgarbage("count")`
und waren immer echt.

Jetzt liefert `debugprofilestop()` echte Millisekunden (`os.clock`). Die
absoluten Zahlen sind die dieser Maschine, nicht die von WoW. Wofür sie
taugen: Aufgaben **gegeneinander** zu vergleichen und eine zu finden, die
unverhältnismässig teuer ist. `tools/test-scale.lua` sagt seitdem Sätze wie
„langsamste Seite unter Last: dashboard mit 20,3 ms Harness-Zeit", und das
ist eine Zahl, die vorher nicht existierte.

Drei kleinere Lücken im selben Durchgang geschlossen:

* `Show()` / `Hide()` feuerten `OnShow` / `OnHide` nicht — der halbe
  Lebenszyklus jeder Seite war ungetestet.
* `AuditText` prüfte auch unsichtbare Regionen und meldete Überlappungen für
  Dinge, die niemand sieht.
* `SetClipsChildren` wurde verworfen statt aufgezeichnet, also konnte kein
  Test prüfen, ob der Inhaltsbereich überhaupt klippt — genau der Punkt, an
  dem die Seiten im echten Client übereinander lagen.

### Die einzige Optimierung, die gemessen nötig war

Auf deinem Client stand *Sampling tasks* bei **16,5 ms/s** mit geschlossenem
Fenster, bei **182 Addon-Ordnern**. Alles darin ist billig bis auf eine
Sache: `UpdateAddOnMemoryUsage()` läuft einmal durch den kompletten
Lua-Zustand. Ein Client mit 200 Ordnern zahlt für denselben Aufruf ein
Vielfaches eines Clients mit 20 — und das Intervall war für beide gleich.

Der Scan misst sich jetzt selbst und streckt sein eigenes Intervall, wenn er
über dem Budget liegt (`C.MEMORY_SCAN_BUDGET_MS`, Deckel bei 6x). Er ist
schnell beim Strecken und langsam beim Zurückgehen, damit ein einzelner
billiger Scan keine Entscheidung umwirft. Nichts entfällt dabei — der
Wachstumstrend bekommt weiter Messpunkte, nur weniger davon. Und es passiert
nicht heimlich: die System-Seite hat dafür eine eigene Zeile, und die
Overhead-Aufschlüsselung nennt den Scan beim Namen, statt ihn in einer Summe
verschwinden zu lassen.

Alles andere im Hot Path wurde gemessen und **nicht** angefasst. Die
Scheduler-Koinzidenz zum Beispiel: die drei teuersten Sampler treffen sich
bei 60 fps in 20 von 36 000 Frames. Dafür lohnt sich keine Zeile Code.

### Zwei neue Suiten

| Suite | Was sie festnagelt |
|---|---|
| `tools/test-ui.lua` | Jede Seite bei 940x600, 1280x800 und 1920x1080: nichts ragt aus seinem Elternteil, nichts überlappt **horizontal wie vertikal**, nichts überlebt einen Seitenwechsel, keine Kartenüberschrift wird auf Initialen gekürzt. Dazu Hover, Klick, Rechtsklick, echtes Scrollen, Tooltip-Abbau, Schliessen und Wiederöffnen. |
| `tools/test-longrun.lua` | Sechs simulierte Stunden bei 0,1 s Takt durch den **echten** Scheduler. Caps, Kompaktierung, Allokationsbudgets, das Selbstdrosseln des Scans, und zum Schluss ein Quervergleich: dieselbe Zahl muss überall dieselbe sein. |

## 0.7.2: der Harness lernt die zweite Achse

Bis hierher löste der Mock **nur horizontale** Anker auf. Jede vertikale
Layoutfrage — passt diese Zeile noch in diese Karte, passt dieser Satz in die
zwei Zeilen, die er bekommen hat — wurde von einem Screenshot beantwortet oder
gar nicht. Das ist jetzt zu.

### Erst die Abdeckung, dann der Audit

Die erste Messung war ernüchternd: von 993 sichtbaren Regionen liessen sich
**169 horizontal** und **157 vertikal** auflösen. Der Text-Audit, den es seit
0.5.0 gibt, war also für rund 83 % der Oberfläche blind, ohne dass das jemand
gemerkt hätte.

Zwei Ursachen, beide im Mock:

| Bruchstelle | Folge |
|---|---|
| `Minimap` hatte gar keinen Anker | Der komplette Minimap-Button-Teilbaum löste sich nicht auf |
| Ein **Scroll-Child** trägt keine Anker — der ScrollFrame positioniert es | Die Kette brach an jeder scrollenden Seite ab, und das ist fast jede |

Nach beiden Fixes: **945 horizontal, 783 vertikal.** Derselbe Audit-Code, die
gleiche Oberfläche, fünfmal so viel gesehen.

Nebenbei fiel auf, dass `GetVerticalScroll` im Mock **gar nicht existierte**.
Jeder Mausrad-Handler liest den Wert, bevor er einen Schritt abzieht — ein
Rad-Ereignis hätte also geworfen. Es hat nie eines gegeben, obwohl „scrolled"
in der Kopfzeile der UI-Suite stand. Jetzt ist der Pfad echt und wird geprüft.

### Was der vertikale Audit meldet

| Art | Bedeutung |
|---|---|
| `spill` | Nichts klippt, WoW malt den Inhalt über das, was darunter liegt |
| `cutoff` | Etwas weiter oben klippt: nichts wird übermalt, der Inhalt ist einfach weg |
| `truncated` | Umbrechender Text braucht mehr Zeilen, als seine Höhe erlaubt |

Ein Frame, der seine **eigenen** Kinder klippt, ist ein Viewport — dort ist
Überstand gewollt. Eine virtualisierte Liste zeichnet absichtlich eine Zeile
über den unteren Rand hinaus, damit beim Scrollen eine angeschnittene Zeile
sichtbar ist. Gemeldet wird deshalb nur, was über einen Eltern-Frame
hinausläuft, der **nicht** klippt.

### Neun Layoutfehler, die dabei herausfielen

Alle waren im echten Client sichtbar, und keiner hätte sich vorher zeigen
können.

| Seite | Fund |
|---|---|
| System | Die CLIENT-Karte trug eine handgesetzte Höhe. Ich hatte eine Zeile ergänzt — die letzten **zwei** Zeilen waren abgeschnitten |
| Incidents | Die INCIDENT-Karte füllt ihr Panel; bei 940x600 fehlten **vier** von 15 Fakten |
| Timeline | SELECTED RANGE war **48 px** zu kurz: drei von sieben Zeilen weg |
| Timeline | Markerspur und Detailpanel hingen **40 px** unter dem Seitenrand |
| Overview | BIGGEST CONCERN: eine Zeile abgeschnitten |
| Sessions | SUMMARY: eine Zeile abgeschnitten |
| Alerts | RECENT ALERTS: 4 px zu kurz, letzte Zeile weg |
| Events | EVENT STORMS: 4 px zu kurz, vierte Zeile weg |
| Errors, Memory | Sechs bzw. fünf Karten wurden stur nebeneinander gequetscht |

Die vier mittleren hatten dieselbe Ursache: das Widget rechnet sich seine
`naturalHeight` selbst aus, und die Seite überschrieb sie mit einer kleineren
Handzahl. `grid:Add` gibt einem Widget jetzt **nie weniger als seine
naturalHeight** — ein Fix an einer Stelle statt sieben neuer Zahlen.

### Drei Fehler, bei denen Text zu Unsinn wurde

**`UI.FitText` gab die leere Zeichenkette zurück**, wenn nicht einmal ein
Zeichen plus Ellipse passte. Das Label verschwand dann spurlos — neunmal in
einem einzigen Durchlauf über die Seiten. Es gibt jetzt in jedem Fall
mindestens drei Punkte aus: „hier steht Text, frag danach" ist mehr als nichts.

**Die Processes-Zusammenfassung** bekam hinter sechs Filterknöpfen **55 px**
und las sich als `"176 of ..."`. Mit `UI.FitBest` wählt sie die längste
Formulierung, die ganz passt — in derselben Breite steht dort jetzt
`"176/220"`.

**Jede StatRow** reservierte die Hälfte ihrer Breite für den Wert. Eine 321 px
breite Zeile gab **160 px an die Zeichenkette `"0"`** und kürzte
„Collections observed" auf den Rest. Ursache war ein Anker: der Wert war
zusätzlich zur rechten Kante an die **Mitte** der Zeile gebunden, und das ist
ein fest verdrahteter 50/50-Split, den kein `SetWidth` überstimmt — im echten
Client so wenig wie hier. Label jetzt 267 px statt 154.

### Formatierer: was auf den Schirm kommt, wenn die Zahl keine ist

Jeder Formatierer beantwortete `nil` mit `"-"`. Für die **anderen** Arten, wie
eine Messung schiefgeht, hatte keiner eine Antwort: eine Rate über null
Sekunden ist ein NaN, ein Anteil an einer leeren Summe eine Unendlichkeit, und
beides landete wörtlich auf dem Bildschirm — `-nan KB`, `infh ago`, `inf %`.
Alles, was gar keine Zahl war, **warf** — aus einem Refresh-Pfad heraus, dem
schlechtesten Ort für eine Meinung über Eingaben.

Gemessen: **44 Würfe und 29 Mal `nan`/`inf`** über elf Formatierer. Jetzt ein
Tor an der Grenze (`finite`), und „keine brauchbare Zahl" wird überall so
behandelt wie `nil` es schon wurde.

## 0.7.3: Layout und eine Messung, die sich selbst gemessen hat

### Die Settings-Seite

Sechzehn Abschnitte in **einer festen 520-px-Spalte**. Bei 1920 stand das
rechte Drittel leer und die Seite war 4840 px hoch, egal wie viel Platz da
war. Die Abschnitte sind jetzt Karten und fliessen in so viele Spalten, wie
die Breite hergibt:

| Fenster | Spalten | Seitenhöhe |
|---|---|---|
| 940 x 600 | 1 | 4840 px |
| 1280 x 800 | 2 | 2460 px |
| 1920 x 1080 | 3 | **1656 px** |

Dazu ein Filterfeld: `memory` lässt 2 von 16 Abschnitten stehen, `error`
einen. Bei sechzehn Abschnitten ist Scrollen keine Suche.

Die Button-Raster in *Commands* und *Developer* waren auf ein Drittel von 520
px fest verdrahtet; sie verteilen sich jetzt über die Breite, die ihre Karte
tatsächlich bekommen hat.

### Seitenspalten: ein Mass statt acht

Acht Seiten hatten eine Listen-oder-Detail-Spalte und **acht verschiedene
feste Breiten** — 196, 230, 250, 280, 300, 320, 330, 380. Eine feste Breite
ist an beiden Enden falsch: bei 940 frisst eine 380er-Spalte 40 % der Seite,
bei 1920 ist dieselbe Spalte ein Streifen neben einer riesigen Fläche.

Jetzt ein Anteil mit Deckel (`UI.SideColumnWidth`): 250 px bei 940 (34 %),
280 px bei 1280 (26 %), 400 px bei 1920 (23 %) — auf allen fünf betroffenen
Seiten identisch.

### Die Messung, die sich selbst gemessen hat

Ein Seiten-Refresh schien **151 KB** zu allokieren, zweimal pro Sekunde. Das
sah nach dem dringendsten Optimierungsziel im ganzen Addon aus.

Es war der Harness. Zwei Stellen:

| Fund | Kosten |
|---|---|
| `SetPoint` baute pro Aufruf eine Tabelle | 384 Bytes x 324 Aufrufe pro Listen-Refresh |
| `ClearAllPoints` warf diese Tabellen weg | jedes folgende `SetPoint` allokierte neu — und Layout-Code macht fast immer beides nacheinander |
| `checkColor` iterierte über `{ r, g, b }` | eine Tabelle pro Farbsetzung, 171 pro Refresh |

Im echten Client sind Anker überhaupt keine Lua-Tabellen. Nach dem Fix
(Anker werden in place aktualisiert und in einem Pool wiederverwendet, die
Farbprüfung vergleicht direkt):

Dazu kam eine dritte Stelle: die Anker-Auflösung legte pro Aufruf eine
`seen`-Tabelle für die Zyklenerkennung an. Ein Merker auf der Region selbst
sagt dasselbe und kostet nichts.

```
ein Listen-Refresh:   137,9 KB  ->   2,7 KB
errors-Seite:         151,3 KB  ->   2,8 KB      2,02 ms -> 0,55 ms
performance:          189,2 KB  ->   4,5 KB      1,83 ms -> 0,85 ms
timeline:             132,5 KB  ->   4,6 KB      1,87 ms -> 0,75 ms
dashboard:            145,4 KB  ->  19,8 KB      1,71 ms -> 0,73 ms
settings:              56,4 KB  ->   0,1 KB
```

Rund **90 % der scheinbaren Addon-Allokation waren das Messgerät.** Das ist
dieselbe Lektion wie bei `debugprofilestop` in 0.7.1, und deshalb steht sie
jetzt als Assertion in `tools/test-ui.lua`: ein erneutes Anker-Setzen muss
unter 8 Bytes pro Aufruf bleiben, und ein Seiten-Refresh unter 100 KB. Sonst
versteckt sich die nächste echte Regression wieder hinter dem Rauschen.

**Am Addon wurde daraufhin fast nichts optimiert** — die Zahl, die das
gefordert hätte, gab es nicht. Eine Stelle blieb übrig, nachdem die Messung
ehrlich war: `Overhead:GetBreakdown(out)` nimmt eine Tabelle entgegen, damit
es zweimal pro Sekunde ohne Allokation laufen kann, und baute intern trotzdem
ein frisches fünfelementiges Array aus frischen Tabellen. Es füllt die Zeilen
jetzt in place.

Der Rest — Dashboard 19,8 KB, System 18,2 KB pro Refresh — verteilt sich auf
zwanzig bis dreissig formatierte Zeilen ohne einzelnen Hebel. Dort wurde
bewusst aufgehört: eine Zeile, die eine Zahl formatiert, allokiert einen
String, und daran vorbei kommt man nur mit Cachestrukturen, die den Code
schlechter lesbar machen als der Gewinn wert ist. Der Deckel steht als
Assertion: **keine Seite über 60 KB pro Refresh.**

Nebenbei wurde die UI-Suite dadurch schneller: 1 m 53 s bei 68 Assertions ->
1 m 21 s bei 118.

## 0.7.4: 273 Würfe, die keiner gesehen hat

Eine Methode, deren Name eine Antwort verspricht, muss eine liefern — nicht
werfen. Das ist nicht akademisch: der Aufrufer, der mit einem veralteten Index
oder einem verworfenen Datensatz bei einer Abfrage landet, ist ein Bug, und ein
Wurf macht daraus eine kaputte Seite **plus** einen Lua-Fehler — ausgerechnet
in dem Addon, dessen Aufgabe es ist, fremde Lua-Fehler anzuzeigen.

Der Fuzz-Durchgang über jede abfrageförmige Methode (`Get*`, `Describe*`,
`Count*`, `Is*`, `Has*`, `Top*`, `Most*`, `Worst*`, `Estimate*`, `Rate*`,
`Find*`, `Percentile*`) mit zwölf feindseligen Argumenten:

```
1212 Aufrufe, 273 Würfe
```

### Ein Idiom, 30 Mal wiederholt, eine Fehlerklasse

Der grösste Anteil war **eine einzige kopierte Zeile**. Dreissig Methoden
nehmen eine optionale Scratch-Tabelle entgegen, damit sie zweimal pro Sekunde
ohne Allokation laufen können, und jede begann so:

```lua
out = out or {}
for i = #out, 1, -1 do out[i] = nil end
```

`out or {}` akzeptiert alles Wahrheitswertige. Ein String kam durch den Guard
und warf erst in der Leerschleife. `WTM.Scratch(out)` schreibt das Idiom
einmal auf — und macht den Code dabei **kürzer**, nicht länger: 38 Fundstellen
verlieren je eine Zeile.

### Der Rest

| Muster | Beispiel | Antwort |
|---|---|---|
| Zeitfenster als Zahl | `CountSince("abc")` | `tonumber(x) or default` |
| Bereichsgrenzen | `GetInRange("a", "b")` | keine Zahl → leeres Ergebnis |
| Objekt-Argument | `Sessions:Describe(1e12)`, `IsIgnored(1e12)` | keine Tabelle → `"-"` bzw. `false` |
| Name als String | `Compat.GetCVar({})`, `IsLibrary(…)` | kein String → `nil` bzw. `false` |
| Feld fehlt im Datensatz | `Describe({})` — kein `label`, keine Latenz | benannter Ersatz statt Wurf |

Der letzte Fall ist der interessanteste: ein Spike-Datensatz aus einer
Datenbank einer älteren Version kann ein Feld nicht haben. Statt im Tooltip zu
werfen, steht dort jetzt „World latency: not recorded for this spike".

```
1212 Aufrufe, 0 Würfe
```

Der Fuzz-Durchgang steht als Assertion in `tools/test.lua` und läuft in allen
32 Szenarien mit. Baut man `WTM.Scratch` auf das alte `out or {}` zurück,
meldet er sofort wieder **109 Würfe** — die Prüfung ist also keine, die immer
grün ist.

## 0.8.0: Design/UI/Graphics Overhaul — was die neue Fläche prüft und was nicht

Der grösste Teil dieser Version ist Optik: Theme-Presets, ein Accent-Picker,
Density, ein erweiterter Graph-Engine-Funktionsumfang (Nebenlinien,
Threshold-Zonen, schweregestufte Marker, Graph Style, Graph Quality), ein
Icon-System und eine zentral geschedulte Animation. Genau dafür gilt die
Warnung am Kopf dieser Datei am unmittelbarsten: **der Mock zeichnet nichts.**
Was hier grün ist, beweist Layout, Struktur und Absturzfreiheit — nie, ob es
gut aussieht.

### Was neu geprüft wird (`tools/test-ui.lua`, sechs neue Blöcke)

| Block | Prüft |
|---|---|
| Theme/Accent/Density-Wechsel | Jede Kombination aus 4 Paletten × 5 Accents wird durchgeschaltet, dazwischen wird die aktuelle Seite neu gezeichnet. Kein Wurf, `windowBg` ändert sich pro Palette wirklich, Compact-Density senkt `rowHeight` wirklich, und nach dem Zurückschalten steht wieder exakt der Ausgangswert. |
| Graph-Engine-Randfälle | Threshold-Zonen zeichnen nachweisbar nichts, solange die Einstellung aus ist, und nachweisbar etwas, sobald sie an ist und die Daten tatsächlich im ELEVATED-Bereich liegen (eigens gebauter Graph mit bekannten Werten, nicht der Recorder-gespeiste Seiten-Graph — der hat in einem headless Lauf nicht zuverlässig genug Daten für eine echte Aussage). Performance-Qualität schaltet die Nebenlinien nachweisbar ab, High schaltet sie nachweisbar an. Auto-Fill zeichnet auf einem Zwei-Serien-Graphen nachweisbar weniger Segmente als erzwungenes Area. Ein extremer Ausreisser (4200 ms in einer Reihe von ~10 ms) wird als `clipped` markiert, der wahre Peak bleibt im Report erhalten. Drei Datenformen, die der normale Fixture-Lauf nie erzeugt — kein Sample, ein Sample, 4096 rohe Samples — werfen beim Zeichnen nicht, und der letzte Fall beweist, dass die Segmentzahl weiter an die Pixelbreite gebunden bleibt, nicht an die Samplezahl. |
| Pooling-Statistik | `UI.GetGraphPoolStats()` sieht mindestens so viele Graphen wie es Seiten gibt, und `created >= active` gilt (die Kennzahl kann nicht weniger erschaffen haben, als gerade aktiv ist). |
| Reduced Motion | `UI.Animate` löst bei aktivem „Reduce motion" **synchron**, ohne einen Frame Verzögerung, auf Fraction 1 auf — das ist die ganze Zusicherung, die die Einstellung macht. |
| UI-Scale-Varianten | Dieselben drei Fenstergrössen zusätzlich bei 0.75× und 1.25× UI-Scale, auf vier repräsentativen Seiten. Nur eine Wurf-Prüfung — Layout-Kollisionen bei Nicht-1.0-Skalierung sind (noch) keine eigene geometrische Prüfung, siehe unten. |
| Badges unter Last | 300 zusätzliche simulierte Spikes und Fehler (zusätzlich zu den 40 der Standard-Fixture) dürfen nicht werfen, und das Error-Badge in der Sidebar bleibt bei „999+" lesbar statt beliebig breit zu werden. |

### Was weiterhin nur im Retail-Client zu beurteilen ist

* **Ob es tatsächlich hochwertiger aussieht.** Die Prüfungen oben zeigen "zeichnet
  etwas" bzw. "zeichnet nichts" und "wirft nicht" — nie "sieht gut aus".
* **Die vier Theme-Presets und fünf Accents als Bild.** Der Mock kann beweisen,
  dass sich `windowBg` ändert; ob Graphite neben Midnight tatsächlich wie zwei
  unterscheidbare, professionelle Paletten aussieht statt wie zwei sehr ähnliche
  Grautöne, ist eine visuelle Frage.
* **Die elf Icon-Silhouetten bei 12 px.** Ob „bars" wirklich als „hier gibt es
  einen Graphen" gelesen wird und nicht als undefinierter Klecks, lässt sich nur
  am Bildschirm beurteilen.
* **Threshold-Zonen und Nebenlinien als Bildeindruck.** „Subtil, nicht aufdringlich"
  ist die Vorgabe aus dem Briefing; der Mock kann nur zeigen, dass die Bänder mit
  welcher Alpha-Stufe gezeichnet werden, nicht, ob sie am Bildschirm subtil wirken.
* **UI-Scale jenseits von 1.0× als Bildeindruck.** Der neue Block oben beweist nur
  Wurf-Freiheit bei 0.75×/1.25×; ob dabei irgendwo Text oder eine Graph-Linie
  sichtbar kollidiert, prüft (noch) keine geometrische Assertion bei
  Nicht-Standard-Skalierung — nur der bestehende `AuditText`/`AuditTextOverlap`/
  `AuditVertical`-Dreiklang bei Scale 1.0 tut das systematisch.
* **Der einmalige Badge-Pulse als Bewegung.** Der Test beweist, dass er synchron
  auflöst, wenn Motion aus ist; wie er sich anfühlt, wenn Motion an ist, ist keine
  Assertion, sondern ein Seherlebnis.

## Was der Mock nicht kann

* **Keine echten Rückgabewerte.** Ob `GetEventCPUUsage` ms oder s liefert,
  entscheidet der echte Client.
* **Keine echten Kosten.** Seit 0.7.1 misst der Mock echte Zeit, aber es ist
  die Zeit dieser Maschine an einem nachgebauten Client. Sie taugt zum
  Vergleich zwischen Aufgaben, nicht als Vorhersage. Ob `RegisterAllEvents`
  im Schlachtzug tragbar ist, zeigt nur der Schlachtzug — dafür gibt es
  `/wtm benchmark`.
* **Kein Taint.** Das Addon fasst nichts Geschütztes an, aber bewiesen ist das
  erst durch einen Kampf ohne Blocked-Action-Meldung.
* **Kein Rendering.** Seit 0.7.2 werden beide Achsen aufgelöst, der Mock kann
  also sagen, ob etwas in seinen Kasten passt. Ob es *gut aussieht* — ob ein
  Graph lesbar ist, ob eine Farbe trägt — sehe ich weiter nur auf deinen
  Screenshots.
* **Nur enUS.** Deutsche Umlaute in Addon-Titeln sind ungetestet.
