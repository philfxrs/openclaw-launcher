[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$SchemaPath,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RepositoryRoot 'artifacts\test'
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Resolve-OpenClawCommand {
    foreach ($candidate in @('openclaw.cmd', 'openclaw.exe', 'openclaw')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    return $null
}

function Convert-NodeTypeToText {
    param([object]$Node)

    $types = New-Object System.Collections.Generic.List[string]

    if ($Node.PSObject.Properties['type'] -and $null -ne $Node.type) {
        if ($Node.type -is [System.Array]) {
            foreach ($entry in $Node.type) {
                $types.Add([string]$entry)
            }
        } else {
            $types.Add([string]$Node.type)
        }
    }

    foreach ($branchName in @('anyOf', 'oneOf', 'allOf')) {
        $branches = if ($Node.PSObject.Properties[$branchName]) { $Node.$branchName } else { $null }
        if ($branches) {
            foreach ($branch in $branches) {
                if ($branch.PSObject.Properties['const'] -and $null -ne $branch.const) {
                    $types.Add('const')
                    continue
                }

                if ($branch.PSObject.Properties['type'] -and $null -ne $branch.type) {
                    if ($branch.type -is [System.Array]) {
                        foreach ($entry in $branch.type) {
                            $types.Add([string]$entry)
                        }
                    } else {
                        $types.Add([string]$branch.type)
                    }
                }

                if ($branch.PSObject.Properties['$ref']) {
                    $types.Add('ref')
                }
            }
        }
    }

    $result = @($types | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($result.Count -eq 0) {
        return 'unknown'
    }

    return ($result -join '|')
}

function Convert-NodeEnumToText {
    param([object]$Node)

    $values = New-Object System.Collections.Generic.List[string]
    if ($Node.PSObject.Properties['enum'] -and $Node.enum) {
        foreach ($entry in $Node.enum) {
            $values.Add([string]$entry)
        }
    }

    foreach ($branchName in @('anyOf', 'oneOf')) {
        $branches = if ($Node.PSObject.Properties[$branchName]) { $Node.$branchName } else { $null }
        if ($branches) {
            foreach ($branch in $branches) {
                if ($branch.PSObject.Properties['const'] -and $null -ne $branch.const) {
                    $values.Add([string]$branch.const)
                }
            }
        }
    }

    return (@($values | Select-Object -Unique) -join ', ')
}

function Convert-ValueToCompactString {
    param([object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string] -or $Value -is [int] -or $Value -is [long] -or $Value -is [bool] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]$Value
    }

    return ($Value | ConvertTo-Json -Depth 12 -Compress)
}

function Add-SchemaRows {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [string]$Path,
        [Parameter(Mandatory = $true)][System.Collections.IList]$Rows
    )

    $propertiesNode = if ($Node.PSObject.Properties['properties']) { $Node.properties } else { $null }
    $itemsNode = if ($Node.PSObject.Properties['items']) { $Node.items } else { $null }
    $itemsPropertiesNode = if ($itemsNode -and $itemsNode.PSObject.Properties['properties']) { $itemsNode.properties } else { $null }

    $hasProperties = $null -ne $propertiesNode -and @($propertiesNode.PSObject.Properties).Count -gt 0
    $hasAdditionalProperties = $Node.PSObject.Properties['additionalProperties'] -and $null -ne $Node.additionalProperties
    $hasItems = $null -ne $itemsNode

    if (-not [string]::IsNullOrWhiteSpace($Path) -and ($hasProperties -or $hasAdditionalProperties -or $hasItems -or -not $hasProperties)) {
        $Rows.Add([pscustomobject]@{
            key = $Path
            type = Convert-NodeTypeToText -Node $Node
            enum = Convert-NodeEnumToText -Node $Node
            default = Convert-ValueToCompactString -Value $(if ($Node.PSObject.Properties['default']) { $Node.default } else { $null })
            description = [string]$(if ($Node.PSObject.Properties['description']) { $Node.description } else { '' })
        })
    }

    if ($hasProperties) {
        foreach ($property in $propertiesNode.PSObject.Properties) {
            $childPath = if ([string]::IsNullOrWhiteSpace($Path)) { $property.Name } else { $Path + '.' + $property.Name }
            Add-SchemaRows -Node $property.Value -Path $childPath -Rows $Rows
        }
    }

    if ($hasItems -and $null -ne $itemsPropertiesNode -and @($itemsPropertiesNode.PSObject.Properties).Count -gt 0) {
        foreach ($property in $itemsPropertiesNode.PSObject.Properties) {
            $childPath = if ([string]::IsNullOrWhiteSpace($Path)) { '[].' + $property.Name } else { $Path + '[].' + $property.Name }
            Add-SchemaRows -Node $property.Value -Path $childPath -Rows $Rows
        }
    }
}

function Get-CoverageStatus {
    param(
        [string]$Key,
        [string]$TypeText,
        [System.Collections.Generic.HashSet[string]]$UiKeys
    )

    if ($UiKeys.Contains($Key)) {
        if ($TypeText -match 'ref' -or $TypeText -match 'array' -or $TypeText -match 'object') {
            return 'S2'
        }

        return 'S1'
    }

    if ($TypeText -match 'array' -or $TypeText -match 'object' -or $TypeText -match 'ref') {
        return 'S3'
    }

    return 'S3'
}

if (-not $SchemaPath) {
    $SchemaPath = Join-Path $OutputDirectory 'openclaw-config-schema.json'
    $openClawCommand = Resolve-OpenClawCommand
    if ($openClawCommand) {
        Write-Host ('Exporting schema via ' + $openClawCommand)
        $schemaJson = & $openClawCommand config schema
        [System.IO.File]::WriteAllText($SchemaPath, ($schemaJson -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    }
}

if (-not (Test-Path $SchemaPath)) {
    throw 'Schema JSON was not found and openclaw config schema could not be exported.'
}

$schema = Get-Content -Path $SchemaPath -Raw | ConvertFrom-Json
$rows = New-Object 'System.Collections.Generic.List[object]'
Add-SchemaRows -Node $schema -Path '' -Rows $rows

$configuratorSource = Join-Path $RepositoryRoot 'configurator\OpenClawConfigurator.cs'
$uiKeySet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$keyMatches = Select-String -Path $configuratorSource -Pattern 'Key\s*=\s*"([^"]+)"' -AllMatches
foreach ($match in $keyMatches) {
    foreach ($capture in $match.Matches) {
        $null = $uiKeySet.Add($capture.Groups[1].Value)
    }
}

$matrixRows = foreach ($row in $rows) {
    if ([string]::IsNullOrWhiteSpace($row.key)) {
        continue
    }

    $section = ($row.key -split '\.')[0]
    [pscustomobject]@{
        section = $section
        key = $row.key
        type = $row.type
        enum = $row.enum
        default = $row.default
        description = $row.description
        coverage = Get-CoverageStatus -Key $row.key -TypeText $row.type -UiKeys $uiKeySet
    }
}

$summaryRows = $matrixRows |
    Group-Object section, coverage |
    Sort-Object Name |
    ForEach-Object {
        $nameParts = $_.Name -split ', '
        [pscustomobject]@{
            section = $nameParts[0]
            coverage = $nameParts[1]
            count = $_.Count
        }
    }

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$matrixPath = Join-Path $OutputDirectory ('config-coverage-matrix-v0.2-' + $timestamp + '.md')
$csvPath = Join-Path $OutputDirectory ('config-field-table-' + $timestamp + '.csv')

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# OpenClaw Config Coverage Matrix V0.2')
$lines.Add('')
$lines.Add(('Generated: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
$lines.Add(('Schema source: ' + $SchemaPath))
$lines.Add(('Configurator source: ' + $configuratorSource))
$lines.Add('')
$lines.Add('## Coverage Legend')
$lines.Add('')
$lines.Add('| Status | Meaning |')
$lines.Add('| --- | --- |')
$lines.Add('| S1 | Dedicated scalar UI field exists in Configurator |')
$lines.Add('| S2 | UI exists, but schema type includes object/array/ref branches so full editing still requires Raw JSON |')
$lines.Add('| S3 | No dedicated UI; editable and preserved through Raw JSON path |')
$lines.Add('| S4 | Reserved for unsupported keys; no current rows were classified as S4 in this export |')
$lines.Add('| S5 | Reserved for non-schema / derived keys; reported separately in code, not in schema table |')
$lines.Add('')
$lines.Add('## Summary')
$lines.Add('')
$lines.Add('| Section | S1 | S2 | S3 |')
$lines.Add('| --- | --- | --- | --- |')

$sections = @($matrixRows.section | Sort-Object -Unique)
foreach ($section in $sections) {
    $sectionRows = @($summaryRows | Where-Object { $_.section -eq $section })
    $s1 = (@($sectionRows | Where-Object { $_.coverage -eq 'S1' } | Select-Object -ExpandProperty count) + 0 | Measure-Object -Sum).Sum
    $s2 = (@($sectionRows | Where-Object { $_.coverage -eq 'S2' } | Select-Object -ExpandProperty count) + 0 | Measure-Object -Sum).Sum
    $s3 = (@($sectionRows | Where-Object { $_.coverage -eq 'S3' } | Select-Object -ExpandProperty count) + 0 | Measure-Object -Sum).Sum
    $lines.Add('| ' + $section + ' | ' + $s1 + ' | ' + $s2 + ' | ' + $s3 + ' |')
}

$lines.Add('')
$lines.Add('## Full Field Table')
$lines.Add('')
$lines.Add('| Key | Section | Type | Enum | Default | Coverage | Description |')
$lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
foreach ($row in $matrixRows | Sort-Object key) {
    $enum = ([string]$row.enum).Replace('|', '\|')
    $type = ([string]$row.type).Replace('|', '\|')
    $default = ([string]$row.default).Replace('|', '\|')
    $description = ([string]$row.description).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
    $lines.Add('| ' + $row.key + ' | ' + $row.section + ' | ' + $type + ' | ' + $enum + ' | ' + $default + ' | ' + $row.coverage + ' | ' + $description + ' |')
}

[System.IO.File]::WriteAllLines($matrixPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
$matrixRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ('Coverage matrix: ' + $matrixPath)
Write-Host ('Field table CSV: ' + $csvPath)