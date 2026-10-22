#requires -Version 7.0
<#
.SYNOPSIS
    Esporta uno snapshot Bicep di un'istanza APIM e i media del Developer Portal.
.DESCRIPTION
    Enumera le risorse ARM APIM (incluse quelle annidate), segue nextLink e salva
    un sorgente Bicep senza parametri o variabili. I file HTML, XML e binari
    sono referenziati con le funzioni loadTextContent/loadFileAsBase64.
    L'output puo' contenere dati riservati. I segreti che Azure non restituisce non
    possono essere ricostruiti; il template e' uno snapshot, non una garanzia di
    redeploy senza modifiche (alcune proprieta' GET sono di sola lettura).
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$ServiceName,
    [string]$OutputDirectory,
    [switch]$NoApis
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2024-05-01'
$serviceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ServiceName"
$armBase = "https://management.azure.com$serviceId"
$token = & az account get-access-token --subscription $SubscriptionId --resource 'https://management.azure.com/' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw 'Autenticazione Azure CLI non riuscita. Eseguire az login e verificare la sottoscrizione.'
}
$headers = @{ Authorization = "Bearer $token" }
$resources = [System.Collections.Generic.List[object]]::new()
$fileExpressions = [ordered]@{}
$unavailable = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$rules = @{}
# Tipi gestiti da ApiOps (Supported Scenarios, 2022-09-01). Non si escludono
# automaticamente i discendenti: alcuni, come releases e wikis, non sono coperti.
$apiOpsTypes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($type in @(
    'apis', 'apis/diagnostics', 'apis/operations', 'apis/operations/policies',
    'apis/policies', 'apis/resolvers', 'apis/resolvers/policies', 'apis/schemas',
    'apis/tags', 'apiVersionSets', 'backends', 'diagnostics',
    'gateways', 'gateways/apis', 'loggers', 'namedValues', 'policies',
    'policyFragments', 'products', 'products/apis', 'products/apiLinks',
    'products/groups', 'products/groupLinks', 'products/policies',
    'products/tags', 'tags', 'tags/apiLinks', 'tags/productLinks', 'tags/operationLinks'
)) { $null = $apiOpsTypes.Add($type) }
$previewVersions = @{
    'apis/tools'                       = '2025-09-01-preview'
    'clientApplications'               = '2025-09-01-preview'
    'clientApplications/productLinks'  = '2025-09-01-preview'
    'eventGridFilters'                 = '2025-03-01-preview'
}
$nameOnlyTypes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($association in @(
    'apis/operations/tags', 'apis/tags', 'gateways/apis', 'groups/users',
    'notifications/recipientEmails', 'notifications/recipientUsers',
    'products/apis', 'products/groups', 'products/tags',
    'workspaces/groups/users', 'workspaces/notifications/recipientEmails',
    'workspaces/notifications/recipientUsers'
)) { $null = $nameOnlyTypes.Add($association) }

# Percorsi read-only verificati con BCP073 e con la specifica APIM 2024-05-01.
# Sono specifici del tipo: "status", per esempio, non e' read-only ovunque.
$readOnlyPaths = @{
    'service' = @(
        'identity/principalId', 'identity/tenantId',
        'properties/createdAtUtc', 'properties/developerPortalUrl',
        'properties/gatewayRegionalUrl', 'properties/gatewayUrl',
        'properties/managementApiUrl', 'properties/outboundPublicIPAddresses',
        'properties/platformVersion', 'properties/portalUrl',
        'properties/privateEndpointConnections/properties/groupIds',
        'properties/privateEndpointConnections/properties/privateEndpoint/id',
        'properties/privateEndpointConnections/properties/provisioningState',
        'properties/privateIPAddresses', 'properties/provisioningState',
        'properties/publicIPAddresses', 'properties/scmUrl',
        'properties/targetProvisioningState'
    )
    'service/apis' = @('properties/isOnline', 'properties/provisioningState')
    'service/apis/releases' = @('properties/createdDateTime', 'properties/updatedDateTime')
    'service/apis/schemas' = @('properties/provisioningState')
    'service/groups' = @('properties/builtIn')
    'service/namedValues' = @('properties/keyVault/lastStatus', 'properties/provisioningState')
    'service/notifications' = @('properties')
    'service/policyFragments' = @('properties/provisioningState')
    'service/portalRevisions' = @(
        'properties/createdDateTime', 'properties/provisioningState',
        'properties/status', 'properties/statusDetails', 'properties/updatedDateTime'
    )
    'service/privateEndpointConnections' = @(
        'properties/groupIds', 'properties/privateEndpoint', 'properties/provisioningState'
    )
    'service/schemas' = @('properties/provisioningState')
    'service/subscriptions' = @(
        'properties/createdDate', 'properties/endDate', 'properties/expirationDate',
        'properties/notificationDate', 'properties/startDate', 'properties/stateComment'
    )
    'service/templates' = @('properties/isDefault')
    'service/users' = @('properties/groups', 'properties/registrationDate')
    'service/workspaces/apis' = @('properties/isOnline', 'properties/provisioningState')
    'service/workspaces/apis/releases' = @('properties/createdDateTime', 'properties/updatedDateTime')
    'service/workspaces/apis/schemas' = @('properties/provisioningState')
    'service/workspaces/namedValues' = @('properties/keyVault/lastStatus', 'properties/provisioningState')
    'service/workspaces/policyFragments' = @('properties/provisioningState')
    'service/workspaces/schemas' = @('properties/provisioningState')
}
$removedReadOnly = [ordered]@{}

function Remove-ReadOnlyPath($node, [string[]]$parts) {
    if ($node -is [array]) {
        $count = 0
        foreach ($item in $node) { $count += Remove-ReadOnlyPath $item $parts }
        return $count
    }
    $key = $parts[0]
    if ($node -is [System.Collections.IDictionary]) {
        if (-not $node.Contains($key)) { return 0 }
        if ($parts.Count -eq 1) {
            $node.Remove($key)
            return 1
        }
        return Remove-ReadOnlyPath $node[$key] $parts[1..($parts.Count - 1)]
    }
    if ($null -eq $node -or $null -eq $node.PSObject.Properties[$key]) { return 0 }
    if ($parts.Count -eq 1) {
        $node.PSObject.Properties.Remove($key)
        return 1
    }
    return Remove-ReadOnlyPath $node.$key $parts[1..($parts.Count - 1)]
}

function Remove-ReadOnlyProperties {
    foreach ($resource in $resources) {
        $type = $resource.type.Replace('Microsoft.ApiManagement/', '')
        if (-not $readOnlyPaths.ContainsKey($type)) { continue }
        foreach ($path in $readOnlyPaths[$type]) {
            $count = Remove-ReadOnlyPath $resource ($path -split '/')
            if ($count) { $removedReadOnly["$type/$path"] = $count + [int]$removedReadOnly["$type/$path"] }
        }
    }
}

function Add-Children([string]$parentType, [string[]]$collections) {
    $rules[$parentType] = $collections
}

# Collection GET e risorse PUT della specifica APIM 2024-05-01, con i tipi
# aggiunti dalle versioni preview indicate in $previewVersions.
Add-Children '' @(
    'apis', 'apiVersionSets', 'authorizationProviders', 'authorizationServers',
    'backends', 'caches', 'certificates', 'clientApplications', 'contentTypes',
    'diagnostics', 'documentations', 'eventGridFilters', 'templates', 'gateways',
    'groups', 'identityProviders',
    'loggers', 'namedValues', 'notifications', 'openidConnectProviders',
    'policies', 'policyFragments', 'policyRestrictions', 'portalconfigs',
    'portalRevisions', 'portalsettings', 'privateEndpointConnections',
    'products', 'schemas', 'subscriptions', 'tags', 'tenant', 'users',
    'workspaces', 'workspaceLinks'
)
Add-Children 'apis' @(
    'releases', 'operations', 'resolvers', 'policies', 'schemas', 'diagnostics',
    'issues', 'tagDescriptions', 'tags', 'tools', 'wikis'
)
Add-Children 'apis/operations' @('policies', 'tags')
Add-Children 'apis/resolvers' @('policies')
Add-Children 'apis/issues' @('comments', 'attachments')
Add-Children 'authorizationProviders' @('authorizations')
Add-Children 'authorizationProviders/authorizations' @('accessPolicies')
Add-Children 'clientApplications' @('productLinks')
Add-Children 'contentTypes' @('contentItems')
Add-Children 'gateways' @('apis', 'certificateAuthorities', 'hostnameConfigurations')
Add-Children 'groups' @('users')
Add-Children 'notifications' @('recipientEmails', 'recipientUsers')
Add-Children 'products' @('apiLinks', 'apis', 'groupLinks', 'groups', 'policies', 'tags', 'wikis')
Add-Children 'tags' @('apiLinks', 'operationLinks', 'productLinks')
Add-Children 'workspaces' @(
    'apis', 'apiVersionSets', 'backends', 'certificates', 'diagnostics', 'groups',
    'loggers', 'namedValues', 'notifications', 'policies', 'policyFragments',
    'products', 'schemas', 'subscriptions', 'tags'
)
Add-Children 'workspaces/apis' @('releases', 'operations', 'policies', 'schemas', 'diagnostics')
Add-Children 'workspaces/apis/operations' @('policies')
Add-Children 'workspaces/groups' @('users')
Add-Children 'workspaces/notifications' @('recipientEmails', 'recipientUsers')
Add-Children 'workspaces/products' @('apiLinks', 'groupLinks', 'policies')
Add-Children 'workspaces/tags' @('apiLinks', 'operationLinks', 'productLinks')

function Invoke-Arm([string]$uri, [string]$method = 'GET', [switch]$AllowNotFound) {
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $uri -Headers $headers -Method $method
        }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            if ($status -eq 404 -and $AllowNotFound) {
                $unavailable.Add(([uri]$uri).AbsolutePath.Replace($serviceId, '', [StringComparison]::OrdinalIgnoreCase))
                return $null
            }
            if ($status -in @(429, 500, 502, 503, 504) -and $attempt -lt 4) {
                Start-Sleep -Seconds ([Math]::Min(2 * [Math]::Pow(2, $attempt), 20))
                continue
            }
            throw "Richiesta ARM $method non riuscita ($status): $(([uri]$uri).AbsolutePath). $($_.Exception.Message)"
        }
    }
}

function Get-Collection([string]$path, [string]$version) {
    $result = [System.Collections.Generic.List[object]]::new()
    $uri = "$armBase/$path`?api-version=$version"
    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($uri) {
        if (-not $visited.Add($uri)) { throw "nextLink ciclico: $path" }
        $page = Invoke-Arm $uri -AllowNotFound
        if ($null -eq $page) { break }
        if ($null -eq $page.value) { throw "Risposta senza value: $path" }
        foreach ($item in $page.value) { $result.Add($item) }
        $uri = $page.nextLink
    }
    return $result.ToArray()
}

function Add-Resource($item, [string]$relativeId, [string]$typePath) {
    if (-not $seen.Add($relativeId)) { throw "Risorsa duplicata: $relativeId" }
    $segments = $relativeId.Split('/')
    $nameParts = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $segments.Length; $i += 2) {
        $nameParts.Add([uri]::UnescapeDataString($segments[$i]))
    }
    $resource = [ordered]@{
        type       = "Microsoft.ApiManagement/service/$typePath"
        apiVersion = $(if ($previewVersions.ContainsKey($typePath)) { $previewVersions[$typePath] } else { $apiVersion })
        name       = "$ServiceName/$($nameParts -join '/')"
    }
    if (-not $nameOnlyTypes.Contains($typePath)) {
        foreach ($field in @('location', 'tags', 'sku', 'identity', 'properties')) {
            if ($null -ne $item.PSObject.Properties[$field]) { $resource[$field] = $item.$field }
        }
    }
    $resources.Add($resource)
}

function Set-FileExpression([string]$expression) {
    $marker = "APIM_FILE_EXPRESSION_$($fileExpressions.Count)_END"
    $fileExpressions[$marker] = $expression
    return $marker
}

function Get-SafeName([string]$value) {
    $value = $value.Replace('/', '_')
    $name = [IO.Path]::GetFileName($value)
    if (-not $name -or $name -ne $value -or $name -in @('.', '..') -or $name.EndsWith('.')) {
        throw "Nome file non valido: $value"
    }
    foreach ($character in [IO.Path]::GetInvalidFileNameChars()) {
        if ($name.Contains([string]$character)) { throw "Nome file non valido: $value" }
    }
    return $name
}

function Get-SafeResourceName([string]$name) {
    return [regex]::Replace($name, '[^a-zA-Z0-9_.-]', '_')
}

function Get-BicepPath([string]$relativePath) {
    return "'./$($relativePath.Replace('\', '/').Replace("'", "\'"))'"
}

function Export-TextContent($node, [string]$resourceKey, [string]$propertyKey, [string]$destination) {
    if ($node -is [pscustomobject]) {
        foreach ($property in $node.PSObject.Properties) {
            $property.Value = Export-TextContent $property.Value $resourceKey "$propertyKey-$($property.Name)" $destination
        }
        return $node
    }
    if ($node -is [array]) {
        for ($i = 0; $i -lt $node.Count; $i++) {
            $node[$i] = Export-TextContent $node[$i] $resourceKey "$propertyKey-$i" $destination
        }
        return ,$node
    }
    if ($node -is [string] -and $node -match '(?is)^\s*(?:<!doctype\s+html|<html\b|<(?:p|div|span|h[1-6]|table|ul|ol|a|img|style|script)\b)') {
        $filename = (Get-SafeResourceName "$resourceKey-$propertyKey") + '.html'
        $path = Join-Path $destination $filename
        [IO.File]::WriteAllText($path, $node, [Text.UTF8Encoding]::new($false))
        return Set-FileExpression "loadTextContent($(Get-BicepPath "html/$filename"))"
    }
    return $node
}

function Export-PolicyAndHtml([string]$target) {
    $policyDirectory = Join-Path $target 'policies'
    $htmlDirectory = Join-Path $target 'html'
    $null = New-Item -Path $policyDirectory, $htmlDirectory -ItemType Directory -Force
    $policyCount = 0
    $htmlCount = 0
    foreach ($resource in $resources) {
        if (-not $resource.Contains('properties')) { continue }
        $key = Get-SafeResourceName "$($resource.type.Replace('Microsoft.ApiManagement/service/', ''))-$($resource.name)"
        if ($resource.type -match '/(?:policies|policyFragments)$' -and
            $resource.properties.PSObject.Properties['value'] -and
            $resource.properties.value -is [string]) {
            $filename = "$key.xml"
            [IO.File]::WriteAllText((Join-Path $policyDirectory $filename), $resource.properties.value, [Text.UTF8Encoding]::new($false))
            $resource.properties.value = Set-FileExpression "loadTextContent($(Get-BicepPath "policies/$filename"))"
            $policyCount++
        }
        else {
            $before = $fileExpressions.Count
            $resource.properties = Export-TextContent $resource.properties $key 'properties' $htmlDirectory
            $htmlCount += $fileExpressions.Count - $before
        }
    }
    return @{ policies = $policyCount; html = $htmlCount }
}

function Visit-Children([string]$parentPath, [string]$parentType) {
    if (-not $rules.ContainsKey($parentType)) { return }
    foreach ($collection in $rules[$parentType]) {
        $typePath = if ($parentType) { "$parentType/$collection" } else { $collection }
        $collectionPath = if ($parentPath) { "$parentPath/$collection" } else { $collection }
        if ($NoApis -and $apiOpsTypes.Contains($typePath) -and -not $rules.ContainsKey($typePath)) { continue }
        $version = if ($previewVersions.ContainsKey($typePath)) { $previewVersions[$typePath] } else { $apiVersion }
        $items = @(Get-Collection $collectionPath $version)
        foreach ($item in $items) {
            if (-not $item.name) { throw "Risorsa priva di name in $collectionPath" }
            $relativeId = "$collectionPath/$([uri]::EscapeDataString($item.name))"
            if (-not ($NoApis -and $apiOpsTypes.Contains($typePath))) {
                $detail = if ($nameOnlyTypes.Contains($typePath)) {
                    $item
                }
                else {
                    Invoke-Arm "$armBase/$relativeId`?api-version=$version"
                }
                Add-Resource $detail $relativeId $typePath
            }
            Visit-Children $relativeId $typePath
        }
        if ($items.Count) { Write-Host "$collectionPath : $($items.Count)" }
    }
}

function Export-PortalMedia([string]$destination) {
    $contentItems = @($resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/contentTypes/contentItems' -and $_.name -match '/blob/' })
    $byBlobId = @{}
    $reservedNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $contentItems | Sort-Object name) {
        $id = [string]$item.name.Split('/')[-1]
        if (-not $id -or $byBlobId.ContainsKey($id) -or ($item.properties.blobId -and $item.properties.blobId -ne $id)) {
            throw "ID del media mancante, duplicato o incoerente: $($item.name)"
        }
        $filename = Get-SafeName ([string]$item.properties.fileName)
        if (-not $reservedNames.Add($filename)) {
            $filename = [IO.Path]::GetFileNameWithoutExtension($filename) + "_$id" + [IO.Path]::GetExtension($filename)
            if (-not $reservedNames.Add($filename)) { throw "Nome media duplicato: $filename" }
        }
        $byBlobId[$id] = @{ resource = $item; filename = $filename; downloaded = $false }
    }
    $secrets = Invoke-Arm "$armBase/portalSettings/mediaContent/listSecrets?api-version=$apiVersion" -method POST
    if (-not $secrets.containerSasUrl) { throw 'SAS dei media del Developer Portal assente.' }
    $sas = [uri]$secrets.containerSasUrl
    $root = $sas.GetLeftPart([UriPartial]::Path)
    $query = $sas.Query.TrimStart('?')
    $marker = ''
    $count = 0
    $chunked = 0
    $orphans = [System.Collections.Generic.List[string]]::new()
    $null = New-Item -Path $destination -ItemType Directory -Force
    do {
        $listUri = "$root`?restype=container&comp=list&maxresults=5000&$query"
        if ($marker) { $listUri += '&marker=' + [uri]::EscapeDataString($marker) }
        # Non scrivere mai l'URL SAS nei messaggi di errore o nei file di output.
        try {
            $xmlText = (Invoke-WebRequest -Uri $listUri).Content.TrimStart([char]0xFEFF)
            [xml]$listing = $xmlText
        }
        catch { throw 'Impossibile elencare i media del Developer Portal (SAS o risposta XML non valida).' }
        foreach ($blob in @($listing.EnumerationResults.Blobs.Blob)) {
            if (-not $blob.Name) { continue }
            $blobId = [string]$blob.Name
            if ($byBlobId.ContainsKey($blobId)) {
                $entry = $byBlobId[$blobId]
                $name = $entry.filename
            }
            else {
                $name = Get-SafeName $blobId
                $baseName = [IO.Path]::GetFileNameWithoutExtension($name)
                $extension = [IO.Path]::GetExtension($name)
                $suffix = 0
                while (-not $reservedNames.Add($name)) {
                    $suffix++
                    $name = "${baseName}_$suffix$extension"
                }
                $orphans.Add($blobId)
            }
            $filename = [IO.Path]::GetFullPath((Join-Path $destination $name))
            $mediaRoot = [IO.Path]::GetFullPath($destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $filename.StartsWith($mediaRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Nome blob non valido: percorso esterno alla cartella dei media.'
            }
            $encoded = ($blob.Name.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            try { Invoke-WebRequest -Uri "$root/$encoded`?$query" -OutFile $filename | Out-Null }
            catch { Write-Warning "Download media non riuscito: $($blob.Name) (verificare SAS e connettivita')." }
            if ($entry) { $entry.downloaded = $true; $entry = $null }
            $count++
        }
        $marker = [string]$listing.EnumerationResults.NextMarker
    } while ($marker)
    foreach ($id in @($byBlobId.Keys | Sort-Object)) {
        $entry = $byBlobId[$id]
        if (-not $entry.downloaded) {
            $url = [string]$entry.resource.properties.downloadUrl
            if (-not $url) { throw "Media $id non presente nello storage e privo di downloadUrl." }
            $uri = [uri]$url
            if ($uri.Scheme -ne 'https') { Write-Warning "downloadUrl non HTTPS per media $id" }
            try { Invoke-WebRequest -Uri $uri -OutFile (Join-Path $destination $entry.filename) | Out-Null }
            catch { Write-Warning "Download media non riuscito per $id (verificare il downloadUrl)."; continue }
            $entry.downloaded = $true
            $count++
        }
        $file = Join-Path $destination $entry.filename
        $parts = [System.Collections.Generic.List[string]]::new()
        $bytes = [IO.File]::ReadAllBytes($file)
        if ($bytes.Length -gt 92160) {
            $chunked++
            $partDir = Join-Path $destination "parts\$id"
            $null = New-Item -Path $partDir -ItemType Directory -Force
            for ($offset = 0; $offset -lt $bytes.Length; $offset += 92160) {
                $size = [Math]::Min(92160, $bytes.Length - $offset)
                $part = [byte[]]::new($size)
                [array]::Copy($bytes, $offset, $part, 0, $size)
                $partName = '{0:D4}.part' -f ($parts.Count + 1)
                [IO.File]::WriteAllBytes((Join-Path $partDir $partName), $part)
                $parts.Add("loadFileAsBase64($(Get-BicepPath "portal-media/parts/$id/$partName"))")
            }
        }
        else {
            $parts.Add("loadFileAsBase64($(Get-BicepPath "portal-media/$($entry.filename)"))")
        }
        $expression = if ($parts.Count -eq 1) { $parts[0] } else { "concat($($parts -join ', '))" }
        $entry.resource.properties.PSObject.Properties.Remove('downloadUrl')
        $entry.resource.properties | Add-Member -NotePropertyName data -NotePropertyValue (Set-FileExpression $expression) -Force
    }
    return @{ count = $count; orphans = $orphans.ToArray(); chunked = $chunked }
}

try {
    $service = Invoke-Arm "$armBase`?api-version=$apiVersion"
    if ($service.id -ine $serviceId) { throw "Istanza APIM inattesa: $($service.id)" }
    $root = [ordered]@{ type = 'Microsoft.ApiManagement/service'; apiVersion = $apiVersion; name = $ServiceName }
    foreach ($field in @('location', 'tags', 'sku', 'identity', 'properties')) {
        if ($null -ne $service.PSObject.Properties[$field]) { $root[$field] = $service.$field }
    }
    $resources.Add($root)
    Visit-Children '' ''

    $target = [IO.Path]::GetFullPath($OutputDirectory)
    $null = New-Item -Path $target -ItemType Directory -Force
    $media = Export-PortalMedia (Join-Path $target 'portal-media')
    Remove-ReadOnlyProperties
    $text = Export-PolicyAndHtml $target
    $template = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        resources      = $resources.ToArray()
    }
    $intermediate = Join-Path $target '_apim-intermediate.json'
    $generated = Join-Path $target '_apim-intermediate.bicep'
    $compiled = Join-Path $target '_apim-compile-check.json'
    try {
        [IO.File]::WriteAllText($intermediate, (ConvertTo-Json -InputObject $template -Depth 100), [Text.UTF8Encoding]::new($false))
        & az bicep decompile --file $intermediate --force --only-show-errors
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $generated)) { throw 'Decompilazione Bicep non riuscita.' }
        $source = [IO.File]::ReadAllText($generated)
        foreach ($marker in $fileExpressions.Keys) {
            $literal = "'$marker'"
            if ($source.IndexOf($literal, [StringComparison]::Ordinal) -lt 0) { throw "Riferimento Bicep non trovato: $marker" }
            $source = $source.Replace($literal, $fileExpressions[$marker])
        }
        $bicepFile = Join-Path $target 'main.bicep'
        [IO.File]::WriteAllText($bicepFile, $source, [Text.UTF8Encoding]::new($false))
        & az bicep build --file $bicepFile --outfile $compiled --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Compilazione Bicep non riuscita.' }
        $compiledBytes = (Get-Item -LiteralPath $compiled).Length
        $lint = (& az bicep lint --file $bicepFile --diagnostics-format sarif 2>&1) -join "`n"
        $lintExitCode = $LASTEXITCODE
        $readOnlyLintWarnings = [regex]::Matches($lint, '"ruleId"\s*:\s*"BCP073"').Count
        $otherLintWarnings = [regex]::Matches($lint, '"ruleId"\s*:\s*"BCP(?!073)\d+"').Count
        if ($lintExitCode -ne 0) {
            Write-Warning "Linter Bicep non riuscito (codice $lintExitCode). Verificare manualmente main.bicep."
        }
        if ($readOnlyLintWarnings) {
            Write-Warning "Il Bicep contiene ancora $readOnlyLintWarnings proprieta read-only (BCP073). Aggiornare la mappa readOnlyPaths."
        }
    }
    finally {
        foreach ($temporary in @($intermediate, $generated, $compiled)) {
            if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
    $report = [ordered]@{
        resourceId = $serviceId
        apiVersion = $apiVersion
        noApis = [bool]$NoApis
        armResourceCount = $resources.Count
        removedReadOnlyProperties = $removedReadOnly
        portalMediaCount = $media.count
        chunkedMediaCount = $media.chunked
        portalMediaWithoutContentItem = $media.orphans
        extractedPolicies = $text.policies
        extractedHtml = $text.html
        compiledArmBytes = $compiledBytes
        fitsSingleArmDeployment = ($compiledBytes -le 4MB)
        bicepLintExitCode = $lintExitCode
        readOnlyBicepWarnings = $readOnlyLintWarnings
        otherBicepWarnings = $otherLintWarnings
        unavailableCollections = @($unavailable | Sort-Object -Unique)
        coverage = $(if ($unavailable.Count) {
            'Non verificabile per le collection HTTP 404 elencate (possono essere vuote o non supportate).'
        } else {
            'Tutte le collection interrogate hanno risposto.'
        })
        caveats = @(
            'I segreti non restituiti da ARM (password, chiavi, valori segreti) non sono recuperabili dallo snapshot.'
            'I media del Developer Portal sono blob separati; non sono risorse del template ARM.'
            'Il sorgente Bicep contiene anche proprieta di sola lettura: verificarlo prima del redeploy.'
            'La compilazione Bicep incorpora i media: il template ARM risultante puo superare il limite ARM di 4 MB.'
        )
    }
    [IO.File]::WriteAllText((Join-Path $target 'report.json'), (ConvertTo-Json -InputObject $report -Depth 10), [Text.UTF8Encoding]::new($false))
    Write-Host "Dump: $target ($($resources.Count) risorse, $($media.count) media, $($text.policies) XML, $($text.html) HTML). Collection 404: $(@($unavailable | Sort-Object -Unique).Count)."
    if ($compiledBytes -gt 4MB) {
        Write-Warning "ARM compilato: $compiledBytes byte (> 4 MiB). Il Bicep e' valido, ma non puo' essere distribuito come singolo template ARM."
    }
}
finally {
    $token = $null
    $headers.Clear()
}
