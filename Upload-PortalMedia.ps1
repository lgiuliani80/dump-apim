#requires -Version 7.0
<#
.SYNOPSIS
    Carica i media nel Developer Portal di destinazione e aggiorna le URL per Bicep.
.DESCRIPTION
    Richiede az login. Eseguire prima di compilare e distribuire main.bicep.
    L'istanza APIM di destinazione deve gia' esistere.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroupName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ServiceName
)

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot 'portal-media-manifest.json'
$urlsPath = Join-Path $PSScriptRoot 'portal-media-urls.json'
$mediaRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'portal-media')) + [IO.Path]::DirectorySeparatorChar
$manifest = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100)
$urls = Get-Content -LiteralPath $urlsPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
$files = @{}
foreach ($entry in $manifest) {
    if ([string]::IsNullOrWhiteSpace($entry.blobName) -or [string]::IsNullOrWhiteSpace($entry.fileName) -or $files.ContainsKey($entry.blobName)) {
        throw 'Manifest media non valido: blobName/fileName mancante o blob duplicato.'
    }
    $file = [IO.Path]::GetFullPath((Join-Path $mediaRoot $entry.fileName))
    if (-not $file.StartsWith($mediaRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "File media mancante o esterno alla cartella portal-media: $($entry.fileName)"
    }
    $files[$entry.blobName] = $file
}
foreach ($id in $urls.Keys) {
    if (-not $files.ContainsKey($id)) { throw "Media referenziato ma assente nel manifest: $id" }
}
if (-not $manifest.Count) {
    Write-Host 'Nessun media da caricare.'
    return
}

$serviceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ServiceName"
$previousSas = $env:AZURE_STORAGE_SAS_TOKEN
$temporary = "$urlsPath.tmp"
try {
    $response = & az rest --method post --url "https://management.azure.com$serviceId/portalconfigs/default/listMediaContentSecrets?api-version=2021-08-01" --subscription $SubscriptionId --query containerSasUrl --output tsv --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Impossibile ottenere la SAS dei media. Verificare az login, destinazione e autorizzazioni APIM.' }
    $sas = $null
    if (-not [uri]::TryCreate(($response -join "`n").Trim(), [UriKind]::Absolute, [ref]$sas) -or
        $sas.Scheme -ne 'https' -or -not $sas.Query -or $sas.AbsolutePath.Trim('/').Contains('/') -or -not $sas.AbsolutePath.Trim('/')) {
        throw 'Risposta listMediaContentSecrets non valida: containerSasUrl HTTPS con SAS richiesto.'
    }
    $container = [uri]::UnescapeDataString($sas.AbsolutePath.Trim('/'))
    $endpoint = $sas.GetLeftPart([UriPartial]::Authority)
    $root = $sas.GetLeftPart([UriPartial]::Path).TrimEnd('/')
    $env:AZURE_STORAGE_SAS_TOKEN = $sas.Query.TrimStart('?')
    foreach ($entry in $manifest) {
        $arguments = @(
            'storage', 'blob', 'upload', '--account-name', $sas.Host.Split('.')[0],
            '--blob-endpoint', $endpoint, '--container-name', $container,
            '--name', $entry.blobName, '--file', $files[$entry.blobName],
            '--overwrite', 'true', '--output', 'none', '--only-show-errors'
        )
        if ($entry.contentType) { $arguments += @('--content-type', $entry.contentType) }
        $uploadOutput = & az @arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Upload media non riuscito: $($entry.blobName). Verificare SAS e connettivita'." }
        if ($urls.Contains($entry.blobName)) {
            $encoded = ($entry.blobName.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            $urls[$entry.blobName] = "$root/$encoded"
        }
    }
    [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $urls -Depth 100), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $urlsPath, $true)
    Write-Host "Caricati $($manifest.Count) media. URL aggiornate per $($urls.Count) content item. Ricompilare main.bicep con serviceName = $ServiceName."
}
finally {
    $env:AZURE_STORAGE_SAS_TOKEN = $previousSas
    $sas = $null
    $response = $null
    $uploadOutput = $null
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
