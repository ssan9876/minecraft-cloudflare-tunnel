# Connects to the Minecraft server through Cloudflare, adds it to the Multiplayer list,
# opens the Minecraft Launcher, and disconnects when the game closes. For a Fabric server it
# also installs Fabric and the server's mods (MODS in server.conf).
# Settings come from server.conf next to this script (copy server.conf.example); parameters override it.
param(
    [string]$Hostname,
    [int]$LocalPort,
    [string]$ServerName
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Windows PowerShell's progress bar makes downloads very slow
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$config = @{ HOSTNAME = "mc.example.com"; SERVER_NAME = "Minecraft Server"; LOCAL_PORT = "25565"; MODS = ""; SCRIPTS = "" }
$configFile = Join-Path $PSScriptRoot "server.conf"
if (Test-Path $configFile) {
    foreach ($line in Get-Content $configFile) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $config[$Matches[1]] = $Matches[2].Trim('"') }
    }
}
# The join scripts keep themselves up to date: with SCRIPTS in server.conf set to where the latest copies are
# published, a newer join.ps1 there replaces this one and runs instead. Bump this whenever the script changes.
$JoinScriptVersion = 2
if ($config.SCRIPTS -and -not $env:JOIN_SCRIPT_UPDATED) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri ($config.SCRIPTS.TrimEnd('/') + "/join.ps1")
        $latest = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
        if ($latest -match '(?m)^\$JoinScriptVersion = (\d+)' -and [int]$Matches[1] -gt $JoinScriptVersion) {
            $newVersion = $Matches[1]
            $null = [ScriptBlock]::Create($latest)  # only take it if it parses
            [IO.File]::WriteAllText($PSCommandPath, $latest, (New-Object Text.UTF8Encoding $true))
            Write-Host "Updated the join script to version $newVersion."
            $env:JOIN_SCRIPT_UPDATED = "1"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @PSBoundParameters
            exit $LASTEXITCODE
        }
    } catch {
        Write-Host "Couldn't check for a newer join script, carrying on: $($_.Exception.Message)"
    }
}

if (-not $Hostname) { $Hostname = $config.HOSTNAME }
if (-not $ServerName) { $ServerName = $config.SERVER_NAME }
if (-not $LocalPort) { $LocalPort = [int]$config.LOCAL_PORT }
if ($Hostname -eq "mc.example.com") {
    Write-Host "No server address set. Copy server.conf.example to server.conf and set HOSTNAME."
    exit 1
}

$Address = "localhost:$LocalPort"
$McDir = Join-Path $env:APPDATA ".minecraft"

function Write-NbtString([IO.BinaryWriter]$w, [string]$s) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($s)
    $w.Write([byte](($bytes.Length -shr 8) -band 0xFF))
    $w.Write([byte]($bytes.Length -band 0xFF))
    $w.Write($bytes)
}

function Write-NbtInt([IO.BinaryWriter]$w, [int]$n) {
    $b = [BitConverter]::GetBytes($n)
    [Array]::Reverse($b)
    $w.Write($b)
}

# Adds the server to the top of servers.dat in the game folder (uncompressed NBT:
# root compound > "servers" list of compounds with "name" and "ip").
function Add-ServerToList([string]$dir) {
    if (-not (Test-Path $dir)) { return "no-minecraft-dir" }
    $file = Join-Path $dir "servers.dat"

    $count = 0
    $rest = [byte[]]@(0)  # root TAG_End
    if (Test-Path $file) {
        $data = [IO.File]::ReadAllBytes($file)
        $text = [Text.Encoding]::GetEncoding(28591).GetString($data)
        if ($text.Contains($ServerName) -and $text.Contains($Address)) { return "already-added" }

        # Expect: 0A 0000 | 09 0007 "servers" | <element type> <int32 count> | entries... | 00
        $header = [byte[]](0x0A, 0, 0, 0x09, 0, 7) + [Text.Encoding]::ASCII.GetBytes("servers")
        $matches_ = $data.Length -ge 19
        for ($i = 0; $matches_ -and $i -lt $header.Length; $i++) { $matches_ = $data[$i] -eq $header[$i] }
        if (-not $matches_) { return "unrecognized" }
        $count = ([int]$data[14] -shl 24) -bor ([int]$data[15] -shl 16) -bor ([int]$data[16] -shl 8) -bor [int]$data[17]
        if ($data[13] -ne 0x0A -and $count -ne 0) { return "unrecognized" }
        $rest = $data[18..($data.Length - 1)]
        Copy-Item $file "$file.bak" -Force
    }

    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($ms)
    $w.Write([byte]0x0A); Write-NbtString $w ""
    $w.Write([byte]0x09); Write-NbtString $w "servers"
    $w.Write([byte]0x0A); Write-NbtInt $w ($count + 1)
    $w.Write([byte]0x08); Write-NbtString $w "ip";   Write-NbtString $w $Address
    $w.Write([byte]0x08); Write-NbtString $w "name"; Write-NbtString $w $ServerName
    $w.Write([byte]0x00)
    $w.Write([byte[]]$rest)
    $w.Flush()
    [IO.File]::WriteAllBytes($file, $ms.ToArray())
    return "added"
}

# Reads the mods list (see mods.txt.example): the Minecraft and Fabric Loader versions, and the mods.
# Mods are https:// links, or for a list next to this script, also paths relative to it.
function Read-ModList([string]$source) {
    $base = $null
    if ($source -match '^https://') {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $source
        $text = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
    } else {
        $path = if ([IO.Path]::IsPathRooted($source)) { $source } else { Join-Path $PSScriptRoot $source }
        $text = [IO.File]::ReadAllText($path)
        $base = Split-Path $path -Parent
    }

    $list = @{ Minecraft = $null; Loader = $null; Mods = @() }
    foreach ($line in $text -split "`r?`n") {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $key, $value = $line -split '\s+', 2
        switch ($key) {
            "minecraft"     { $list.Minecraft = $value }
            "fabric-loader" { $list.Loader = $value }
            "mod" {
                if ($value -match '^https://') { $list.Mods += $value }
                elseif ($base) { $list.Mods += (Join-Path $base $value) }
                else { throw "mod '$value' in $source must be an https:// link" }
            }
        }
    }
    if (-not $list.Minecraft -or -not $list.Loader) { throw "$source needs 'minecraft' and 'fabric-loader' lines" }
    return $list
}

# Installs Fabric and the server's mods into their own game folder, with a launcher installation named after
# the server, so the player's own mods and other versions are left alone. Returns the game folder.
function Install-ServerMods($list) {
    if (-not (Test-Path $McDir)) { throw "open the Minecraft Launcher once first, then run join again" }

    # Fabric's launcher version, as the Fabric installer would set it up
    $versionId = "fabric-loader-$($list.Loader)-$($list.Minecraft)"
    $versionDir = Join-Path $McDir "versions\$versionId"
    $versionJson = Join-Path $versionDir "$versionId.json"
    if (-not (Test-Path $versionJson)) {
        Write-Host "Installing Fabric $($list.Loader) for Minecraft $($list.Minecraft)..."
        New-Item -ItemType Directory -Force $versionDir | Out-Null
        Invoke-WebRequest -UseBasicParsing -OutFile "$versionJson.part" `
            -Uri "https://meta.fabricmc.net/v2/versions/loader/$($list.Minecraft)/$($list.Loader)/profile/json"
        Move-Item -Force "$versionJson.part" $versionJson
    }

    $slug = ($ServerName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) { $slug = "server" }
    $gameDir = Join-Path $McDir "profiles\$slug"
    $modsDir = Join-Path $gameDir "mods"
    New-Item -ItemType Directory -Force $modsDir | Out-Null

    # Jars from an earlier list that aren't on this one are removed. Ones the player added are left alone.
    $managedFile = Join-Path $modsDir ".server-mods.txt"
    $previous = if (Test-Path $managedFile) { @(Get-Content $managedFile) } else { @() }
    $wanted = @()
    foreach ($mod in $list.Mods) {
        $name = if ($mod -match '^https://') { [Uri]::UnescapeDataString(([Uri]$mod).Segments[-1]) } else { Split-Path $mod -Leaf }
        if ($name -notmatch '^[^\\/]+\.jar$') { throw "not a .jar: $mod" }
        $wanted += $name
        $target = Join-Path $modsDir $name
        if (Test-Path $target) { continue }
        Write-Host "Downloading $name..."
        if ($mod -match '^https://') { Invoke-WebRequest -UseBasicParsing -Uri $mod -OutFile "$target.part" }
        else { Copy-Item $mod "$target.part" }
        Move-Item -Force "$target.part" $target
    }
    foreach ($name in $previous) {
        if ($wanted -notcontains $name -and $name -match '^[^\\/]+\.jar$') {
            Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $modsDir $name)
        }
    }
    Set-Content -Path $managedFile -Value $wanted -Encoding ASCII

    # Start from the player's usual settings (controls, video) the first time
    $options = Join-Path $gameDir "options.txt"
    if (-not (Test-Path $options) -and (Test-Path "$McDir\options.txt")) { Copy-Item "$McDir\options.txt" $options }

    # The launcher installation, marked as just used so the launcher selects it
    $files = @("launcher_profiles.json", "launcher_profiles_microsoft_store.json") |
        ForEach-Object { Join-Path $McDir $_ } | Where-Object { Test-Path $_ }
    if (-not $files) { $files = @(Join-Path $McDir "launcher_profiles.json") }
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    foreach ($file in $files) {
        $json = if (Test-Path $file) { [IO.File]::ReadAllText($file) | ConvertFrom-Json } else { [pscustomobject]@{} }
        if (-not $json.profiles) { $json | Add-Member -Force profiles ([pscustomobject]@{}) }
        $installation = $json.profiles.$slug
        if (-not $installation) { $installation = [pscustomobject]@{ created = $now } }
        $values = @{ name = $ServerName; type = "custom"; icon = "Grass"; lastVersionId = $versionId; gameDir = $gameDir; lastUsed = $now }
        foreach ($key in $values.Keys) { $installation | Add-Member -Force $key $values[$key] }
        $json.profiles | Add-Member -Force $slug $installation
        [IO.File]::WriteAllText($file, ($json | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
    }

    return $gameDir
}

function Start-MinecraftLauncher {
    $pkg = Get-AppxPackage -Name Microsoft.4297127D64EC6 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) {
        $appId = @((Get-AppxPackageManifest $pkg).Package.Applications.Application)[0].Id
        Start-Process "shell:AppsFolder\$($pkg.PackageFamilyName)!$appId"
        return $true
    }
    foreach ($exe in "${env:ProgramFiles(x86)}\Minecraft Launcher\MinecraftLauncher.exe",
                     "$env:ProgramFiles\Minecraft Launcher\MinecraftLauncher.exe") {
        if (Test-Path $exe) { Start-Process $exe; return $true }
    }
    return $false
}

function Get-GameProcess {
    Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" |
        Where-Object { $_.CommandLine -match 'minecraft' }
}

# 1. On a Fabric server, install Fabric and the server's mods
$gameDir = $McDir
if ($config.MODS) {
    Write-Host "Checking the server's mods..."
    try {
        $gameDir = Install-ServerMods (Read-ModList $config.MODS)
    } catch {
        Write-Host "Couldn't install the server's mods: $($_.Exception.Message)"
        exit 1
    }
    Write-Host "Mods are up to date."
}

# 2. Make sure cloudflared is installed
if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
    Write-Host "Installing cloudflared (one time only)..."
    winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
        Write-Host "cloudflared installed but isn't on PATH yet. Close this window and run join again."
        exit 1
    }
}

# 3. Start the tunnel in the background (replacing one left over from a previous run)
Get-CimInstance Win32_Process -Filter "Name = 'cloudflared.exe'" |
    Where-Object { $_.CommandLine -match 'access tcp' -and $_.CommandLine -match [regex]::Escape($Hostname) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$log = Join-Path $env:TEMP "minecraft-tunnel.log"
$tunnel = Start-Process cloudflared -WindowStyle Hidden -PassThru -RedirectStandardError $log `
    -ArgumentList "access", "tcp", "--hostname", $Hostname, "--url", "127.0.0.1:$LocalPort"
Start-Sleep -Seconds 2
if ($tunnel.HasExited) {
    Write-Host "The connection to $Hostname failed to start. Details:"
    Get-Content $log -Tail 20
    exit 1
}
Write-Host "Connected to $Hostname."

try {
    # 4. Put the server in the Multiplayer list
    switch (Add-ServerToList $gameDir) {
        "added"         { Write-Host "Added '$ServerName' to your Multiplayer list." }
        "already-added" { }
        default         { Write-Host "Couldn't add the server automatically. In Multiplayer, click Add Server and enter: $Address" }
    }

    # 5. Open the launcher (unless the game is already running)
    if (-not (Get-GameProcess)) {
        if (Start-MinecraftLauncher) {
            Write-Host "Opening the Minecraft Launcher..."
        } else {
            Write-Host "Couldn't find the Minecraft Launcher. Open Minecraft yourself."
        }
    }

    Write-Host ""
    if ($config.MODS) {
        Write-Host "In the launcher, pick the '$ServerName' installation next to PLAY (it's selected for you)."
        Write-Host "If the launcher was already open, close and reopen it so it shows up."
    }
    Write-Host "Click PLAY, then Multiplayer > '$ServerName'."
    Write-Host "You can minimize this window. It disconnects automatically when Minecraft closes."
    Write-Host ""

    # 6. Wait for the game to start (up to 30 min), then for it to close
    $deadline = (Get-Date).AddMinutes(30)
    while (-not (Get-GameProcess)) {
        if ((Get-Date) -gt $deadline) { Write-Host "Minecraft didn't start. Disconnecting."; exit 0 }
        if ($tunnel.HasExited) { Write-Host "The connection dropped. Run join again."; exit 1 }
        Start-Sleep -Seconds 3
    }
    while (Get-GameProcess) { Start-Sleep -Seconds 5 }
    Write-Host "Minecraft closed. Disconnecting."
}
finally {
    if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
}
