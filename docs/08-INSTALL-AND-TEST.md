# Installation und erster Test in allen vier Clients

## 1. Installation

Kopiere den Ordner **`WoWTaskManager`** (den Ordner selbst, nicht seinen Inhalt)
nach:

| Client | Zielpfad |
|---|---|
| Retail / Midnight 12.1.0 | `World of Warcraft\_retail_\Interface\AddOns\WoWTaskManager` |
| MoP Classic 5.5.4 | `World of Warcraft\_classic_\Interface\AddOns\WoWTaskManager` |
| TBC Anniversary 2.5.6 | `World of Warcraft\_classic_era_ptr_` bzw. der Ordner deiner TBC-Installation |
| Classic Era 1.15.9 | `World of Warcraft\_classic_era_\Interface\AddOns\WoWTaskManager` |

> Der Ordnername **muss** `WoWTaskManager` heißen. Die TOC-Dateien heißen
> `WoWTaskManager.toc`, `WoWTaskManager_Mainline.toc` usw. — WoW verlangt, dass
> der TOC-Name dem Ordnernamen entspricht.

Danach muss so aussehen:

```
Interface/AddOns/WoWTaskManager/
    WoWTaskManager.toc
    WoWTaskManager_Mainline.toc
    WoWTaskManager_Mists.toc
    WoWTaskManager_TBC.toc
    WoWTaskManager_Vanilla.toc
    Includes.xml
    Core/  Compatibility/  Monitoring/  History/  Analysis/  UI/  Utils/  Libs/
```

**Ace3 ist nicht nötig.** Ist `Libs/` leer, benutzt das Addon seine interne
Implementierung. Wer Ace3 will: Ordner nach `WoWTaskManager/Libs/` legen und in
`Libs/embeds.xml` die auskommentierten Zeilen aktivieren.

Im Charakterauswahl-Bildschirm unter *AddOns* prüfen, dass **WoW Task Manager**
gelistet und aktiviert ist. Falls nicht: „Veraltete AddOns laden" anhaken —
falls das nötig ist, sag mir bitte Bescheid, dann stimmt die Interface-Nummer
für deinen Build nicht.

---

## 2. Der 60-Sekunden-Rauchtest

Das hier bitte in **jedem** der vier Clients einmal durchgehen.

| # | Schritt | Erwartet |
|---|---|---|
| 1 | Einloggen | Genau **eine** Chat-Zeile beim ersten Start: der Capability-Report. Danach nur noch eine kurze Statuszeile. **Keine Lua-Fehler.** |
| 2 | `/wtm` | Fenster öffnet sich, Dashboard ist aktiv |
| 3 | Oben ansehen | FPS, Frame Time, 1% Low, Home/World Latency, Addon CPU, Addon Memory, Events/sec |
| 4 | 30 Sekunden warten | Die sechs Graphen füllen sich von rechts nach links |
| 5 | Sidebar durchklicken | Alle 11 Seiten öffnen ohne Fehler |
| 6 | Fenster ziehen / Ecke ziehen | Verschieben und Größe ändern funktioniert |
| 7 | `Esc` | Fenster schließt |
| 8 | `/wtm caps` | Capability-Report im Chat |
| 9 | `/wtm benchmark` | Nach 10 s ein Overhead-Report im Chat |

**Wichtigster Wert im Benchmark:** `TOTAL MEASURED`. Alles unter ~2 ms/s ist
unauffällig. Deutlich darüber will ich sofort sehen.

---

## 3. Was ich pro Client wissen muss

Bitte für **jeden** Client kurz beantworten:

```
CLIENT: ................ (z.B. Retail 12.1.0)

1. Lua-Fehler beim Login?          ja / nein   -> falls ja: kompletter Text
2. /wtm öffnet das Fenster?        ja / nein
3. FPS-Wert plausibel?             ja / nein   -> angezeigt: ....  echt (Strg+R): ....
4. Frame Time plausibel?           ja / nein   -> ~1000/FPS?
5. Home / World Latency plausibel? ja / nein   -> angezeigt: .... / ....
6. Addon Memory > 0?               ja / nein
7. Events/sec > 0?                 ja / nein
8. Alle 11 Seiten ohne Fehler?     ja / nein   -> falls nein: welche
9. /wtm benchmark TOTAL MEASURED:  ...... ms/s
10. Screenshot vom Dashboard
```

---

## 4. CPU-Profiling einschalten

Standardmäßig ist der `scriptProfile`-CVar aus. Dann zeigt das Dashboard oben
prominent **„Addon CPU profiling is disabled"** mit zwei Buttons.

1. **Enable profiling** klicken → setzt nur den CVar, lädt **nichts** neu.
2. **Reload UI** klicken (oder `/reload`).
3. Nach dem Reload: Processes-Seite → die CPU-Spalten zeigen Werte statt `-`.

**Zu prüfen:**

* Vorher zeigen die CPU-Spalten `-`, **nicht** `0.00`. Wenn dort Nullen stehen,
  ist das ein Bug — bitte melden.
* Nichts lädt ohne Klick neu.
* `/wtm benchmark` danach nochmal: der Overhead steigt, weil der *Client*-Profiler
  läuft. Das ist normal und nicht die Schuld des Addons.

**Wieder ausschalten:** `/wtm profiling` und `/reload`. Blizzards Profiler kostet
dauerhaft Leistung; er sollte nur an sein, wenn du wirklich misst.

---

## 5. Spike-Erkennung testen — ohne dein Spiel zu ruckeln

```
/wtm dev on
/wtm dev spike 250
```

Das erzeugt **kein** echtes Ruckeln. Es speist eine synthetische Frametime in
den Detektor, sodass der komplette Pfad läuft.

Erwartet:

* Chat: `Injected Freeze SIMULATED spike: 250 ms ...`
* Dashboard → *Recent incidents*: ein Eintrag mit **SIMULATED**
* Sidebar → *Incidents*: der Incident, anklickbar
* Incident-Detail: Timestamp, Severity, Frame Time, FPS-Äquivalent, Baseline,
  Latenzen, Event-Rate, Speicher, Combat, Zone, Instance
* Beim CPU-Block muss dastehen **„within a X.XX s observation window"** —
  niemals „of this frame"

Weiter:

```
/wtm dev spike 120
/wtm dev spike 95      (zügig hintereinander)
```
→ sollten zu **einem** Cluster verschmelzen: Peak, Dauer, `affected frames`.

```
/wtm dev storm 3000
/wtm dev memory 20
/wtm dev freemem
/wtm dev rings
/wtm dev scheduler
```

---

## 6. Fehlalarme prüfen

Das Addon soll **nicht** melden:

| Situation | So testest du es | Erwartet |
|---|---|---|
| Login | einloggen | keine Freezes in den ersten ~12 s |
| `/reload` | `/reload` eingeben | kein Freeze-Incident |
| Zonenwechsel | Portal / Flugpunkt nehmen | kein Incident |
| Ladebildschirm | Instanz betreten | kein Incident |
| Alt-Tab | rausklicken, 20 s warten, zurück | idealerweise kein Incident |

Nach jedem dieser Vorgänge zeigt das Dashboard-Banner etwas wie
`3 frame spikes not reported: 2 loading screen, 1 initial login`. Genau so soll
es sein — unterdrückt, aber sichtbar, nicht verschwiegen.

`/wtm dev suppress` zeigt den Zustand.

**Alt-Tab-Erkennung ist bewusst nur eine Heuristik** (über `maxFPSBk`). Wenn du
keinen Background-FPS-Cap gesetzt hast, kann sie nicht funktionieren — dann
bitte melden, dann schalte ich sie für den Fall ab.

---

## 7. Fehlerbericht

Am hilfreichsten ist:

1. **Kompletter Lua-Error.** Falls du BugSack/BugGrabber hast, den ganzen Stack.
   Sonst: `/console scriptErrors 1`, `/reload`, Fehler abschreiben.
2. **Screenshot** der betroffenen Seite.
3. `/wtm caps` (Chat kopieren).
4. `/wtm benchmark` (Chat kopieren).
5. **Client + Version**, exakt.

Bei Verdacht auf falsche Messwerte zusätzlich:

* Was zeigt das Addon, was zeigt das Spiel (`Strg+R` für FPS/Latenz)?
* Bei CPU: `/wtm dev scheduler` — dort steht, ob überhaupt gesampelt wird.

---

## 8. Was in diesem Stand noch NICHT funktionieren kann

Damit du nicht danach suchst:

* **Kein Minimap-Icon.** Nur `/wtm`.
* **Kein Export**, außer `/wtm dev incident` und dem Textreport auf der
  Diagnostics-Seite.
* **Events → Addon** ist eine Namenspräfix-Heuristik. Anonyme Frames sind
  grundsätzlich nicht zuordenbar; bei den meisten Addons bleibt die Spalte
  daher überwiegend leer. Das ist kein Bug.
* **Keine Per-Addon-Sub-Tracks** in der Timeline.
* **Sessions** erscheinen erst nach dem zweiten Login, weil eine Session beim
  Ausloggen geschrieben wird (und mindestens 30 s gedauert haben muss).
