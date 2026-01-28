# installer/install.ps1
# ComfyUI One-Click Installer (CUDA/NVIDIA edition)
# Installs: ComfyUI + venv + requirements + PyTorch CUDA + custom nodes from nodes.list
# Health Check:
# - In CI_MODE (GitHub Actions): skips launching ComfyUI
# - On real machine: launches ComfyUI -> waits for port 8188 -> pings -> shuts down

$ErrorActionPreference = "Stop"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "=== $msg ==="
}

function Test-Command($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Get-RepoNameFromUrl($url) {
    $u = $url.Trim()
    if ($u.EndsWith(".git")) { $u = $u.Substring(0, $u.Length - 4) }
    $parts = $u.Split("/")
    return $parts[$parts.Length - 1]
}

function Wait-ForUrl($url, $timeoutSeconds = 300) {
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $timeoutSeconds) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
                return $true
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

# -------------------------
# Paths + logging
# -------------------------
$root = Join-Path $PSScriptRoot ".."
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$logFile = Join-Path $logDir "install.log"
Start-Transcript -Path $logFile -Append

Write-Step "ComfyUI One-Click Installer (CUDA/NVIDIA)"

# -------------------------
# CI mode detection
# -------------------------
$ciMode = $env:CI_MODE -eq "1"
if ($ciMode) {
    Write-Host "CI_MODE detected: YES (GitHub Actions / non-GPU test environment)"
} else {
    Write-Host "CI_MODE detected: NO (real machine mode)"
}

# -------------------------
# Validate tools
# -------------------------
Write-Step "Checking prerequisites"

if (!(Test-Command "git")) {
    throw "Git is not installed or not in PATH."
}
if (!(Test-Command "python")) {
    throw "Python is not installed or not in PATH."
}

python --version
git --version

# -------------------------
# Setup directories
# -------------------------
$comfyDir = Join-Path $root "ComfyUI"
$venvDir  = Join-Path $comfyDir "venv"
$nodesDir = Join-Path $comfyDir "custom_nodes"
$nodesListPath = Join-Path $root "installer\nodes.list"

# -------------------------
# Install/update ComfyUI
# -------------------------
Write-Step "Installing/Updating ComfyUI"

if (!(Test-Path $comfyDir)) {
    Write-Host "Cloning ComfyUI..."
    git clone https://github.com/comfyanonymous/ComfyUI.git $comfyDir
} else {
    Write-Host "ComfyUI exists, pulling updates..."
    Set-Location $comfyDir
    git pull
}

# -------------------------
# Create venv
# -------------------------
Write-Step "Creating virtual environment"

Set-Location $comfyDir

if (!(Test-Path $venvDir)) {
    python -m venv venv
    Write-Host "venv created."
} else {
    Write-Host "venv already exists."
}

$py  = Join-Path $venvDir "Scripts\python.exe"
$pip = Join-Path $venvDir "Scripts\pip.exe"

# -------------------------
# Upgrade pip
# -------------------------
Write-Step "Upgrading pip"
& $py -m pip install --upgrade pip

# -------------------------
# Install PyTorch CUDA build
# -------------------------
Write-Step "Installing PyTorch (CUDA build)"
& $pip install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# -------------------------
# Install ComfyUI requirements
# -------------------------
Write-Step "Installing ComfyUI requirements"
& $pip install -r (Join-Path $comfyDir "requirements.txt")

# -------------------------
# Install custom nodes
# -------------------------
Write-Step "Installing custom nodes"
New-Item -ItemType Directory -Force -Path $nodesDir | Out-Null

if (!(Test-Path $nodesListPath)) {
    Write-Host "No nodes.list found at: $nodesListPath"
    Write-Host "Skipping custom nodes."
} else {
    $nodeUrls = Get-Content $nodesListPath | Where-Object { $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") }

    foreach ($url in $nodeUrls) {
        $name = Get-RepoNameFromUrl $url
        $target = Join-Path $nodesDir $name

        if (!(Test-Path $target)) {
            Write-Host "Cloning node: $name"
            git clone $url $target
        } else {
            Write-Host "Updating node: $name"
            Set-Location $target
            git pull
        }

        # If node has requirements.txt, install it
        $req = Join-Path $target "requirements.txt"
        if (Test-Path $req) {
            Write-Host "Installing node requirements for $name"
            & $pip install -r $req
        }
    }
}

# -------------------------
# Verification: Torch import
# -------------------------
Write-Step "Verification (Torch + CUDA availability)"
& $py -c "import torch; print('torch version:', torch.__version__); print('cuda available:', torch.cuda.is_available()); print('cuda device count:', torch.cuda.device_count())"

# -------------------------
# CI MODE: Skip server launch test
# -------------------------
if ($ciMode) {
    Write-Step "CI_MODE enabled - skipping ComfyUI launch health check"
    Write-Host "This is expected because GitHub Actions runners do not have NVIDIA GPUs."
    Write-Step "DONE"
    Stop-Transcript
    exit 0
}

# -------------------------
# Launch + health check (real machine mode)
# -------------------------
Write-Step "Launching ComfyUI and running health check"
Set-Location $comfyDir

$serverUrl = "http://127.0.0.1:8188/"
$logServer = Join-Path $logDir "comfyui-server.log"

Write-Host "Starting ComfyUI..."
Write-Host "Logging ComfyUI output to: $logServer"

# Start ComfyUI and redirect output directly to file (reliable)
$comfyProcess = Start-Process `
    -FilePath $py `
    -ArgumentList "main.py --listen 127.0.0.1 --port 8188" `
    -WorkingDirectory $comfyDir `
    -RedirectStandardOutput $logServer `
    -RedirectStandardError $logServer `
    -PassThru `
    -WindowStyle Hidden

Write-Host "Waiting for ComfyUI at $serverUrl ..."
$ok = Wait-ForUrl $serverUrl 300   # 5 minutes timeout (important)

if (-not $ok) {
    Write-Host ""
    Write-Host "Health check FAILED. Printing last 80 lines of ComfyUI log:"
    Write-Host "--------------------------------------------------------"

    if (Test-Path $logServer) {
        Get-Content $logServer -Tail 80 | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "(No comfyui-server.log created)"
    }

    try { Stop-Process -Id $comfyProcess.Id -Force } catch {}
    throw "Health check FAILED: ComfyUI did not respond on port 8188."
}

Write-Host "Health check PASSED: ComfyUI responded."

Write-Host "Stopping ComfyUI..."
try { Stop-Process -Id $comfyProcess.Id -Force } catch {}

Write-Step "DONE"
Stop-Transcript
