# installer/setup_comfy.ps1
# ComfyNVIDIA — ComfyUI NVIDIA CUDA Installer (Windows)
# Compatible with Windows PowerShell 5.1
#
# Professional installer behavior:
# - Detects existing installation
# - Offers mode selection: Install / Update / Repair / Exit
# - CI compatible: auto-selects UPDATE mode and skips prompts/folder picker
# - Uses YAML-safe paths for extra_model_paths.yaml and auto-scans all model subfolders

$ErrorActionPreference = "Stop"

# -------------------------
# CI Detection
# -------------------------
$IsCI = $false
if ($env:CI -eq "true") { $IsCI = $true }
if ($env:GITHUB_ACTIONS -eq "true") { $IsCI = $true }

# -------------------------
# UI (Folder picker)
# Only used in non-CI mode
# -------------------------
Add-Type -AssemblyName System.Windows.Forms

function Select-Folder($title) {
    if ($script:IsCI) { return $null }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $title
    $dialog.ShowNewFolderButton = $false

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }
    return $dialog.SelectedPath
}

function Write-Banner {
    Write-Host ""
    Write-Host "========================================="
    Write-Host "        ComfyNVIDIA Installer"
    Write-Host "   ComfyUI + CUDA PyTorch (Windows)"
    Write-Host "========================================="
    Write-Host ""
    if ($script:IsCI) {
        Write-Host "CI mode: ON (auto mode selection, no prompts)"
        Write-Host ""
    }
}

function Write-Step($msg) {
    Write-Host ""
    Write-Host "=== $msg ==="
}

function Write-OK($msg) {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Green
    Write-Host $msg -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Green
    Write-Host ""
}

function Write-Warn($msg) {
    Write-Host "WARNING: $msg" -ForegroundColor Yellow
}

function Test-Command($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

function Fail($msg) {
    Write-Host ""
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Write-Host ""
    exit 1
}

function Ensure-Git {
    if (!(Test-Command "git")) {
        Fail "Git not found. Please install Git first from https://git-scm.com/downloads and restart CMD/PowerShell."
    }
}

function Ensure-WinGet {
    return (Test-Command "winget")
}

function Get-PythonVersionString {
    if (!(Test-Command "python")) { return $null }
    try {
        $v = python -c "import sys; print(str(sys.version_info.major)+'.'+str(sys.version_info.minor)+'.'+str(sys.version_info.micro))"
        return $v.Trim()
    } catch {
        return $null
    }
}

function Install-Python311 {
    Write-Step "Installing Python 3.11 (forced)"

    if (!(Ensure-WinGet)) {
        Fail "winget not found. Install Python manually from https://www.python.org/downloads/windows/ (Python 3.11 recommended)."
    }

    winget install -e --id Python.Python.3.11 --accept-package-agreements --accept-source-agreements
    Refresh-Path

    if (!(Test-Command "python")) {
        Fail "Python installation finished but python is still not available in PATH. Restart PC and run again."
    }
}

function Ensure-Python311 {
    if ($script:IsCI) {
        $ver = Get-PythonVersionString
        if ($null -eq $ver) {
            Fail "Python not found in CI. Ensure actions/setup-python installs Python 3.11 before running installer."
        }
        if ($ver -notmatch "^3\.11\.") {
            Fail "CI Python must be 3.11.x. Detected: $ver. Fix workflow to use actions/setup-python@v5 with python-version: 3.11"
        }
        Write-Host "CI Python OK: $ver"
        return
    }

    $ver = Get-PythonVersionString
    if ($null -eq $ver) {
        Write-Warn "Python not found. Installing Python 3.11..."
        Install-Python311
        $ver = Get-PythonVersionString
    }

    if ($null -eq $ver) {
        Fail "Python still not detected after installation."
    }

    if ($ver -notmatch "^3\.11\.") {
        Write-Warn "Detected Python: $ver"
        Write-Warn "Installing Python 3.11 for best compatibility..."
        Install-Python311
        $ver = Get-PythonVersionString
    }

    if ($ver -notmatch "^3\.11\.") {
        Fail "Python 3.11.x could not be enforced. Current python version: $ver"
    }

    Write-Host "Using Python: $ver"
}

function Ask-YesNo($prompt, $defaultYes=$true) {
    if ($script:IsCI) { return $defaultYes }

    $suffix = "[Y/n]"
    if (-not $defaultYes) { $suffix = "[y/N]" }

    $answer = Read-Host "$prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $defaultYes }
    $answer = $answer.Trim().ToLower()
    return ($answer -eq "y" -or $answer -eq "yes")
}

function Choose-Mode($isInstalled) {
    # Modes: INSTALL, UPDATE, REPAIR, EXIT
    if ($script:IsCI) {
        if ($isInstalled) { return "UPDATE" }
        return "INSTALL"
    }

    if (-not $isInstalled) {
        Write-Host "No existing ComfyUI installation found."
        return "INSTALL"
    }

    Write-Host ""
    Write-Host "ComfyUI is already installed in this folder."
    Write-Host ""
    Write-Host "Choose what you want to do:"
    Write-Host "  1) Update   (git pull ComfyUI + nodes)"
    Write-Host "  2) Repair   (reinstall Python packages in venv)"
    Write-Host "  3) Exit"
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Enter 1 / 2 / 3"
        switch ($choice.Trim()) {
            "1" { return "UPDATE" }
            "2" { return "REPAIR" }
            "3" { return "EXIT" }
            default { Write-Host "Invalid choice. Try again." }
        }
    }
}

function Get-RepoNameFromUrl($url) {
    $u = $url.Trim()
    if ($u.EndsWith(".git")) { $u = $u.Substring(0, $u.Length - 4) }
    $parts = $u.Split("/")
    return $parts[$parts.Length - 1]
}

function Install-InsightFaceWheel {
    param(
        [string]$py,
        [string]$pip,
        [string]$rootDir
    )

    Write-Step "Installing InsightFace (prebuilt wheel - no C++ build tools)"

    $wheelUrl = "https://github.com/Gourieff/Assets/raw/main/Insightface/insightface-0.7.3-cp311-cp311-win_amd64.whl"

    $wheelDir = Join-Path $rootDir "installer\wheels"
    New-Item -ItemType Directory -Force -Path $wheelDir | Out-Null
    $wheelFile = Join-Path $wheelDir ([IO.Path]::GetFileName($wheelUrl))

    Write-Host "Downloading InsightFace wheel..."
    Invoke-WebRequest -Uri $wheelUrl -OutFile $wheelFile -UseBasicParsing

    Write-Host "Installing InsightFace wheel..."
    & $pip install --upgrade pip
    & $pip install $wheelFile
    & $pip install --upgrade onnxruntime opencv-python tqdm

    Write-Host "InsightFace installed."
}

function To-YamlPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    return ($p -replace "\\", "/")
}

function Write-ExtraModelPathsYaml {
    param(
        [string]$comfyDir,
        [string]$modelsPath
    )

    Write-Step "Generating extra_model_paths.yaml (auto scan)"

    $yamlPath = Join-Path $comfyDir "extra_model_paths.yaml"
    $modelsYaml = To-YamlPath $modelsPath

    if (!(Test-Path $modelsPath)) {
        Fail "Models folder not found: $modelsPath"
    }

    $folders = Get-ChildItem -Path $modelsPath -Directory -ErrorAction SilentlyContinue

    $lines = @()
    $lines += "# Auto-generated by ComfyNVIDIA installer"
    $lines += "# Base models folder: $modelsYaml"
    $lines += "comfyui:"
    $lines += "  base_path: `"$modelsYaml`""

    foreach ($f in $folders) {
        $name = $f.Name
        if ($name.StartsWith(".")) { continue }
        $val = To-YamlPath $f.FullName
        $lines += "  ${name}: `"$val`""
    }

    Set-Content -Path $yamlPath -Value $lines -Encoding UTF8
    Write-Host "Created: $yamlPath"
    Write-Host ("Mapped {0} model subfolders." -f ($folders.Count))
}

function Ensure-Venv($comfyDir) {
    $venvDir  = Join-Path $comfyDir "venv"
    if (!(Test-Path $venvDir)) {
        Write-Step "Creating virtual environment"
        Set-Location $comfyDir
        python -m venv venv
    } else {
        Write-Host "venv already exists."
    }

    $py  = Join-Path $venvDir "Scripts\python.exe"
    $pip = Join-Path $venvDir "Scripts\pip.exe"

    if (!(Test-Path $py)) { Fail "venv python not found: $py" }
    if (!(Test-Path $pip)) { Fail "venv pip not found: $pip" }

    return @{ py=$py; pip=$pip; venvDir=$venvDir }
}

function Install-CorePackages($pip, $comfyDir) {
    Write-Step "Upgrading pip"
    & $pip install --upgrade pip

    Write-Step "Installing PyTorch (CUDA build cu121)"
    & $pip install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

    Write-Step "Installing ComfyUI requirements"
    & $pip install -r (Join-Path $comfyDir "requirements.txt")
}

function Install-Or-Update-Nodes($pip, $nodesDir, $nodesListPath) {
    Write-Step "Installing/Updating custom nodes"
    New-Item -ItemType Directory -Force -Path $nodesDir | Out-Null

    if (!(Test-Path $nodesListPath)) {
        Write-Host "No nodes.list found. Skipping custom nodes."
        return
    }

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

        $req = Join-Path $target "requirements.txt"
        if (Test-Path $req) {
            Write-Host "Installing node requirements for $name"
            & $pip install -r $req
        }
    }
}

function Create-HelperFiles($root) {
    Write-Step "Creating helper files (run/update)"

    $runBat = Join-Path $root "run_comfyui.bat"
    $updateBat = Join-Path $root "update_comfyui.bat"

    $runContent = @"
@echo off
cd /d "%~dp0"
cd ComfyUI
venv\Scripts\python.exe main.py --listen 127.0.0.1 --port 8188 --windows-standalone-build --enable-manager
pause
"@

    $updateContent = @"
@echo off
cd /d "%~dp0"

echo Updating ComfyUI...
cd ComfyUI
git pull

echo Updating custom nodes...
cd custom_nodes
for /d %%D in (*) do (
  echo Updating %%D ...
  cd %%D
  git pull
  cd ..
)

echo Done.
pause
"@

    Set-Content -Path $runBat -Value $runContent -Encoding ASCII
    Set-Content -Path $updateBat -Value $updateContent -Encoding ASCII

    Write-Host "Created: run_comfyui.bat"
    Write-Host "Created: update_comfyui.bat"
}

# -------------------------
# Paths + logging
# -------------------------
$root = Join-Path $PSScriptRoot ".."
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$logFile = Join-Path $logDir "install.log"
Start-Transcript -Path $logFile -Append

Write-Banner

# -------------------------
# Prerequisites
# -------------------------
Write-Step "Checking prerequisites"
Ensure-Git
Ensure-Python311
git --version | Out-Host

# -------------------------
# Setup directories
# -------------------------
$comfyDir = Join-Path $root "ComfyUI"
$nodesDir = Join-Path $comfyDir "custom_nodes"
$nodesListPath = Join-Path $root "installer\nodes.list"

$isInstalled = (Test-Path $comfyDir)
$mode = Choose-Mode $isInstalled

if ($mode -eq "EXIT") {
    Write-Host "Exiting."
    Stop-Transcript
    exit 0
}

# -------------------------
# Install / Update ComfyUI repo
# -------------------------
if ($mode -eq "INSTALL") {
    Write-Step "Installing ComfyUI"
    if (!(Test-Path $comfyDir)) {
        git clone https://github.com/comfyanonymous/ComfyUI.git $comfyDir
    }
} elseif ($mode -eq "UPDATE") {
    Write-Step "Updating ComfyUI"
    if (Test-Path $comfyDir) {
        Set-Location $comfyDir
        git pull
    } else {
        Write-Warn "ComfyUI folder not found. Switching to INSTALL mode."
        git clone https://github.com/comfyanonymous/ComfyUI.git $comfyDir
        $mode = "INSTALL"
    }
} elseif ($mode -eq "REPAIR") {
    Write-Step "Repair mode: keeping ComfyUI repo as-is"
    if (!(Test-Path $comfyDir)) {
        Fail "Repair mode selected but ComfyUI folder does not exist."
    }
}

# -------------------------
# Venv + packages
# -------------------------
$venv = Ensure-Venv $comfyDir
$py = $venv.py
$pip = $venv.pip

if ($mode -eq "INSTALL" -or $mode -eq "REPAIR") {
    Install-CorePackages -pip $pip -comfyDir $comfyDir
} elseif ($mode -eq "UPDATE") {
    # Update mode still ensures requirements are up-to-date, but less intrusive
    Install-CorePackages -pip $pip -comfyDir $comfyDir
}

# -------------------------
# Nodes
# -------------------------
if ($mode -eq "INSTALL" -or $mode -eq "UPDATE") {
    Install-Or-Update-Nodes -pip $pip -nodesDir $nodesDir -nodesListPath $nodesListPath
} else {
    Write-Step "Repair mode: skipping node git pulls"
}

# -------------------------
# Optional InsightFace
# -------------------------
Write-Step "InsightFace"
$defaultInsight = $true
if ($script:IsCI) { $defaultInsight = $false }

if (Ask-YesNo "Install InsightFace? (Recommended for FaceID nodes / IPAdapter FaceID)" $defaultInsight) {
    Install-InsightFaceWheel -py $py -pip $pip -rootDir $root
} else {
    Write-Host "Skipping InsightFace."
}

# -------------------------
# Models folder linking
# -------------------------
Write-Step "Models folder"
if ($script:IsCI) {
    Write-Host "CI mode: skipping external Models folder setup."
} else {
    if (Ask-YesNo "Do you want to link an existing Models folder from another drive?" $true) {
        $modelsPath = Select-Folder "Select your existing Models folder (example: D:\AI\Models)"

        if ([string]::IsNullOrWhiteSpace($modelsPath)) {
            Write-Host "No folder selected. Skipping."
        } elseif (!(Test-Path $modelsPath)) {
            Write-Warn "Folder not found: $modelsPath"
        } else {
            Write-Host "Selected Models path: $modelsPath"
            Write-ExtraModelPathsYaml -comfyDir $comfyDir -modelsPath $modelsPath
        }
    } else {
        Write-Host "Skipping external Models linking."
    }
}

# -------------------------
# Verification
# -------------------------
Write-Step "Verification (Torch + CUDA availability)"
& $py -c "import torch; print('torch version:', torch.__version__); print('cuda available:', torch.cuda.is_available()); print('cuda device count:', torch.cuda.device_count())"

# -------------------------
# Helper scripts
# -------------------------
Create-HelperFiles -root $root

# -------------------------
# End
# -------------------------
if ($script:IsCI) {
    Write-OK "CI TEST PASSED: Installer ran successfully."
    Stop-Transcript
    exit 0
}

Write-OK "✅ ComfyUI successfully installed"
Write-Host "Start ComfyUI by running: run_comfyui.bat"
Write-Host "Or manually:"
Write-Host "  cd .\ComfyUI"
Write-Host "  .\venv\Scripts\python.exe main.py --listen 127.0.0.1 --port 8188"
Write-Host ""

Stop-Transcript
