# Offene Punkte / noch abzuklären und zu testen

Features, die eingebaut, aber noch **nicht ausreichend getestet oder fachlich geklärt** sind.
Einträge erst entfernen, wenn sie geklärt und getestet sind.

---

## 1. Platzhalter-Seiten für fehlende Parent-Seiten (experimentell)

**Seit:** 2026-11-09 (Unreleased)
**Code:** `WikiImporter#create_placeholder_parent` (`lib/redmine_subwikifiles/wiki_importer.rb`)

**Verhalten:**
Eine importierte Datei verweist im Frontmatter auf `parent: X`, und `X` existiert weder als Wiki-Seite noch als Datei.
Dann wird eine Platzhalter-Seite `X` mit dem Inhalt `{{child_pages}}` angelegt. Dabei entsteht auch `X.md`.
Die importierte Seite wird darunter gehängt.
Angelegte Platzhalter werden als Warnung angezeigt (Seitenaufruf) bzw. in der Sync-Meldung aufgezählt.

**Vorher:** Der Git-Abgleich (`GitSync#create_page_in_redmine`) hat die Seite **ohne Parent** und **mit dem Frontmatter im Seitentext** angelegt.
Der Parent ging beim nächsten Speichern stillschweigend verloren.
Neue Dateien laufen jetzt in beiden Wegen (Git-Abgleich und Datei-Scan) über `WikiImporter`.

**Abzuklären:**
- [ ] Ist ein automatischer Platzhalter fachlich gewünscht, oder lieber Import ohne Parent + Warnung bzw. manuelle Zuordnung?
- [ ] Inhalt des Platzhalters: `{{child_pages}}` ok? Kennzeichnung als Platzhalter (z. B. Hinweistext) nötig?
- [ ] Tippfehler im `parent:` erzeugen ungewollte Platzhalter-Seiten. Braucht es eine Bestätigung oder ein Aufräumen?

**Zu testen:**
- [ ] Parent-Ketten: Datei → fehlender Parent, der selbst einen fehlenden Parent hätte (Platzhalter landet auf oberster Ebene)
- [ ] Mehrere Dateien mit demselben fehlenden Parent (nur ein Platzhalter)
- [ ] Parent-Titel mit Leerzeichen/Sonderzeichen/Umlauten (Titel- und Dateinamen-Normalisierung)
- [ ] Rekursiver Sync über Unterprojekte
- [ ] Alle drei Konfliktstrategien (`file_wins`, `db_wins`, `manual`)
- [ ] Redmine 4, 5, 6, 7
- [ ] Unit-/Integrationstest ergänzen

---

## 2. Sync-Status-Chip und Sync-Popover (Etappe 1)

**Seit:** 2026-11-09 (Unreleased)
**Code:** `SyncState` (Drei-Wege-Vergleich), `SyncPlan` (Vorschau + Ausführen), `SyncUiHooks`,
`app/assets/javascripts/subwikifiles_sync.js`, `app/assets/stylesheets/subwikifiles_sync.css`,
`SubwikifilesController#plan` / `#apply`

**Verhalten:**
- Ein Chip neben „Bearbeiten“ zeigt den Zustand der Seite: synchron / Datei fehlt / Datei geändert / Wiki geändert / Konflikt / Datei gelöscht / Ordner nicht beschreibbar.
- Ein Klick öffnet das Popover mit vier Umfängen (Seite · Zweig · Wiki · + Unterprojekte) und der Anzahl Änderungen pro Umfang, dazu die Vorschau aller Aktionen.
- Die Richtung wird pro Seite automatisch bestimmt, als Basis dient der letzte Git-Commit.
- Eine Entscheidung braucht es nur bei Konflikten (Datei / Wiki / Überspringen) und bei gelöschten Dateien (Wiederherstellen / Überspringen).
- Die automatischen Abgleiche beim Seitenaufruf übernehmen nur noch eindeutige Datei-Änderungen. Konflikte werden nicht mehr automatisch aufgelöst und auch nicht committet.
- Die rote Warnung „Ref-Datei fehlt“ und der Sync-Button darin sind entfernt.

**Abzuklären:**
- [ ] Seiten ohne gemeinsamen Stand (nie committet): Notlösung „neuere gewinnt“ (mit ≈ markiert). Reicht das?
- [x] ~~Sollen eindeutige Fälle ohne Klick erledigt werden?~~ Erledigt: Nach dem Laden einer Wiki-Seite übernimmt `SubwikifilesController#auto` im Hintergrund alle eindeutigen Aktionen im ganzen Projektbaum (Datei anlegen, nur Datei bzw. nur Wiki geändert, Import mit Header). Angezeigt werden nur unsichere Fälle: Konflikt, gelöscht, kein gemeinsamer Stand, ohne Header, Anhang. Mit `db_wins` werden Datei-Änderungen nicht automatisch übernommen.
- [x] ~~Automatik drosseln~~: höchstens einmal pro `AUTO_INTERVAL` (60 s) pro Projektbaum, über alle Nutzer (`RedmineSubwikifiles.throttle_slot?`; Rails-Cache, bei NullStore im Speicher des Prozesses). Die Vorschau (nur lesend) wird weiterhin bei jedem Aufruf berechnet.
- [ ] Intervall als Plugin-Einstellung?
- [ ] Löschungen werden nie automatisch ausgeführt: Wiki-Seite gelöscht → Datei bleibt („Zu löschen?“: Datei löschen / Seite neu anlegen / Überspringen); Datei gelöscht → Seite bleibt (Seite löschen / Datei wiederherstellen / Überspringen). Vorauswahl ist immer „Überspringen“. Testen, inkl. „alle löschen“ und Rückfrage.
- [ ] Automatische Änderungen sind nur im Tooltip und in der Wiki-/Git-Historie sichtbar. Reicht das, oder braucht es ein Protokoll?
- [ ] Performance von „+ Unterprojekte“ bei grossen Bäumen (pro abweichender Seite 1–2 Git-Aufrufe). Evtl. pro Umfang nachladen.
- [ ] Chip auch auf Projektübersicht / Wiki-Index mit Gesamtzahl?
- [ ] Dateien ohne Wiki-Header und andere Dateien erscheinen jetzt im Popover (Importieren / Anhängen, Ziel ist die aktuelle Seite wie beim ✓-Button). Wird die gelbe Meldung „Zuweisung erforderlich“ damit überflüssig?
- [ ] Ziel bei Unterprojekten: Dort gibt es keine „aktuelle Seite“, darum Import auf oberster Ebene bzw. Anhang ans Wiki. Ist das ok?

**Zu testen:**
- [ ] Ganzen Ordner löschen (inkl. `.git`) → „Datei gelöscht – Seite auch löschen?“ für alle Seiten; Basis-Pfad ändern → „Datei anlegen“ (nicht „gelöscht“)
- [ ] Im Browser: Chip-Position, Popover, Tooltips, Entscheidungen, Übernehmen (r4–r7, verschiedene Themes)
- [ ] Alle drei Konfliktstrategien als Vorauswahl
- [ ] Datei-Umbenennung (Header-`id`) → Anzeige „← alter Titel“, keine gleichzeitige „gelöscht“-Meldung
- [ ] Gesperrte Dateien, Projekte ohne Berechtigung, nicht beschreibbarer Pfad
- [ ] Unit-/Integrationstests für `SyncState` und `SyncPlan`

**Geplant:** Etappe 2 (Gegenüberstellung bei Konflikten), Etappe 3 (Rückgängig über Git-Revert und Wiki-Versionen).

---

## 3. Live-Split-Preview im Wiki-Editor (HedgeDoc-Style)

**Seit:** 2026-11-11 (Unreleased)
**Code:** `SyncUiHooks`, `app/assets/javascripts/subwikifiles_live_preview.js`, `app/assets/stylesheets/subwikifiles_live_preview.css`, `app/views/settings/_redmine_subwikifiles_settings.html.erb`

**Verhalten:**
- In den Plugin-Einstellungen ein- und ausschaltbar (`live_preview`, standardmässig aktiv).
- Im Wiki-Editor erscheint zwischen „Bearbeiten“ und „Vorschau“ der Reiter **„Split“** (auf Bildschirmen > 900 px standardmässig aktiv; Auswahl wird im `localStorage` unter `swf-editor-mode` gemerkt).
- Links bleibt das Textfeld samt Formatierungs-Toolbar editierbar, rechts wird die echte Redmine-Vorschau (inkl. Makros wie `{{child_pages}}`, Wiki-Links und Anhängen) beim Tippen verzögert (280 ms Debounce + `AbortController`) aktualisiert.
- Schmaler Trenner mit Griff (Handle), per Maus zwischen 20 % und 80 % verschiebbar (`swf-editor-split-ratio` im `localStorage`), Doppelklick stellt 50/50 wieder her.
- Synchrones proportionales Scrollen in beide Richtungen und automatische Höhenanpassung beim Vergrössern des Textfelds.

**Zu testen:**
- [ ] Darstellung und Umschalten (`Bearbeiten` / `Split` / `Vorschau`) in Redmine 4, 5, 6, 7 und verschiedenen Themes
- [ ] Verschieben des Trenners per Maus und Doppelklick-Reset auf 50/50
- [ ] Verhalten bei sehr langen Seiten, Tabellen, Bildern und Makros
- [ ] Einfügen von Links über den ✓-Button bei nicht zugeordneten Dateien im Split-Modus
