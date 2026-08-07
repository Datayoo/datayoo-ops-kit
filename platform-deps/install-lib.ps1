# Install every jar under .\lib into a local Maven repository.
#
# GAV comes from each jar's META-INF/maven/**/pom.properties; the embedded pom.xml is
# installed alongside so Maven can resolve the public dependencies (jackson, httpclient,
# commons-*, ...) from its normal remote repositories.
#
# Jars containing META-INF/maven/plugin.xml are installed with packaging=maven-plugin so
# Maven registers them as plugins instead of plain libraries.
#
# Parent POMs are chased recursively. A parent shipped as lib\<artifactId>-<version>.pom is
# installed verbatim; a parent from a private group that exists nowhere is stubbed; a parent
# from a public group is left untouched so Maven downloads the real one (stubbing those would
# strip their dependencyManagement and break ${property} resolution in the children).
#
# Usage:
#   .\install-lib.ps1
#   .\install-lib.ps1 -Repo C:\path\to\repository
#   .\install-lib.ps1 -Repo C:\path\to\repository -Force

param(
  [string]$Repo,
  [switch]$Force,
  [string[]]$PrivateGroup = @('org.datayoo')
)

Add-Type -AssemblyName System.IO.Compression.FileSystem
Set-Location -Path $PSScriptRoot

$libDir = Join-Path $PSScriptRoot 'lib'
if (-not (Test-Path $libDir)) {
  Write-Host "[ERROR] lib directory not found: $libDir"
  exit 1
}

if (-not (Get-Command mvn -ErrorAction SilentlyContinue)) {
  Write-Host '[ERROR] mvn not found in PATH'
  exit 1
}

if ($Repo) {
  $localRepo = $Repo
} elseif ($env:MAVEN_REPO) {
  $localRepo = $env:MAVEN_REPO
} else {
  $localRepo = Read-Host 'Maven local repository path'
}
if ([string]::IsNullOrWhiteSpace($localRepo)) {
  Write-Host '[ERROR] Maven local repository path is required'
  exit 1
}
$localRepo = $localRepo.Trim().Trim('"')
if (-not (Test-Path $localRepo)) { New-Item -ItemType Directory -Force -Path $localRepo | Out-Null }
$localRepo = (Resolve-Path -LiteralPath $localRepo).ProviderPath

Write-Host "Local Maven repo: $localRepo"
Write-Host "Private groups  : $($PrivateGroup -join ', ')"
if ($Force) { Write-Host 'Mode            : FORCE overwrite' } else { Write-Host 'Mode            : skip if already installed' }
Write-Host ''

function Get-ArtifactDir([string]$groupId, [string]$artifactId, [string]$version) {
  Join-Path $localRepo (Join-Path $groupId.Replace('.', '\') (Join-Path $artifactId $version))
}

# A cached copy is only usable if Maven considers it locally installed. Artifacts downloaded
# earlier from an internal Nexus are recorded in _remote.repositories as "<file>><repoId>=",
# and once that repository is no longer configured (this project ships without one) Maven
# rejects the cached file with "Could not find artifact" even though it sits right there.
# A local install is recorded with an empty repository id instead.
function Test-LocallyInstalled([string]$directory, [string]$fileName) {
  $marker = Join-Path $directory '_remote.repositories'
  if (-not (Test-Path $marker)) { return $true }
  $pattern = '^\s*' + [regex]::Escape($fileName) + '>\s*=\s*$'
  foreach ($line in (Get-Content -LiteralPath $marker)) {
    if ($line -match $pattern) { return $true }
  }
  return $false
}

function Test-PrivateGroup([string]$groupId) {
  foreach ($p in $PrivateGroup) {
    if ($groupId -eq $p -or $groupId.StartsWith("$p.")) { return $true }
  }
  return $false
}

# XPath helper that ignores the POM namespace, which some hand-written POMs omit.
function Select-PomNode($node, [string]$relativePath) {
  $xpath = (($relativePath -split '/') | ForEach-Object { "*[local-name()='$_']" }) -join '/'
  return $node.SelectSingleNode($xpath)
}

function Get-PomText([string]$path) {
  try { return [xml](Get-Content -LiteralPath $path -Raw) } catch { return $null }
}

function Get-ParentGav($xml) {
  if (-not $xml) { return $null }
  $parent = Select-PomNode $xml.DocumentElement 'parent'
  if (-not $parent) { return $null }
  $g = Select-PomNode $parent 'groupId'
  $a = Select-PomNode $parent 'artifactId'
  $v = Select-PomNode $parent 'version'
  if (-not $g -or -not $a -or -not $v) { return $null }
  return @{ groupId = $g.InnerText.Trim(); artifactId = $a.InnerText.Trim(); version = $v.InnerText.Trim() }
}

function Write-StubPom([string]$groupId, [string]$artifactId, [string]$version, [string]$dest) {
  $stub = @"
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>$groupId</groupId>
  <artifactId>$artifactId</artifactId>
  <version>$version</version>
  <packaging>pom</packaging>
</project>
"@
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
  [System.IO.File]::WriteAllText($dest, $stub, (New-Object System.Text.UTF8Encoding($false)))
}

# Walk the parent chain of an installed POM, making sure every private ancestor resolves.
function Install-ParentChain([string]$pomPath) {
  $seen = @{}
  $current = $pomPath
  while ($current) {
    $xml = Get-PomText $current
    $parent = Get-ParentGav $xml
    if (-not $parent) { break }

    $key = "$($parent.groupId):$($parent.artifactId):$($parent.version)"
    if ($seen.ContainsKey($key)) { break }
    $seen[$key] = $true

    $destDir = Get-ArtifactDir $parent.groupId $parent.artifactId $parent.version
    $dest = Join-Path $destDir "$($parent.artifactId)-$($parent.version).pom"

    if (Test-Path $dest) { $current = $dest; continue }

    $shipped = Join-Path $libDir "$($parent.artifactId)-$($parent.version).pom"
    if (Test-Path $shipped) {
      New-Item -ItemType Directory -Force -Path $destDir | Out-Null
      Copy-Item -LiteralPath $shipped -Destination $dest -Force
      Write-Host "  [PARENT] installed $key from lib"
      $current = $dest
      continue
    }

    if (-not (Test-PrivateGroup $parent.groupId)) {
      Write-Host "  [PARENT] $key is public, left for Maven to download"
      break
    }

    Write-StubPom $parent.groupId $parent.artifactId $parent.version $dest
    Write-Host "  [PARENT] stubbed $key"
    $current = $dest
  }
}

function Read-JarMetadata([string]$jarPath) {
  $zip = [System.IO.Compression.ZipFile]::OpenRead($jarPath)
  try {
    $propEntry = $zip.Entries | Where-Object { $_.FullName -match '^META-INF/maven/.+/pom\.properties$' } | Select-Object -First 1
    if (-not $propEntry) { return $null }

    $reader = New-Object System.IO.StreamReader($propEntry.Open())
    try { $propText = $reader.ReadToEnd() } finally { $reader.Close() }

    $pomText = $null
    $pomEntry = $zip.Entries | Where-Object { $_.FullName -match '^META-INF/maven/.+/pom\.xml$' } | Select-Object -First 1
    if ($pomEntry) {
      $pomReader = New-Object System.IO.StreamReader($pomEntry.Open())
      try { $pomText = $pomReader.ReadToEnd() } finally { $pomReader.Close() }
    }

    # A Maven plugin is identified by its generated descriptor, not by the packaging alone.
    $goalPrefix = $null
    $pluginName = $null
    $descriptorEntry = $zip.Entries | Where-Object { $_.FullName -eq 'META-INF/maven/plugin.xml' } | Select-Object -First 1
    $isPlugin = [bool]$descriptorEntry
    if ($descriptorEntry) {
      $descReader = New-Object System.IO.StreamReader($descriptorEntry.Open())
      try { $descText = $descReader.ReadToEnd() } finally { $descReader.Close() }
      if ($descText -match '<goalPrefix>\s*([^<]+?)\s*</goalPrefix>') { $goalPrefix = $Matches[1] }
      if ($descText -match '<name>\s*([^<]+?)\s*</name>') { $pluginName = $Matches[1] }
    }
  } finally {
    $zip.Dispose()
  }

  $groupId = $null; $artifactId = $null; $version = $null
  foreach ($line in ($propText -split "`r?`n")) {
    if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
    if ($line -match '^\s*groupId\s*=\s*(.+)$')    { $groupId = $Matches[1].Trim() }
    elseif ($line -match '^\s*artifactId\s*=\s*(.+)$') { $artifactId = $Matches[1].Trim() }
    elseif ($line -match '^\s*version\s*=\s*(.+)$')    { $version = $Matches[1].Trim() }
  }
  if (-not $groupId -or -not $artifactId -or -not $version) { return $null }

  $packaging = 'jar'
  if ($pomText -and $pomText -match '<packaging>\s*([^<]+)\s*</packaging>') { $packaging = $Matches[1].Trim() }
  if ($isPlugin) { $packaging = 'maven-plugin' }

  return @{
    groupId = $groupId; artifactId = $artifactId; version = $version
    packaging = $packaging; isPlugin = $isPlugin; pomText = $pomText
    goalPrefix = $goalPrefix; pluginName = $pluginName
  }
}

# install-file never writes the group level maven-metadata-local.xml, so a plugin installed
# this way cannot be invoked by its short prefix (mvn descriptor:descriptorPack). Merge the
# entries ourselves, keeping whatever the repository already lists.
function Update-PluginGroupMetadata([string]$groupId, $plugins) {
  $metaPath = Join-Path (Join-Path $localRepo $groupId.Replace('.', '\')) 'maven-metadata-local.xml'
  $entries = [ordered]@{}

  if (Test-Path $metaPath) {
    $existing = Get-PomText $metaPath
    if ($existing) {
      foreach ($node in $existing.DocumentElement.SelectNodes("*[local-name()='plugins']/*[local-name()='plugin']")) {
        $a = Select-PomNode $node 'artifactId'
        $p = Select-PomNode $node 'prefix'
        $n = Select-PomNode $node 'name'
        if ($a -and $p) {
          $entries[$a.InnerText.Trim()] = @{
            prefix = $p.InnerText.Trim()
            name = if ($n) { $n.InnerText.Trim() } else { $a.InnerText.Trim() }
          }
        }
      }
    }
  }

  foreach ($plugin in $plugins) {
    $entries[$plugin.artifactId] = @{ prefix = $plugin.prefix; name = $plugin.name }
  }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
  [void]$sb.AppendLine('<metadata>')
  [void]$sb.AppendLine('  <plugins>')
  foreach ($key in $entries.Keys) {
    [void]$sb.AppendLine('    <plugin>')
    [void]$sb.AppendLine("      <name>$($entries[$key].name)</name>")
    [void]$sb.AppendLine("      <prefix>$($entries[$key].prefix)</prefix>")
    [void]$sb.AppendLine("      <artifactId>$key</artifactId>")
    [void]$sb.AppendLine('    </plugin>')
  }
  [void]$sb.AppendLine('  </plugins>')
  [void]$sb.AppendLine('</metadata>')

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $metaPath) | Out-Null
  [System.IO.File]::WriteAllText($metaPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

# Not every jar carries META-INF/maven metadata (repackaged natives such as sigar do not).
# Those need a sidecar lib\<jar base name>.pom spelling out the coordinates.
function Get-GavFromPomFile([string]$path) {
  $xml = Get-PomText $path
  if (-not $xml) { return $null }
  $g = Select-PomNode $xml.DocumentElement 'groupId'
  if (-not $g) { $g = Select-PomNode $xml.DocumentElement 'parent/groupId' }
  $a = Select-PomNode $xml.DocumentElement 'artifactId'
  $v = Select-PomNode $xml.DocumentElement 'version'
  if (-not $v) { $v = Select-PomNode $xml.DocumentElement 'parent/version' }
  if (-not $g -or -not $a -or -not $v) { return $null }
  $p = Select-PomNode $xml.DocumentElement 'packaging'
  $packaging = 'jar'
  if ($p) { $packaging = $p.InnerText.Trim() }
  return @{
    groupId = $g.InnerText.Trim(); artifactId = $a.InnerText.Trim(); version = $v.InnerText.Trim()
    packaging = $packaging; isPlugin = $false; pomText = $null; goalPrefix = $null; pluginName = $null
  }
}

function Invoke-InstallFile([string]$file, [hashtable]$gav, [string]$pomFile) {
  $mvnArgs = @(
    'install:install-file'
    "-Dfile=$file"
    "-DgroupId=$($gav.groupId)"
    "-DartifactId=$($gav.artifactId)"
    "-Dversion=$($gav.version)"
    "-Dpackaging=$($gav.packaging)"
    "-Dmaven.repo.local=$localRepo"
  )
  if ($pomFile) { $mvnArgs += "-DpomFile=$pomFile" }
  $output = & mvn -q -B @mvnArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host "    $_" }
    return $false
  }
  return $true
}

$count = 0
$installed = 0
$skipped = 0
$failed = 0
$pluginsByGroup = [ordered]@{}
$installedPoms = New-Object System.Collections.Generic.List[string]

foreach ($jar in (Get-ChildItem -LiteralPath $libDir -Filter *.jar | Sort-Object Name)) {
  $count++
  $gav = Read-JarMetadata $jar.FullName
  $sidecarPom = Join-Path $libDir "$($jar.BaseName).pom"
  if (-not $gav -and (Test-Path $sidecarPom)) {
    $gav = Get-GavFromPomFile $sidecarPom
    if ($gav -and $gav.packaging -eq 'pom') { $gav.packaging = 'jar' }
  }
  if (-not $gav) {
    Write-Host "[MISS] $($jar.Name) carries no META-INF/maven metadata."
    Write-Host "       Add lib\$($jar.BaseName).pom declaring its groupId/artifactId/version."
    $failed++
    continue
  }

  $coord = "$($gav.groupId):$($gav.artifactId):$($gav.version)"
  $destDir = Get-ArtifactDir $gav.groupId $gav.artifactId $gav.version
  $destJar = Join-Path $destDir "$($gav.artifactId)-$($gav.version).jar"
  $destPom = Join-Path $destDir "$($gav.artifactId)-$($gav.version).pom"
  if ($gav.isPlugin -and $gav.goalPrefix) {
    if (-not $pluginsByGroup.Contains($gav.groupId)) {
      $pluginsByGroup[$gav.groupId] = New-Object System.Collections.ArrayList
    }
    $name = $gav.pluginName
    if (-not $name) { $name = $gav.artifactId }
    [void]$pluginsByGroup[$gav.groupId].Add(@{ artifactId = $gav.artifactId; prefix = $gav.goalPrefix; name = $name })
  }

  $usable = (Test-Path $destJar) -and (Test-LocallyInstalled $destDir "$($gav.artifactId)-$($gav.version).jar")
  if ($usable -and -not $Force) {
    Write-Host "[SKIP] $coord"
    $skipped++
    # Still verify the ancestry: a previous run may have installed the jar but not its parents.
    if (Test-Path $destPom) {
      Install-ParentChain $destPom
      $installedPoms.Add($destPom)
    }
    continue
  }
  if ((Test-Path $destJar) -and -not $usable) {
    Write-Host "[RELINK] $coord cached copy is bound to a remote repository, reinstalling"
  }

  # An explicit lib\<artifactId>-<version>.pom wins over the one baked into the jar.
  $shippedPom = Join-Path $libDir "$($gav.artifactId)-$($gav.version).pom"
  $pomFile = $null
  $tempPom = $null
  if (Test-Path $shippedPom) {
    $pomFile = $shippedPom
  } elseif ($gav.pomText) {
    $pomText = $gav.pomText
    # install-file trusts the POM over -Dpackaging, so a plugin whose POM forgot the
    # packaging would land as a plain jar and never resolve by prefix.
    if ($gav.isPlugin -and $pomText -notmatch '<packaging>\s*maven-plugin\s*</packaging>') {
      if ($pomText -match '<packaging>\s*[^<]+\s*</packaging>') {
        $pomText = $pomText -replace '<packaging>\s*[^<]+\s*</packaging>', '<packaging>maven-plugin</packaging>'
      } else {
        $pomText = $pomText -replace '(</version>)', "`$1`r`n  <packaging>maven-plugin</packaging>", 1
      }
    }
    $tempPom = [System.IO.Path]::GetTempFileName() + '.pom'
    [System.IO.File]::WriteAllText($tempPom, $pomText, (New-Object System.Text.UTF8Encoding($false)))
    $pomFile = $tempPom
  }

  Write-Host "[INSTALL] $coord ($($gav.packaging))  <- $($jar.Name)"
  try {
    $ok = Invoke-InstallFile $jar.FullName $gav $pomFile
  } finally {
    if ($tempPom -and (Test-Path $tempPom)) { Remove-Item -LiteralPath $tempPom -Force }
  }

  if (-not $ok) {
    Write-Host "[FAIL] $coord"
    $failed++
    continue
  }

  if (Test-Path $destPom) {
    Install-ParentChain $destPom
    $installedPoms.Add($destPom)
  }
  $installed++
}

# Standalone POMs (parents or BOMs that ship without a jar).
foreach ($pom in (Get-ChildItem -LiteralPath $libDir -Filter *.pom | Sort-Object Name)) {
  if (Test-Path (Join-Path $libDir "$($pom.BaseName).jar")) { continue }

  $count++
  $xml = Get-PomText $pom.FullName
  if (-not $xml) {
    Write-Host "[MISS] invalid POM: $($pom.Name)"
    $failed++
    continue
  }

  $gNode = Select-PomNode $xml.DocumentElement 'groupId'
  if (-not $gNode) { $gNode = Select-PomNode $xml.DocumentElement 'parent/groupId' }
  $aNode = Select-PomNode $xml.DocumentElement 'artifactId'
  $vNode = Select-PomNode $xml.DocumentElement 'version'
  if (-not $vNode) { $vNode = Select-PomNode $xml.DocumentElement 'parent/version' }
  if (-not $gNode -or -not $aNode -or -not $vNode) {
    Write-Host "[MISS] cannot read GAV from $($pom.Name)"
    $failed++
    continue
  }

  $gav = @{
    groupId = $gNode.InnerText.Trim(); artifactId = $aNode.InnerText.Trim()
    version = $vNode.InnerText.Trim(); packaging = 'pom'
  }
  $coord = "$($gav.groupId):$($gav.artifactId):$($gav.version)"
  $destDir = Get-ArtifactDir $gav.groupId $gav.artifactId $gav.version
  $dest = Join-Path $destDir "$($gav.artifactId)-$($gav.version).pom"

  $usable = (Test-Path $dest) -and (Test-LocallyInstalled $destDir "$($gav.artifactId)-$($gav.version).pom")
  if ($usable -and -not $Force) {
    Write-Host "[SKIP] $coord (pom)"
    $skipped++
    Install-ParentChain $dest
    continue
  }
  if ((Test-Path $dest) -and -not $usable) {
    Write-Host "[RELINK] $coord cached copy is bound to a remote repository, reinstalling"
  }

  Write-Host "[INSTALL] $coord (pom)  <- $($pom.Name)"
  if (-not (Invoke-InstallFile $pom.FullName $gav $pom.FullName)) {
    Write-Host "[FAIL] $coord (pom)"
    $failed++
    continue
  }
  Install-ParentChain $dest
  $installedPoms.Add($dest)
  $installed++
}

# Report private dependencies that nothing provides. Public coordinates are skipped because
# Maven resolves those from its remote repositories on the next build. The walk follows the
# transitive closure: a jar added to lib usually drags in private dependencies of its own, and
# reporting only the first level would make the user re-run once per level.
function Get-PomPropertyTable($xml) {
  $props = @{}
  $root = $xml.DocumentElement
  $version = Select-PomNode $root 'version'
  if (-not $version) { $version = Select-PomNode $root 'parent/version' }
  $group = Select-PomNode $root 'groupId'
  if (-not $group) { $group = Select-PomNode $root 'parent/groupId' }
  if ($version) {
    $props['project.version'] = $version.InnerText.Trim()
    $props['version'] = $version.InnerText.Trim()
  }
  if ($group) { $props['project.groupId'] = $group.InnerText.Trim() }
  $parentVersion = Select-PomNode $root 'parent/version'
  if ($parentVersion) {
    $props['project.parent.version'] = $parentVersion.InnerText.Trim()
    $props['parent.version'] = $parentVersion.InnerText.Trim()
  }
  $declared = Select-PomNode $root 'properties'
  if ($declared) {
    foreach ($node in $declared.ChildNodes) {
      if ($node.NodeType -eq 'Element') { $props[$node.LocalName] = $node.InnerText.Trim() }
    }
  }
  return $props
}

function Resolve-PomValue([string]$value, $props) {
  $result = $value
  for ($i = 0; $i -lt 5 -and $result -match '\$\{'; $i++) {
    $result = [regex]::Replace($result, '\$\{([^}]+)\}', {
      param($m)
      $key = $m.Groups[1].Value
      if ($props.ContainsKey($key)) { return $props[$key] }
      return $m.Value
    })
  }
  if ($result -match '\$\{') { return $null }
  return $result
}

function Get-PrivateDependencies([string]$pomPath) {
  $result = New-Object System.Collections.Generic.List[object]
  $xml = Get-PomText $pomPath
  if (-not $xml) { return $result }
  $props = Get-PomPropertyTable $xml

  foreach ($dep in $xml.DocumentElement.SelectNodes("*[local-name()='dependencies']/*[local-name()='dependency']")) {
    $g = Select-PomNode $dep 'groupId'
    $a = Select-PomNode $dep 'artifactId'
    $v = Select-PomNode $dep 'version'
    if (-not $g -or -not $a -or -not $v) { continue }

    # test/provided/optional dependencies never have to resolve for a normal build.
    $scope = Select-PomNode $dep 'scope'
    if ($scope -and $scope.InnerText.Trim() -in @('test', 'provided', 'system')) { continue }
    $optional = Select-PomNode $dep 'optional'
    if ($optional -and $optional.InnerText.Trim() -eq 'true') { continue }

    $gid = Resolve-PomValue $g.InnerText.Trim() $props
    $aid = Resolve-PomValue $a.InnerText.Trim() $props
    $ver = Resolve-PomValue $v.InnerText.Trim() $props
    if (-not $gid -or -not $aid -or -not $ver) { continue }
    if (-not (Test-PrivateGroup $gid)) { continue }
    if ($ver -in @('RELEASE', 'LATEST')) { continue }

    $result.Add(@{ groupId = $gid; artifactId = $aid; version = $ver })
  }
  return $result
}

$missing = New-Object System.Collections.Generic.List[string]
$visited = New-Object System.Collections.Generic.HashSet[string]
$queue = New-Object System.Collections.Generic.Queue[string]
foreach ($pomPath in $installedPoms) { $queue.Enqueue($pomPath) }

while ($queue.Count -gt 0) {
  $pomPath = $queue.Dequeue()
  if (-not $visited.Add($pomPath.ToLowerInvariant())) { continue }

  foreach ($dep in (Get-PrivateDependencies $pomPath)) {
    $depDir = Get-ArtifactDir $dep.groupId $dep.artifactId $dep.version
    $depJar = Join-Path $depDir "$($dep.artifactId)-$($dep.version).jar"
    if (-not (Test-Path $depJar)) {
      $entry = "$($dep.groupId):$($dep.artifactId):$($dep.version)"
      if (-not $missing.Contains($entry)) { $missing.Add($entry) }
      continue
    }
    $depPom = Join-Path $depDir "$($dep.artifactId)-$($dep.version).pom"
    if (Test-Path $depPom) { $queue.Enqueue($depPom) }
  }
}

Write-Host ''
Write-Host "Done. files=$count installed=$installed skipped=$skipped failed=$failed"

if ($missing.Count -gt 0) {
  Write-Host ''
  Write-Host "[WARN] $($missing.Count) private dependencies are referenced but not present in the repo."
  Write-Host '       Add the matching jars to lib\ and re-run, or the build will fail to resolve them:'
  foreach ($m in ($missing | Sort-Object)) { Write-Host "       - $m" }
}

if ($pluginsByGroup.Count -gt 0) {
  Write-Host ''
  foreach ($g in $pluginsByGroup.Keys) {
    Update-PluginGroupMetadata $g $pluginsByGroup[$g]
    $prefixes = ($pluginsByGroup[$g] | ForEach-Object { $_.prefix }) -join ', '
    Write-Host "[PLUGINS] $g registered with prefixes: $prefixes"
  }
  Write-Host '          To use those prefixes outside this project, add to your settings.xml:'
  Write-Host '            <pluginGroups>'
  foreach ($g in $pluginsByGroup.Keys) { Write-Host "              <pluginGroup>$g</pluginGroup>" }
  Write-Host '            </pluginGroups>'
}

if ($failed -gt 0) { exit 1 }
