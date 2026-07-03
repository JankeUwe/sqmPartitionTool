# sqmPartitionTool — Changelog

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
