[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SummaryPath,
    [Parameter(Mandatory = $true)]
    [string]$UploadUri
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SummaryPath)) {
    throw "Diagnostics summary not found: $SummaryPath"
}

Add-Type -AssemblyName System.Net.Http

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(3)

try {
    $content = New-Object System.Net.Http.MultipartFormDataContent

    $summaryBytes = [System.IO.File]::ReadAllBytes($SummaryPath)
    $summaryPart = New-Object System.Net.Http.ByteArrayContent($summaryBytes)
    $summaryPart.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json')

    $content.Add($summaryPart, 'summary', [System.IO.Path]::GetFileName($SummaryPath))
    $content.Add((New-Object System.Net.Http.StringContent('windows-installer')), 'source')

    $response = $client.PostAsync($UploadUri, $content).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    if (-not $response.IsSuccessStatusCode) {
        throw ("Diagnostics upload failed: HTTP {0} {1}" -f [int]$response.StatusCode, $body)
    }

    $result = $body | ConvertFrom-Json
    return [pscustomobject]@{
        success = [bool]$result.success
        reportId = [string]$result.reportId
    }
} finally {
    if ($null -ne $client) {
        $client.Dispose()
    }
}
