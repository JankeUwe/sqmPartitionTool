# sqmPartitionTool — Admin-Handbuch

Automatische SQL-Server-Tabellen-Partitionierung: Konvertierung bestehender Tabellen,
Sliding-Window-Wartung, Retention/Archivierung alter Partitionen und Migration ganzer Tabellen in
eine separate Archiv-Datenbank — per GUI-Assistent oder vollstaendig per PowerShell/CLI.

Zielgruppe dieses Handbuchs: SQL-Server-DBAs, die das Tool operativ einsetzen (nicht die
Entwicklung des Moduls selbst). Fuer die Versionshistorie siehe [CHANGELOG.md](../CHANGELOG.md),
fuer eine Kurzuebersicht [README.md](../README.md).

---

## Inhalt

1. [Ueberblick: welcher Workflow passt zu meiner Situation?](#1-ueberblick)
2. [Voraussetzungen und Installation](#2-voraussetzungen-und-installation)
3. [Ablaufplan A: Bestehende Tabelle in-place partitionieren](#3-ablaufplan-a-bestehende-tabelle-in-place-partitionieren)
4. [Ablaufplan B: Automatische Wartung einrichten (Sliding-Window + Retention)](#4-ablaufplan-b-automatische-wartung-einrichten)
5. [Ablaufplan C: Tabelle in eine Archiv-Datenbank migrieren (Cutover)](#5-ablaufplan-c-tabelle-in-eine-archiv-datenbank-migrieren)
5a. [Ablaufplan D: Bereits partitionierte Tabelle mit neuer Partitionierung kopieren](#5a-ablaufplan-d-bereits-partitionierte-tabelle-mit-neuer-partitionierung-kopieren)
6. [BoundaryType/SurrogateDateFormat — Referenz](#6-boundarytypesurrogatedateformat--referenz)
7. [GUI-Assistent: Schritt-fuer-Schritt](#7-gui-assistent-schritt-fuer-schritt)
8. [Troubleshooting und bekannte Einschraenkungen](#8-troubleshooting-und-bekannte-einschraenkungen)
9. [Sicherheitshinweise](#9-sicherheitshinweise)

---

## 1. Ueberblick

Das Modul deckt fuenf unterschiedliche, unabhaengig voneinander nutzbare Szenarien ab. Die
Entscheidung, welches passt, haengt davon ab, **wo die Daten am Ende liegen sollen** und **ob die
Tabelle aktiv bleibt**:

| Szenario | Funktion | Quelltabelle danach | Wann sinnvoll |
|---|---|---|---|
| **A** — In-Place-Partitionierung | `Invoke-sqmTablePartitionConversion` | Bleibt in derselben DB, ist jetzt partitioniert | Tabelle soll partitioniert werden, aber in derselben Datenbank bleiben |
| **B1** — Sliding-Window-Erweiterung | `New-sqmPartitionExtendJob` (SQL-Agent-Job) | Unveraendert (nur neue leere Partitionen kommen dazu) | Nach A: automatisch dafuer sorgen, dass nie "die letzte Partition" volllaeuft |
| **B2** — Retention/Archivierung | `New-sqmPartitionRetentionJob` (SQL-Agent-Job) | Alte Partitionen werden geloescht oder vorher archiviert | Nach A: alte Daten nach X Monaten/Jahren automatisch entfernen |
| **C** — Archiv-DB-Migration + Cutover | `Invoke-sqmTableArchiveMigration` | Umbenannt, durch eine View auf die Archiv-DB ersetzt | Ganze Tabelle soll dauerhaft in eine andere (typischerweise kleinere/langsamer angebundene) Datenbank umziehen, Anwendungscode aber unveraendert weiterlaufen |
| **D** — Neu-partitionierte Kopie | `Copy-sqmPartitionedTable` | **Unveraendert, bleibt aktiv** (keine Umbenennung, kein Cutover) | Eine **bereits partitionierte** Tabelle soll zusaetzlich als eigenstaendige Kopie mit **anderer** Granularitaet/Filegroup-Strategie in einer anderen Datenbank existieren (z.B. Reporting-Abzug mit groeberer Granularitaet) |

**Faustregel:** Wenn die Tabelle **in der Quelldatenbank bleiben** soll → A (+ optional B1/B2).
Wenn die Tabelle **komplett in eine andere Datenbank** soll (z.B. Archiv-Instanz, separate
Datenbank mit weniger Backup-/Storage-Anforderungen) → C. Wenn die Quelltabelle **bereits
partitioniert ist** und **parallel** mit einer anderen Partitionierung anderswo weiterexistieren
soll (kein Cutover, keine Umbenennung) → D.

---

## 2. Voraussetzungen und Installation

- PowerShell 5.1 oder hoeher (GUI benoetigt Desktop-CLR/WinForms — unter PowerShell 7 auf Windows
  weiterhin verfuegbar, nicht aber auf PowerShell 7 unter Linux/macOS).
- Module `dbatools` und `sqmSQLTool` (>= 1.9.2.0) muessen installiert sein.
- Ein SQL-Server-Login mit ausreichenden Rechten auf der/den Zieldatenbank(en): `ALTER` auf die
  betroffene(n) Tabelle(n)/Datenbank(en), `CREATE`/`ALTER PROCEDURE`, sowie fuer die
  SQL-Agent-Jobs (Szenario B) Rechte auf `msdb`.
- Fuer Szenario C: die **Ziel-Archivdatenbank muss vom Admin vorher angelegt sein** — das Tool legt
  sie nicht automatisch an (bewusste Entscheidung, da Dateigroessen/-pfade/Recovery-Modell
  admin-spezifisch sind).

```powershell
Import-Module "C:\CCM\SQL-Tools\sqmPartitionTool\sqmPartitionTool.psd1"
```

Verbindung erfolgt wahlweise per Windows-Authentifizierung (Standard) oder SQL Server
Authentifizierung (`-SqlCredential`, auch im GUI-Assistenten in Schritt 0 waehlbar).

---

## 3. Ablaufplan A: Bestehende Tabelle in-place partitionieren

Ziel: eine bestehende, nicht partitionierte Tabelle wird in derselben Datenbank partitioniert.

1. **Pruefen, ob die Tabelle geeignet ist.**
   ```powershell
   Test-sqmPartitionReadiness -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" -PartitionColumn "OrderDate"
   ```
   Meldet u.a., ob ein `-AllowKeyChange` noetig ist (PRIMARY KEY/UNIQUE-Constraint muss um die
   Partitionsspalte erweitert werden) und ob eingehende Fremdschluessel/Trigger vorhanden sind
   (relevant fuer `-Method BatchedSwap`, siehe unten).
2. **Granularitaet und Filegroup-Strategie festlegen** — Month/Quarter/Year, sowie `Single` (eine
   Filegroup fuer alle Partitionen) oder `PerPeriod` (eine eigene Filegroup je Periode — bessere
   I/O-Isolation, mehr Verwaltungsaufwand).
3. **Konvertierung ausfuehren:**
   ```powershell
   Invoke-sqmTablePartitionConversion -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
       -Table "OrderHistory" -PartitionColumn "OrderDate" -Granularity Month `
       -FilegroupStrategy Single -AllowKeyChange
   ```
   Je nach Ausgangslage waehlt die Funktion automatisch die passende Umsetzung:
   - Clustered Index/PK ohne Partitionsspalte im Schluessel → `ALTER TABLE ... DROP/ADD CONSTRAINT`.
   - Clustered Index bereits passend → `CREATE CLUSTERED INDEX ... WITH (DROP_EXISTING=ON)`.
   - Heap → neuer Clustered Index direkt auf dem Partition Scheme, oder `-Method NewTableSwap` fuer
     sehr grosse Heaps.
   - **`-Method BatchedSwap`** (Heap **und** indizierte/PK-Tabellen): fuer sehr grosse Tabellen auf
     Datentraegern mit **wenig freiem Speicherplatz** — baut eine neue, leere partitionierte Kopie
     auf und verschiebt die Daten segmentweise (je Boundary-Periode, weiter unterteilt in
     `-BatchSize`), mit periodischem `DBCC SHRINKFILE` waehrend die alte Tabelle sich leert.
     **Einschraenkung:** bricht mit Fehler ab, wenn die Tabelle eingehende Fremdschluessel oder
     Trigger hat — dafuer `-Method Default`/`NewTableSwap` verwenden.
4. **Ergebnis pruefen:**
   ```powershell
   Get-sqmPartitionStatus -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory"
   ```
5. Die Tabelle wird automatisch in `master.dbo.sqm_PartitionRegistry` registriert (ausser
   `-NoRegister`) — Voraussetzung fuer Szenario B.

---

## 4. Ablaufplan B: Automatische Wartung einrichten

Setzt voraus, dass die Tabelle bereits partitioniert und registriert ist (Ablaufplan A).

1. **Sliding-Window-Erweiterung** (sorgt dafuer, dass immer ein paar Perioden im Voraus als leere
   Partitionen existieren, `-FutureBufferPeriods` aus Ablaufplan A):
   ```powershell
   New-sqmPartitionExtendJob -SqlInstance "SQL01"
   ```
   Legt einen SQL-Agent-Job an, der `sqm_ExtendPartitionWindow` (T-SQL-Prozedur, liest die
   Registry) periodisch ausfuehrt — idempotent, mehrfache Ausfuehrung am selben Tag aendert nichts.
2. **Retention/Archivierung** (entfernt Partitionen, die aelter als die konfigurierte
   Aufbewahrungsfrist sind):
   ```powershell
   Register-sqmPartitionTable -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" `
       -PartitionColumn "OrderDate" -PartitionFunctionName "..." -PartitionSchemeName "..." `
       -Granularity Month -BoundaryType Date -RetentionValue 36 -RetentionUnit Months `
       -ArchiveEnabled -ArchiveDatabaseName "SalesArchive"
   New-sqmPartitionRetentionJob -SqlInstance "SQL01"
   ```
   Mit `-ArchiveEnabled` werden ablaufende Partitionen **vor** dem Entfernen per
   `Invoke-sqmPartitionArchive` in die angegebene Archiv-Datenbank kopiert (SWITCH PARTITION,
   Batch-Kopie, dann `MERGE RANGE`) statt einfach geloescht zu werden. Ohne `-ArchiveEnabled`
   werden abgelaufene Partitionen unwiderruflich geloescht — vorher testen!
3. **Status/Fortschritt pruefen:**
   ```powershell
   Get-sqmPartitionRegistry -SqlInstance "SQL01"
   ```

**Wichtig:** dieser Pfad betrifft **einzelne, nach und nach ablaufende Partitionen** einer
weiterhin aktiven, partitionierten Tabelle — nicht die gesamte Tabelle auf einmal. Fuer eine
sofortige Komplettmigration der ganzen Tabelle siehe Ablaufplan C.

### Ad-hoc statt Job: sofortige Retention fuer eine einzelne Tabelle

`New-sqmPartitionRetentionJob` deckt den Dauerbetrieb ab (woechentlich, alle registrierten
Tabellen). Fuer einen sofortigen, einmaligen Lauf — Test vor dem Einrichten des Jobs, eine
Notfall-Bereinigung ("wir brauchen JETZT Platz"), oder eine Tabelle, die (noch) gar nicht
registriert ist — gibt es `Invoke-sqmPartitionRetention`:

```powershell
Invoke-sqmPartitionRetention -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
    -Table "OrderHistory" -RetentionValue 120 -RetentionUnit Months
```

Entfernt sofort alle Partitionen aelter als der angegebene Cutoff (hier: 120 Monate = 10 Jahre),
per derselben SWITCH-PARTITION-+-MERGE-RANGE-Logik wie oben (`Invoke-sqmPartitionArchive`
dahinter), optional mit `-ArchiveDatabaseName` fuer eine Kopie vor dem Entfernen. Braucht **keine**
vorherige Registrierung — die Grenzwerte jeder Partition werden direkt gelesen und ausgewertet.
Eine einzige Bestaetigungsabfrage fuer den ganzen Lauf (zeigt vorab die Anzahl betroffener
Partitionen), nicht eine pro Partition. `-WhatIf` zeigt, wie viele Partitionen betroffen waeren,
ohne etwas zu aendern.

---

## 5. Ablaufplan C: Tabelle in eine Archiv-Datenbank migrieren

Ziel: eine (noch nicht partitionierte) aktive Tabelle wird **komplett** in eine partitionierte
Kopie in einer separaten Archiv-Datenbank ueberfuehrt — die Quelltabelle wird am Ende umbenannt und
durch eine Kompatibilitaets-View ersetzt, sodass bestehender Anwendungscode unveraendert weiter auf
denselben Tabellennamen zugreifen kann (jetzt transparent gegen die Archiv-Kopie).

1. **Archiv-Datenbank anlegen** (Admin-Aufgabe, nicht automatisiert) — Dateigroessen, Pfade,
   Recovery-Modell nach eigenem Ermessen.
2. **Schluessel pruefen:** die Migration braucht eine Spalte (oder Kombination aus bis zu 4
   Spalten), die jede Zeile eindeutig identifiziert (fuer den MERGE-Abgleich). Ein einspaltiger
   oder bis zu 4-spaltiger Clustered Index/PK wird automatisch erkannt — nur bei einem echten Heap
   oder einem Schluessel mit mehr als 4 Spalten ist `-KeyColumn` Pflicht.
3. **Migration starten:**
   ```powershell
   Invoke-sqmTableArchiveMigration -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
       -Table "OrderHistory" -ArchiveDatabaseName "SalesArchive" -DateColumn "OrderDate" `
       -AllowKeyChange -PurgeSourceAfterArchive -CutoverToArchiveView -Confirm:$false
   ```
   Ablauf im Detail:
   - Legt (beim ersten Aufruf) eine leere, partitionierte Strukturkopie in der Archiv-Datenbank an
     (nutzt intern dieselbe Logik wie Ablaufplan A) und registriert sie automatisch fuer
     Sliding-Window-Wartung — kein separates `New-sqmPartitionExtendJob` fuer die Archiv-Tabelle
     noetig, das passiert automatisch.
   - Migriert **monatsweise** per idempotenter `MERGE`-Batch-Prozedur (`dbo.sqm_ArchiveMonthBatch`,
     wird in der Quelldatenbank deployed). Der laufende, noch nicht abgeschlossene Kalendermonat
     wird standardmaessig **nicht** migriert (`-EndPeriod`-Default: Vormonat).
   - **`-PurgeSourceAfterArchive`**: loescht nach jedem bestaetigt abgeschlossenen Monat dessen
     Zeilen aus der Quelltabelle (nach Row-Count-Gegenpruefung) und gibt den Speicherplatz per
     `DBCC SHRINKFILE` zurueck — wichtig bei wenig freiem Plattenplatz, da Quelle und Archiv-Kopie
     sonst gleichzeitig Platz brauchen.
   - **`-CutoverToArchiveView`**: sobald alle angeforderten Monate archiviert sind, wird die
     Quelltabelle umbenannt (Standard-Suffix `_Original`, konfigurierbar ueber
     `-RenamedTableSuffix`) und durch eine View mit dem urspruenglichen Namen ersetzt, die auf die
     Archiv-Kopie zeigt. **Die umbenannte Original-Tabelle wird nie automatisch geloescht** — das
     bleibt eine spaetere, manuelle Admin-Entscheidung.
   - **Fortsetzbar/unterbrechbar:** jeder Schritt ist idempotent (MERGE, Row-Count-Gegenpruefung
     vor jedem Loeschen). Ein Abbruch (Netzwerk, Prozess-Kill, Wartungsfenster zu Ende) an
     beliebiger Stelle verliert nichts — ein erneuter Aufruf mit denselben Parametern setzt exakt
     dort fort, wo zuletzt committet wurde.
4. **Fortschritt beobachten** (bei sehr grossen Tabellen kann die Migration Stunden bis Tage
   dauern): die Funktion zeigt `Write-Progress` sowie eine Konsolenzeile pro Monat
   (`Archiving period 202401 (1 of 30) ...`) — sichtbar sowohl interaktiv als auch in einem
   Transkript/umgeleiteten Log. Zusaetzlich laesst sich der Stand jederzeit direkt abfragen:
   ```powershell
   Invoke-Sqlcmd -ServerInstance "SQL01" -Database "Sales" -Query "SELECT * FROM dbo.sqm_ArchiveMonthLog ORDER BY YYYYMM"
   ```
5. **Nach erfolgreichem Cutover:** die umbenannte Original-Tabelle (`OrderHistory_Original`) nach
   Pruefung manuell entfernen, sobald sicher ist, dass keine Restdaten (z.B. der zuletzt offene
   Monat) mehr benoetigt werden.

### Wann `-Method BatchedSwap` (Ablaufplan A) statt Ablaufplan C?

`-Method BatchedSwap` partitioniert **innerhalb derselben Datenbank** (kein Datenbankwechsel,
schnellere Batches da keine Cross-DB-Kommunikation noetig) — geeignet, wenn die Tabelle in der
Quelldatenbank bleiben soll, aber wenig Plattenplatz fuer eine klassische Ein-Schritt-Konvertierung
vorhanden ist. Ablaufplan C ist die richtige Wahl, wenn die Daten **dauerhaft in eine andere
Datenbank** sollen (typischerweise eine separate, guenstiger/anders gesicherte Archiv-Instanz).

---

## 5a. Ablaufplan D: Bereits partitionierte Tabelle mit neuer Partitionierung kopieren

Ziel: eine **bereits partitionierte**, weiterhin aktive Tabelle soll zusaetzlich (nicht statt dessen)
als eigenstaendige, **neu partitionierte** Kopie in einer anderen Datenbank existieren — z.B. mit
groeberer Granularitaet fuer Reporting, oder als Testabzug vor einer geplanten Umstellung der
Produktionstabelle. Im Unterschied zu Ablaufplan C gibt es **keinen Cutover**: die Quelltabelle wird
nie umbenannt, nie durch eine View ersetzt und bleibt unter ihrem eigenen Partitionierungsschema
vollstaendig unveraendert.

1. **Zieldatenbank anlegen** (Admin-Aufgabe, nicht automatisiert — gleiche Begruendung wie bei C).
2. **Schluessel pruefen:** wie bei Ablaufplan C wird fuer den Batch-Kopiervorgang eine eindeutige
   Spalte benoetigt. Ein einspaltiger Clustered Index/PK wird automatisch erkannt; bei Heap oder
   zusammengesetztem Schluessel ist `-KeyColumn` Pflicht. Diese Spalte muss **nicht** mit der neuen
   Partitionsspalte identisch sein.
3. **Kopie starten:**
   ```powershell
   Copy-sqmPartitionedTable -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" `
       -TargetDatabaseName "SalesReporting" -Granularity Year -Confirm:$false
   ```
   Ablauf im Detail:
   - Prueft, dass die Quelltabelle tatsaechlich bereits partitioniert ist (sonst Fehler mit Verweis
     auf Ablaufplan A/C) und leitet die Partitionsspalte automatisch aus dem bestehenden Partition
     Scheme ab, sofern `-PartitionColumn` nicht ausdruecklich eine andere Spalte vorgibt.
   - Legt beim ersten Aufruf die neue Partitionierung (Filegroups, Partition Function/Scheme) in der
     Zieldatenbank an und erstellt dort eine strukturell identische Tabelle (Spalten, Indizes,
     PK/UNIQUE-Constraints — Fremdschluessel/Trigger werden **nicht** mitgenommen).
   - Kopiert alle Zeilen batchweise per Keyset-Pagination (`-KeyColumn`, `-BatchSize`) — resumable:
     ein Abbruch oder `-MaxDurationMinutes` kann jederzeit per erneutem Aufruf fortgesetzt werden,
     der dann automatisch bei der zuletzt kopierten Zeile weitermacht und Schritt "Tabelle anlegen"
     ueberspringt.
   - Registriert die neue Tabelle in `sqm_PartitionRegistry` (ausser `-NoRegister`) — Ablaufplan B1
     (Sliding-Window) kann fuer sie danach wie fuer jede andere partitionierte Tabelle eingerichtet
     werden.
4. **Verifikation:** Zeilenzahlen von Quelle und Kopie werden am Ende automatisch abgeglichen —
   weichen sie ab (z.B. weil waehrend der Kopie neue Zeilen in die weiterhin aktive Quelle
   eingefuegt wurden), bricht die Funktion mit einer Fehlermeldung ab; ein erneuter Aufruf kopiert
   die Differenz nach.
5. Live gegen DEV01 verifiziert (`PartitionTestDB.dbo.sqmCopyTestSrc`, Month-partitioniert, 2600
   Zeilen → `ArchiveTestDB.dbo.sqmCopyTestDst`, neu partitioniert nach Year): Quelle blieb
   unveraendert auf ihrem Month-Scheme, Zielkopie zeigte korrekte Year-Grenzen und identische
   Zeilenzahl, ein erneuter Aufruf kopierte 0 zusaetzliche Zeilen (Resume-Pfad).

---

## 6. BoundaryType/SurrogateDateFormat — Referenz

Alle Partitionierungs-/Migrationsfunktionen unterstuetzen drei Spaltentypen fuer die
Partitions-/Periodenspalte, ueber `-BoundaryType` (ohne Angabe automatisch aus dem SQL-Spaltentyp
abgeleitet):

| BoundaryType | Passender SQL-Spaltentyp | Beispielwert | Hinweis |
|---|---|---|---|
| `Date` | `date`/`datetime`/`datetime2`/`smalldatetime`/`datetimeoffset` | `2024-01-15` | Standardfall, keine weitere Konfiguration noetig |
| `Int` | `int`/`bigint`/`smallint`/`tinyint` | `20240115` | Numerischer Datums-Surrogatschluessel |
| `Text` | `char`/`varchar`/`nchar`/`nvarchar` | `'20240115'` | String-Datums-Surrogatschluessel |

Bei `Int`/`Text` steuert `-SurrogateDateFormat` die Genauigkeit:

- `yyyyMMdd` (Standard) — Tagesgenauigkeit, z.B. `20240115`.
- `yyyyMM` — Monatsgenauigkeit ohne Tag, z.B. `202401` (typisch, wenn die Quellspalte selbst nur
  auf Monatsebene gefuehrt wird).

Ein bekanntes reales Beispiel: eine Tabelle mit einer `INT`-Spalte im Format `YYYYMMDD` (z.B.
`VTDAT`) braucht `-BoundaryType Int` (oder automatische Ableitung, falls kein anderer Typ
zutreffen wuerde).

---

## 7. GUI-Assistent: Schritt-fuer-Schritt

```powershell
Show-sqmPartitionToolGui -SqlInstance "SQL01"
```

| Schritt | Inhalt |
|---|---|
| 0 — Connection | Instanz + Authentifizierung (Windows oder SQL Server Login), Datenbank waehlen |
| 1 — Select Table | Kandidatentabellen (mit Zeilenzahl/Groesse/Heap-oder-Clustered) |
| 2 — Select Column | Partitions-/Datumsspalte auswaehlen |
| 3 — Min/Max Preview | Tatsaechlicher Wertebereich der Quelldaten (oder manuelle Werte bei leerer Tabelle) |
| 4 — Granularity & Filegroups | Month/Quarter/Year, Single/PerPeriod, bei Nicht-Datumsspalten zusaetzlich Surrogate Date Format |
| 5 — Boundary Preview | Berechnete Partitionsgrenzen zur Kontrolle vor der Ausfuehrung |
| 6 — Archive & Retention | Zwei sich gegenseitig ausschliessende Modi (siehe unten) |
| 7 — Summary & Execute | Zusammenfassung, Ausfuehren-Button, Live-Log |

**Schritt 6 — zwei Modi:**

- **"Migrate to archive database now"** → Ablaufplan C. Bei aktivierter Checkbox erscheint bei
  Bedarf (Heap oder Schluessel mit mehr als 4 Spalten) ein "Key Column(s)"-Auswahlfeld mit den
  tatsaechlichen Spalten der Tabelle zum Ankreuzen. Bleibt der normale Fall (einfacher oder bis zu
  4-spaltiger Schluessel automatisch erkennbar), bleibt dieser Bereich unsichtbar.
- **"Set up automatic maintenance"** → Ablaufplan B. Nur relevant, wenn die Tabelle **in-place**
  partitioniert bleibt (Ablaufplan A) — bei aktivem "Migrate now" ist dieser ganze Bereich
  ausgeblendet, da er sich nicht auf den Sofort-Migrations-Pfad bezieht.

---

## 8. Troubleshooting und bekannte Einschraenkungen

- **"'-KeyColumn' ist Pflicht"** bei Ablaufplan C: die Tabelle ist ein Heap oder hat einen
  Schluessel mit mehr als 4 Spalten. Im GUI erscheint dafuer automatisch ein Auswahlfeld; per CLI
  `-KeyColumn 'Spalte1','Spalte2',...` (max. 4) explizit angeben.
- **"date ist inkompatibel mit int"**: die Datumsspalte ist kein echter DATE/DATETIME-Typ, sondern
  ein numerischer/String-Surrogatschluessel — `-BoundaryType Int`/`Text` (+ ggf.
  `-SurrogateDateFormat`) angeben, siehe Abschnitt 6.
- **`-Method BatchedSwap` bricht mit Fehler ab** ("eingehende Fremdschluessel/Trigger"): diese
  Methode unterstuetzt aktuell keine Tabellen, auf die andere Tabellen per Fremdschluessel
  verweisen, oder die Trigger haben. Fremdschluessel/Trigger vorher entfernen, oder
  `-Method Default`/`NewTableSwap` verwenden.
- **Performance bei sehr grossen Tabellen (Ablaufplan C):** ohne einen Index mit der Datumsspalte
  als fuehrender Spalte scanned jeder Batch-Aufruf potenziell die gesamte Tabelle. Das Tool warnt
  automatisch, wenn kein passender Index gefunden wird, legt aber keinen automatisch an (bewusste
  Admin-Entscheidung bei einer sehr grossen Tabelle) — vor einem echten Migrationslauf einen
  nichtclustered Index auf `(Datumsspalte, Schluesselspalte(n))` in Erwaegung ziehen.
  `-BatchSize` (Standard 50000) steuert, wie viele Zeilen pro Batch verarbeitet werden.
  `-ShrinkAfterEveryNPeriods` (bei `-PurgeSourceAfterArchive`) steuert, wie oft der freigewordene
  Speicherplatz zurueckgegeben wird.
- **Umbenannte Original-Tabelle nach Cutover** (Ablaufplan C) waechst nicht weiter, enthaelt aber
  ggf. noch den zuletzt offenen (nicht migrierten) Monat — vor dem endgueltigen Loeschen pruefen.
- **`-Method BatchedSwap` und Ablaufplan C laufen nicht online** — beide sperren waehrend der
  jeweiligen Batches kurzzeitig die betroffenen Zeilen/Partitionen. Fuer produktive Systeme
  Wartungsfenster oder Zeiten mit geringer Last einplanen.

---

## 9. Sicherheitshinweise

- Alle destruktiven Operationen (Retention-Loeschung ohne `-ArchiveEnabled`, `-PurgeSourceAfterArchive`)
  loeschen Daten unwiderruflich aus der Quelle — vor dem produktiven Einsatz an einer Testtabelle
  mit repraesentativen Daten ausprobieren.
- Die umbenannte Original-Tabelle (Ablaufplan C, `_Original`-Suffix) wird **nie** automatisch
  geloescht — das ist Absicht, kein Bug. Das Tool loescht generell keine Tabellen automatisch,
  sondern verlaesst sich auf den Admin fuer den letzten, endgueltigen Schritt.
- Fuer produktive Migrationen empfiehlt sich vorab ein vollstaendiges Backup der Quelldatenbank
  sowie ein Testlauf mit `-WhatIf` (alle Kernfunktionen unterstuetzen `SupportsShouldProcess`).
- SQL-Server-Authentifizierung (`-SqlCredential`) sollte nur ueber Mixed-Mode-Logins mit minimal
  notwendigen Rechten erfolgen, nicht ueber `sa`.
