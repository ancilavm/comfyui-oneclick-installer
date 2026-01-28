# ComfyUI NVIDIA CUDA Installer (ComfyUI + Custom Nodes)

> **⚠️ NVIDIA ONLY:** This installer is designed for **NVIDIA GPUs with CUDA**.
> It installs the **CUDA-enabled PyTorch build (cu121)** and is **not intended for AMD GPUs**.

This repository provides a **PowerShell installer** that automatically installs **ComfyUI** along with **CUDA PyTorch** and a curated set of **custom nodes**.

It is intended for Windows users who want a reproducible setup without manually editing `.bat` files each time.

---

## What this repo does

When you run the installer, it will:

✅ Clone / update ComfyUI
✅ Create a Python virtual environment (`venv`)
✅ Install **PyTorch CUDA build (cu121)**
✅ Install ComfyUI requirements
✅ Install custom nodes from a list
✅ Install node requirements (if `requirements.txt` exists in the node repo)
✅ Run a health check (on real machines) by launching ComfyUI and checking port 8188

---

## Repository contents

### Installer script

* `installer/install.ps1`

### Custom nodes list (editable)

* `installer/nodes.list`

### Install command helper file

* `how_to_install.txt` (contains the install command)

---

## Default custom nodes included

The installer installs these nodes by default (from `installer/nodes.list`):

* ComfyUI-Manager — [https://github.com/Comfy-Org/ComfyUI-Manager](https://github.com/Comfy-Org/ComfyUI-Manager)
* rgthree-comfy — [https://github.com/rgthree/rgthree-comfy](https://github.com/rgthree/rgthree-comfy)
* ComfyUI-SeedVR2_VideoUpscaler — [https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler](https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler)
* ComfyUI-KJNodes — [https://github.com/kijai/ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes)
* ComfyUI-Easy-Use — [https://github.com/yolain/ComfyUI-Easy-Use](https://github.com/yolain/ComfyUI-Easy-Use)
* ComfyUI-Impact-Pack — [https://github.com/ltdrdata/ComfyUI-Impact-Pack](https://github.com/ltdrdata/ComfyUI-Impact-Pack)
* ComfyUI-Inspire-Pack — [https://github.com/ltdrdata/ComfyUI-Inspire-Pack](https://github.com/ltdrdata/ComfyUI-Inspire-Pack)
* ComfyUI-GGUF — [https://github.com/city96/ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF)

---

## Requirements

### System

* Windows 10 / Windows 11
* **NVIDIA GPU required (CUDA)**

### Software

* Git installed and available in PATH
* Python installed and available in PATH

Minimum recommended hardware:

* 8GB VRAM (more is better)
* 16GB RAM (32GB recommended)
* 20–40 GB free disk space (depends on models)

---

## Installation Instructions

### Step 1 — Clone this repo

Open Command Prompt / Terminal and run:

```bash
git clone https://github.com/<YOUR_USERNAME>/<YOUR_REPO>.git
cd <YOUR_REPO>
```

### Step 2 — Run installer (PowerShell)

Open PowerShell inside the repo folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File installer\install.ps1
```

> The installer may take several minutes depending on your internet speed and GPU environment.

---

## How to start ComfyUI (after install)

After installation, ComfyUI will be available in:

```
ComfyUI\
```

To start ComfyUI manually:

```powershell
cd ComfyUI
.\venv\Scripts\python.exe main.py --listen 127.0.0.1 --port 8188
```

Then open in your browser:

[http://127.0.0.1:8188](http://127.0.0.1:8188)

---

## Logs

The installer creates logs inside:

```
logs\
```

### Main installer log

```
logs\install.log
```

### ComfyUI server log (only when health check runs)

```
logs\comfyui-server.log
```

If installation fails, upload `logs/install.log` for debugging.

---

## Updating / Re-running the installer

You can safely run the installer again. It is designed to be repeatable:

* If ComfyUI exists → it will `git pull`
* If node exists → it will update it via `git pull`
* If venv exists → it will reuse it

Recommended update process:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File installer\install.ps1
```

---

## Customizing Nodes

Edit this file:

```
installer/nodes.list
```

Rules:

* One GitHub repo URL per line
* Empty lines allowed
* Lines starting with `#` are ignored

Example:

```txt
# Base
https://github.com/Comfy-Org/ComfyUI-Manager

# Extra nodes
https://github.com/rgthree/rgthree-comfy
```

---

## Troubleshooting

### 1) Health check fails (ComfyUI did not respond on port 8188)

This usually happens when:

* ComfyUI takes longer to load on first run (custom nodes + manager)
* A custom node fails during import
* Port 8188 is already being used

Fix:
Run ComfyUI manually to see the error:

```powershell
cd ComfyUI
.\venv\Scripts\python.exe main.py --listen 127.0.0.1 --port 8188
```

If it starts successfully, open:
[http://127.0.0.1:8188](http://127.0.0.1:8188)

---

### 2) Port 8188 already in use

If another ComfyUI instance is already running, try:

* close old ComfyUI windows OR
* restart PC OR
* run ComfyUI on another port:

```powershell
.\venv\Scripts\python.exe main.py --listen 127.0.0.1 --port 8190
```

---

### 3) Torch CUDA not detected / GPU not used

Check torch status:

```powershell
cd ComfyUI
.\venv\Scripts\python.exe -c "import torch; print(torch.__version__); print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NO GPU')"
```

If CUDA is not available:

* update NVIDIA drivers
* ensure your GPU is supported
* ensure you're not using CPU-only torch

---

### 4) Antivirus / Bitdefender blocks installer

Some antivirus solutions flag PowerShell automation scripts as suspicious because they:

* download dependencies
* install packages
* clone repositories

This is usually a false-positive.

If blocked:

* temporarily disable script scanning (if applicable), or
* add this repo folder to antivirus exceptions, or
* run the installer on a dev/test machine

---

### 5) Node dependency errors (ModuleNotFoundError)

Some custom nodes require additional external tools (FFmpeg, Visual C++ runtime, etc.).

If ComfyUI starts but a node fails:

* check the console output
* check `logs/comfyui-server.log`

---

## Notes

* This installer is designed for **NVIDIA CUDA environments only**
* GitHub Actions CI runs in `CI_MODE` (no GPU) so it skips launching ComfyUI
* Model downloads are NOT included (you must download models separately)

---

## Disclaimer

This repository automates downloads and installation of Python packages and Git repositories.
Use at your own risk.
