# sqmPartitionTool

Teil der [powershelldba.de](https://www.powershelldba.de) SQL-Server-Tools von [Uwe Janke](https://www.powershelldba.de) — Projektseite: [powershelldba.de/sqmpartitiontool](https://www.powershelldba.de/sqmpartitiontool/)

Automatische SQL-Server-Tabellen-Partitionierung — GUI und CLI.

Baut auf [dbatools](https://dbatools.io) und [sqmSQLTool](https://github.com/JankeUwe/sqmSQLTool)
auf (Logging, Konfiguration, WinForms-Theme werden von sqmSQLTool wiederverwendet).

## Funktionsumfang

- Bestehende (nicht partitionierte) Tabelle in eine partitionierte Tabelle
  umwandeln — Partitionsspalte wählen, Min/Max der vorhandenen Daten erkennen,
  Granularität (Monat/Quartal/Jahr) und Filegroup-Strategie festlegen.
- Automatische Sliding-Window-Erweiterung (neue, leere Partitionen im Voraus
  anlegen) über einen SQL-Agent-Job.
- Automatisches Entfernen alter Partitionen nach konfigurierbarer Aufbewahrung
  (Monate/Jahre), optional mit Auslagerung in eine Archiv-Datenbank auf
  derselben Instanz — über einen zweiten SQL-Agent-Job.
- Vollstaendige Migration einer aktiven Tabelle in eine separate Archiv-Datenbank
  (`Invoke-sqmTableArchiveMigration`) — monatsweise per MERGE, fortsetzbar, mit
  optionalem Cutover (Quelltabelle wird durch eine View auf die Archiv-Kopie
  ersetzt, bestehender Anwendungscode laeuft unveraendert weiter).
- WinForms-GUI-Assistent (`Show-sqmPartitionToolGui`) und vollständige CLI
  (alle Kernfunktionen sind eigenständig aus der PowerShell-Konsole nutzbar).

## Voraussetzungen

- PowerShell 5.1+
- Modul `dbatools`
- Modul `sqmSQLTool`

## Installation

```powershell
Import-Module "C:\CCM\SQL-Tools\sqmPartitionTool\sqmPartitionTool.psd1"
```

## Schnellstart

```powershell
# GUI-Assistent
Show-sqmPartitionToolGui -SqlInstance "SQL01"

# CLI: bestehende Tabelle partitionieren
Invoke-sqmTablePartitionConversion -SqlInstance "SQL01" -Database "Sales" `
    -Schema "dbo" -Table "OrderHistory" -PartitionColumn "OrderDate" `
    -Granularity Month

# Wartungs-Jobs anlegen (Erweiterung + Retention)
New-sqmPartitionExtendJob -SqlInstance "SQL01"
New-sqmPartitionRetentionJob -SqlInstance "SQL01"
```

Siehe [docs/AdminHandbuch.md](docs/AdminHandbuch.md) für detaillierte Ablaufplaene je Szenario
und [CHANGELOG.md](CHANGELOG.md) für die Versionshistorie.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
