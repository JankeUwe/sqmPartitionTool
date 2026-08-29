# sqmPartitionTool — Changelog

## [1.9.1.0] — 2026-08-29

### Doc fix: `-ViewCutover` read-consistency claim, after live verification against DEV01

v1.9.0.0's changelog entry claimed the bridge view gives a "complete, always-consistent dataset"
throughout migration - live-tested against a 60,000-row table on DEV01 (~110s run), that's very
slightly too strong. `COUNT(*)` through the view never dropped below the full row count (good -
that's the property that actually matters), but occasionally read `+1 BatchSize` transiently: under
`READ COMMITTED`, if a batch commits between the view's scan of the old table and its scan of the
new table within the same `SELECT`, that batch's rows can be counted in both for the instant of that
one query. Never missing rows, occasionally a momentary duplicate. Documented in the function's
`.DESCRIPTION`/`-ViewCutover` help; no code change, no functional change from v1.9.0.0.

## [1.9.0.0] — 2026-08-29

### New: `Invoke-sqmTablePartitionConversion -Method BatchedSwap -ViewCutover` — read continuity during the whole migration

Prompted by comparing our approach against
[db-berater.de's "Partition a big table with zero downtime"](https://www.db-berater.de/2026/08/partition-a-big-table-with-zero-downtime/),
which we already matched closely (new partitioned table built in parallel, batched
`DELETE ... OUTPUT ... INTO`, final rename swap) but with one real gap: `BatchedSwap` deleted rows
straight out of the still-originally-named table for the whole (potentially hours-long) segment
loop, so `SELECT`s against the table name mid-migration saw a shrinking subset of the data, not the
full current dataset.

`-ViewCutover` closes that gap. Immediately after the new empty partitioned table is created (a
seconds-wide window, not the full migration), the original table is renamed to `..._sqmPartOld` and
a `UNION ALL` view is created under the original name over `..._sqmPartOld` and the new table. From
that point on, `SELECT`s against the original name see the complete, always-consistent dataset for
the entire segment loop - including while a boundary period is mid-move and its rows are split
across both tables (each batch's `DELETE ... OUTPUT ... INTO` is atomic, so a row is never in both
or neither). At the end: view dropped, new table renamed into place, the now-empty
`..._sqmPartOld` stays (same as the non-cutover path).

Deliberately **read-only**: a plain `UNION ALL` view isn't natively writable, and true automatic
`INSERT`/`UPDATE`/`DELETE` routing (SQL Server's "updatable partitioned view") needs disjoint
CHECK-CONSTRAINT value ranges between the member tables - which doesn't hold here while a period is
actively being migrated (its rows are on both sides for the duration). Building that with
`INSTEAD OF` triggers was considered and deliberately deferred - real complexity and a real place to
introduce a data-loss bug, for a codebase that would need thorough testing before being trusted
against a real table. Writes against the table name fail while the view exists; only use
`-ViewCutover` where write traffic can tolerate that for the migration's duration.

## [1.8.1.0] — 2026-08-27

### Fix: `Invoke-sqmTableRelocation -TargetSchemaName` created the schema in the SOURCE database, not the target

Spotted while building `Copy-sqmPartitionedTable` (v1.8.0.0, see below), which needed the same
"create target schema if missing" logic and got it right by comparison. Root cause:

```powershell
Invoke-DbaQuery @connParams -Database $Database -Query "IF SCHEMA_ID(N'$TargetSchemaName') IS NULL EXEC(N'CREATE SCHEMA [$TargetSchemaName]');" ...
```

`-Database $Database` is the SOURCE database - `CREATE SCHEMA` ran there instead of in
`$TargetDatabaseName`, where the very next statement (`SELECT * INTO
[$TargetDatabaseName].[$TargetSchemaName].[$Table] ...`) actually needs it. Latent bug: since
`-TargetSchemaName` defaults to the source `-Schema` (usually `dbo`, which already exists
everywhere), it only surfaces when a caller explicitly passes a `-TargetSchemaName` that doesn't
yet exist in the target database - then `SELECT INTO` would fail with an invalid-schema error
instead of the schema being auto-created as intended.

- Fix: changed `-Database $Database` to `-Database $TargetDatabaseName` on that line.
- Verified live against DEV01: `Invoke-sqmTableRelocation` from `PartitionTestDB.dbo.sqmRelocSrc`
  to `ArchiveTestDB.sqmRelocFixTest.sqmRelocSrc` (schema `sqmRelocFixTest` did not exist in either
  database beforehand) - after the fix, the schema was created only in `ArchiveTestDB` (never in
  `PartitionTestDB`), and the relocation completed successfully (50 rows, cutover done).

## [1.8.0.0] — 2026-08-27

### Feature: `Copy-sqmPartitionedTable` — copy an already-partitioned table into another database with a NEW partitioning scheme

User request: enable turning an already-partitioned table into a new partitioned table in a
different database, with a new (independent) partitioning scheme, exposed via the GUI wizard.
Until now, every existing cross-database path (`Invoke-sqmTableRelocation`,
`Invoke-sqmTableArchiveMigration`) assumed a NOT-yet-partitioned source and ended with a cutover
(source renamed + replaced by a view) - there was no way to keep an already-partitioned source
fully active while also producing an independent, differently-partitioned copy elsewhere. The GUI
wizard's Step 1 actively rejected already-partitioned tables ("This table is already partitioned -
please select another one").

- Added `Public/Copy-sqmPartitionedTable.ps1`: auto-derives the source's existing partitioning
  column from its partition scheme (`sys.index_columns.partition_ordinal = 1`) unless
  `-PartitionColumn` overrides it, computes a brand-new boundary list for the requested
  `-Granularity` from the source's live data range, builds the new filegroups/partition
  scheme/function in the target database, creates a structurally identical target table on that
  scheme (reusing `Get-sqmTableDefinitionSql`), and copies all rows via the same resumable
  keyset-pagination batch pattern as `Invoke-sqmTableRelocation` (`-KeyColumn`, `-BatchSize`,
  `-MaxDurationMinutes`). The source table is NEVER renamed, dropped, or replaced by a view - this
  is a pure copy, not a migration. Registers the new table in `sqm_PartitionRegistry` unless
  `-NoRegister`. A second call against an already-existing target table resumes the copy instead of
  re-creating the scheme.
- Extended `Private/Get-sqmTableDefinitionSql.ps1` with an optional `-TargetSchema` parameter
  (defaults to `-Schema`, so the existing `Invoke-sqmTablePartitionConversion -Method BatchedSwap`
  caller is unaffected) - needed because the target table can now live in a different schema than
  the source, which the function's `CREATE TABLE`/index DDL previously always qualified with the
  SOURCE schema regardless of `-TargetTable`.
- Verified live against DEV01: `PartitionTestDB.dbo.sqmCopyTestSrc` (Month-partitioned via
  `Invoke-sqmTablePartitionConversion`, 2600 rows, composite PK after `-AllowKeyChange`) copied to
  `ArchiveTestDB.dbo.sqmCopyTestDst` with `-Granularity Year`: source scheme/row count unchanged
  after the copy, target showed correct Year boundaries (2024/2025/2026/2027/2028/2029) and matching
  row counts (2600/2600), `sqm_PartitionRegistry` entry created, and a second (resume) call
  correctly copied 0 additional rows.
- Wired into `Show-sqmPartitionToolGui.ps1`: Step 1 no longer rejects an already-partitioned table
  ("This table is already partitioned - please select another one" is gone) - selecting one instead
  sets a `SourceIsPartitioned` wizard flag. Steps 2-5 (column, min/max, granularity/filegroups,
  boundary preview) are reused unchanged, since they already describe the NEW partitioning
  regardless of the source's current state. Step 6 shows a dedicated "Copy to another database"
  panel instead of the Migrate-now/Retention/Archive controls (mutually exclusive via
  `Set-Step6Mode`), with its own single-column key-picker (`Test-Step6CopyKeyColumnNeed` -
  deliberately a separate check function from the existing `Test-Step6KeyColumnNeed`, since
  `Copy-sqmPartitionedTable` only auto-derives a single-column key, unlike
  `Invoke-sqmTableArchiveMigration`'s up-to-4-column rule). Step 7 execute calls
  `Copy-sqmPartitionedTable` instead of the conversion/migration functions when the flag is set.
  Only the core engine function was exercised live against DEV01 (see above) - the GUI glue code
  itself was verified by static parse check (`[System.Management.Automation.Language.Parser]`),
  the repo's own `Tools/Test-DuplicateParameterBinding.ps1` (clean, 29 files), and a full module
  import/export check, consistent with this module having no automated GUI tests (see
  `Show-sqmPartitionToolGui.ps1` `.NOTES`) - an interactive click-through was not performed.

## [1.7.2.0] — 2026-08-03

### Fix: GUI wizard crashes at Step 4 "Data Compression" with "property ... cannot be found"

User-reported error (German UI): `Ausnahme beim Festlegen von "DataCompression": "Die Eigenschaft
"DataCompression" wurde fuer dieses Objekt nicht gefunden. Ueberpruefen Sie, dass die Eigenschaft
vorhanden ist und festgelegt werden kann."` when clicking "Next" on Step 4.

Root cause: `Show-sqmPartitionToolGui.ps1` keeps wizard state in `$script:wiz`, a
`[PSCustomObject]@{...}` literal. Unlike a hashtable, a `[PSCustomObject]` literal does NOT
support adding a new property via dot-notation after creation - `$obj.NewProp = value` throws
exactly this "property cannot be found" `SetValueInvocationException` unless `NewProp` was already
present in the original literal (verified directly: `[PSCustomObject]@{A=1}; $o.B = 2` throws the
identical message on real PS 5.1). The Step 4 handler at line 661 does
`$script:wiz.DataCompression = ...`, but `DataCompression` was missing from the initial
`$script:wiz` property list (every other property later assigned - `Boundaries`, `MinValue`,
`FilegroupStrategy`, etc. - was already declared there) - so this one assignment reliably crashed
the wizard every time Step 4 was completed.

- Fix: added `DataCompression = 'None'` to the initial `$script:wiz` literal so the later
  assignment just updates an existing property instead of trying to create a new one.

### Fix: `-DataCompression` silently ignored for `-Method Default`/`NewTableSwap`

Bug report from the GUI wizard (Step 4 "Data Compression"): the conversion reported success, but
the resulting table's partitions were never actually compressed. Root cause: `-DataCompression`
was only ever applied inside the `-Method BatchedSwap` branch of `Invoke-sqmTablePartitionConversion`
(`ALTER TABLE ... REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = ...)` right after building the
new swap table). The `Default` and `NewTableSwap` branches (the ones the GUI wizard actually uses -
it never sets `-Method`) built the partitioned table via `CREATE (CLUSTERED) INDEX ... WITH
(DROP_EXISTING = ON) ON <scheme>` and never referenced `$DataCompression` at all, so the parameter
was silently a no-op there - no error, no warning, `Status = 'Success'`.

- Verified against DEV01 (`PartitionTestDB.dbo.sqmTestCompress`, 400 rows, `-Method Default
  -DataCompression Row`): before the fix, all 18 partitions came back `data_compression_desc =
  NONE` despite `Status = Success`; after the fix, all 18 show `ROW`.
- Fix: apply the same `ALTER TABLE ... REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = ...)`
  (in the same non-fatal try/catch as the BatchedSwap branch - a compression failure, e.g. an
  edition without compression support, logs a WARNING and lets the conversion complete rather
  than aborting an otherwise-successful partitioning run) right after the `CREATE (CLUSTERED)
  INDEX`/heap DDL in the `Default`/`NewTableSwap` branch too, so `-DataCompression` now behaves
  identically across all three `-Method` values.

## [1.7.0.0] — 2026-07-06

### Merged two changes developed in parallel (DEV02/DEV03)

While this machine (DEV03, completely rebuilt) was working on `Invoke-sqmTableArchiveMigration`,
DEV02 (since gone offline) had independently already developed and pushed `BoundaryType 'Text'`
+ `-SurrogateDateFormat` for the partitioning side - both sides solved the same problem
(VARCHAR/CHAR surrogate key columns) under a different name (`Varchar` vs. `Text`) and with
different scope (DEV03: YYYYMMDD only; DEV02: configurable YYYYMMDD/YYYYMM, also carried through
into `sqm_ExtendPartitionWindow` and the retention sweep job).

- The DEV02 design (`Text`/`-SurrogateDateFormat`) is the more complete one and is adopted as
  canonical. `Invoke-sqmTableArchiveMigration` and `sqm_ArchiveMonthBatch` (previously `Varchar`,
  YYYYMMDD only) have been switched accordingly to `Text` + `-SurrogateDateFormat`, so there is
  now only ONE naming scheme for date surrogate keys across the whole module.
- No loss of capability on either side: the capabilities developed on DEV03 (composite keys,
  cutover view, Write-Progress, `-Method BatchedSwap`, GUI rework) and the ones developed on
  DEV02 (`Text`/`SurrogateDateFormat` carried through to Extend/Retention) are both fully
  preserved.

## [1.6.6.0] — 2026-07-06

### `Invoke-sqmTableArchiveMigration`: visible progress (Write-Progress + console output)

User feedback: for a very large table (several 100GB-TB), a migration runs for hours to days -
but `Invoke-sqmLogging` writes EXCLUSIVELY to a log file, never to the console. An admin who
started the run directly via PowerShell (the realistic way for a migration of this scale - not
through the GUI wizard, which nobody would want to keep open for hours) previously saw no sign
of life at all until the function returned at the very end - indistinguishable from a hung run.

- New: `Write-Progress` with a percentage display (months processed / months total) - updated
  after every batch, not just after every completed month, so that progress remains visible even
  within a very large month with many batches.
- Additionally one `Write-Host` line each at the start and completion of every month (e.g.
  "Archiving period 202401 (1 of 30) ...", "Period 202401 done: 12345 row(s) archived (running
  total: 12345)."), so progress remains visible in a transcript or redirected output too (e.g. a
  scheduled task, `Start-Transcript`), where `Write-Progress` isn't rendered.
- Verified live against DEV01: console output shows progress period-by-period exactly as
  intended.

## [1.6.5.0] — 2026-07-05

### GUI feedback: misleading key-column field + retention section applying where it shouldn't

User feedback on the GUI from [1.6.3.0]: "if I don't need this it's absolutely confusing when
it's shown. If I need it, a text field is unusable" (key column), plus "once the archive
database is set up, only the backward-pointing view gets written to from then on - 'When
partitions expire later' doesn't make sense at that point".

- **Key Column(s)** is no longer an always-visible free-text field. Step 6 now checks (once per
  table selection, live against the DB) the same clustered index/PK key that
  `Invoke-sqmTableArchiveMigration` would also derive automatically itself - if the table has a
  usable 1-4 column key, the whole section stays completely hidden (not just disabled). Only for
  an actual heap or a key with more than 4 columns is it shown - then as a `CheckedListBox` with
  the table's ACTUAL columns (no free text, no more risk of a typo in a column name).
- The **"Set up automatic maintenance" section** (including the nested "Copy to an archive
  database before removal" checkbox) is now completely hidden when "Migrate to archive database
  now" is active, instead of merely being grayed out with an explanation - the previous
  explanatory text is thereby obsolete and was removed. A valid point: after a cutover to the
  archive DB, every access goes only through the backward-pointing view - "when partitions expire
  later" refers to a concept that no longer makes sense for the source (which by then doesn't
  even exist anymore as a standalone table). The "Archive Database" field remains visible
  (still shared by both modes) and is repositioned depending on the mode.
- Verified live against DEV01: a heap table (0 key columns) and a fresh 4-column composite PK
  table produce the expected "needed"/"not needed" result via the same query that's actually used
  in the GUI.

## [1.6.4.0] — 2026-07-05

### `Invoke-sqmTableArchiveMigration`: YYYYMMDD integer/string date columns (BoundaryType)

During the live test of [1.6.3.0] against the real `CORO_DB.dbo.CARCHIVE` table (the original
trigger for the composite key), the migration still failed afterwards: `VTDAT` is stored as
`INT` in YYYYMMDD format (e.g. `20240115`), not as a real DATE/DATETIME - but the function blindly
cast the source value range via `[datetime]`, and the SQL procedure directly compared
DATE-typed period boundaries against the column ("date is incompatible with int"). A separate,
pre-existing gap - independent of the composite key, but necessary to be able to play through the
original bug report end-to-end at all.

The partitioning side of the module (`Invoke-sqmTablePartitionConversion`/
`Get-sqmPartitionBoundaryList`) already knows this convention (`-BoundaryType Int`/`Varchar` for
a YYYYMMDD surrogate) - `Invoke-sqmTableArchiveMigration` now adopts the same convention instead
of reinventing it.

- **`Invoke-sqmTableArchiveMigration`**: `-BoundaryType` (an already-existing parameter, so far
  only passed through to `Invoke-sqmTablePartitionConversion`) is now additionally evaluated
  locally - without it being specified, it's automatically derived from the SQL column type of
  `-DateColumn` (Date/Datetime types -> `Date`, Varchar/Nvarchar/Char/Nchar -> `Varchar`,
  otherwise -> `Int`, same derivation as in `Invoke-sqmTablePartitionConversion`). The
  Start/EndPeriod derivation from the source value range now parses `MinValue` for `Int`/`Varchar`
  as a YYYYMMDD string instead of via a direct `[datetime]` cast. The period boundaries for
  `-PurgeSourceAfterArchive`'s row-count cross-check/deletion are now formatted appropriately per
  `BoundaryType` (Int: raw integer, Varchar: quoted string, Date: quoted ISO date) instead of
  always as a date literal.
- **`sqm_ArchiveMonthBatch`**: new parameter `@BoundaryType` (Date/Int/Varchar, default `Date`
  for backward compatibility with direct procedure calls that don't pass this parameter). The
  period boundaries (`@PeriodStart`/`@PeriodEnd`) still only serve calendar arithmetic from
  `@YYYYMM` - for the actual comparison with `@DateColumn` they are additionally converted into
  `SQL_VARIANT` parameters with the integer/string/date value matching `@BoundaryType` (the same,
  already-proven principle as the `@pLastKeyN` key parameters from [1.6.3.0]).
- Verified live against the REAL `CORO_DB.dbo.CARCHIVE` table (30 months processed, 12 of them
  with actual data - Jan-Dec 2024, 60000/60000 rows, source unchanged afterwards): the checksum
  over all 34 non-`text` columns as well as the total length of the `text` column (`VDATA`) match
  exactly between source and archive copy. This fully verifies the original bug report (composite
  key + YYYYMMDD integer column together) end-to-end, not just with synthetic test tables.

## [1.6.3.0] — 2026-07-05

### Composite keys for `Invoke-sqmTableArchiveMigration` + GUI clarifications

A show-stopper from a live test against the real table `CORO_DB.dbo.CARCHIVE` (7 TB in
production): `-KeyColumn` so far only supported ONE column, used both as the MERGE match
condition and for keyset pagination within a month - but `CARCHIVE` has a composite 4-column
clustered PK (`VMTG, VID1, VID2, VSEQ`), none of these columns is unique on its own. Since
everything aborted BEFORE the actual archiving (key-column determination is the very first step),
nothing had been created in `CORO_DB` either (neither the archive table nor
`sqm_ArchiveMonthLog`/`sqm_ArchiveMonthBatch`) - which explained three reported symptoms at once
("KeyColumn required", "no new table in the archive DB", "where is the merge procedure/helper
table we already discussed") as ONE shared root cause.

- **`Invoke-sqmTableArchiveMigration`**: `-KeyColumn` now accepts 1-4 columns (`[string[]]`,
  `ValidateCount(1,4)`) instead of only one. Automatic derivation (without `-KeyColumn`) now
  takes ALL columns of a composite clustered index/PK in `key_ordinal` order, instead of aborting
  for more than one column - only an actual heap or a key with more than 4 columns still requires
  explicit specification. New, non-blocking warning before the migration run if no index has
  `$DateColumn` as its leading column (otherwise potentially a full scan per batch on very large
  tables) - recommends an index on `($DateColumn, <key>)`, but doesn't create it automatically
  (admin's decision).
- **`sqm_ArchiveMonthBatch`**: `@KeyColumn SYSNAME` replaced with `@KeyColumns NVARCHAR(400)`
  (comma-separated, `key_ordinal` order). The MERGE ON clause, UPDATE SET exclusion, ORDER BY and
  the keyset pagination condition are now built dynamically for 1-4 columns. Two correctness
  points that are NOT trivial with a composite key (documented in detail in the file header):
  (1) the pagination condition is the true lexicographic tuple ">" evaluation as a nested
  OR/AND expression, NOT individually AND-combined column ">" comparisons (that would incorrectly
  skip rows); (2) the new resume point after a batch is determined via a
  `ROW_NUMBER() OVER (ORDER BY <key>)` sequence number per batch row (the row with the highest
  sequence number), NOT via the column-wise maximum (which for composite keys can produce a tuple
  combination that never exists and thereby silently and permanently skip real rows later - data
  loss on a 7 TB table would have been the consequence).
- **`sqm_ArchiveMonthLog`**: new columns `LastKeyProcessed1`..`LastKeyProcessed4` (resume point as
  a tuple), added additively via an idempotent `ALTER TABLE ... ADD` (the old single column
  `LastKeyProcessed` remains, unused). The upgrade path wasn't optional for this session - DEV01's
  test database already had the old schema deployed from earlier tests.
- **`Show-sqmPartitionToolGui`**: new optional "Key Column(s)" field in step 6 (only active with
  "Migrate to archive database now", empty = automatic derivation). Also two clarifications from
  the same bug report: an explanatory hint appears when "Migrate now" is active ("Automated
  maintenance for the archive copy is registered automatically...") - previously the maintenance
  section was simply grayed out without comment; and the nested "Copy to an archive database
  before removal" checkbox was reworded ("When partitions expire later, move their data to an
  archive database first...") plus a tooltip, to clarify that it refers to the OTHER, ongoing
  automated retention - not the immediate migration above.
- Verified live against DEV01: a purpose-built test table with a real 4-column composite key (no
  subset of the 4 columns unique on its own, to specifically test the maximum-per-column risk),
  `-BatchSize 137` forces ~4-6 batches per month - 2000/2000 rows archived, source/archive
  checksums identical, no duplicate/skipped rows, resume-point tuple advanced plausibly per month
  in the log. Tested both with an explicit `-KeyColumn` and with automatic derivation. Regression
  test with a single-column IDENTITY table (unchanged behavior) passed.
  **A known, separate limitation** (not part of this change, discovered live against the real
  `CORO_DB.dbo.CARCHIVE` table): `-DateColumn` is internally treated as a real DATE/DATETIME type
  (cast + DATE-typed batch parameters) - a date column stored as `INT` in YYYYMMDD format (like
  `CARCHIVE.VTDAT`) is therefore NOT supported ("date is incompatible with int"). This limitation
  already existed before this change and is not part of the composite-key fix - to be addressed
  separately if needed.

## [1.6.2.0] — 2026-07-05

### `Invoke-sqmTableArchiveMigration`: cutover to the archive view + GUI "Migrate now"

A show-stopper from a live test: with "Archive Database" set, the GUI so far only configured a
LATER, automated retention (individual, expired partitions only move to the archive after their
retention period expires) - the source table itself was partitioned in-place immediately and
stayed there. The customer requirement instead was an immediate, complete move: copy +
partitioning in the archive DB, data transfer via the existing MERGE procedure, resume-point
tracking in the source database, and finally renaming the source table + a compatibility view
under the old name pointing to the archive copy - exactly the cutover pattern already established
for `Invoke-sqmTableRelocation`, now also for the monthly, partitioned archive path.

- **`Invoke-sqmTableArchiveMigration`**: new switches `-CutoverToArchiveView` and
  `-RenamedTableSuffix` (default `_Original`, same convention as `Invoke-sqmTableRelocation`).
  Once all requested months (`-StartPeriod`..`-EndPeriod`) have been archived (whether in this
  call or an earlier one), the source table is renamed (fully preserved, no automatic drop) and
  replaced under its old name by a view onto the partitioned archive copy - existing application
  code keeps running unchanged. Idempotent (cutover is skipped if the renamed table already
  exists) and can be guarded via `-WhatIf`/`-Confirm`. The current, still-open month is never
  migrated automatically and therefore remains as a residual in the renamed table - explicitly
  reported in the log so the admin can review/follow up before deleting it. The return object was
  extended with `CutoverPerformed`.
- **`Show-sqmPartitionToolGui`**: new checkbox "Migrate to archive database now" in step 6 -
  mutually exclusive with the existing "later automated retention" option (both are exclusive for
  a single wizard run). In step 7 calls `Invoke-sqmTableArchiveMigration` with
  `-PurgeSourceAfterArchive -CutoverToArchiveView` instead of `Invoke-sqmTablePartitionConversion`
  + `Register-sqmPartitionTable`. `-KeyColumn` is not asked separately - automatic derivation from
  a single-column clustered index/PK as before; for a composite key/heap the function aborts with
  a clear error message.
- Tested live against a real SQL Server (DEV01) - two cases found and fixed there that wouldn't
  have surfaced from a pure code review: (1) a follow-up call on a source table already fully
  emptied (via `-PurgeSourceAfterArchive`) previously already failed when reading the source value
  range ("table is empty"), even though this is exactly the case where `-CutoverToArchiveView`
  should sensibly be applied retroactively - Start/EndPeriod are now derived from
  `dbo.sqm_ArchiveMonthLog` when the source is empty but history already exists. (2) a repeat call
  AFTER a cutover had already happened failed with a misleading "-KeyColumn is required" message
  (the source table is now a view without a clustered index) - this is now detected right at the
  start and treated as a clean no-op ("already completed").

## [1.6.1.0] — 2026-07-05

### `Show-sqmPartitionToolGui`: SQL Server authentication + certificate trust

A show-stopper from a live test against a workgroup machine (no domain trust, only SQL logins
configured): in step 0 ("Connection") the GUI only supported Windows authentication - no
login/password field, no way to connect via SQL auth.

- New fields in step 0: Windows/SQL Server Authentication (radio buttons) + login/password
  (only active with SQL auth). `$script:connParams['SqlCredential']` is built from this and
  reused by ALL following steps (table/column selection, boundary preview, execution) -
  unchanged, already-proven splat pattern.
- **An additional bug found while testing**: the `Get-DbaDatabase` call in step 0 (raw instance
  as a string) does NOT fail with an exception on a self-signed certificate (the normal case for a
  fresh SQL Server install), but only logs a warning and SILENTLY returns 0 databases - in the GUI
  this would have incorrectly shown as "0 database(s) found (OK)", without the actual error
  becoming visible. Fix: connect explicitly for this one call via
  `Connect-DbaInstance -TrustServerCertificate` and use the resulting object for
  `Get-DbaDatabase` (NOT passed on to later steps - passing a connected object with a differing
  `-Database` to another function unexpectedly fell back to Windows auth during testing; the raw
  instance name + `-SqlCredential`, which all sqmPartitionTool functions use themselves, doesn't
  need this and already works fine with a self-signed certificate).

## [1.6.0.0] — 2026-07-05

### Space-friendly, segment-wise migration (source cleanup + shrink)

Customer request: on SAN/storage with little free space, space during a migration keeps getting
tighter, because source and copy both need space at the same time, and previously nothing could
be freed until the migration was fully complete. Two independent, purely additive extensions
(default behavior unchanged):

- **`Invoke-sqmTableArchiveMigration`**: new switches `-PurgeSourceAfterArchive` (deletes, after
  every month confirmed complete, its rows from the source table - only after a row-count
  cross-check against `dbo.sqm_ArchiveMonthLog`, in batches like the existing MERGE-batch
  mechanism), `-ShrinkAfterEveryNPeriods` and `-AggressiveShrink`. No change to
  `sqm_ArchiveMonthBatch.proc.sql` needed - the purge runs entirely in PowerShell after the
  procedure call, using the same month boundary as the MERGE.
- **`Invoke-sqmTablePartitionConversion`**: new `-Method BatchedSwap` (in addition to
  `Default`/`NewTableSwap`) for very large tables without a separate archive database - builds a
  new, empty partitioned copy and moves the data segment by segment (per boundary period, further
  subdivided by `-BatchSize`) via an atomic `DELETE ... OUTPUT ... INTO` (source and target in the
  same database - no separate verify step needed, unlike the cross-archive-database variant
  above). Applies to both heap AND indexed/PK tables (the previous `NewTableSwap` only for
  heaps). Optional `-DataCompression` and periodic shrinking
  (`-ShrinkAfterEveryNSegments`/`-AggressiveShrink`) of the source table while it empties out.
  Finally an `sp_rename` swap (old, now-empty table -> `..._sqmPartOld`, new table -> original
  name) - the source is never automatically dropped, same as with `NewTableSwap`.
  **V1 limitation**: aborts with an error if the table has incoming foreign keys or triggers (for
  these cases keep using `-Method Default`/`NewTableSwap`) - automatic FK/trigger/permission
  carry-over is deliberately not part of this version.
- New private helper function `Get-sqmTableDefinitionSql` (column/index/PK DDL reconstruction),
  extracted from the logic previously duplicated inline in `Invoke-sqmPartitionArchive.ps1`
  (behavior there unchanged, now just reused instead of duplicated).
- New private helper function `Invoke-sqmFileSpaceShrink` (used by both features): by default
  `DBCC SHRINKFILE(..., TRUNCATEONLY)` (fast, no page movement/fragmentation, only returns free
  space at the end of the file), with `-Aggressive` (`-AggressiveShrink` on the calling functions)
  a full shrink instead (more space reclaimed, fragments the remaining indexes - a rebuild is
  recommended afterwards).

## [1.5.1.0] — 2026-07-05

### `-DataCompression` and `-ConfirmArchiveTable` for `Invoke-sqmTableArchiveMigration` / `Invoke-sqmPartitionArchive`

Customer request: some customers insist on a specific compression setting for archive tables,
and an admin should be able to check the empty archive table before the actual
partitioning/data-copy step, instead of the process running through without a pause.

- **`-DataCompression`** (`None`/`Row`/`Page`, default `None`) on both functions. Only applied
  when the archive table is NEWLY created in this call - `SELECT INTO` has no compression clause,
  so it's applied as a separate `ALTER TABLE ... REBUILD` afterwards:
  - `Invoke-sqmTableArchiveMigration`: `REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = ...)`
    AFTER partitioning (applies to all partitions).
  - `Invoke-sqmPartitionArchive`: `REBUILD WITH (DATA_COMPRESSION = ...)` directly after the
    `SELECT INTO` (the archive table here is not partitioned).
- **`-ConfirmArchiveTable`** (switch, off by default) on both functions. Pauses via `Read-Host`
  AFTER creating the empty archive table, BEFORE proceeding with partitioning
  (`Invoke-sqmTableArchiveMigration`) or copying the partition data (`Invoke-sqmPartitionArchive`).
  On rejection: a clean abort, nothing is lost (with `Invoke-sqmPartitionArchive` the partition
  has at this point already been moved into the staging table via SWITCH and stays there for
  manual review).
- Both parameters are purely additive (default values = previous behavior unchanged) - no
  breaking changes for existing calls/jobs.
- **Note**: no existing "handful of rows" test function was found in this module (researched
  before implementation) - if that exists elsewhere, it wasn't part of this module.

## [1.5.0.0] — 2026-07-04

### New function: `Invoke-sqmTableArchiveMigration`

Addition for the case where a not-yet-partitioned, still-active table should NOT be partitioned
in the actual database (that remains the job of `Invoke-sqmTablePartitionConversion`), but
instead moved step by step as a partitioned copy into a separate archive database already set up
by the admin - month by month (YYYYMM) via T-SQL `MERGE`, without touching or deleting the source
table:

- Creates an empty structural copy of the table in the archive database if needed and partitions
  it via the existing `Invoke-sqmTablePartitionConversion` logic (`-ManualStartValue`/
  `-ManualEndValue` from the source's actual value range, since the copy itself is empty) - no
  duplication of the partitioning logic.
- New, dedicated infrastructure **in the source database** (deliberately not in `master`, since
  it's tied to a single migration project): `dbo.sqm_ArchiveMonthLog` (progress log, one row per
  month with a resume point `LastKeyProcessed`) and `dbo.sqm_ArchiveMonthBatch` (batch procedure,
  `MERGE` with `WHEN MATCHED THEN UPDATE` / `WHEN NOT MATCHED THEN INSERT`). New, dedicated
  installer `Install-sqmArchiveMigrationInfra` (reads `sql\archive\*.sql`, deploys to `-Database`
  instead of `master` - separate from the existing `Install-sqmPartitionMaintenanceProcs`, which
  serves `master` exclusively).
- Every batch call is repeatable any number of times via `MERGE` (no duplicates, even for rows
  already archived and since changed in the source). The resume point lives permanently in
  `sqm_ArchiveMonthLog`, not in the function call - an abort at any point (network, process kill)
  loses nothing, a repeat call resumes exactly there.
- The current (still "open") calendar month is NOT migrated by default (`-EndPeriod` default:
  previous month), to avoid a month being logged as "complete" while the source is still actively
  writing to it.
- Deleting the source data is deliberately NOT part of this function - that remains a later,
  manual admin decision after the migration is fully complete.

## [1.4.1.0] — 2026-07-04

### Text support for YYYYMMDD format (DEV03 side, later replaced by [1.4.0.0]/DEV02)

- **`Get-sqmPartitionBoundaryList`**: new BoundaryType `Text` for VARCHAR/NVARCHAR columns with a
  YYYYMMDD string format (e.g. '20240115'). Returns boundaries as strings instead of Int/DateTime.
- **`Invoke-sqmTablePartitionConversion`**: validation and automatic type detection extended
  (varchar/nvarchar -> BoundaryType 'Text'). Warning if BoundaryType doesn't match the column
  type.
- **`Register-sqmPartitionTable`**: BoundaryType parameter updated.
- **All functions**: fully tested on DEV03 with Text/Int/Date examples.
- Developed independently of [1.4.0.0] (DEV02), before the two lines of changes were merged (see
  [1.7.0.0]) - only covered YYYYMMDD, no configurable `-SurrogateDateFormat`.

## [1.4.0.0] — 2026-07-03

### Varchar surrogate keys (BoundaryType 'Text') + configurable yyyyMM format

- So far `BoundaryType 'Int'` only covered numeric YYYYMMDD surrogate keys. Some projects use the
  same date format but as a `char`/`varchar` column, and/or only at month granularity (YYYYMM
  instead of YYYYMMDD). Both are now supported:
  - New `BoundaryType` value `'Text'` (in addition to `'Date'`/`'Int'`) for
    `char`/`varchar`/`nchar`/`nvarchar` surrogate keys.
  - New parameter `-SurrogateDateFormat` (`'yyyyMMdd'` default or `'yyyyMM'`) for
    `Get-sqmPartitionBoundaryList`, `Invoke-sqmTablePartitionConversion` and
    `Register-sqmPartitionTable` - controls whether the surrogate key has day or only month
    precision.
  - `Invoke-sqmTablePartitionConversion` still automatically detects `BoundaryType` from the
    column type when not specified: date types -> `Date`, `int`/`bigint`/`smallint`/`tinyint` ->
    `Int`, `char`/`varchar`/`nchar`/`nvarchar` -> `Text`. The `SqlDataType` that flows into the
    `CREATE PARTITION FUNCTION` DDL is now built with the actual column length for text types
    (e.g. `varchar(6)`); previously an unlength-specified `varchar` (implicitly `varchar(1)`)
    would have been used.
  - `New-sqmPartitionSchemeSet` now quotes `[string]` boundary values as `N'...'` literals in the
    `CREATE PARTITION FUNCTION ... VALUES (...)` DDL.
  - `sqm_ExtendPartitionWindow` (T-SQL maintenance procedure): now reads `SurrogateDateFormat`
    from the registry and parses/builds boundary values depending on format and type (yyyyMM has
    no matching `CONVERT` style and is manually assembled from year/month; `Text` literals are
    quoted, `Int` literals are not).
  - `Invoke-sqmPartitionRetentionSweep.ps1` (retention job): the cutoff comparison previously cast
    the raw boundary value blindly as `[datetime]` - correct for `BoundaryType 'Date'`, but a
    miscast for `'Int'`/`'Text'` (a value like `20240115` interpreted as `[datetime]` ends up as
    an OLE Automation date serial, not as Jan 15, 2024). Now parses depending on format via
    `[datetime]::ParseExact`.
  - `Invoke-sqmPartitionArchive` (`MERGE RANGE` DDL): `[string]` boundary values are now quoted as
    `N'...'` literals instead of relying on implicit int->varchar conversion.
  - `Show-sqmPartitionToolGui`: step 4 (granularity) additionally shows a `Surrogate Date Format`
    selector (`yyyyMMdd`/`yyyyMM`) for non-date columns.
  - `sqm_PartitionRegistry`: new column `SurrogateDateFormat` (with an `ALTER TABLE ... ADD`
    migration path for already-existing installations).
- Verified end-to-end on DEV02: one test table each with a `varchar(6)` column (`BoundaryType
  Text`) and an `int` column (`BoundaryType Int`), both in `yyyyMM` format - the full cycle
  conversion -> `sqm_ExtendPartitionWindow` (including an idempotency re-run) -> retention sweep
  (`Invoke-sqmPartitionRetentionSweep.ps1`) ran through without errors in both cases; boundary
  values and retired partitions were spot-checked against `sys.partition_range_values`.

## [1.3.0.0] — 2026-07-03

### Switched the GUI to English

- **`Show-sqmPartitionToolGui`**: all visible GUI text (step titles, window title, field labels,
  buttons, grid column headers, status messages, confirmation/error dialogs) switched from German
  to English - the earlier "de-DE instead of en-US" fix (1.2.1.0) only affected number/date
  formatting, not the GUI's actual language. Code comments and `Invoke-sqmLogging` messages
  remain deliberately German (consistent with the rest of the project - only the visible
  interface was switched).
- Internal column `Name` identifiers (for `$row.Cells['...']` access in code) left unchanged,
  only the displayed `HeaderText` values were translated - no logic change needed. Cell values
  used as comparison values in code (e.g. status "already partitioned" instead of "bereits
  partitioniert", the compatible column "Yes" instead of "Ja") were updated consistently in both
  places (display AND comparison).
- Clicked through interactively on DEV02 (connection -> select table -> summary): all text
  correctly in English, decimal values still with a dot (e.g. "0.42" MB).

## [1.2.1.0] — 2026-07-03

### Fixes after further feedback

- **Enforced a minimum version of `sqmSQLTool.psd1`**: `RequiredModules` now explicitly requires
  `sqmSQLTool >= 1.9.2.0` (the version in which `Get-sqmSaLogin` was exported, which
  `New-sqmPartitionExtendJob`/`-RetentionJob` need). Previously an older, already-installed
  sqmSQLTool version was loaded without complaint and the error only became visible later with a
  confusing "Get-sqmSaLogin not recognized" message (the root cause of the previously reported
  "step 2 shows no tables" case). `Install.ps1` now also explicitly checks the installed
  sqmSQLTool version and warns with clear guidance if it's too old.
- **Fix `Show-sqmPartitionToolGui`**: `SizeMB` (a decimal value) was passed directly to the
  table-selection grid - .NET renders `[decimal]` values without explicit formatting using the
  thread culture's decimal separator, so under de-DE with a comma instead of a dot (e.g. "12,34"
  instead of "12.34"), even though the rest of the GUI display should be unambiguous.
  `_FormatDisplayValue` now also explicitly formats decimal values with `InvariantCulture`, not
  just date values as before. Verified: under a simulated de-DE culture, `(12.34).ToString()`
  still returns "12,34", the fix correctly returns "12.34".

## [1.2.0.0] — 2026-07-03

### New function: `Invoke-sqmTableRelocation`

Addition after feedback on the existing archive functionality: `Invoke-sqmPartitionArchive`
continuously moves only EXPIRED PARTITIONS of a still-active, partitioned table. For the
one-time, complete relocation of an entire (typically very large) table into a separate database,
there is now `Invoke-sqmTableRelocation`:

- Batch-wise, NON-destructive copy (the source table remains fully unchanged until completion,
  each batch its own small transaction - the transaction log doesn't grow uncontrollably).
- Resumable: on every call reads the actual progress (MAX of the key column in the target) and
  continues from there - `-MaxDurationMinutes` allows deliberately splitting very large tables
  across multiple maintenance windows.
- Cutover only after a complete, verified row-count reconciliation: the original table is renamed
  (a safety net, fully preserved), then a view is created under the original table name that
  points to the target table via a cross-DB query - existing queries/reports keep running
  unchanged.
- Verified on DEV02: 275 rows moved in batches of 100, the view transparently returns the same
  data, the renamed original table remains completely untouched (275 rows).
- Two bugs found and fixed during testing: (1) `MAX()` over an empty target table returns
  `[System.DBNull]::Value`, not PowerShell's `$null` - without special handling this produced an
  empty, syntactically invalid `WHERE` clause (`WHERE [Id] > `). (2) a single-row
  `Invoke-DbaQuery` result is a single `System.Data.DataRow` object instead of an array -
  `$result[0]` then invokes the DataRow's OWN column indexer (returns the value of the first
  column instead of the object itself); `.ColumnName` on that silently returned `$null` instead
  of an error. Fix: explicitly force the result into array context with `@(...)` before indexing.

## [1.1.1.0] — 2026-07-03

### Feedback from the GUI review implemented

- **Fix `Show-sqmPartitionToolGui`**: date values (Min/Max preview, boundary preview) were shown
  with the default `ToString()`, whose format depends on the session/system culture (e.g.
  `06/16/2026` in en-US style vs. `16.06.2026` in de-DE style) - actually misread once while
  clicking through this session (confused with a different date). A new `_FormatDisplayValue`
  helper function now always shows date values unambiguously as `yyyy-MM-dd` (invariant culture).
- **Enhancement `Invoke-sqmPartitionArchive`**: `-ArchiveBatchSize` was previously an ineffective
  parameter - the archive copy always ran as a single `INSERT...SELECT` in one transaction (risk
  for very large partitions: transaction-log growth, long locks, timeouts). Now copies in batches
  (`DELETE TOP (@BatchSize) ... OUTPUT INTO`, each its own transaction) once the partition
  contains more rows than `-ArchiveBatchSize`. Verified on DEV02 (31 rows, ArchiveBatchSize=15 ->
  3 batches, all rows including IDENTITY values correctly carried over).

## [1.1.0.0] — 2026-07-03

### GUI wizard built, critical quarter-boundary bug found and fixed

- `Public/Show-sqmPartitionToolGui.ps1` - new 8-step wizard (Connection -> Table -> Column ->
  Min/Max -> Granularity/Filegroups -> Boundary preview -> Archive/Retention ->
  Summary/Execute), a pure wrapper around existing core functions, dark theme identical to
  `Show-sqmBackupExcludeForm` (sqmSQLTool). Clicked through interactively on DEV02.
- **Critical fix `Get-sqmPartitionBoundaryList`**: `Granularity Quarter` computed incorrect
  quarter boundaries while clicking through the GUI (step 6, boundary preview) - for the test
  table date 2026-06-16 (Q2), the first future buffer period was incorrectly flagged as only
  starting at Q4/2026 instead of Q3/2026. Cause: `[int](($date.Month - 1) / 3)` - PowerShell's `/`
  is ALWAYS floating-point division (unlike T-SQL/C with int operands) and the `[int]` cast
  ROUNDS (instead of truncating), e.g. `[int](5/3)` gives `2`, not `1`. Affected the last month of
  every quarter (March/June/September/December) - for December, this would even have produced
  month 13 (`[datetime]::new(...,13,1)` throws an exception). Fix:
  `[math]::Floor(($date.Month-1)/3.0)` instead of `[int](...)`. Affected both `_PeriodStart` AND
  `_PeriodLabel` (same bug in both places). Verified: the original case (2026-06-16) now
  correctly returns Q3/2026 as the first buffer, the December edge case (previously a potential
  exception) now runs through without error. **Note**: conversions already performed in this
  session (TestOrdersPK, TestOrdersHeap) used `Granularity Month`, not `Quarter` - not affected by
  the bug, no rework needed.
- **Second critical fix `Get-sqmPartitionStatus`**: the `LowerBoundaryValue` column actually
  contained the UPPER boundary of every partition (SQL join `prv.boundary_id =
  p.partition_number` instead of `p.partition_number - 1`) - partition 1 incorrectly showed a
  value instead of NULL/infinity. `Invoke-sqmPartitionArchive`'s `MERGE RANGE` used this column
  for the boundary value and only worked correctly by coincidence, because the (mis-named) value
  happened to be the one actually needed for MERGE RANGE. The retention sweep logic
  (`Invoke-sqmPartitionRetentionSweep.ps1`), on the other hand, read
  `$status[i+1].LowerBoundaryValue` assuming correct semantics - with the buggy column, one
  boundary too far, which could lead to incorrect retire decisions for cutoffs sitting close to a
  period boundary (not visible so far due to the generous test margins used in this session's
  previous tests). Fix: `Get-sqmPartitionStatus` now explicitly returns both
  `LowerBoundaryValue` (the true lower boundary, NULL for partition 1) and `UpperBoundaryValue`
  (the true upper boundary, NULL for the last/future partition) as separate columns - no caller
  needs to infer this from neighboring rows anymore. `Invoke-sqmPartitionArchive` now uses
  `UpperBoundaryValue` for MERGE RANGE, the retention sweep uses `$oldest.UpperBoundaryValue`
  directly. Verified on DEV02: correct boundaries for all 14 partitions (partition 1 now
  correctly shows NO lower boundary), retiring partition 2 merges the correct boundary (269 of
  300 rows correctly retained).

### Maintenance jobs implemented

- `sql/sqm_ExtendPartitionWindow.proc.sql` - instance-wide procedure, extends the sliding window
  of all active registry entries (only FilegroupStrategy 'Single' automatically, see the comment
  in the file). Fix: `EXEC()` doesn't accept an expression that inlines `QUOTENAME()` directly via
  string concatenation (a syntax error despite a valid expression for SELECT) - it must first be
  written into a variable. Fix: an off-by-one - the next period to add is one period AFTER the
  existing max boundary, not at it (otherwise "duplicate range boundary values"). Verified on
  DEV02 (28 boundaries added, second run correctly a no-op).
- `jobs/Invoke-sqmPartitionRetentionSweep.ps1` - a PowerShell script (deliberately not a T-SQL
  procedure, see the comment in the file) for the weekly retention/archiving, uses the
  already-tested `Invoke-sqmPartitionArchive`. Fix: `Where-Object { $_.RetentionValue }` alone
  doesn't filter out NULL values (returned from SQL Server as `[DBNull]::Value`) - explicitly
  checks `-isnot [System.DBNull]`. Fix: partition numbers shift after every MERGE RANGE (all
  subsequent partitions move down one number) - a list of PartitionNumber values planned ahead of
  time becomes invalid after the first removal; the status is now re-read on every iteration.
  Verified on DEV02 (13 partitions removed, all 2000 original rows correctly found again in the
  archive).
- `Public/New-sqmPartitionExtendJob.ps1`, `Public/New-sqmPartitionRetentionJob.ps1` - create the
  two instance-wide SQL Agent jobs (daily/weekly), `-Update` switch idempotent. Verified on DEV02
  (Create/AlreadyExists/Update for both jobs).
- Added the export of `Get-sqmSaLogin` from sqmSQLTool (see its CHANGELOG 1.9.2.0) - the same
  cross-module visibility restriction as with `Invoke-sqmLogging`.

### Core conversion functions completed

- `Get-sqmPartitionCandidateTable`, `Get-sqmPartitionColumnCandidate`,
  `Get-sqmPartitionColumnRange`, `Get-sqmPartitionBoundaryList`,
  `Test-sqmPartitionReadiness`, `Test-sqmPartitionIndexAlignment`,
  `New-sqmPartitionFilegroupPlan`, `New-sqmPartitionSchemeSet`,
  `Invoke-sqmTablePartitionConversion`, `Register-sqmPartitionTable`,
  `Get-sqmPartitionRegistry`, `Get-sqmPartitionStatus`,
  `Remove-sqmPartitionRegistration`, `Invoke-sqmPartitionArchive`
  implemented and verified on DEV02 against PK and heap test tables.
- Fix `Invoke-sqmPartitionArchive`: SWITCH PARTITION failed with "no matching
  index", even though the staging table's columns/uniqueness were structurally
  identical. Root cause (verified empirically via a minimal repro): if the
  source index is defined as a PRIMARY KEY/UNIQUE CONSTRAINT, SQL Server
  requires a constraint on the staging table too (not just a structurally
  identical plain index). This now applies to all indexes of the source table
  (not just the clustered index).
- Fix `Invoke-sqmPartitionArchive`: the IDENTITY property wasn't carried over
  when creating the staging table (also required for SWITCH PARTITION).
- Fix `Invoke-sqmPartitionArchive`: the archive copy failed with an
  "IDENTITY_INSERT" error for IDENTITY columns - the copy now uses an
  explicit column list and `SET IDENTITY_INSERT ON/OFF` where needed.
- Fix `Invoke-sqmPartitionArchive`: `Invoke-DbaQuery -ErrorAction Stop` didn't
  throw a terminating exception on real SQL Server execution errors
  (execution continued with just a warning) - added `-EnableException`
  everywhere as well.
- Fix `Get-sqmPartitionStatus`: invalid `return foreach (...)` syntax.

## [1.0.0.0] — 2026-07-03

### Initial project

- Basic module scaffold created (psd1/psm1, Public/Private/sql/Docs/jobs/tests
  structure, RequiredModules `dbatools` + `sqmSQLTool`).
- Concept: `master.dbo.sqm_PartitionRegistry` as a central metadata table
  (one row per registered table), two instance-wide SQL Agent jobs
  (`sqm_ExtendPartitionWindow`, `sqm_RetirePartitionWindow`) instead of a
  job per table.
- Further functionality (core conversion, maintenance jobs, GUI wizard)
  follows in subsequent versions — see the project plan.
