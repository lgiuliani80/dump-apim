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

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
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

function az {
    if ($args[0] -eq 'account') {
        $global:LASTEXITCODE = 0
        return 'offline-test-token'
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
    if ($path -eq 'portalSettings/mediaContent/listSecrets') {
        Assert-True ($Method -eq 'POST') 'listSecrets deve usare POST'
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
    param([string]$Uri)
    Assert-True (([uri]$Uri).Host -eq 'offline.invalid') 'Richiesta media inattesa'
    return [pscustomobject]@{ Content = '<EnumerationResults><Blobs/><NextMarker/></EnumerationResults>' }
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
        Assert-True (@($arm.resources | Where-Object type -EQ 'Microsoft.ApiManagement/service/contentTypes/contentItems').Count -eq 1) 'Content item omesso'
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
        $content = $arm.resources | Where-Object type -EQ 'Microsoft.ApiManagement/service/contentTypes/contentItems'
        Assert-True ($content.properties.document.reference -match "parameters\('serviceName'\)") 'Riferimento annidato non parametrizzato'
        Assert-True ($content.properties.document.nested[0].id -match "parameters\('serviceName'\)") 'ID case-insensitive non parametrizzato'
        Assert-True ($content.properties.document.nested[1].id -eq "$fixtureServiceId-other/apis/example") 'Riferimento ad altra istanza alterato'
        $htmlValue = $content.properties.document.html
        if ($htmlValue -match "^\[variables\('([^']+)'\)\]$") { $htmlValue = $arm.variables.($Matches[1]) }
        Assert-True ($htmlValue -eq '<p>Offline test</p>') "Estrazione HTML alterata: $htmlValue"
        Assert-True ($report.extractedHtml -eq 1) 'File HTML non estratto'
        Assert-True ($report.extractedPolicies -eq [int](-not $flags.NoApis)) 'Estrazione policy alterata'
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
