#requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$azCommand = (Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$scriptPath = Join-Path $PSScriptRoot '..\Dump-ApimArm.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("apim-dump-tests-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $testRoot -ItemType Directory
$fixtureServiceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.ApiManagement/service/source-apim'
$fixture = [ordered]@{}
$requests = [System.Collections.Generic.List[string]]::new()
$compiledTemplates = [System.Collections.Generic.List[object]]::new()
$uploadCalls = [System.Collections.Generic.List[object]]::new()
$uploadState = @{ failAt = 0 }

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Resolve-CompiledValue($template, $value) {
    if ($value -is [string] -and $value -match "^\[variables\('([^']+)'\)(?:\.([^\]]+))?\]$") {
        $name = $Matches[1]
        $property = $Matches[2]
        $resolved = Resolve-CompiledValue $template $template.variables.$name
        if ($property) { return $resolved.$property }
        return $resolved
    }
    return $value
}

function Add-Fixture([string]$path, [hashtable]$properties = @{}) {
    $fixture[$path] = [pscustomobject]@{
        name = [uri]::UnescapeDataString($path.Split('/')[-1])
        properties = [pscustomobject]$properties
    }
}

foreach ($name in @('page', 'document', 'layout', 'blogpost', 'blob', 'url', 'navigation', 'block', 'popup', 'custom')) {
    Add-Fixture "contentTypes/$name" @{ displayName = $name }
}
Add-Fixture 'contentTypes/page/contentItems/home' @{
    document = @{
        reference = "$fixtureServiceId/apis/example"
        nested = @(@{ id = $fixtureServiceId.ToUpperInvariant() }, @{ id = "$fixtureServiceId-other/apis/example" })
        html = '<p>Offline test</p>'
    }
}
Add-Fixture 'policies/policy' @{
    format = 'rawxml'
    value = '<policies><inbound/><backend/><outbound/><on-error/></policies>'
}
foreach ($id in @('large', 'small', 'fallback')) {
    Add-Fixture "contentTypes/blob/contentItems/$id" @{
        blobId = $id
        fileName = $(if ($id -eq 'fallback') { 'fallback.pdf' } else { 'shared image.png' })
        contentType = $(if ($id -eq 'fallback') { 'application/pdf' } else { 'image/png' })
        downloadUrl = "https://offline.invalid/media/$id"
        data = 'obsolete-inline-data'
    }
}
foreach ($name in @('delegation', 'default', 'signin')) {
    Add-Fixture "portalsettings/$name" @{ enabled = $true }
}
Add-Fixture 'users/admin' @{ firstName = 'Test'; lastName = 'User'; email = 'test@example.com'; state = 'active' }
Add-Fixture 'groups/developers' @{ displayName = 'Developers' }
Add-Fixture 'groups/developers/users/admin'
Add-Fixture 'subscriptions/test' @{
    displayName = 'Test'
    ownerId = "$fixtureServiceId/users/admin"
    scope = $fixtureServiceId
    state = 'active'
}
Add-Fixture 'products/test' @{ displayName = 'Test'; subscriptionRequired = $false }
Add-Fixture 'products/test/groups/developers'
Add-Fixture 'products/test/groupLinks/test' @{ groupId = "$fixtureServiceId/groups/developers" }
Add-Fixture 'notifications/RequestPublisherNotificationMessage'
Add-Fixture 'notifications/RequestPublisherNotificationMessage/recipientUsers/admin'
Add-Fixture 'notifications/RequestPublisherNotificationMessage/recipientEmails/test@example.com'
Add-Fixture 'workspaces/test' @{ displayName = 'Test' }
Add-Fixture 'workspaces/test/groups/developers' @{ displayName = 'Developers' }
Add-Fixture 'workspaces/test/groups/developers/users/admin'
Add-Fixture 'workspaces/test/subscriptions/test' @{ displayName = 'Test'; scope = "$fixtureServiceId/workspaces/test"; state = 'active' }
Add-Fixture 'workspaces/test/products/test' @{ displayName = 'Test'; subscriptionRequired = $false }
Add-Fixture 'workspaces/test/products/test/groupLinks/test' @{ groupId = "$fixtureServiceId/workspaces/test/groups/developers" }
Add-Fixture 'workspaces/test/notifications/RequestPublisherNotificationMessage'
Add-Fixture 'workspaces/test/notifications/RequestPublisherNotificationMessage/recipientUsers/admin'
Add-Fixture 'workspaces/test/notifications/RequestPublisherNotificationMessage/recipientEmails/test@example.com'
Add-Fixture 'identityProviders/aad' @{ type = 'aad'; clientId = 'offline-client'; allowedTenants = @('offline-tenant') }
Add-Fixture 'portalRevisions/old' @{ description = 'Old'; isCurrent = $false }
Add-Fixture 'portalRevisions/current' @{ description = 'Current'; isCurrent = $true }
foreach ($prefix in @('', 'workspaces/test/')) {
    Add-Fixture "${prefix}apis/example" @{ displayName = 'Example'; path = 'example'; protocols = @('https') }
    Add-Fixture "${prefix}apis/example/releases/test" @{ apiId = "$fixtureServiceId/${prefix}apis/example" }
    Add-Fixture "${prefix}namedValues/test" @{ displayName = 'Test'; value = 'test' }
    Add-Fixture "${prefix}tags/test" @{ displayName = 'Test' }
}

function az {
    if ($args[0] -eq 'account') {
        $global:LASTEXITCODE = 0
        return 'offline-test-token'
    }
    if ($args[0] -eq 'rest') {
        $url = $args[[array]::IndexOf($args, '--url') + 1]
        Assert-True ($url -eq 'https://management.azure.com/subscriptions/target-sub/resourceGroups/target-group/providers/Microsoft.ApiManagement/service/target-apim/portalconfigs/default/listMediaContentSecrets?api-version=2021-08-01') 'Endpoint upload SAS errato'
        Assert-True ($args[[array]::IndexOf($args, '--method') + 1] -eq 'post') 'Metodo upload SAS errato'
        $global:LASTEXITCODE = 0
        return 'https://target.blob.core.windows.net/target-media?sig=secret-upload'
    }
    if ($args[0] -eq 'storage') {
        Assert-True ($env:AZURE_STORAGE_SAS_TOKEN -eq 'sig=secret-upload') 'SAS upload assente'
        Assert-True ($args -notcontains '--sas-token') 'SAS esposta negli argomenti CLI'
        Assert-True ($args[[array]::IndexOf($args, '--container-name') + 1] -eq 'target-media') 'Container upload errato'
        Assert-True ($args[[array]::IndexOf($args, '--blob-endpoint') + 1] -eq 'https://target.blob.core.windows.net') 'Endpoint blob errato'
        $file = $args[[array]::IndexOf($args, '--file') + 1]
        Assert-True (Test-Path -LiteralPath $file -PathType Leaf) 'File upload assente'
        $uploadCalls.Add(@{
            name = $args[[array]::IndexOf($args, '--name') + 1]
            file = $file
            contentType = $args[[array]::IndexOf($args, '--content-type') + 1]
        })
        $global:LASTEXITCODE = if ($uploadCalls.Count -eq $uploadState.failAt) { 1 } else { 0 }
        return
    }
    if ($args[0] -ne 'bicep') { throw "Comando az inatteso: $args" }
    & $azCommand @args
    if ($LASTEXITCODE -eq 0 -and $args[1] -eq 'build') {
        $outfileIndex = [array]::IndexOf($args, '--outfile')
        Assert-True ($outfileIndex -ge 0) 'Percorso ARM compilato mancante'
        $compiledTemplates.Add((Get-Content -LiteralPath $args[$outfileIndex + 1] -Raw | ConvertFrom-Json))
    }
}

function Invoke-RestMethod {
    param([string]$Uri, $Headers, [string]$Method)
    $url = [uri]$Uri
    Assert-True ($url.Host -eq 'management.azure.com') "Host ARM inatteso: $($url.Host)"
    Assert-True ($url.AbsolutePath.StartsWith($fixtureServiceId)) 'ID APIM inatteso'
    $path = [uri]::UnescapeDataString($url.AbsolutePath.Substring($fixtureServiceId.Length).TrimStart('/'))
    $requests.Add($path)
    if (-not $path) {
        return [pscustomobject]@{
            id = $fixtureServiceId
            location = 'westeurope'
            sku = [pscustomobject]@{ name = 'Developer'; capacity = 1 }
            properties = [pscustomobject]@{ publisherEmail = 'test@example.com'; publisherName = 'Offline test' }
        }
    }
    if ($path -eq 'portalconfigs/default/listMediaContentSecrets') {
        Assert-True ($Method -eq 'POST') 'listSecrets deve usare POST'
        Assert-True ($url.Query -eq '?api-version=2021-08-01') 'Versione API media errata'
        return [pscustomobject]@{ containerSasUrl = 'https://offline.invalid/media?sig=offline' }
    }
    if ($fixture.Contains($path)) {
        return $fixture[$path] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    }
    $items = @(
        foreach ($key in $fixture.Keys) {
            if ($key.StartsWith("$path/") -and -not $key.Substring($path.Length + 1).Contains('/')) {
                $fixture[$key]
            }
        }
    )
    return [pscustomobject]@{ value = $items; nextLink = $null }
}

function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile)
    Assert-True (([uri]$Uri).Host -eq 'offline.invalid') 'Richiesta media inattesa'
    if ($OutFile) {
        $size = if (([uri]$Uri).AbsolutePath -eq '/media/large') { 5MB } else { 128 }
        [IO.File]::WriteAllBytes($OutFile, [byte[]]::new($size))
        return
    }
    return [pscustomobject]@{ Content = @'
<EnumerationResults><Blobs>
<Blob><Name>large</Name><Properties><Content-Type>image/png</Content-Type></Properties></Blob>
<Blob><Name>small</Name><Properties><Content-Type>image/png</Content-Type></Properties></Blob>
<Blob><Name>orphan/path with space.svg</Name><Properties><Content-Type>image/svg+xml</Content-Type></Properties></Blob>
</Blobs><NextMarker/></EnumerationResults>
'@ }
}

$scenarios = @(
    @{ Name = 'default'; Flags = @{} },
    @{ Name = 'subscriptions'; Flags = @{ NoSubscriptions = $true } },
    @{ Name = 'users-groups'; Flags = @{ NoUsersGroups = $true } },
    @{ Name = 'existing'; Flags = @{ AsExisting = $true } },
    @{ Name = 'all'; Flags = @{ NoSubscriptions = $true; NoUsersGroups = $true; AsExisting = $true } },
    @{ Name = 'apiops'; Flags = @{ NoApis = $true } },
    @{ Name = 'apiops-all'; Flags = @{ NoApis = $true; NoSubscriptions = $true; NoUsersGroups = $true; AsExisting = $true } }
)

$originalLocation = Get-Location
$originalProcessDirectory = [Environment]::CurrentDirectory
try {
    $powershellDirectory = [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar)
    $processDirectory = $PSScriptRoot
    Set-Location -LiteralPath $powershellDirectory
    [Environment]::CurrentDirectory = $processDirectory
    foreach ($scenario in $scenarios) {
        $requests.Clear()
        $relativeOutput = Join-Path 'relative output' $scenario.Name
        $output = Join-Path $testRoot $relativeOutput
        $outputArgument = if ($scenario.Name -eq 'default') { ".\$(Split-Path $testRoot -Leaf)\$relativeOutput" } else { $output }
        $flags = $scenario.Flags
        & $scriptPath -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroupName test -ServiceName source-apim -OutputDirectory $outputArgument @flags
        Assert-True ((Get-Location).Path -eq $powershellDirectory) 'Directory PowerShell modificata'
        Assert-True ([Environment]::CurrentDirectory -eq $processDirectory) 'Directory del processo modificata'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $processDirectory (Split-Path $testRoot -Leaf)))) 'Output creato nella directory del processo'
        foreach ($directory in @('portal-media', 'html', 'policies')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $output $directory) -PathType Container) "Directory di output mancante: $directory"
        }
        $bicep = Join-Path $output 'main.bicep'
        $source = [IO.File]::ReadAllText($bicep)
        $report = Get-Content -LiteralPath (Join-Path $output 'report.json') -Raw | ConvertFrom-Json
        Assert-True ($compiledTemplates.Count -eq 1) "Compilazione mancante: $($scenario.Name)"
        $arm = $compiledTemplates[0]
        $compiledTemplates.Clear()
        Assert-True ($arm.parameters.serviceName.defaultValue -eq 'source-apim') 'Parametro serviceName mancante'
        Assert-True ($arm.parameters.identityProviderClientSecrets.type -eq 'secureObject') 'Parametro segreti non sicuro'
        Assert-True (-not $arm.parameters.identityProviderClientSecrets.PSObject.Properties['defaultValue']) 'Default segreto inatteso'
        Assert-True ($report.requiredIdentityProviderClientSecrets -contains 'aad') 'Provider privo di segreto non segnalato'
        $identity = $arm.resources | Where-Object type -EQ 'Microsoft.ApiManagement/service/identityProviders'
        Assert-True ($identity.properties.clientSecret -match "parameters\('identityProviderClientSecrets'\)") 'Segreto provider non parametrizzato'
        Assert-True (-not @($arm.resources | Where-Object type -EQ 'Microsoft.ApiManagement/service/portalRevisions').Count) 'PortalRevision esportate'
        Assert-True (-not @($requests | Where-Object { $_ -match '^portalRevisions(?:/|$)' }).Count) 'Endpoint PortalRevision interrogato'
        Assert-True ($report.noSubscriptions -eq [bool]$flags.NoSubscriptions) 'Report NoSubscriptions errato'
        Assert-True ($report.noUsersGroups -eq [bool]$flags.NoUsersGroups) 'Report NoUsersGroups errato'
        Assert-True ($report.asExisting -eq [bool]$flags.AsExisting) 'Report AsExisting errato'
        $root = @($arm.resources | Where-Object type -EQ 'Microsoft.ApiManagement/service')
        Assert-True ($root.Count -eq [int](-not $flags.AsExisting)) 'Risorsa padre existing errata'
        $existing = [regex]::Matches($source, '(?ms)^resource .*? existing = \{\r?\n(?<body>.*?)^\}')
        Assert-True ($existing.Count -eq (11 + [int][bool]$flags.AsExisting)) 'Numero risorse existing errato'
        foreach ($declaration in $existing) {
            Assert-True ($declaration.Groups['body'].Value -notmatch '(?m)^  (?!name:|parent:|scope:)\S') 'Proprieta non identitaria in existing'
        }
        $types = @($arm.resources | ForEach-Object type)
        Assert-True ($types -contains 'Microsoft.ApiManagement/service/contentTypes') 'Content type personalizzato omesso'
        Assert-True (@($arm.resources | Where-Object type -EQ 'Microsoft.ApiManagement/service/portalsettings').Count -eq 1) 'Portal settings existing distribuite'
        Assert-True (@($arm.resources | Where-Object type -EQ 'Microsoft.ApiManagement/service/contentTypes/contentItems').Count -eq 4) 'Content item omesso'
        if ($flags.NoSubscriptions) {
            Assert-True (-not @($types | Where-Object { $_ -match '/subscriptions$' }).Count) 'Sottoscrizioni non escluse'
            Assert-True (-not @($requests | Where-Object { $_ -match '(^|/)subscriptions($|/)' }).Count) 'Sottoscrizioni interrogate'
        } else {
            Assert-True (@($types | Where-Object { $_ -match '/subscriptions$' }).Count -eq 2) 'Sottoscrizioni perse'
        }
        if ($flags.NoUsersGroups) {
            Assert-True (-not @($types | Where-Object { $_ -match '/(users|groups|groupLinks|recipientUsers)($|/)' }).Count) 'Utenti/gruppi non esclusi'
            Assert-True (-not @($requests | Where-Object { $_ -match '(^|/)(users|groups|groupLinks|recipientUsers)($|/)' }).Count) 'Utenti/gruppi interrogati'
        } else {
            Assert-True ($types -contains 'Microsoft.ApiManagement/service/users') 'Utenti persi'
            Assert-True ($types -contains 'Microsoft.ApiManagement/service/workspaces/groups/users') 'Appartenenze workspace perse'
        }
        Assert-True ($types -contains 'Microsoft.ApiManagement/service/notifications/recipientEmails') 'Destinatari email persi'
        Assert-True (($types -contains 'Microsoft.ApiManagement/service/products') -eq (-not $flags.NoApis)) 'Comportamento NoApis alterato'
        if ($flags.NoApis) {
            $excludedRoots = 'apis|apiVersionSets|backends|diagnostics|gateways|loggers|namedValues|policies|policyFragments|products|tags'
            Assert-True (-not @($requests | Where-Object { $_ -match "^(?:workspaces/[^/]+/)?(?:$excludedRoots)(?:/|$)" }).Count) 'Endpoint NoApis interrogato'
            Assert-True (-not @($types | Where-Object { $_ -match "/service/(?:workspaces/)?(?:$excludedRoots)(?:/|$)" }).Count) 'Risorsa NoApis esportata'
        }
        Assert-True ($report.armRequests.Count -eq $requests.Count) 'Audit richieste ARM incompleto'
        for ($i = 0; $i -lt $requests.Count; $i++) {
            Assert-True ($report.armRequests[$i].path -eq $requests[$i]) 'Percorso audit ARM errato'
        }
        $content = $arm.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/contentTypes/contentItems' -and $_.properties.document }
        Assert-True ($content.properties.document.reference -match "parameters\('serviceName'\)") 'Riferimento annidato non parametrizzato'
        Assert-True ($content.properties.document.nested[0].id -match "parameters\('serviceName'\)") 'ID case-insensitive non parametrizzato'
        Assert-True ($content.properties.document.nested[1].id -eq "$fixtureServiceId-other/apis/example") 'Riferimento ad altra istanza alterato'
        $htmlValue = $content.properties.document.html
        if ($htmlValue -match "^\[variables\('([^']+)'\)\]$") { $htmlValue = $arm.variables.($Matches[1]) }
        Assert-True ($htmlValue -eq '<p>Offline test</p>') "Estrazione HTML alterata: $htmlValue"
        Assert-True ($report.extractedHtml -eq 1) 'File HTML non estratto'
        Assert-True ($report.extractedPolicies -eq [int](-not $flags.NoApis)) 'Estrazione policy alterata'
        Assert-True ($source.Contains("loadJsonContent('./portal-media-urls.json')")) 'Dizionario JSON non letto dal Bicep'
        Assert-True ($source -notmatch 'loadFileAsBase64|\.part|APIM_FILE_EXPRESSION_') 'Base64, chunk o marker residui nel Bicep'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $output 'portal-media\parts'))) 'Chunking non rimosso'
        Assert-True ($report.portalMediaCount -eq 4) 'Numero media errato'
        Assert-True (-not $report.PSObject.Properties['chunkedMediaCount']) 'Conteggio chunk residuo'
        Assert-True ($report.compiledArmBytes -lt 100KB) 'Media incorporati nel template ARM'
        $mediaItems = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/contentTypes/contentItems' -and $_.properties.blobId })
        Assert-True ($mediaItems.Count -eq 3) 'Content item binari mancanti'
        foreach ($item in $mediaItems) {
            Assert-True (-not $item.properties.PSObject.Properties['data']) 'Proprieta data residua'
            Assert-True ([bool]$item.properties.downloadUrl) 'downloadUrl assente'
        }
        $manifest = Get-Content -LiteralPath (Join-Path $output 'portal-media-manifest.json') -Raw | ConvertFrom-Json
        Assert-True ($manifest.Count -eq 4) 'Manifest incompleto'
        Assert-True (@($manifest.fileName | Sort-Object -Unique).Count -eq 4) 'Nomi file non disambiguati'
        $large = $manifest | Where-Object blobName -EQ 'large'
        Assert-True ((Get-Item -LiteralPath (Join-Path $output "portal-media\$($large.fileName)")).Length -eq 5MB) 'File grande alterato'
        $urlsPath = Join-Path $output 'portal-media-urls.json'
        $originalUrls = [IO.File]::ReadAllText($urlsPath)
        Assert-True ($originalUrls -notmatch '\?|sig=') 'SAS salvata nel dizionario'
        if ($scenario.Name -eq 'default') {
            $uploader = Join-Path $output 'Upload-PortalMedia.ps1'
            $previousSas = $env:AZURE_STORAGE_SAS_TOKEN
            try {
                $env:AZURE_STORAGE_SAS_TOKEN = 'previous-token'
                $uploadState.failAt = 2
                $failed = $false
                try { & $uploader -SubscriptionId target-sub -ResourceGroupName target-group -ServiceName target-apim }
                catch {
                    Assert-True ($_.Exception.Message -match '^Upload media non riuscito:') 'Errore upload inatteso'
                    $failed = $true
                }
                Assert-True $failed 'Errore upload ignorato'
                Assert-True ([IO.File]::ReadAllText($urlsPath) -eq $originalUrls) 'Dizionario modificato dopo upload parziale'
                Assert-True ($env:AZURE_STORAGE_SAS_TOKEN -eq 'previous-token') 'SAS precedente non ripristinata dopo errore'
                $uploadState.failAt = 0
                $uploadCalls.Clear()
                & $uploader -SubscriptionId target-sub -ResourceGroupName target-group -ServiceName target-apim
                Assert-True ($env:AZURE_STORAGE_SAS_TOKEN -eq 'previous-token') 'SAS precedente non ripristinata'
                Assert-True ($uploadCalls.Count -eq 4) 'Media non caricati tutti'
                Assert-True ($uploadCalls.name -contains 'orphan/path with space.svg') 'Blob orfano non caricato con nome originale'
                $urls = Get-Content -LiteralPath $urlsPath -Raw | ConvertFrom-Json -AsHashtable
                foreach ($id in @('large', 'small', 'fallback')) {
                    Assert-True ($urls[$id] -eq "https://target.blob.core.windows.net/target-media/$id") 'URL destinazione errata'
                }
                Assert-True ([IO.File]::ReadAllText($urlsPath) -notmatch 'sig=|\?') 'SAS salvata dopo upload'
                $recompiled = Join-Path $output 'recompiled.json'
                & az bicep build --file $bicep --outfile $recompiled --only-show-errors
                Assert-True ($LASTEXITCODE -eq 0) 'Ricompilazione dopo upload fallita'
                $updated = $compiledTemplates[0]
                $compiledTemplates.Clear()
                $updatedMedia = @($updated.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/contentTypes/contentItems' -and $_.properties.blobId })
                foreach ($item in $updatedMedia) {
                    $resolvedUrl = Resolve-CompiledValue $updated $item.properties.downloadUrl
                    Assert-True ($resolvedUrl -eq $urls[$item.properties.blobId]) "Bicep non usa URL aggiornate: $resolvedUrl"
                }
            }
            finally {
                $env:AZURE_STORAGE_SAS_TOKEN = $previousSas
            }
        }
        foreach ($resource in $arm.resources) {
            Assert-True ($resource.name -match "parameters\('serviceName'\)") "Nome non parametrizzato: $($resource.type)"
        }
        Assert-True (-not @(Get-ChildItem -LiteralPath $output -Filter '_apim-*').Count) 'File intermedi non rimossi'
        Write-Host "PASS: $($scenario.Name)"
    }
}
finally {
    Set-Location -LiteralPath $originalLocation.Path
    [Environment]::CurrentDirectory = $originalProcessDirectory
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
