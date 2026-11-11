<#
.SYNOPSIS
    Downloads LS Retail / LS Central .app files of a given version from LS Retail's public
    Update Service server (no Update Service client, no login). Non-interactive, CI friendly.

.DESCRIPTION
    Produces two zips in OutputFolder:
      app.zip       the requested packages (default LS Central) plus the LS Retail apps they depend
                    on (LS Central System App, License Manager, EFT, Telemetry, ...)
      test_app.zip  the test packages (default LS Central Autotests), in the version that was built
                    for the chosen LS Central version

    Each dependency gets the lowest released version that satisfies the requirement, i.e. the
    version the package was built against. Microsoft apps (System, Base Application, ...) are
    skipped unless -IncludeMicrosoftApps is set.

    Every file is checked against the SHA1 hash from the server. A zip is only rewritten when its
    content changes, and apps already in it are not downloaded again.

    Anonymous REST endpoints used (https://updateservice.lsretail.com):
      /api/SourceList                              catalogue with all package versions
      /api/v1/Packages/{id}/{version}/files        file list (name, size, SHA1 hash)
      /api/v1/Files/{hash}                         raw file content

.PARAMETER Version
    Version of the requested packages: 'latest', a major ('28'), major.minor ('28.2') or an exact
    version ('28.2.19'). A partial version takes the highest released version that starts with it.

.PARAMETER Packages
    Update Service package ids for app.zip. Default 'ls-central-app' (LS Central W1).
    Examples: ls-central-app-runtime, ls-hotels-app.
    Accepts an array or one comma separated string (handy from a workflow input).

.PARAMETER TestPackages
    Update Service package ids for test_app.zip. Default 'ls-central-autotests-app'.
    The version is the newest one built against the packages resolved for app.zip; if a test
    package does not depend on any of them, -Version is used. Pass '' to skip the test zip.
    Only the test apps themselves go in; their dependencies are already in app.zip.

.PARAMETER OutputFolder
    Where the result goes. Created if missing. Default: 'LS Central/latest' under the current folder.

.PARAMETER ZipFile
    Name of the zip for the apps, inside OutputFolder (or a full path). Default 'app.zip'.
    Pass '' to save loose .app files instead.

.PARAMETER TestZipFile
    Name of the zip for the test apps. Default 'test_app.zip'. Pass '' for loose .app files.

.PARAMETER IncludeMicrosoftApps
    Also download the Microsoft apps the packages depend on (bc-system-symbols, bc-application,
    bc-base-application, bc-system-application, ...) into app.zip.

.PARAMETER NoDependencies
    Put only the requested packages in app.zip.

.PARAMETER IncludePrerelease
    Allow -rc / preview versions (normally only released versions are considered).

.PARAMETER Clean
    Delete existing loose *.app files in OutputFolder before downloading (only matters with
    -ZipFile '' or -TestZipFile '').

.PARAMETER ListVersions
    Only print the available versions of the requested and test packages and exit.

.EXAMPLE
    ./Get-LSCentralApps.ps1 -Version 28.2     # -> 'LS Central/latest/app.zip' and 'test_app.zip'

.EXAMPLE
    ./Get-LSCentralApps.ps1 -Version latest -TestPackages '' -IncludeMicrosoftApps

.EXAMPLE
    ./Get-LSCentralApps.ps1 -ListVersions
#>
[CmdletBinding()]
param(
    [string]   $Version      = 'latest',
    [string[]] $Packages     = @('ls-central-app'),
    [string[]] $TestPackages = @('ls-central-autotests-app'),
    [string]   $OutputFolder = 'LS Central/latest',
    [string]   $ZipFile      = 'app.zip',
    [string]   $TestZipFile  = 'test_app.zip',
    [switch]   $IncludeMicrosoftApps,
    [switch]   $NoDependencies,
    [switch]   $IncludePrerelease,
    [switch]   $Clean,
    [switch]   $ListVersions,
    [string]   $ServerUrl    = 'https://updateservice.lsretail.com'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$Server = $ServerUrl.TrimEnd('/')
function Split-Ids($List) { @($List | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() }) }
$Packages     = Split-Ids $Packages
$TestPackages = Split-Ids $TestPackages
if ($Packages.Count -eq 0) { throw 'No packages given.' }

function Invoke-Api([string]$Path) {
    $resp = Invoke-WebRequest -Uri ($Server + $Path) -UseBasicParsing
    return ($resp.Content | ConvertFrom-Json)
}

function Format-Size([double]$Bytes) { if ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f ($Bytes / 1KB) } }

# Version text -> sortable object. '29.0.5-rc.4262' => Num 29.0.5, Pre 'rc.4262'
function ConvertTo-Ver([string]$Text) {
    $t = ($Text -split '\+')[0]                         # drop build metadata (+dbee4714)
    $num, $pre = $t -split '-', 2
    $parts = @($num -split '\.' | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 2) { $parts += 0 }
    [pscustomobject]@{ Text = $t; Num = [version]($parts[0..([Math]::Min(3, $parts.Count - 1))] -join '.'); Pre = [string]$pre }
}

function Compare-Ver($A, $B) {
    $c = $A.Num.CompareTo($B.Num)
    if ($c -ne 0) { return $c }
    if (-not $A.Pre -and -not $B.Pre) { return 0 }
    if (-not $A.Pre) { return 1 }                       # release > prerelease
    if (-not $B.Pre) { return -1 }
    return [string]::CompareOrdinal($A.Pre, $B.Pre)
}

# All versions of a package, ascending. Prerelease only with -IncludePrerelease.
function Get-PackageVersions([string]$PackageId) {
    $raw = @($Catalogue.packages.$PackageId | ForEach-Object { $_ })
    $list = foreach ($p in $raw) {
        $v = ConvertTo-Ver $p.normalizedVersion
        if ($v.Pre -and -not $IncludePrerelease) { continue }
        [pscustomobject]@{ Ver = $v; Text = $v.Text; Raw = [string]$p.version; Date = [string]$p.dateTime; Deps = @($p.dependencies | ForEach-Object { $_ }) }
    }
    $sorted = [Collections.Generic.List[object]]::new()
    foreach ($item in ($list | Sort-Object { $_.Ver.Num })) {
        $i = $sorted.Count
        while ($i -gt 0 -and (Compare-Ver $sorted[$i - 1].Ver $item.Ver) -gt 0) { $i-- }
        $sorted.Insert($i, $item)
    }
    return , $sorted.ToArray()
}

function Select-RequestedVersion($Versions, [string]$Wanted) {
    if ($Versions.Count -eq 0) { return $null }
    if ($Wanted -eq '' -or $Wanted -eq 'latest') { return $Versions[-1] }
    $hit = @($Versions | Where-Object { $_.Text -eq $Wanted })
    if (-not $hit) { $hit = @($Versions | Where-Object { $_.Text -like "$Wanted.*" }) }
    if ($hit) { return $hit[-1] }
    return $null
}

# Dependency query such as '!_ >=29.0.3' or '!_ >=29.0.3-rc.4262 <29.1-0 *-rc || >=29.0.3 <29.1'
# -> one @{ Lo; Hi } per alternative (either may be $null). Prerelease alternatives are dropped
#    unless -IncludePrerelease.
function Get-QueryBounds([string]$Query) {
    $alternatives = $Query -split '\|\||>>'
    if (-not $IncludePrerelease) {
        $released = @($alternatives | Where-Object { $_ -notmatch '>=\s*\S*-' -and $_ -notmatch '\*-' })
        if ($released) { $alternatives = $released }
    }
    foreach ($alt in $alternatives) {
        $min = [regex]::Match($alt, '>=\s*(\d[\w.\-]*)')
        $max = [regex]::Match($alt, '(?<![>=])<\s*(\d[\w.\-]*)')
        [pscustomobject]@{
            Lo = if ($min.Success) { ConvertTo-Ver $min.Groups[1].Value } else { $null }
            Hi = if ($max.Success) { ConvertTo-Ver $max.Groups[1].Value } else { $null }
        }
    }
}

# Lowest version that meets the query.
function Select-DependencyVersion($Versions, [string]$Query) {
    $exact = [regex]::Match($Query, '(?<![<>])=\s*(\d[\w.\-]*)')
    if ($exact.Success) {
        $e = ConvertTo-Ver $exact.Groups[1].Value
        $hit = @($Versions | Where-Object { (Compare-Ver $_.Ver $e) -eq 0 })
        if ($hit) { return $hit[0] }
    }
    foreach ($b in (Get-QueryBounds $Query)) {
        $cand = $Versions
        if ($b.Lo) { $lo = $b.Lo; $cand = @($cand | Where-Object { (Compare-Ver $_.Ver $lo) -ge 0 }) }
        if ($b.Hi) { $hi = $b.Hi; $cand = @($cand | Where-Object { (Compare-Ver $_.Ver $hi) -lt 0 }) }
        if ($cand) { return $cand[0] }
    }
    return $Versions[-1]                                  # no usable bound (e.g. '!^'): latest
}

# Newest test package version built against the already resolved apps: every dependency on a
# resolved app must have a lower bound <= that app's version, in the same major.minor.
# Returns $null when the test package does not depend on any resolved app.
function Select-MatchingTestVersion($Versions, $Resolved) {
    $linked = $false
    for ($i = $Versions.Count - 1; $i -ge 0; $i--) {
        $cand = $Versions[$i]; $ok = $true; $any = $false
        foreach ($dep in $cand.Deps) {
            $depId = [string]$dep.packageId
            if ($dep.onlyRestrictVersion -or -not $Resolved.Contains($depId)) { continue }
            $any = $true
            $have = $Resolved[$depId].Ver
            $lo = @(Get-QueryBounds ([string]$dep.versionQuery) | Where-Object Lo | ForEach-Object Lo) | Select-Object -First 1
            if (-not $lo -or (Compare-Ver $lo $have) -gt 0 -or
                $lo.Num.Major -ne $have.Num.Major -or $lo.Num.Minor -ne $have.Num.Minor) { $ok = $false; break }
        }
        if ($any) { $linked = $true; if ($ok) { return $cand } }
    }
    if ($linked) { return 'NO_MATCH' }
    return $null
}

function Get-FileSha1([string]$Path) {
    $sha1 = [Security.Cryptography.SHA1]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try { return [Convert]::ToBase64String($sha1.ComputeHash($fs)).TrimEnd('=') } finally { $fs.Dispose(); $sha1.Dispose() }
}

function Save-PackageFile($File, [string]$OutFile) {
    $expected = ([string]$File.hash).TrimEnd('=')
    if ((Test-Path -LiteralPath $OutFile) -and (Get-FileSha1 $OutFile) -eq $expected) {
        Write-Host "    already present: $(Split-Path $OutFile -Leaf)"
        return
    }
    $part = "$OutFile.partial"
    # Hashes are base64 and may contain '/' and '+'. The server unescapes the path once before
    # routing, so a single-encoded '%2F' still breaks the route (404). Encode twice.
    $url  = $Server + '/api/v1/Files/' + [Uri]::EscapeDataString([Uri]::EscapeDataString($File.hash))
    $sw   = [Diagnostics.Stopwatch]::StartNew()
    for ($try = 1; $try -le 3; $try++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing -TimeoutSec 600
            $size = (Get-Item -LiteralPath $part).Length
            if ($size -ne [int64]$File.size) { throw "got $size of $($File.size) bytes" }
            $actual = Get-FileSha1 $part
            if ($actual -ne $expected) { throw "SHA1 mismatch (expected $expected, got $actual)" }
            Move-Item -LiteralPath $part -Destination $OutFile -Force
            Write-Host ("    downloaded: {0} ({1}, {2:N0} s)" -f (Split-Path $OutFile -Leaf), (Format-Size $size), $sw.Elapsed.TotalSeconds)
            return
        } catch {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            if ($try -eq 3) { throw "Download of $($File.filePath) failed: $($_.Exception.Message)" }
            Write-Warning "  attempt $try for $($File.filePath) failed: $($_.Exception.Message). Retrying..."
            Start-Sleep -Seconds (5 * $try)
        }
    }
}

# Downloads the .app files of a package set, either loose into OutputFolder or into one zip.
# Returns the list of saved files.
function Save-AppSet($Set, [string]$Zip, [string]$Label) {
    Write-Host "`n=== $Label ==="
    if ($Zip) {
        $zipPath = if ([IO.Path]::IsPathRooted($Zip)) { $Zip } else { Join-Path $OutputFolder $Zip }
        # Download into a staging folder. The current zip is unpacked there first, so files that
        # did not change are not downloaded again.
        $target = Join-Path ([IO.Path]::GetTempPath()) ("lsc-apps-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        if (Test-Path -LiteralPath $zipPath) { [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $target) }
    } else {
        $target = $OutputFolder
    }

    $saved = [Collections.Generic.List[object]]::new()
    try {
        foreach ($entry in $Set.GetEnumerator()) {
            $id = $entry.Key; $v = $entry.Value
            Write-Host "$id $($v.Text):"
            $files = @((Invoke-Api "/api/v1/Packages/$id/$([Uri]::EscapeDataString($v.Raw))/files").data | ForEach-Object { $_ })
            $apps  = @($files | Where-Object { $_.filePath -like '*.app' })
            if (-not $apps) { Write-Host '    (no .app files in this package, skipped)'; continue }
            foreach ($f in $apps) {
                $out = Join-Path $target (Split-Path $f.filePath -Leaf)
                Save-PackageFile $f $out
                $saved.Add([pscustomobject]@{ Package = $id; Version = $v.Text; File = (Split-Path $out -Leaf); Size = [int64]$f.size; Hash = ([string]$f.hash).TrimEnd('='); Zip = $Zip })
            }
        }

        if ($Zip) {
            # The zip holds exactly this set: drop apps of other versions that came from the old zip.
            Get-ChildItem -LiteralPath $target -Recurse -File | Where-Object { $_.Name -notin $saved.File } | Remove-Item -Force

            # Rewrite the zip only when its content changes. A new zip of the same files still has
            # different bytes (timestamps), which would give a pointless commit.
            $same = $false
            if (Test-Path -LiteralPath $zipPath) {
                $zipArchive = [IO.Compression.ZipFile]::OpenRead($zipPath)
                try {
                    $old = @($zipArchive.Entries | Where-Object Name | ForEach-Object {
                        $s = $_.Open(); $sha1 = [Security.Cryptography.SHA1]::Create()
                        try { '{0}|{1}' -f $_.FullName, [Convert]::ToBase64String($sha1.ComputeHash($s)).TrimEnd('=') } finally { $s.Dispose(); $sha1.Dispose() }
                    } | Sort-Object)
                } finally { $zipArchive.Dispose() }
                $new  = @($saved | ForEach-Object { '{0}|{1}' -f $_.File, $_.Hash } | Sort-Object -Unique)
                $same = ($old -join "`n") -ceq ($new -join "`n")
            }
            if ($same) {
                Write-Host "$zipPath already contains these apps, left unchanged." -ForegroundColor Green
            } elseif ($saved.Count -eq 0) {
                Write-Warning "No .app files for $Label, $zipPath not written."
            } else {
                $tmpZip = "$zipPath.partial"
                Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
                [IO.Compression.ZipFile]::CreateFromDirectory($target, $tmpZip, [IO.Compression.CompressionLevel]::Optimal, $false)
                Move-Item -LiteralPath $tmpZip -Destination $zipPath -Force
                Write-Host ("Done: {0} app file(s) in {1} ({2})" -f $saved.Count, $zipPath, (Format-Size (Get-Item -LiteralPath $zipPath).Length)) -ForegroundColor Green
            }
        } else {
            Write-Host "Done: $($saved.Count) app file(s) in $OutputFolder" -ForegroundColor Green
        }
    } finally {
        if ($Zip) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $saved.ToArray()                               # unrolled; callers collect with @()
}

function Test-IsMicrosoftPackage([string]$Id) { $Id -like 'bc-*' }

# ---------------------------------------------------------------------------------------------
Write-Host "Reading package catalogue from $Server ..."
$Catalogue = Invoke-Api '/api/SourceList'

if ($ListVersions) {
    foreach ($id in @($Packages + $TestPackages)) {
        $vers = Get-PackageVersions $id
        Write-Host "`n$id ($($vers.Count) versions):"
        $vers | Group-Object { $_.Ver.Num.Major } | ForEach-Object {
            Write-Host ("  {0,3}: {1}" -f $_.Name, (($_.Group | ForEach-Object Text) -join ' '))
        }
    }
    return
}

# --- Resolve the apps -------------------------------------------------------------------------
$resolved = [ordered]@{}                                  # packageId -> version object
$queue    = [Collections.Generic.Queue[object]]::new()

foreach ($id in $Packages) {
    $vers = Get-PackageVersions $id
    if ($vers.Count -eq 0) { throw "Package '$id' not found on $Server (or it has no released versions; try -IncludePrerelease)." }
    $v = Select-RequestedVersion $vers $Version
    if (-not $v) {
        $majors = ($vers | ForEach-Object { $_.Ver.Num.Major } | Sort-Object -Unique) -join ', '
        throw "Version '$Version' of '$id' not found (released majors: $majors). Run with -ListVersions to see all versions."
    }
    $resolved[$id] = $v
    $queue.Enqueue($id)
}

if (-not $NoDependencies) {
    while ($queue.Count -gt 0) {
        $parentId = $queue.Dequeue()
        foreach ($dep in $resolved[$parentId].Deps) {
            $depId = [string]$dep.packageId
            if ($dep.onlyRestrictVersion -or $dep.optional) { continue }   # version restrictions, not installs
            if ($depId -like '*/*' -or $depId -in 'ls-setup-helper', 'bc-server') { continue }
            if ((Test-IsMicrosoftPackage $depId) -and -not $IncludeMicrosoftApps) { continue }
            if ($resolved.Contains($depId)) { continue }
            $vers = Get-PackageVersions $depId
            if ($vers.Count -eq 0) { Write-Warning "Dependency '$depId' of '$parentId' not found, skipped."; continue }
            $resolved[$depId] = Select-DependencyVersion $vers ([string]$dep.versionQuery)
            $queue.Enqueue($depId)
        }
    }
}

# --- Resolve the test apps --------------------------------------------------------------------
$resolvedTests = [ordered]@{}
foreach ($id in $TestPackages) {
    $vers = Get-PackageVersions $id
    if ($vers.Count -eq 0) { throw "Test package '$id' not found on $Server." }
    $v = Select-MatchingTestVersion $vers $resolved
    if ($v -eq 'NO_MATCH') {
        $main = ($resolved.GetEnumerator() | Select-Object -First 1)
        throw "No released version of '$id' is built for $($main.Key) $($main.Value.Text) yet. Pick another -Version, or skip tests with -TestPackages ''."
    }
    if (-not $v) { $v = Select-RequestedVersion $vers $Version }
    if (-not $v) { throw "Version '$Version' of test package '$id' not found." }
    $resolvedTests[$id] = $v
}

Write-Host "`nApps ($(if ($ZipFile) { $ZipFile } else { 'loose files' })):"
$resolved.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-45} {1}" -f $_.Key, $_.Value.Text) }
if ($resolvedTests.Count) {
    Write-Host "Test apps ($(if ($TestZipFile) { $TestZipFile } else { 'loose files' })):"
    $resolvedTests.GetEnumerator() | ForEach-Object { Write-Host ("  {0,-45} {1}" -f $_.Key, $_.Value.Text) }
}

# --- Download ---------------------------------------------------------------------------------
if (-not [IO.Path]::IsPathRooted($OutputFolder)) { $OutputFolder = Join-Path (Get-Location).Path $OutputFolder }
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$OutputFolder = (Resolve-Path -LiteralPath $OutputFolder).ProviderPath
if ($Clean) { Get-ChildItem -LiteralPath $OutputFolder -Filter *.app -File | Remove-Item -Force }

$saved = @(Save-AppSet $resolved $ZipFile 'Apps')
if ($resolvedTests.Count) { $saved += @(Save-AppSet $resolvedTests $TestZipFile 'Test apps') }

# --- GitHub Actions integration (ignored when run locally) ------------------------------------
$mainVersion = $resolved[$Packages[0]].Text
if ($env:GITHUB_OUTPUT) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "version=$mainVersion"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "folder=$OutputFolder"
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "count=$($saved.Count)"
}
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @("### LS Central apps $mainVersion", '', '| Zip | Package | Version | File | Size |', '|---|---|---|---|---|')
    $md += $saved | ForEach-Object { "| $($_.Zip) | $($_.Package) | $($_.Version) | $($_.File) | $(Format-Size $_.Size) |" }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n")
}
