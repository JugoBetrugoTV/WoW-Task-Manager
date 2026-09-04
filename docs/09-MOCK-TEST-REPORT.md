# Mock-Testbericht

Erzeugt am 2026-09-04 gegen Addon-Version 0.7.1.

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
  PASS  Retail-12.1.0      profiling=on  api=normal   no-ace3    437 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=normal   ace3       437 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=degraded no-ace3    447 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=on  api=degraded ace3       447 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=normal   no-ace3    438 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=normal   ace3       438 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=degraded no-ace3    448 passed, 0 failed, 0 lua errors
  PASS  Retail-12.1.0      profiling=off api=degraded ace3       448 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=normal   no-ace3    437 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=normal   ace3       437 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=degraded no-ace3    447 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=on  api=degraded ace3       447 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=normal   no-ace3    438 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=normal   ace3       438 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=degraded no-ace3    448 passed, 0 failed, 0 lua errors
  PASS  MoP-5.5.4          profiling=off api=degraded ace3       448 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=normal   no-ace3    437 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=normal   ace3       437 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=degraded no-ace3    447 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=on  api=degraded ace3       447 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=normal   no-ace3    438 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=normal   ace3       438 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=degraded no-ace3    448 passed, 0 failed, 0 lua errors
  PASS  TBC-2.5.6          profiling=off api=degraded ace3       448 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=normal   no-ace3    437 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=normal   ace3       437 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=degraded no-ace3    447 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=on  api=degraded ace3       447 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=normal   no-ace3    438 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=normal   ace3       438 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=degraded no-ace3    448 passed, 0 failed, 0 lua errors
  PASS  Classic-1.15.9     profiling=off api=degraded ace3       448 passed, 0 failed, 0 lua errors
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
| `tools/test-ui.lua` | Jede Seite bei 940x600, 1280x800 und 1920x1080: nichts ragt aus seinem Elternteil, nichts überlappt, nichts überlebt einen Seitenwechsel. Dazu Hover, Klick, Rechtsklick, Scroll, Tooltip-Abbau, Schliessen und Wiederöffnen. |
| `tools/test-longrun.lua` | Sechs simulierte Stunden bei 0,1 s Takt durch den **echten** Scheduler. Caps, Kompaktierung, Allokationsbudgets, das Selbstdrosseln des Scans, und zum Schluss ein Quervergleich: dieselbe Zahl muss überall dieselbe sein. |

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
* **Kein Rendering.** Ob Text abgeschnitten wird oder Graphen lesbar sind,
  sehe ich nur auf deinen Screenshots.
* **Nur enUS.** Deutsche Umlaute in Addon-Titeln sind ungetestet.
