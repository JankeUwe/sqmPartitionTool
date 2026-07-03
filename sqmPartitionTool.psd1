<#
	===========================================================================
	 Module Manifest
	-------------------------------------------------------------------------
	 Module Name: sqmPartitionTool
	===========================================================================
#>

@{
	# Script module or binary module file associated with this manifest
	RootModule             = 'sqmPartitionTool.psm1'

	# Version number of this module.
	ModuleVersion          = '1.3.0.0'

	# ID used to uniquely identify this module
	GUID                   = 'dea1027c-a846-4dbe-8d25-6a4416525e06'

	Author                 = 'Uwe Janke'

	# Company or vendor of this module
	CompanyName            = 'dtcSoftware'

	# Copyright statement for this module
	Copyright              = '(c) 2026 Uwe Janke. MIT License.'

	# Description of the functionality provided by this module
	Description            = 'Automatic SQL Server table partitioning: convert existing tables to partitioned tables, sliding-window maintenance (extend), scheduled retention/archiving of old partitions, GUI wizard and CLI. Built on dbatools and sqmSQLTool.'

	# Minimum PS-Version 5.1 (Generic.List, dbatools, WinForms/Desktop CLR fuer die GUI)
	PowerShellVersion      = '5.1'

	# Minimum version of the .NET Framework required by this module
	DotNetFrameworkVersion = '4.5'

	# Minimum version of the common language runtime (CLR) required by this module
	CLRVersion             = '4.0'

	# Processor architecture (None, X86, Amd64, IA64) required by this module
	ProcessorArchitecture  = 'None'

	# Modules that must be imported into the global environment prior to importing this module
	# sqmSQLTool >= 1.9.2.0: das ist die Version, in der Get-sqmSaLogin exportiert wurde
	# (New-sqmPartitionExtendJob/-RetentionJob nutzen es). Ohne Versions-Pin laedt PowerShell
	# klaglos eine aeltere sqmSQLTool-Installation und schlaegt erst spaeter mit einer
	# verwirrenden "Get-sqmSaLogin nicht erkannt"-Meldung fehl statt gleich beim Import.
	RequiredModules        = @('dbatools', @{ ModuleName = 'sqmSQLTool'; ModuleVersion = '1.9.2.0' })

	# Assemblies that must be loaded prior to importing this module
	RequiredAssemblies     = @()

	# Script files (.ps1) that are run in the caller's environment prior to importing this module
	ScriptsToProcess       = @()

	# Type files (.ps1xml) to be loaded when importing this module
	TypesToProcess         = @()

	# Format files (.ps1xml) to be loaded when importing this module
	FormatsToProcess       = @()

	# Modules to import as nested modules of the module specified in ModuleToProcess
	NestedModules          = @()

	# FunctionsToExport: Explizite Liste ALLER public Funktionen
	# Export-ModuleMember wird in .psm1 NICHT aufgerufen (gleiche Begruendung wie sqmSQLTool -
	# vermeidet die PowerShell WARNING ueber Bindestriche in Verb-Noun-Funktionsnamen).
	FunctionsToExport      = @(
		'Get-sqmPartitionCandidateTable',
		'Get-sqmPartitionColumnCandidate',
		'Get-sqmPartitionColumnRange',
		'Get-sqmPartitionBoundaryList',
		'Test-sqmPartitionReadiness',
		'Test-sqmPartitionIndexAlignment',
		'New-sqmPartitionFilegroupPlan',
		'New-sqmPartitionSchemeSet',
		'Invoke-sqmTablePartitionConversion',
		'Register-sqmPartitionTable',
		'Get-sqmPartitionRegistry',
		'Get-sqmPartitionStatus',
		'Invoke-sqmPartitionArchive',
		'Invoke-sqmTableRelocation',
		'Remove-sqmPartitionRegistration',
		'New-sqmPartitionExtendJob',
		'New-sqmPartitionRetentionJob',
		'Show-sqmPartitionToolGui'
	)

	# Keine Cmdlets im Modul - explizit leer statt '*'
	CmdletsToExport        = @()

	# Keine Variablen exportieren - explizit leer statt '*'
	VariablesToExport      = @()

	# Keine Aliases - explizit leer statt '*'
	AliasesToExport        = @()

	# List of all modules packaged with this module
	ModuleList             = @()

	# List of all files packaged with this module
	FileList               = @()

	# Private data to pass to the module specified in ModuleToProcess.
	PrivateData            = @{
		PSData = @{
			# Tags applied to this module. These help with module discovery in online galleries.
			Tags                       = @('SQLServer', 'DBA', 'Partitioning', 'Automation')

			# A URL to the license for this module.
			LicenseUri                 = 'https://github.com/JankeUwe/sqmPartitionTool/blob/main/LICENSE'

			# A URL to the main website for this project.
			ProjectUri                 = 'https://github.com/JankeUwe/sqmPartitionTool'

			# ReleaseNotes of this module
			ReleaseNotes               = 'See CHANGELOG.md'

			# External module dependencies
			ExternalModuleDependencies = @('dbatools', 'sqmSQLTool')
		}
	}
}
