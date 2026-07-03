# sqmPartitionTool — Changelog

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
