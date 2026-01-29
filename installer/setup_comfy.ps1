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
    & $py -m pip install --upgrade pip
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
    & $py -m pip install --upgrade pip

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

    $run1 = Join-Path $root "run_nvidia_gpu.bat"
    $run2 = Join-Path $root "run_nvidia_gpu_fast_fp16_accumulation.bat"

    $upd1 = Join-Path $root "update_comfyui.bat"
    $upd2 = Join-Path $root "update_comfyui_and_python_dependencies.bat"
    $upd3 = Join-Path $root "update_comfyui_stable.bat"

    $runContent1 = @"
@echo off
cd /d "%~dp0"
cd ComfyUI
venv\Scripts\python.exe main.py --windows-standalone-build --enable-manager
pause
"@

    $runContent2 = @"
@echo off
cd /d "%~dp0"
cd ComfyUI
venv\Scripts\python.exe main.py --windows-standalone-build --enable-manager --fast --fp16-accumulation
pause
"@

    $updateContent1 = @"
@echo off
cd /d "%~dp0"
cd ComfyUI

if exist venv\Scripts\python.exe (
  venv\Scripts\python.exe ..\installer\update\update.py
) else (
  python ..\installer\update\update.py
)

pause
"@

    $updateContent2 = @"
@echo off
cd /d "%~dp0"
cd ComfyUI

if exist venv\Scripts\python.exe (
  venv\Scripts\python.exe ..\installer\update\update.py --deps
) else (
  python ..\installer\update\update.py --deps
)

pause
"@

    $updateContent3 = @"
@echo off
cd /d "%~dp0"
cd ComfyUI

if exist venv\Scripts\python.exe (
  venv\Scripts\python.exe ..\installer\update\update.py --stable --deps
) else (
  python ..\installer\update\update.py --stable --deps
)

pause
"@

    Set-Content -Path $run1 -Value $runContent1 -Encoding ASCII
    Set-Content -Path $run2 -Value $runContent2 -Encoding ASCII
    Set-Content -Path $upd1 -Value $updateContent1 -Encoding ASCII
    Set-Content -Path $upd2 -Value $updateContent2 -Encoding ASCII
    Set-Content -Path $upd3 -Value $updateContent3 -Encoding ASCII

    Write-Host "Created: run_nvidia_gpu.bat"
    Write-Host "Created: run_nvidia_gpu_fast_fp16_accumulation.bat"
    Write-Host "Created: update_comfyui.bat"
    Write-Host "Created: update_comfyui_and_python_dependencies.bat"
    Write-Host "Created: update_comfyui_stable.bat"
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

# -------------------------
# Create official-style updater (update.py)
# -------------------------
Write-Step "Setting up updater files"
$updDir = Join-Path $root "installer\update"
New-Item -ItemType Directory -Force -Path $updDir | Out-Null

$updPy = Join-Path $updDir "update.py"
$updContent = @"
import pygit2
from datetime import datetime
import sys
import os
import shutil
import filecmp

def pull(repo, remote_name='origin', branch='master'):
    for remote in repo.remotes:
        if remote.name == remote_name:
            remote.fetch()
            remote_master_id = repo.lookup_reference('refs/remotes/origin/%s' % (branch)).target
            merge_result, _ = repo.merge_analysis(remote_master_id)
            # Up to date, do nothing
            if merge_result & pygit2.GIT_MERGE_ANALYSIS_UP_TO_DATE:
                return
            # We can just fastforward
            elif merge_result & pygit2.GIT_MERGE_ANALYSIS_FASTFORWARD:
                repo.checkout_tree(repo.get(remote_master_id))
                try:
                    master_ref = repo.lookup_reference('refs/heads/%s' % (branch))
                    master_ref.set_target(remote_master_id)
                except KeyError:
                    repo.create_branch(branch, repo.get(remote_master_id))
                repo.head.set_target(remote_master_id)
            elif merge_result & pygit2.GIT_MERGE_ANALYSIS_NORMAL:
                repo.merge(remote_master_id)

                if repo.index.conflicts is not None:
                    for conflict in repo.index.conflicts:
                        print('Conflicts found in:', conflict[0].path)  # noqa: T201
                    raise AssertionError('Conflicts, ahhhhh!!')

                user = repo.default_signature
                tree = repo.index.write_tree()
                repo.create_commit('HEAD',
                                    user,
                                    user,
                                    'Merge!',
                                    tree,
                                    [repo.head.target, remote_master_id])
                # We need to do this or git CLI will think we are still merging.
                repo.state_cleanup()
            else:
                raise AssertionError('Unknown merge analysis result')

pygit2.option(pygit2.GIT_OPT_SET_OWNER_VALIDATION, 0)
repo_path = str(sys.argv[1])
repo = pygit2.Repository(repo_path)
ident = pygit2.Signature('comfyui', 'comfy@ui')
try:
    print(""stashing current changes"")  # noqa: T201
    repo.stash(ident)
except KeyError:
    print(""nothing to stash"")  # noqa: T201
except:
    print(""Could not stash, cleaning index and trying again."")  # noqa: T201
    repo.state_cleanup()
    repo.index.read_tree(repo.head.peel().tree)
    repo.index.write()
    try:
        repo.stash(ident)
    except KeyError:
        print(""nothing to stash."")  # noqa: T201

backup_branch_name = 'backup_branch_{}'.format(datetime.today().strftime('%Y-%m-%d_%H_%M_%S'))
print(""creating backup branch: {}"".format(backup_branch_name))  # noqa: T201
try:
    repo.branches.local.create(backup_branch_name, repo.head.peel())
except:
    pass

print(""checking out master branch"")  # noqa: T201
branch = repo.lookup_branch('master')
if branch is None:
    try:
        ref = repo.lookup_reference('refs/remotes/origin/master')
    except:
        print(""fetching."")  # noqa: T201
        for remote in repo.remotes:
            if remote.name == ""origin"":
                remote.fetch()
        ref = repo.lookup_reference('refs/remotes/origin/master')
    repo.checkout(ref)
    branch = repo.lookup_branch('master')
    if branch is None:
        repo.create_branch('master', repo.get(ref.target))
else:
    ref = repo.lookup_reference(branch.name)
    repo.checkout(ref)

print(""pulling latest changes"")  # noqa: T201
pull(repo)

if ""--stable"" in sys.argv:
    def latest_tag(repo):
        versions = []
        for k in repo.references:
            try:
                prefix = ""refs/tags/v""
                if k.startswith(prefix):
                    version = list(map(int, k[len(prefix):].split(""."")))
                    versions.append((version[0] * 10000000000 + version[1] * 100000 + version[2], k))
            except:
                pass
        versions.sort()
        if len(versions) > 0:
            return versions[-1][1]
        return None
    latest_tag = latest_tag(repo)
    if latest_tag is not None:
        repo.checkout(latest_tag)

print(""Done!"")  # noqa: T201

self_update = True
if len(sys.argv) > 2:
    self_update = '--skip_self_update' not in sys.argv

update_py_path = os.path.realpath(__file__)
repo_update_py_path = os.path.join(repo_path, "".ci/update_windows/update.py"")

cur_path = os.path.dirname(update_py_path)


req_path = os.path.join(cur_path, ""current_requirements.txt"")
repo_req_path = os.path.join(repo_path, ""requirements.txt"")


def files_equal(file1, file2):
    try:
        return filecmp.cmp(file1, file2, shallow=False)
    except:
        return False

def file_size(f):
    try:
        return os.path.getsize(f)
    except:
        return 0


if self_update and not files_equal(update_py_path, repo_update_py_path) and file_size(repo_update_py_path) > 10:
    shutil.copy(repo_update_py_path, os.path.join(cur_path, ""update_new.py""))
    exit()

if not os.path.exists(req_path) or not files_equal(repo_req_path, req_path):
    import subprocess
    try:
        subprocess.check_call([sys.executable, '-s', '-m', 'pip', 'install', '-r', repo_req_path])
        shutil.copy(repo_req_path, req_path)
    except:
        pass


stable_update_script = os.path.join(repo_path, "".ci/update_windows/update_comfyui_stable.bat"")
stable_update_script_to = os.path.join(cur_path, ""update_comfyui_stable.bat"")

try:
    if not file_size(stable_update_script_to) > 10:
        shutil.copy(stable_update_script, stable_update_script_to)
except:
    pass


"@
Set-Content -Path $updPy -Value $updContent -Encoding UTF8
Write-Host "Created: installer/update/update.py"

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
