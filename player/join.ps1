# Connects to the Minecraft server through Cloudflare, adds it to the Multiplayer list,
# opens the Minecraft Launcher, and disconnects when the game closes.
# Settings come from server.conf next to this script (copy server.conf.example); parameters override it.
param(
    [string]$Hostname,
    [int]$LocalPort,
    [string]$ServerName
)

$ErrorActionPreference = "Stop"

$config = @{ HOSTNAME = "mc.example.com"; SERVER_NAME = "Minecraft Server"; LOCAL_PORT = "25565" }
$configFile = Join-Path $PSScriptRoot "server.conf"
if (Test-Path $configFile) {
    foreach ($line in Get-Content $configFile) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $config[$Matches[1]] = $Matches[2].Trim('"') }
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

# Adds the server to the top of .minecraft\servers.dat (uncompressed NBT:
# root compound > "servers" list of compounds with "name" and "ip").
function Add-ServerToList {
    $dir = Join-Path $env:APPDATA ".minecraft"
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

# 1. Make sure cloudflared is installed
if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
    Write-Host "Installing cloudflared (one time only)..."
    winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
        Write-Host "cloudflared installed but isn't on PATH yet. Close this window and run join again."
        exit 1
    }
}

# 2. Start the tunnel in the background (replacing one left over from a previous run)
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
    # 3. Put the server in the Multiplayer list
    switch (Add-ServerToList) {
        "added"         { Write-Host "Added '$ServerName' to your Multiplayer list." }
        "already-added" { }
        default         { Write-Host "Couldn't add the server automatically. In Multiplayer, click Add Server and enter: $Address" }
    }

    # 4. Open the launcher (unless the game is already running)
    if (-not (Get-GameProcess)) {
        if (Start-MinecraftLauncher) {
            Write-Host "Opening the Minecraft Launcher..."
        } else {
            Write-Host "Couldn't find the Minecraft Launcher. Open Minecraft yourself."
        }
    }

    Write-Host ""
    Write-Host "Click PLAY, then Multiplayer > '$ServerName'."
    Write-Host "You can minimize this window. It disconnects automatically when Minecraft closes."
    Write-Host ""

    # 5. Wait for the game to start (up to 30 min), then for it to close
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
