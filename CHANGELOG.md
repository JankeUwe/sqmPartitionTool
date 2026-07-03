# sqmPartitionTool — Changelog

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
