# sqmPartitionTool — Changelog

## [1.7.0.0] — 2026-07-06

### Zusammenfuehrung zweier parallel entwickelter Aenderungsstraenge (DEV02/DEV03)

Waehrend an diesem Rechner (DEV03, komplett neu aufgesetzt) an `Invoke-sqmTableArchiveMigration`
gearbeitet wurde, war auf DEV02 (mittlerweile ausgefallen) unabhaengig voneinander bereits
`BoundaryType 'Text'` + `-SurrogateDateFormat` fuer die Partitionierungsseite entwickelt und
gepusht worden - beide Seiten loesten dasselbe Problem (VARCHAR/CHAR-Surrogatschluessel-Spalten)
mit unterschiedlichem Namen (`Varchar` vs. `Text`) und unterschiedlichem Funktionsumfang (DEV03:
nur YYYYMMDD; DEV02: konfigurierbar YYYYMMDD/YYYYMM, zusaetzlich bis in `sqm_ExtendPartitionWindow`
und den Retention-Sweep-Job durchgezogen).

- Der DEV02-Entwurf (`Text`/`-SurrogateDateFormat`) ist der vollstaendigere und wird als kanonisch
  uebernommen. `Invoke-sqmTableArchiveMigration` und `sqm_ArchiveMonthBatch` (bislang `Varchar`,
  nur YYYYMMDD) sind entsprechend auf `Text` + `-SurrogateDateFormat` umgestellt worden, damit es
  im gesamten Modul nur noch EIN Namensschema fuer Datums-Surrogatschluessel gibt.
- Kein Funktionsverlust auf beiden Seiten: die auf DEV03 entwickelten Faehigkeiten (zusammengesetzte
  Schluessel, Cutover-View, Write-Progress, `-Method BatchedSwap`, GUI-Ueberarbeitung) und die auf
  DEV02 entwickelten (`Text`/`SurrogateDateFormat` durchgaengig bis Extend/Retention) sind beide
  vollstaendig erhalten.

## [1.6.6.0] — 2026-07-06

### `Invoke-sqmTableArchiveMigration`: sichtbarer Fortschritt (Write-Progress + Konsolenausgabe)

Nutzer-Feedback: bei einer sehr grossen Tabelle (mehrere 100GB-TB) laeuft eine Migration ueber
Stunden bis Tage - `Invoke-sqmLogging` schreibt aber AUSSCHLIESSLICH in eine Logdatei, niemals auf
die Konsole. Ein Admin, der den Lauf direkt per PowerShell gestartet hat (der realistische Weg fuer
eine Migration dieser Groessenordnung - nicht durch den GUI-Assistenten, den man dafuer nicht
stundenlang offen halten wuerde), sah bisher ueberhaupt kein Lebenszeichen, bis die Funktion ganz
am Ende zurueckkehrt - nicht von einem haengenden Lauf unterscheidbar.

- Neu: `Write-Progress` mit Prozentanzeige (Monate verarbeitet / Monate gesamt) - aktualisiert nach
  jedem Batch, nicht nur nach jedem abgeschlossenen Monat, damit auch innerhalb eines sehr grossen
  Monats mit vielen Batches sichtbar bleibt, dass es weitergeht.
- Zusaetzlich je eine `Write-Host`-Zeile beim Start und beim Abschluss jedes Monats (z.B.
  "Archiving period 202401 (1 of 30) ...", "Period 202401 done: 12345 row(s) archived (running
  total: 12345)."), damit der Fortschritt auch in einem Transkript oder einer umgeleiteten Ausgabe
  (z.B. geplanter Task, `Start-Transcript`) sichtbar bleibt, wo `Write-Progress` nicht dargestellt
  wird.
- Live gegen DEV01 verifiziert: Konsolenausgabe zeigt Periode-fuer-Periode den Fortschritt exakt wie
  gewuenscht.

## [1.6.5.0] — 2026-07-05

### GUI-Feedback: irrefuehrendes Key-Column-Feld + falsch anwendbare Retention-Sektion

Nutzer-Feedback zur GUI aus [1.6.3.0]: "wenn ich diese nicht brauche dann ist es absolut
irritierend wenn das angezeigt wird. Wenn ich sie brauche, dann ist ein Textfeld unbrauchbar" (Key
Column) sowie "wenn einmal die Archiv-Datenbank aufgesetzt ist, wird nur noch in die
rueckwaertsverweisende View geschrieben - 'When partitions expire later' ist dann Unsinn".

- **Key Column(s)** ist nicht mehr ein immer sichtbares Freitextfeld. Schritt 6 prueft jetzt
  (einmalig pro Tabellenauswahl, live gegen die DB) denselben Clustered-Index/PK-Schluessel, den
  `Invoke-sqmTableArchiveMigration` auch selbst automatisch ableiten wuerde - hat die Tabelle einen
  brauchbaren 1-4-spaltigen Schluessel, bleibt der ganze Bereich vollstaendig ausgeblendet (nicht
  nur deaktiviert). Nur bei einem echten Heap oder einem Schluessel mit mehr als 4 Spalten wird er
  eingeblendet - dann als `CheckedListBox` mit den TATSAECHLICHEN Spalten der Tabelle (kein
  Freitext, kein Tippfehlerrisiko bei Spaltennamen mehr).
- **"Set up automatic maintenance"-Bereich** (inkl. der verschachtelten "Copy to an archive
  database before removal"-Checkbox) wird bei aktivem "Migrate to archive database now" jetzt
  komplett ausgeblendet statt nur ausgegraut+erklaert - der vorherige Erklaerungstext ist damit
  hinfaellig und wurde entfernt. Berechtigter Punkt: nach einem Cutover in die Archiv-DB laeuft
  jeder Zugriff nur noch ueber die rueckwaertsverweisende View - "wenn Partitionen spaeter ablaufen"
  bezieht sich auf ein Konzept, das fuer die (dann gar nicht mehr als eigenstaendige Tabelle
  existierende) Quelle keinen Sinn mehr ergibt. Das "Archive Database"-Feld bleibt (weiterhin von
  beiden Modi gemeinsam genutzt) sichtbar und wird je nach Modus neu positioniert.
- Live gegen DEV01 verifiziert: Heap-Tabelle (0 Schluesselspalten) und eine frische 4-spaltige
  zusammengesetzte PK-Tabelle liefern das erwartete "gebraucht"/"nicht gebraucht"-Ergebnis ueber
  dieselbe Abfrage, die auch tatsaechlich in der GUI verwendet wird.

## [1.6.4.0] — 2026-07-05

### `Invoke-sqmTableArchiveMigration`: YYYYMMDD-Ganzzahl-/String-Datumsspalten (BoundaryType)

Beim Live-Test von [1.6.3.0] gegen die reale `CORO_DB.dbo.CARCHIVE`-Tabelle (der urspruengliche
Anlass fuer den zusammengesetzten Schluessel) schlug die Migration selbst danach noch fehl: `VTDAT`
ist als `INT` im YYYYMMDD-Format gespeichert (z.B. `20240115`), nicht als echtes DATE/DATETIME - die
Funktion castete den Quellwertebereich aber blind per `[datetime]`, und die SQL-Prozedur verglich
fest DATE-typisierte Periodengrenzen direkt gegen die Spalte ("date ist inkompatibel mit int"). Eine
separate, vorbestehende Luecke - unabhaengig vom zusammengesetzten Schluessel, aber notwendig, um
den urspruenglichen Bug-Report ueberhaupt einmal komplett end-to-end durchspielen zu koennen.

Die Partitionierungsseite des Moduls (`Invoke-sqmTablePartitionConversion`/
`Get-sqmPartitionBoundaryList`) kennt diese Konvention bereits (`-BoundaryType Int`/`Varchar` fuer
ein YYYYMMDD-Surrogat) - `Invoke-sqmTableArchiveMigration` uebernimmt jetzt dieselbe Konvention statt
sie neu zu erfinden.

- **`Invoke-sqmTableArchiveMigration`**: `-BoundaryType` (bereits vorhandener, bisher nur an
  `Invoke-sqmTablePartitionConversion` durchgereichter Parameter) wird jetzt zusaetzlich lokal
  ausgewertet - ohne Angabe automatische Ableitung aus dem SQL-Spaltentyp von `-DateColumn`
  (Date/Datetime-Typen -> `Date`, Varchar/Nvarchar/Char/Nchar -> `Varchar`, sonst -> `Int`, gleiche
  Herleitung wie in `Invoke-sqmTablePartitionConversion`). Start/EndPeriod-Ableitung aus dem
  Quellwertebereich parst `MinValue` bei `Int`/`Varchar` jetzt als YYYYMMDD-String statt per
  direktem `[datetime]`-Cast. Die Periodengrenzen fuer `-PurgeSourceAfterArchive`s
  Row-Count-Gegenpruefung/Loeschung werden je nach `BoundaryType` passend formatiert (Int: rohe
  Ganzzahl, Varchar: quotierter String, Date: quotiertes ISO-Datum) statt immer als Datums-Literal.
- **`sqm_ArchiveMonthBatch`**: neuer Parameter `@BoundaryType` (Date/Int/Varchar, Standard `Date`
  fuer Abwaertskompatibilitaet bei direkten Prozeduraufrufen ohne diesen Parameter). Die
  Periodengrenzen (`@PeriodStart`/`@PeriodEnd`) dienen weiterhin nur der Kalenderarithmetik aus
  `@YYYYMM` - fuer den eigentlichen Vergleich mit `@DateColumn` werden sie zusaetzlich in
  `SQL_VARIANT`-Parameter mit dem zu `@BoundaryType` passenden Ganzzahl-/String-/Datumswert
  konvertiert (gleiches, bereits bewaehrtes Prinzip wie die `@pLastKeyN`-Schluesselparameter aus
  [1.6.3.0]).
- Live gegen die ECHTE `CORO_DB.dbo.CARCHIVE`-Tabelle verifiziert (30 Monate verarbeitet, davon 12
  mit tatsaechlichen Daten - Jan-Dez 2024, 60000/60000 Zeilen, Quelle danach unveraendert): Checksumme
  ueber alle 34 nicht-`text`-Spalten sowie Gesamtlaenge der `text`-Spalte (`VDATA`) stimmen zwischen
  Quelle und Archiv-Kopie exakt ueberein. Damit ist der urspruengliche Bug-Report (zusammengesetzter
  Schluessel + YYYYMMDD-Ganzzahlspalte gemeinsam) jetzt vollstaendig end-to-end verifiziert, nicht
  nur mit synthetischen Testtabellen.

## [1.6.3.0] — 2026-07-05

### Zusammengesetzte Schluessel fuer `Invoke-sqmTableArchiveMigration` + GUI-Klarstellungen

Show Stopper aus Live-Test gegen die reale Tabelle `CORO_DB.dbo.CARCHIVE` (7 TB in Produktion):
`-KeyColumn` unterstuetzte bisher nur EINE Spalte, verwendet sowohl als MERGE-Abgleichsbedingung
als auch fuer die Keyset-Pagination innerhalb eines Monats - `CARCHIVE` hat aber einen
zusammengesetzten 4-spaltigen Clustered-PK (`VMTG, VID1, VID2, VSEQ`), keine Spalte davon ist
allein eindeutig. Da alles VOR der eigentlichen Archivierung abbricht (die KeyColumn-Ermittlung ist
der allererste Schritt), wurde bislang auch in `CORO_DB` nichts angelegt (weder Archiv-Tabelle noch
`sqm_ArchiveMonthLog`/`sqm_ArchiveMonthBatch`) - das erklaerte gleich drei gemeldete Symptome
("KeyColumn Pflicht", "keine neue Tabelle in der Archiv-DB", "wo ist die Merge-Prozedur/Hilfstabelle,
die wir schon besprochen hatten") als EINE gemeinsame Ursache.

- **`Invoke-sqmTableArchiveMigration`**: `-KeyColumn` akzeptiert jetzt 1-4 Spalten
  (`[string[]]`, `ValidateCount(1,4)`) statt nur einer. Automatische Ableitung (ohne `-KeyColumn`)
  nimmt jetzt ALLE Spalten eines zusammengesetzten Clustered Index/PK in `key_ordinal`-Reihenfolge,
  statt bei mehr als einer Spalte abzubrechen - nur ein echter Heap oder ein Schluessel mit mehr als
  4 Spalten verlangt weiterhin die explizite Angabe. Neuer, nicht blockierender Warnhinweis vor dem
  Migrationslauf, falls kein Index `$DateColumn` als fuehrende Spalte hat (bei sehr grossen Tabellen
  sonst potenziell ein Full Scan pro Batch) - empfiehlt einen Index auf `($DateColumn, <Schluessel>)`,
  legt ihn aber nicht automatisch an (Admin-Entscheidung).
- **`sqm_ArchiveMonthBatch`**: `@KeyColumn SYSNAME` ersetzt durch `@KeyColumns NVARCHAR(400)`
  (komma-getrennt, `key_ordinal`-Reihenfolge). MERGE-ON, UPDATE-SET-Ausschluss, ORDER BY und die
  Keyset-Pagination-Bedingung werden jetzt dynamisch fuer 1-4 Spalten aufgebaut. Zwei
  Korrektheitspunkte, die bei einem zusammengesetzten Schluessel NICHT trivial sind (ausfuehrlich im
  Datei-Header dokumentiert): (1) die Pagination-Bedingung ist die echte lexikografische
  Tupel-">"-Auswertung als verschachtelter OR/AND-Ausdruck, NICHT einzeln UND-verknuepfte
  Spalten-">"-Vergleiche (das wuerde Zeilen faelschlich auslassen); (2) der neue Fortsetzpunkt nach
  einem Batch wird ueber eine `ROW_NUMBER() OVER (ORDER BY <Schluessel>)`-Sequenznummer je
  Batch-Zeile ermittelt (die Zeile mit der hoechsten Sequenznummer), NICHT ueber das spaltenweise
  Maximum (das bei zusammengesetzten Schluesseln eine nie existierende Tupel-Kombination erzeugen
  und dadurch spaeter echte Zeilen dauerhaft und stillschweigend ueberspringen kann - Datenverlust
  auf einer 7-TB-Tabelle waere die Folge gewesen).
- **`sqm_ArchiveMonthLog`**: neue Spalten `LastKeyProcessed1`..`LastKeyProcessed4` (Fortsetzpunkt als
  Tupel), additiv per idempotentem `ALTER TABLE ... ADD` nachgezogen (alte Einzelspalte
  `LastKeyProcessed` bleibt unbenutzt erhalten). Der Upgrade-Pfad war fuer diese Session nicht
  optional - DEV01s Testdatenbank hatte das alte Schema bereits aus frueheren Tests deployed.
- **`Show-sqmPartitionToolGui`**: neues optionales "Key Column(s)"-Feld in Schritt 6 (nur bei
  "Migrate to archive database now" aktiv, leer = automatische Ableitung). Zusaetzlich zwei
  Klarstellungen aus demselben Bug-Report: ein erklaerender Hinweistext erscheint, wenn "Migrate
  now" aktiv ist ("Automated maintenance for the archive copy is registered automatically...") -
  vorher wurde der Wartungsbereich kommentarlos ausgegraut; und die verschachtelte "Copy to an
  archive database before removal"-Checkbox wurde umformuliert ("When partitions expire later, move
  their data to an archive database first...") plus Tooltip, um klarzustellen, dass sie sich auf die
  ANDERE, laufende automatisierte Retention bezieht - nicht auf die sofortige Migration oben.
- Live gegen DEV01 verifiziert: eigens gebaute Testtabelle mit echtem 4-spaltigem zusammengesetzten
  Schluessel (keine Teilmenge der 4 Spalten fuer sich allein eindeutig, um das
  Maximum-pro-Spalte-Risiko gezielt zu pruefen), `-BatchSize 137` erzwingt ~4-6 Batches pro Monat -
  2000/2000 Zeilen archiviert, Quelle/Archiv-Checksummen identisch, keine doppelten/ausgelassenen
  Zeilen, Fortsetzpunkt-Tupel im Log plausibel je Monat fortgeschrieben. Sowohl mit explizitem
  `-KeyColumn` als auch mit automatischer Ableitung getestet. Regressionstest mit einer
  Einzelspalten-IDENTITY-Tabelle (unveraendertes Verhalten) bestanden.
  **Bekannte, separate Einschraenkung** (nicht Teil dieser Aenderung, live gegen die echte
  `CORO_DB.dbo.CARCHIVE`-Tabelle entdeckt): `-DateColumn` wird intern als echter DATE/DATETIME-Typ
  behandelt (Cast + DATE-typisierte Batch-Parameter) - eine als `INT` im Format YYYYMMDD
  gespeicherte Datumsspalte (wie `CARCHIVE.VTDAT`) wird dadurch NICHT unterstuetzt
  ("date ist inkompatibel mit int"). Diese Einschraenkung bestand bereits vor dieser Aenderung und
  ist kein Teil des Zusammengesetzte-Schluessel-Fixes - separat zu adressieren, falls benoetigt.

## [1.6.2.0] — 2026-07-05

### `Invoke-sqmTableArchiveMigration`: Cutover zur Archiv-View + GUI "Migrate now"

Show Stopper aus Live-Test: die GUI konfigurierte mit gesetzter "Archive Database" bisher nur eine
SPAETERE, automatisierte Retention (einzelne, abgelaufene Partitionen wandern erst nach Ablauf ihrer
Retention-Frist ins Archiv) - die Quelltabelle wurde dabei sofort in-place partitioniert und blieb
dort. Kundenanforderung war stattdessen ein sofortiger, vollstaendiger Umzug: Kopie + Partitionierung
in der Archiv-DB, Datenuebertragung per bestehender MERGE-Prozedur, Fortsetzpunkt-Tracking in der
Quelldatenbank, abschliessend Umbenennen der Quelltabelle + Kompatibilitaets-View unter dem alten
Namen auf die Archiv-Kopie - genau das bereits bei `Invoke-sqmTableRelocation` etablierte Cutover-
Muster, jetzt auch fuer den monatsweisen, partitionierten Archiv-Pfad.

- **`Invoke-sqmTableArchiveMigration`**: neue Schalter `-CutoverToArchiveView` und
  `-RenamedTableSuffix` (Standard `_Original`, gleiche Konvention wie `Invoke-sqmTableRelocation`).
  Sobald alle angeforderten Monate (`-StartPeriod`..`-EndPeriod`) archiviert sind (egal ob in
  diesem oder einem frueheren Aufruf), wird die Quelltabelle umbenannt (bleibt vollstaendig
  erhalten, kein automatisches Drop) und unter ihrem alten Namen durch eine View auf die
  partitionierte Archiv-Kopie ersetzt - bestehender Anwendungscode laeuft unveraendert weiter.
  Idempotent (Cutover wird uebersprungen, wenn die umbenannte Tabelle schon existiert) und ueber
  `-WhatIf`/`-Confirm` absicherbar. Der laufende, noch offene Monat wird nie automatisch migriert
  und bleibt daher als Restbestand in der umbenannten Tabelle zurueck - wird explizit im Log
  ausgewiesen, damit der Admin ihn vor dem Loeschen pruefen/nachziehen kann. Rueckgabeobjekt um
  `CutoverPerformed` erweitert.
- **`Show-sqmPartitionToolGui`**: neue Checkbox "Migrate to archive database now" in Schritt 6 -
  exklusiv zur bestehenden "spaetere automatisierte Retention"-Option (beide schliessen sich fuer
  einen Wizard-Durchlauf gegenseitig aus). Ruft in Schritt 7 `Invoke-sqmTableArchiveMigration` mit
  `-PurgeSourceAfterArchive -CutoverToArchiveView` auf statt `Invoke-sqmTablePartitionConversion` +
  `Register-sqmPartitionTable`. `-KeyColumn` wird nicht separat abgefragt - automatische Ableitung
  aus einem einspaltigen Clustered Index/PK wie bisher; bei zusammengesetztem Schluessel/Heap
  bricht die Funktion mit einer klaren Fehlermeldung ab.
- Live gegen echten SQL Server getestet (DEV01) - dabei zwei Faelle gefunden und behoben, die beim
  reinen Code-Review nicht aufgefallen waeren: (1) ein bereits (per `-PurgeSourceAfterArchive`)
  vollstaendig geleerter Quelltabellen-Folgeaufruf schlug bisher schon beim Lesen des
  Quellwertebereichs fehl ("Tabelle ist leer"), obwohl genau das der Fall ist, in dem
  `-CutoverToArchiveView` sinnvoll nachgeholt werden soll - Start/EndPeriod werden jetzt aus
  `dbo.sqm_ArchiveMonthLog` abgeleitet, wenn die Quelle leer, aber bereits Historie vorhanden ist.
  (2) ein erneuter Aufruf NACH bereits erfolgtem Cutover scheiterte mit einer irrefuehrenden
  "-KeyColumn ist Pflicht"-Meldung (die Quelltabelle ist jetzt ja eine View ohne Clustered Index) -
  wird jetzt ganz am Anfang erkannt und als sauberes No-Op ("bereits abgeschlossen") behandelt.

## [1.6.1.0] — 2026-07-05

### `Show-sqmPartitionToolGui`: SQL Server Authentication + Zertifikatsvertrauen

Show Stopper aus Live-Test gegen einen Workgroup-Rechner (kein Domaenen-Trust, nur SQL-Logins
konfiguriert): die GUI unterstuetzte in Schritt 0 ("Verbindung") ausschliesslich Windows-
Authentifizierung - kein Login/Passwort-Feld, kein Weg, sich per SQL-Auth zu verbinden.

- Neue Felder in Schritt 0: Windows/SQL Server Authentication (Radiobuttons) + Login/Passwort
  (nur bei SQL-Auth aktiv). `$script:connParams['SqlCredential']` wird daraus gebaut und von
  ALLEN folgenden Schritten wiederverwendet (Tabellen-/Spaltenauswahl, Boundary-Vorschau,
  Ausfuehrung) - unveraendertes, bereits bewaehrtes Splat-Muster.
- **Zusaetzlicher, beim Testen gefundener Bug**: der `Get-DbaDatabase`-Aufruf in Schritt 0 (rohe
  Instanz als String) schlaegt bei einem selbst signierten Zertifikat (Normalfall bei einer
  frischen SQL-Server-Installation) NICHT mit einer Exception fehl, sondern loggt nur eine
  Warnung und liefert STILLSCHWEIGEND 0 Datenbanken zurueck - in der GUI waere das faelschlich als
  "0 database(s) found (OK)" erschienen, ohne dass der eigentliche Fehler sichtbar wird. Fix: nur
  fuer diesen einen Aufruf explizit ueber `Connect-DbaInstance -TrustServerCertificate` verbinden
  und das Ergebnisobjekt fuer `Get-DbaDatabase` verwenden (NICHT an spaetere Schritte
  weitergereicht - ein verbundenes Objekt mit abweichender `-Database` an eine andere Funktion
  weiterzugeben fiel bei Tests unerwartet auf Windows-Auth zurueck; der rohe Instanzname +
  `-SqlCredential`, den alle sqmPartitionTool-Funktionen selbst nutzen, braucht das nicht und
  funktioniert bereits klaglos mit einem selbst signierten Zertifikat).

## [1.6.0.0] — 2026-07-05

### Speicherplatz-schonende, segmentweise Migration (Quellenbereinigung + Shrink)

Kundenanfrage: auf SAN/Datentraegern mit wenig freiem Platz wird der Platz waehrend einer
Migration immer knapper, weil Quelle und Kopie gleichzeitig Platz brauchen und bisher erst nach
vollstaendigem Abschluss irgendetwas freigegeben werden konnte. Zwei unabhaengige, rein additive
Erweiterungen (Standardverhalten unveraendert):

- **`Invoke-sqmTableArchiveMigration`**: neue Schalter `-PurgeSourceAfterArchive` (loescht nach
  jedem als abgeschlossen bestaetigten Monat dessen Zeilen aus der Quelltabelle - erst nach einer
  Row-Count-Gegenpruefung gegen `dbo.sqm_ArchiveMonthLog`, in Batches wie der bestehende
  MERGE-Batch-Mechanismus), `-ShrinkAfterEveryNPeriods` und `-AggressiveShrink`. Keine Aenderung
  an `sqm_ArchiveMonthBatch.proc.sql` noetig - der Purge laeuft komplett in PowerShell nach dem
  Prozeduraufruf, mit derselben Monatsgrenze wie die MERGE.
- **`Invoke-sqmTablePartitionConversion`**: neues `-Method BatchedSwap` (zusaetzlich zu
  `Default`/`NewTableSwap`) fuer sehr grosse Tabellen ohne separate Archiv-Datenbank - baut eine
  neue, leere partitionierte Kopie und verschiebt die Daten segmentweise (je Boundary-Periode,
  weiter unterteilt in `-BatchSize`) per atomarem `DELETE ... OUTPUT ... INTO` (Quelle und Ziel in
  derselben Datenbank - kein separater Verify-Schritt noetig, im Unterschied zur
  archiv-datenbank-uebergreifenden Variante oben). Gilt fuer Heap UND indizierte/PK-Tabellen
  (bisheriges `NewTableSwap` nur fuer Heaps). Optional `-DataCompression` und periodisches
  Shrinken (`-ShrinkAfterEveryNSegments`/`-AggressiveShrink`) der Quelltabelle, waehrend sie sich
  leert. Abschliessend `sp_rename`-Swap (alte, jetzt leere Tabelle -> `..._sqmPartOld`, neue
  Tabelle -> Originalname) - Quelle wird wie bei `NewTableSwap` nie automatisch geloescht.
  **V1-Einschraenkung**: bricht mit Fehler ab, wenn die Tabelle eingehende Fremdschluessel oder
  Trigger hat (fuer diese Faelle weiterhin `-Method Default`/`NewTableSwap` verwenden) -
  automatische FK-/Trigger-/Berechtigungs-Uebernahme ist bewusst nicht Teil dieser Version.
- Neue private Hilfsfunktion `Get-sqmTableDefinitionSql` (Spalten-/Index-/PK-DDL-Rekonstruktion),
  extrahiert aus der bisher inline duplizierten Logik in `Invoke-sqmPartitionArchive.ps1`
  (Verhalten dort unveraendert, jetzt nur wiederverwendet statt dupliziert).
- Neue private Hilfsfunktion `Invoke-sqmFileSpaceShrink` (gemeinsam von beiden Features
  verwendet): standardmaessig `DBCC SHRINKFILE(..., TRUNCATEONLY)` (schnell, keine
  Seitenverschiebung/Fragmentierung, gibt nur am Dateiende freien Platz zurueck), mit
  `-Aggressive` (`-AggressiveShrink` auf den aufrufenden Funktionen) stattdessen ein voller Shrink
  (mehr Platzgewinn, fragmentiert die verbleibenden Indizes - Rebuild danach empfohlen).

## [1.5.1.0] — 2026-07-05

### `-DataCompression` und `-ConfirmArchiveTable` fuer `Invoke-sqmTableArchiveMigration` / `Invoke-sqmPartitionArchive`

Kundenanfrage: manche Kunden bestehen auf eine bestimmte Kompressionseinstellung fuer
Archiv-Tabellen, und ein Admin soll die leere Archiv-Tabelle vor dem eigentlichen
Partitionieren/Daten-Kopieren pruefen koennen, statt dass der Ablauf ohne Zwischenstopp
durchlaeuft.

- **`-DataCompression`** (`None`/`Row`/`Page`, Standard `None`) auf beiden Funktionen. Wird nur
  angewendet, wenn die Archiv-Tabelle in diesem Aufruf NEU angelegt wird - `SELECT INTO` kennt
  keine Kompressions-Klausel, daher als separates `ALTER TABLE ... REBUILD` danach:
  - `Invoke-sqmTableArchiveMigration`: `REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = ...)`
    NACH der Partitionierung (gilt fuer alle Partitionen).
  - `Invoke-sqmPartitionArchive`: `REBUILD WITH (DATA_COMPRESSION = ...)` direkt nach dem
    `SELECT INTO` (die Archiv-Tabelle hier ist nicht partitioniert).
- **`-ConfirmArchiveTable`** (Switch, Standard aus) auf beiden Funktionen. Pausiert per
  `Read-Host` NACH dem Anlegen der leeren Archiv-Tabelle, BEVOR mit Partitionierung
  (`Invoke-sqmTableArchiveMigration`) bzw. dem Kopieren der Partitionsdaten
  (`Invoke-sqmPartitionArchive`) fortgefahren wird. Bei Ablehnung: sauberer Abbruch, nichts geht
  verloren (bei `Invoke-sqmPartitionArchive` ist die Partition zu diesem Zeitpunkt bereits per
  SWITCH in die Staging-Tabelle verschoben und bleibt dort bis zur manuellen Pruefung).
- Beide Parameter sind rein additiv (Standardwerte = bisheriges Verhalten unveraendert) - keine
  Breaking Changes fuer bestehende Aufrufe/Jobs.
- **Hinweis**: keine vorhandene "Handvoll-Datensaetze"-Testfunktion in diesem Modul gefunden
  (Recherche vor der Umsetzung) - falls das anderswo existiert, war es nicht Teil dieses Moduls.

## [1.5.0.0] — 2026-07-04

### Neue Funktion: `Invoke-sqmTableArchiveMigration`

Ergaenzung fuer den Fall, dass eine noch nicht partitionierte, weiterhin aktive Tabelle NICHT
in der eigentlichen Datenbank partitioniert werden soll (dafuer bleibt
`Invoke-sqmTablePartitionConversion` zustaendig), sondern schrittweise als partitionierte Kopie
in eine separate, vom Admin bereits angelegte Archiv-Datenbank ueberfuehrt wird - monatsweise
(YYYYMM) per T-SQL `MERGE`, ohne die Quelltabelle anzufassen oder zu loeschen:

- Legt bei Bedarf eine leere Strukturkopie der Tabelle in der Archiv-Datenbank an und
  partitioniert sie ueber die bestehende `Invoke-sqmTablePartitionConversion`-Logik
  (`-ManualStartValue`/`-ManualEndValue` aus dem tatsaechlichen Wertebereich der Quelle, da die
  Kopie selbst leer ist) - keine Duplizierung der Partitionierungslogik.
- Neue, eigene Infrastruktur **in der Quelldatenbank** (bewusst nicht in `master`, da an ein
  einzelnes Migrationsprojekt gebunden): `dbo.sqm_ArchiveMonthLog` (Fortschritts-Log, eine Zeile
  je Monat mit Fortsetzpunkt `LastKeyProcessed`) und `dbo.sqm_ArchiveMonthBatch` (Batch-Prozedur,
  `MERGE` mit `WHEN MATCHED THEN UPDATE` / `WHEN NOT MATCHED THEN INSERT`). Neuer, eigener
  Installer `Install-sqmArchiveMigrationInfra` (liest `sql\archive\*.sql`, deployed nach
  `-Database` statt `master` - getrennt vom bestehenden `Install-sqmPartitionMaintenanceProcs`,
  das ausschliesslich `master` bedient).
- Jeder Batch-Aufruf ist durch `MERGE` beliebig oft wiederholbar (keine Duplikate, auch nicht bei
  bereits archivierten, seither in der Quelle geaenderten Zeilen). Der Fortsetzpunkt liegt
  dauerhaft in `sqm_ArchiveMonthLog`, nicht im Funktionsaufruf - ein Abbruch an beliebiger Stelle
  (Netzwerk, Prozess-Kill) verliert nichts, ein erneuter Aufruf setzt exakt dort fort.
- Der laufende (noch "offene") Kalendermonat wird standardmaessig NICHT migriert
  (`-EndPeriod`-Default: Vormonat), um zu vermeiden, dass ein Monat als "abgeschlossen" geloggt
  wird, waehrend die Quelle darin noch aktiv schreibt.
- Loeschen der Quelldaten ist bewusst NICHT Teil dieser Funktion - das bleibt eine spaetere,
  manuelle Admin-Entscheidung nach vollstaendigem Abschluss der Migration.

## [1.4.1.0] — 2026-07-04

### Text-Support für YYYYMMDD-Format (DEV03-Seitig, spaeter durch [1.4.0.0]/DEV02 ersetzt)

- **`Get-sqmPartitionBoundaryList`**: Neuer BoundaryType `Text` für VARCHAR/NVARCHAR-Spalten mit
  YYYYMMDD-String-Format (z.B. '20240115'). Liefert Boundaries als Strings statt als Int/DateTime.
- **`Invoke-sqmTablePartitionConversion`**: Validierung und automatische Typ-Erkennung erweitert
  (varchar/nvarchar -> BoundaryType 'Text'). Warnung, wenn BoundaryType nicht zum Spaltentyp passt.
- **`Register-sqmPartitionTable`**: BoundaryType-Parameter aktualisiert.
- **Alle Funktionen**: Vollständig getestet auf DEV03 mit Text/Int/Date-Beispielen.
- Unabhaengig von [1.4.0.0] (DEV02) entstanden, bevor beide Aenderungsstraenge zusammengefuehrt
  wurden (siehe [1.7.0.0]) - deckte nur YYYYMMDD ab, kein konfigurierbares `-SurrogateDateFormat`.

## [1.4.0.0] — 2026-07-03

### Varchar-Surrogatschluessel (BoundaryType 'Text') + konfigurierbares yyyyMM-Format

- Bisher deckte `BoundaryType 'Int'` nur numerische YYYYMMDD-Surrogatschluessel ab. Manche Projekte
  fuehren dasselbe Datumsformat aber als `char`/`varchar`-Spalte, und/oder nur auf Monatsebene
  (YYYYMM statt YYYYMMDD). Beides wird jetzt unterstuetzt:
  - Neuer `BoundaryType`-Wert `'Text'` (zusaetzlich zu `'Date'`/`'Int'`) fuer
    `char`/`varchar`/`nchar`/`nvarchar`-Surrogatschluessel.
  - Neuer Parameter `-SurrogateDateFormat` (`'yyyyMMdd'` Standard oder `'yyyyMM'`) fuer
    `Get-sqmPartitionBoundaryList`, `Invoke-sqmTablePartitionConversion` und
    `Register-sqmPartitionTable` - steuert, ob der Surrogatschluessel Tages- oder nur
    Monatsgenauigkeit hat.
  - `Invoke-sqmTablePartitionConversion` erkennt `BoundaryType` weiterhin automatisch aus dem
    Spaltentyp, wenn nicht angegeben: Datumstypen -> `Date`, `int`/`bigint`/`smallint`/`tinyint` ->
    `Int`, `char`/`varchar`/`nchar`/`nvarchar` -> `Text`. Der `SqlDataType`, der in die
    `CREATE PARTITION FUNCTION`-DDL einfliesst, wird fuer Text-Typen jetzt mit der tatsaechlichen
    Spaltenlaenge gebildet (z.B. `varchar(6)`), vorher waere ein unlaengenspezifiziertes `varchar`
    (implizit `varchar(1)`) verwendet worden.
  - `New-sqmPartitionSchemeSet` quotet `[string]`-Boundary-Werte jetzt als `N'...'`-Literale in der
    `CREATE PARTITION FUNCTION ... VALUES (...)`-DDL.
  - `sqm_ExtendPartitionWindow` (T-SQL-Wartungsprozedur): liest `SurrogateDateFormat` jetzt aus der
    Registry und parst/erzeugt Boundary-Werte format- und typabhaengig (yyyyMM hat keinen passenden
    `CONVERT`-Style und wird manuell aus Jahr/Monat zusammengesetzt; `Text`-Literale werden gequotet,
    `Int`-Literale nicht).
  - `Invoke-sqmPartitionRetentionSweep.ps1` (Retention-Job): der Cutoff-Vergleich castete den rohen
    Boundary-Wert bisher blind als `[datetime]` - das war fuer `BoundaryType 'Date'` korrekt, fuer
    `'Int'`/`'Text'` aber ein Fehlcast (ein Wert wie `20240115` als `[datetime]` interpretiert landet
    als OLE-Automation-Datumsserial, nicht als 15.01.2024). Parst jetzt formatabhaengig ueber
    `[datetime]::ParseExact`.
  - `Invoke-sqmPartitionArchive` (`MERGE RANGE`-DDL): `[string]`-Boundary-Werte werden jetzt als
    `N'...'`-Literal gequotet statt sich auf implizite int->varchar-Konvertierung zu verlassen.
  - `Show-sqmPartitionToolGui`: Schritt 4 (Granularitaet) zeigt bei Nicht-Datumsspalten zusaetzlich
    eine `Surrogate Date Format`-Auswahl (`yyyyMMdd`/`yyyyMM`).
  - `sqm_PartitionRegistry`: neue Spalte `SurrogateDateFormat` (mit `ALTER TABLE ... ADD`-
    Migrationspfad fuer bereits bestehende Installationen).
- Auf DEV02 end-to-end verifiziert: je eine Testtabelle mit `varchar(6)`-Spalte (`BoundaryType Text`)
  und `int`-Spalte (`BoundaryType Int`), beide im `yyyyMM`-Format - vollstaendiger Zyklus
  Konvertierung -> `sqm_ExtendPartitionWindow` (inkl. Idempotenz-Rerun) -> Retention-Sweep
  (`Invoke-sqmPartitionRetentionSweep.ps1`) lief in beiden Faellen fehlerfrei durch, Boundary-Werte
  und retirierte Partitionen wurden stichprobenartig gegen `sys.partition_range_values` geprueft.

## [1.3.0.0] — 2026-07-03

### GUI auf Englisch umgestellt

- **`Show-sqmPartitionToolGui`**: Alle sichtbaren GUI-Texte (Schritt-Titel, Fenstertitel,
  Feldbeschriftungen, Buttons, Grid-Spaltenkoepfe, Statusmeldungen, Bestaetigungs-/Fehler-Dialoge)
  von Deutsch auf Englisch umgestellt - der fruehere "de-DE statt en-US"-Fix (1.2.1.0) betraf nur
  Zahlen-/Datumsformatierung, nicht die eigentliche GUI-Sprache. Code-Kommentare und
  `Invoke-sqmLogging`-Meldungen bleiben bewusst Deutsch (konsistent mit dem restlichen Projekt -
  nur die sichtbare Oberflaeche wurde umgestellt).
- Interne Spalten-`Name`-Bezeichner (fuer `$row.Cells['...']`-Zugriffe im Code) unveraendert
  gelassen, nur die angezeigten `HeaderText`-Werte uebersetzt - keine Logik-Aenderung noetig.
  Zellwerte, die als Vergleichswerte im Code verwendet werden (z.B. Status "already partitioned"
  statt "bereits partitioniert", Kompatibel-Spalte "Yes" statt "Ja"), wurden konsistent an beiden
  Stellen (Anzeige UND Vergleich) angepasst.
- Auf DEV02 interaktiv durchgeklickt (Verbindung -> Tabelle waehlen -> Zusammenfassung): alle
  Texte korrekt Englisch, Dezimalwerte weiterhin mit Punkt (z.B. "0.42" MB).

## [1.2.1.0] — 2026-07-03

### Fixes nach weiterem Feedback

- **`sqmSQLTool.psd1` Mindestversion erzwungen**: `RequiredModules` verlangt jetzt explizit
  `sqmSQLTool >= 1.9.2.0` (die Version, in der `Get-sqmSaLogin` exportiert wurde, das
  `New-sqmPartitionExtendJob`/`-RetentionJob` benoetigen). Vorher wurde eine aeltere, bereits
  installierte sqmSQLTool-Version klaglos geladen und der Fehler erst spaeter mit einer
  verwirrenden "Get-sqmSaLogin nicht erkannt"-Meldung sichtbar (Ursache des zuvor gemeldeten
  "Schritt 2 zeigt keine Tabellen"-Falls). `Install.ps1` prueft die installierte
  sqmSQLTool-Version jetzt zusaetzlich explizit und warnt mit klarer Anleitung, falls sie zu alt
  ist.
- **Fix `Show-sqmPartitionToolGui`**: `SizeMB` (Dezimalwert) wurde direkt an die
  Tabellen-Auswahl-Grid uebergeben - .NET rendert `[decimal]`-Werte ohne explizite Formatierung
  mit dem Dezimaltrennzeichen der Thread-Culture, unter de-DE also mit Komma statt Punkt (z.B.
  "12,34" statt "12.34"), obwohl die restliche GUI-Anzeige unzweideutig sein sollte.
  `_FormatDisplayValue` formatiert jetzt auch Dezimalwerte explizit mit `InvariantCulture`, nicht
  nur Datumswerte wie zuvor. Verifiziert: unter simulierter de-DE-Culture liefert
  `(12.34).ToString()` weiterhin "12,34", der Fix liefert korrekt "12.34".

## [1.2.0.0] — 2026-07-03

### Neue Funktion: `Invoke-sqmTableRelocation`

Ergaenzung nach Feedback zur bestehenden Archiv-Funktionalitaet: `Invoke-sqmPartitionArchive`
verschiebt fortlaufend nur ABGELAUFENE PARTITIONEN einer weiterhin aktiven, partitionierten
Tabelle. Fuer die einmalige, vollstaendige Auslagerung einer kompletten (typischerweise sehr
grossen) Tabelle in eine separate Datenbank gibt es jetzt `Invoke-sqmTableRelocation`:

- Batchweise, NICHT-destruktive Kopie (Quelltabelle bleibt bis zum Abschluss vollstaendig
  unveraendert bestehen, jeder Batch eine eigene kleine Transaktion - Transaktionslog waechst
  nicht unkontrolliert).
- Fortsetzbar/resumable: liest bei jedem Aufruf den tatsaechlichen Fortschritt (MAX der
  Schluesselspalte im Ziel) und macht dort weiter - `-MaxDurationMinutes` erlaubt die gezielte
  Aufteilung sehr grosser Tabellen auf mehrere Wartungsfenster.
- Cutover erst nach vollstaendigem, verifiziertem Zeilenzahl-Abgleich: Original-Tabelle wird
  umbenannt (Sicherheitsnetz, bleibt vollstaendig erhalten), danach ein View mit dem
  urspruenglichen Tabellennamen angelegt, der per Cross-DB-Query auf die Zieltabelle zeigt -
  bestehende Abfragen/Reports laufen unveraendert weiter.
- Auf DEV02 verifiziert: 275 Zeilen in Batches von 100 verschoben, View liefert transparent
  dieselben Daten, umbenannte Original-Tabelle bleibt vollstaendig unangetastet (275 Zeilen).
- Zwei Bugs waehrend der Tests gefunden und behoben: (1) `MAX()` ueber eine leere Zieltabelle
  liefert `[System.DBNull]::Value`, nicht PowerShells `$null` - ohne Sonderbehandlung entstand
  eine leere, syntaktisch ungueltige `WHERE`-Klausel (`WHERE [Id] > `). (2) Einzeiliges
  `Invoke-DbaQuery`-Ergebnis ist ein einzelnes `System.Data.DataRow`-Objekt statt eines Arrays -
  `$result[0]` ruft dann DataRows EIGENEN Spalten-Indexer auf (liefert den Wert der ersten Spalte
  statt des Objekts selbst); `.ColumnName` darauf lieferte lautlos `$null` statt eines Fehlers.
  Fix: Ergebnis explizit mit `@(...)` in Array-Kontext zwingen vor dem Indizieren.

## [1.1.1.0] — 2026-07-03

### Feedback nach GUI-Review umgesetzt

- **Fix `Show-sqmPartitionToolGui`**: Datumswerte (Min/Max-Vorschau, Boundary-Vorschau) wurden mit
  dem Standard-`ToString()` angezeigt, dessen Format von der Session-/System-Culture abhaengt
  (z.B. `06/16/2026` im en-US-Stil vs. `16.06.2026` im de-DE-Stil) - beim Durchklicken dieser
  Session tatsaechlich einmal falsch gelesen worden (verwechselt mit einem anderen Datum). Neue
  `_FormatDisplayValue`-Hilfsfunktion zeigt Datumswerte jetzt immer unzweideutig als
  `yyyy-MM-dd` (invariante Culture) an.
- **Erweiterung `Invoke-sqmPartitionArchive`**: `-ArchiveBatchSize` war bisher ein
  wirkungsloser Parameter - die Archiv-Kopie lief immer als einzelne `INSERT...SELECT` in einer
  Transaktion (Risiko bei sehr grossen Partitionen: Transaktionslog-Wachstum, lange Sperren,
  Timeouts). Kopiert jetzt in Batches (`DELETE TOP (@BatchSize) ... OUTPUT INTO`, je eine eigene
  Transaktion), sobald die Partition mehr Zeilen als `-ArchiveBatchSize` enthaelt. Auf DEV02
  verifiziert (31 Zeilen, ArchiveBatchSize=15 -> 3 Batches, alle Zeilen inkl. IDENTITY-Werte
  korrekt uebernommen).

## [1.1.0.0] — 2026-07-03

### GUI-Wizard gebaut, kritischer Quarter-Boundary-Bug gefunden und behoben

- `Public/Show-sqmPartitionToolGui.ps1` - neuer 8-Schritte-Assistent (Verbindung -> Tabelle ->
  Spalte -> Min/Max -> Granularitaet/Filegroups -> Boundary-Vorschau -> Archiv/Retention ->
  Zusammenfassung/Ausfuehren), reiner Wrapper um bestehende Core-Funktionen, Dark-Theme
  identisch zu `Show-sqmBackupExcludeForm` (sqmSQLTool). Interaktiv auf DEV02 durchgeklickt.
- **Kritischer Fix `Get-sqmPartitionBoundaryList`**: `Granularity Quarter` berechnete beim
  Durchklicken der GUI (Schritt 6, Boundary-Vorschau) falsche Quartals-Grenzen - beim
  Testtabelle-Datum 16.06.2026 (Q2) wurde die erste Zukunfts-Puffer-Periode faelschlich erst bei
  Q4/2026 statt Q3/2026 markiert. Ursache: `[int](($date.Month - 1) / 3)` - PowerShells `/` ist
  IMMER Fliesskomma-Division (anders als in T-SQL/C mit int-Operanden) und `[int]`-Cast RUNDET
  (statt abzuschneiden), z.B. `[int](5/3)` ergibt `2`, nicht `1`. Betraf die letzten Monate jedes
  Quartals (Maerz/Juni/September/Dezember) - bei Dezember waere sogar Monat 13 entstanden
  (`[datetime]::new(...,13,1)` wirft eine Exception). Fix: `[math]::Floor(($date.Month-1)/3.0)`
  statt `[int](...)`. Betraf `_PeriodStart` UND `_PeriodLabel` (beide Male derselbe Fehler).
  Verifiziert: urspruenglicher Fall (16.06.2026) liefert jetzt korrekt Q3/2026 als ersten
  Puffer, Dezember-Randfall (vorher potenzielle Exception) laeuft jetzt fehlerfrei durch.
  **Hinweis**: bereits durchgefuehrte Konvertierungen in dieser Session (TestOrdersPK,
  TestOrdersHeap) nutzten `Granularity Month`, nicht `Quarter` - nicht vom Bug betroffen, keine
  Nacharbeit noetig.
- **Zweiter kritischer Fix `Get-sqmPartitionStatus`**: die Spalte `LowerBoundaryValue` enthielt
  tatsaechlich die OBERE Grenze jeder Partition (SQL-Join `prv.boundary_id = p.partition_number`
  statt `p.partition_number - 1`) - Partition 1 zeigte faelschlich einen Wert statt NULL/
  unendlich. `Invoke-sqmPartitionArchive`s `MERGE RANGE` nutzte diese Spalte fuer den
  Boundary-Wert und funktionierte nur zufaellig richtig, weil der (falsch benannte) Wert
  tatsaechlich der fuer MERGE RANGE benoetigte war. Die Retention-Sweep-Logik
  (`Invoke-sqmPartitionRetentionSweep.ps1`) las dagegen `$status[i+1].LowerBoundaryValue` in der
  Annahme korrekter Semantik - mit der fehlerhaften Spalte ein Boundary zu weit, was bei knapp an
  einer Periodengrenze liegenden Cutoffs zu falschen Retire-Entscheidungen fuehren konnte (durch
  den grosszuegigen Testabstand in den bisherigen Tests dieser Session nicht sichtbar geworden).
  Fix: `Get-sqmPartitionStatus` liefert jetzt explizit sowohl `LowerBoundaryValue` (echte untere
  Grenze, NULL bei Partition 1) als auch `UpperBoundaryValue` (echte obere Grenze, NULL bei der
  letzten/Zukunfts-Partition) als eigene Spalten - kein Aufrufer muss mehr ueber Nachbar-Zeilen
  ruckschliessen. `Invoke-sqmPartitionArchive` nutzt jetzt `UpperBoundaryValue` fuer MERGE RANGE,
  die Retention-Sweep nutzt `$oldest.UpperBoundaryValue` direkt. Verifiziert auf DEV02: korrekte
  Grenzen fuer alle 14 Partitionen (Partition 1 zeigt jetzt korrekt KEINE untere Grenze), Retire
  von Partition 2 verschmilzt die richtige Boundary (269 von 300 Zeilen korrekt erhalten).

### Wartungs-Jobs implementiert

- `sql/sqm_ExtendPartitionWindow.proc.sql` - instanzweite Prozedur, erweitert das Sliding
  Window aller aktiven Registry-Eintraege (nur FilegroupStrategy 'Single' automatisch,
  siehe Kommentar in der Datei). Fix: `EXEC()` akzeptiert keinen Ausdruck, der `QUOTENAME()`
  direkt per String-Verkettung einbindet (Syntaxfehler trotz gueltigem Ausdruck bei SELECT) -
  muss erst in eine Variable geschrieben werden. Fix: Off-by-one - die naechste zu ergaenzende
  Periode liegt eine Periode NACH dem vorhandenen Max-Boundary, nicht bei ihm selbst (sonst
  "doppelte Bereichsbegrenzungswerte"). Auf DEV02 verifiziert (28 Boundaries hinzugefuegt,
  zweiter Lauf korrekt No-Op).
- `jobs/Invoke-sqmPartitionRetentionSweep.ps1` - PowerShell-Skript (bewusst keine T-SQL-Prozedur,
  siehe Kommentar in der Datei) fuer die woechentliche Retention/Archivierung, nutzt das bereits
  getestete `Invoke-sqmPartitionArchive`. Fix: `Where-Object { $_.RetentionValue }` allein filtert
  NULL-Werte (kommen aus SQL Server als `[DBNull]::Value` zurueck) nicht heraus - explizit auf
  `-isnot [System.DBNull]` pruefen. Fix: Partitionsnummern verschieben sich nach jedem MERGE RANGE
  (alle nachfolgenden Partitionen ruecken eine Nummer runter) - eine vorab geplante Liste von
  PartitionNumber-Werten wird nach der ersten Entfernung ungueltig; Status wird jetzt jede
  Iteration neu gelesen. Auf DEV02 verifiziert (13 Partitionen entfernt, alle 2000
  Original-Zeilen korrekt im Archiv wiedergefunden).
- `Public/New-sqmPartitionExtendJob.ps1`, `Public/New-sqmPartitionRetentionJob.ps1` - legen die
  zwei instanzweiten SQL-Agent-Jobs an (taeglich/woechentlich), `-Update`-Schalter idempotent.
  Auf DEV02 verifiziert (Create/AlreadyExists/Update fuer beide Jobs).
- Export `Get-sqmSaLogin` aus sqmSQLTool ergaenzt (siehe dortiges CHANGELOG 1.9.2.0) - gleiche
  Cross-Module-Sichtbarkeits-Einschraenkung wie bei `Invoke-sqmLogging`.

### Core-Konvertierungsfunktionen abgeschlossen

- `Get-sqmPartitionCandidateTable`, `Get-sqmPartitionColumnCandidate`,
  `Get-sqmPartitionColumnRange`, `Get-sqmPartitionBoundaryList`,
  `Test-sqmPartitionReadiness`, `Test-sqmPartitionIndexAlignment`,
  `New-sqmPartitionFilegroupPlan`, `New-sqmPartitionSchemeSet`,
  `Invoke-sqmTablePartitionConversion`, `Register-sqmPartitionTable`,
  `Get-sqmPartitionRegistry`, `Get-sqmPartitionStatus`,
  `Remove-sqmPartitionRegistration`, `Invoke-sqmPartitionArchive`
  implementiert und auf DEV02 gegen PK- und Heap-Testtabellen verifiziert.
- Fix `Invoke-sqmPartitionArchive`: SWITCH PARTITION schlug mit "kein
  identischer Index" fehl, obwohl Spalten/Eindeutigkeit der Staging-Tabelle
  strukturell identisch waren. Ursache (empirisch per Minimal-Repro
  verifiziert): ist der Quell-Index als PRIMARY KEY/UNIQUE CONSTRAINT
  hinterlegt, verlangt SQL Server auf der Staging-Tabelle ebenfalls einen
  Constraint (nicht nur einen strukturgleichen einfachen Index). Betrifft
  jetzt alle Indizes (nicht nur den Clustered Index) der Quelltabelle.
- Fix `Invoke-sqmPartitionArchive`: IDENTITY-Eigenschaft wurde bei der
  Staging-Tabellen-Erzeugung nicht übernommen (ebenfalls Pflicht für SWITCH
  PARTITION).
- Fix `Invoke-sqmPartitionArchive`: Archiv-Kopie schlug bei IDENTITY-Spalten
  mit "IDENTITY_INSERT"-Fehler fehl - Kopie nutzt jetzt explizite Spaltenliste
  und `SET IDENTITY_INSERT ON/OFF` wenn nötig.
- Fix `Invoke-sqmPartitionArchive`: `Invoke-DbaQuery -ErrorAction Stop` warf
  bei echten SQL-Server-Ausführungsfehlern keine terminierende Exception
  (Ausführung lief mit einer Warnung weiter) - überall zusätzlich
  `-EnableException` ergänzt.
- Fix `Get-sqmPartitionStatus`: ungültige `return foreach (...)`-Syntax.

## [1.0.0.0] — 2026-07-03

### Initiales Projekt

- Modul-Grundgerüst angelegt (psd1/psm1, Public/Private/sql/Docs/jobs/tests-
  Struktur, RequiredModules `dbatools` + `sqmSQLTool`).
- Konzept: `master.dbo.sqm_PartitionRegistry` als zentrale Metadaten-Tabelle
  (eine Zeile pro registrierter Tabelle), zwei instanzweite SQL-Agent-Jobs
  (`sqm_ExtendPartitionWindow`, `sqm_RetirePartitionWindow`) statt Job-pro-
  Tabelle.
- Weitere Funktionalität (Core-Konvertierung, Wartungs-Jobs, GUI-Assistent)
  folgt in nachfolgenden Versionen — siehe Projektplan.
