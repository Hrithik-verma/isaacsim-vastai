# isaacsim-vastai

A Vast.ai-ready Docker template that runs the **NVIDIA Isaac Sim GUI in a web
browser** via **KasmVNC**, on a **KDE Plasma** desktop, with **ROS 2 Humble**
installed and wired into Isaac Sim's ROS 2 bridge.

**This is its own image** — unlike `isaacsim-runpod` (which uses XFCE), this
repo swaps in KDE Plasma to feel closer to Vast.ai's own desktop template. It
is built and published separately; see
[How this differs from Vast.ai's official desktop template](#how-this-differs-from-vastais-official-desktop-template)
for what KDE here does *not* include (Instance Portal, Steam, Blender, Wine,
Selkies/Guacamole, Tailscale, Cloudflare tunnels — those are Vast.ai's own
proprietary nested-VM tooling, not something a Docker image gets for free).

```
ubuntu:22.04
        └── + Miniforge/conda env `env_isaacsim`
        │        └── Isaac Sim installed via pip (isaacsim[all,extscache])
        └── + VirtualGL             → GPU-accelerated rendering into the VNC framebuffer
        └── + KDE Plasma desktop
        └── + KasmVNC 1.4.0         → browser access on port 6901
        └── + ROS 2 Humble          → ros-base, sourced for the isaacsim ros2 bridge
        └── + VS Code, Google Chrome
```

Unlike the official `nvcr.io/nvidia/isaac-sim` container image, this template
installs Isaac Sim **via pip into an isolated conda env**, so you can swap
Isaac Sim versions later with a single `pip install` — no image rebuild
needed. See [Isaac Sim version / upgrading](#isaac-sim-version--upgrading)
below.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the image |
| `Dockerfile.test` | Lightweight variant for quickly testing image changes (no GPU/Isaac Sim/ROS) |
| `entrypoint.sh` | PID 1 — sets up SSH, starts sshd, configures the KasmVNC password, starts KasmVNC + KDE Plasma |
| `run-isaacsim.sh` | Activates the `env_isaacsim` conda env, sets ROS 2 bridge env vars, launches Isaac Sim through VirtualGL |
| `vnc/xstartup` | Starts the KDE Plasma (`startplasma-x11`) session inside VNC |
| `vnc/kasmvnc.yaml` | KasmVNC config (SSL off — see [HTTPS access](#https-access)) |
| `vnc/kscreenlockerrc` | Disables KDE's idle screen locker (no way to unlock a session in this VNC-only setup otherwise) |
| `vnc/kwalletrc` | Disables KWallet so apps (VS Code, Chrome) stop prompting to create an encrypted wallet on every launch |
| `vnc/IsaacSim.desktop` | Desktop launcher icon (runs `run-isaacsim.sh`) |
| `vnc/GoogleChrome.desktop` | Browser launcher icon |
| `vnc/VSCode.desktop` | VS Code launcher icon |
| `vnc/Terminator.desktop` | Terminator launcher icon (also set as KDE's default terminal app) |

## Requirements

- An **RTX-capable NVIDIA GPU** — Isaac Sim's RTX renderer requires ray-tracing
  hardware (RTX A-series, L4/L40, A6000, 3090/4090, etc.). Non-RTX GPUs (T4, V100,
  A100 **without** RTX cores) will not render the viewport.
- A Vast.ai instance with NVIDIA Container Toolkit (all GPU offers on Vast.ai
  provide this).

## Quick start — run it anywhere (test before Vast.ai)

```bash
docker run --rm --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -p 6901:6901 \
  -e VNC_PW='choose-a-password' \
  hrithik108/ubuntu-isaac-sim:kde
```

Open `http://localhost:6901/`, log in with user `kasm_user` and your `VNC_PW`,
then double-click the **Isaac Sim** icon on the desktop (or run
`run-isaacsim.sh` in a terminal).

## Build it yourself

```bash
docker build -t hrithik108/ubuntu-isaac-sim:kde .
docker push hrithik108/ubuntu-isaac-sim:kde
```

Default build args target Isaac Sim 5.0.0 for fast local testing. To ship
Isaac Sim 6.0 instead:

```bash
docker build \
  --build-arg ISAACSIM_PIP_VERSION=6.0.0.1 \
  --build-arg PYTHON_VERSION=3.12 \
  --build-arg TORCH_SPEC=torch==2.11.0 \
  -t hrithik108/ubuntu-isaac-sim:kde-6.0 .
```

| Build arg | Default | Meaning |
|-----------|---------|---------|
| `KASMVNC_VERSION` | `1.4.0` | KasmVNC release to install |
| `ISAACSIM_PIP_VERSION` | `5.0.0` | Isaac Sim pip package version (`isaacsim[all,extscache]==<ver>`) |
| `PYTHON_VERSION` | `3.11` | Python version for the `env_isaacsim` conda env |
| `TORCH_SPEC` | *(empty)* | PyTorch spec to install first, e.g. `torch==2.11.0` (5.0's GUI doesn't need torch; 6.0 does) |
| `TORCH_CUDA_INDEX` | `https://download.pytorch.org/whl/cu128` | pip index used for `TORCH_SPEC` |
| `ROS_PACKAGE` | `ros-humble-ros-base` | ROS 2 package to install |

## Isaac Sim version / upgrading

Because Isaac Sim lives in a pip-installed conda env (`env_isaacsim`) rather
than being baked into the base image, you can upgrade it **without rebuilding**
by execing into a running container:

```bash
conda activate env_isaacsim
pip install "isaacsim[all,extscache]==<new-version>" --extra-index-url https://pypi.nvidia.com
```

For a durable upgrade, rebuild the image with `--build-arg
ISAACSIM_PIP_VERSION=<new-version>` (and matching `PYTHON_VERSION`/
`TORCH_SPEC` if the new version needs them) instead.

## Deploy as a Vast.ai template

This is a plain **Docker Container template** (not the KVM/VM-based template
family Vast.ai's own official desktop templates use — see
[How this differs from Vast.ai's official desktop template](#how-this-differs-from-vastais-official-desktop-template)
below). Vast.ai's Docker templates map ports randomly on the host and don't
provide an Instance Portal/Cloudflare tunnel/Selkies stack for custom
images — you connect directly to whatever external port Vast.ai assigns.

1. **Templates → New Template** (or **Edit Template** on an existing draft).
2. **Image path:** `hrithik108/ubuntu-isaac-sim:kde`.
3. **Launch mode: `docker ENTRYPOINT`** — this image ships its own
   `/usr/local/bin/entrypoint.sh` as `ENTRYPOINT`, so Vast.ai should run the
   container exactly as built rather than injecting Jupyter/SSH-only
   supervision.
4. **Docker Options** — declare the ports you want opened (Vast.ai maps each
   to a random external port unless you use an identity port ≥ 70000):
   ```
   -p 6901:6901 -p 22:22
   ```
5. **Environment variables:**
   | Name | Example | Notes |
   |------|---------|-------|
   | `VNC_PW` | `super-secret` | Web login password — **set this**, it has no secure default |
   | `VNC_USER` | `kasm_user` | web login username (default `kasm_user`) |
   | `RESOLUTION` | `1920x1080` | desktop size |
6. **Recommended disk space:** 30+ GB (Isaac Sim + shader cache + assets).
7. Search for an **RTX GPU** offer, rent it. On the instance card, find the
   **external port mapped to internal 6901** (Vast.ai shows this per-port,
   it will *not* just be `6901`) and open
   `https://<instance-ip>:<mapped-port>/` in your browser.

## How this differs from Vast.ai's official desktop template

Vast.ai's own [Ubuntu Desktop (VM)](https://cloud.vast.ai/template/readme/b522f5577b2c30167c826b54bedffc71)
template runs on the [`vastai/kvm`](https://hub.docker.com/r/vastai/kvm)
image, which boots a full **nested KVM virtual machine** inside the
container (it ships a multi-GB guest disk image and a proprietary
`kaalia-vm-supervisor` binary as `ENTRYPOINT`). Everything in that
template — the Instance Portal on port 1111, Selkies WebRTC, Guacamole,
`OPEN_BUTTON_TOKEN` auth, the built-in Cloudflare tunnel, Tailscale — is
Vast.ai's own proprietary tooling running **inside that guest VM**, not a
generic feature every Docker template gets.

This repo is a normal Docker container (KasmVNC directly on the host kernel,
no nested VM), so none of that machinery applies here: no Instance Portal,
no `OPEN_BUTTON_TOKEN`, no automatic HTTPS/Cloudflare tunnel, and ports are
mapped randomly rather than fixed. What you get instead is the same thing as
`isaacsim-runpod`: a lightweight, directly-accessible KasmVNC desktop with
Isaac Sim and ROS 2 — you just need to read the actual mapped port off the
instance card rather than assuming `6901`.

## Run locally (to test before renting on Vast.ai)

```bash
docker run --rm --gpus all \
  --name local_isaacsim_vastai \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -p 6901:6901 \
  -e VNC_PW='choose-a-password' \
  hrithik108/ubuntu-isaac-sim:kde
```

### Test the GUI locally in a browser

You need a local NVIDIA GPU (RTX-capable) with the NVIDIA Container Toolkit
installed and Docker's default runtime set to `nvidia` (or pass
`--runtime=nvidia`). Then:

1. **Build (or pull) the image:**
   ```bash
   docker build -t isaacsim-vastai:test .
   # or: docker pull hrithik108/ubuntu-isaac-sim:kde
   ```
2. **Run it, mapping the KasmVNC port to something free on your host** (e.g.
   `16901` so it doesn't clash with anything already on 6901):
   ```bash
   docker run -d --name isaacsim-vastai-gui-test --gpus all \
     -e NVIDIA_DRIVER_CAPABILITIES=all \
     -p 16901:6901 \
     -e VNC_PW=password \
     isaacsim-vastai:test
   ```
3. **Open the desktop in your browser:** go to `https://localhost:16901/`
   (KasmVNC serves TLS with a self-signed cert — click through the browser's
   "not secure" warning). Log in with:
   - Username: `kasm_user`
   - Password: `password` (or whatever you set `VNC_PW` to)
4. **Launch Isaac Sim:** double-click the **Isaac Sim** icon on the KDE Plasma
   desktop, or open Terminator (Application Launcher → Terminator, or the
   desktop icon) and run:
   ```bash
   run-isaacsim.sh
   ```
   First launch compiles shaders and can take a minute or two — watch the
   terminal for `Isaac Sim Full Version: ...` and `app ready`.
5. **Check ROS 2 bridge / GPU usage from the host** while it's running:
   ```bash
   docker exec isaacsim-vastai-gui-test ps aux | grep isaacsim
   nvidia-smi   # should show the isaacsim python process using GPU memory
   ```
6. **Tear down** when done:
   ```bash
   docker rm -f isaacsim-vastai-gui-test
   ```

For a fast smoke test of just the KasmVNC/KDE Plasma/entrypoint layer (no GPU,
no Isaac Sim, no ROS — proves the desktop and password path work):

```bash
docker build -f Dockerfile.test -t isaac-kasm-test .
docker run --rm -p 6901:6901 -e VNC_PW=password isaac-kasm-test
# open http://localhost:6901/  (user: kasm_user, pass: password)
```

## SSH access

The container runs `sshd` on port **22** (mapped to a random external port by
Vast.ai). Vast.ai injects your account's SSH public key via the confirmed
`$SSH_PUBLIC_KEY` environment variable; the entrypoint writes it to
`/root/.ssh/authorized_keys`. Make sure you've added your key under Vast.ai
**Account → SSH Keys**.

Once the instance is up, find the external port mapped to internal `22` on
the instance card and connect:

```bash
ssh -p <mapped_port> root@<instance_ip>
```

ROS 2 is auto-sourced in the SSH shell too (added to `/root/.bashrc`), and
`conda activate env_isaacsim` puts you in the Isaac Sim Python env.

## Environment variables

| Var | Default | Meaning |
|-----|---------|---------|
| `VNC_PW` | `isaacsim` | KasmVNC web password — **set this**, there is no Vast.ai-provided token here. Also set as `root`'s Linux password (see below). |
| `VNC_USER` | `kasm_user` | KasmVNC web username |
| `RESOLUTION` | `1920x1080` | Desktop resolution |
| `VNC_PORT` | `6901` | KasmVNC's internal web port (Vast.ai maps this to a random external port — check the instance card) |
| `SSH_PUBLIC_KEY` | *(set by Vast.ai)* | Your account's SSH public key, injected automatically |

The idle screen locker is disabled (`vnc/kscreenlockerrc`), since there's no
display-manager/"switch user" flow in this VNC-only setup to recover a locked
session. As a safety net in case KDE still locks the session for any reason
(manual lock, resume-from-suspend), the entrypoint also sets `root`'s actual
Linux password to `VNC_PW` on every container start, so the same password
unlocks it.

KasmVNC serves over HTTPS with a self-signed certificate on its own — no
Vast.ai HTTPS/Cloudflare feature is involved (that only applies to the
`vastai/kvm`-based official templates; see
[How this differs from Vast.ai's official desktop template](#how-this-differs-from-vastais-official-desktop-template)).
Expect a browser warning on first connect; click through it or use
`http://` if you disable TLS in `vnc/kasmvnc.yaml`.

## Rendering: VirtualGL

Isaac Sim's Vulkan/RTX renderer needs a real GPU render node to draw into, but
KasmVNC's X server is software-only. `run-isaacsim.sh` launches Isaac Sim
through **VirtualGL** (`vglrun -d egl0 isaacsim`), which redirects GPU
rendering to `/dev/dri/renderD128` and blits the result into the VNC
framebuffer. Without VirtualGL the Kit window renders blank over VNC. If no
GPU render node is available, the script falls back to launching Isaac Sim
directly (and warns that the viewport may be blank).

## ROS 2 Humble

The image installs **`ros-humble-ros-base`** (no rviz/VTK) as a *system*
package. This is deliberate: `ros-humble-desktop` pulls rviz + VTK, whose
`libfreetype6-dev` dependency conflicts with the `libfreetype6` shipped in
Isaac Sim's pip wheels and fails to install. ros-base gives you
`rclcpp`/`rclpy`/`ros2` CLI and everything the Isaac Sim ROS 2 bridge needs —
Isaac Sim itself is your visualization.

System ROS 2 is auto-sourced in interactive shells (`~/.bashrc`), but the
`isaacsim.ros2.bridge` extension needs Isaac's **own bundled** ROS 2 Humble
libraries — the system ROS 2 libs have an ABI mismatch with the prebuilt
bridge. `run-isaacsim.sh` therefore points `LD_LIBRARY_PATH` at the bridge's
bundled libs (`isaacsim.ros2.bridge/bin`, `.../humble/lib`,
`omni.usd.libs-*/bin`) **scoped to the Isaac Sim process only** — this is
never registered globally via `ldconfig`, which would break the system `ros2`
CLI (`rclpy` would pick up Isaac's spdlog/fmt and hit an undefined symbol in
`librcl_logging_spdlog.so`).

Verify inside the desktop terminal, after starting the ROS 2 bridge / a
sample in Isaac Sim:

```bash
source /opt/ros/humble/setup.bash
ros2 topic list
```

**Want rviz2 / the full desktop anyway?** Override the build arg — but be
ready to resolve the freetype conflict (e.g. by downgrading/pinning libs),
which can be fragile:

```bash
docker build --build-arg ROS_PACKAGE=ros-humble-desktop -t ... .
```

## Troubleshooting

- **Isaac Sim window doesn't render / black viewport over VNC.** Confirm
  `/dev/dri/renderD128` is present in the container (needs `--gpus all` +
  `NVIDIA_DRIVER_CAPABILITIES=all`) and that `run-isaacsim.sh` reports
  `launching via VirtualGL`. If VirtualGL truly can't help on your setup, the
  NVIDIA-recommended fallback is **WebRTC streaming** — run
  `isaacsim --no-window` and the WebRTC extension, or
  `/isaac-sim/runheadless.webrtc.sh --allow-root` on the official NVIDIA image,
  and connect with the Isaac Sim WebRTC Streaming Client (expose TCP 8211 +
  UDP 47995-48012, 49000-49007). VNC is best for the UI/tooling; WebRTC for
  heavy viewport work.
- **First launch is slow.** Isaac Sim compiles shaders and may download assets
  on first run. Mount a volume at `/root/.cache` and `/root/.nvidia-omniverse`
  to persist this across instance restarts.
- **"Kit cannot run as root".** Already handled — `OMNI_KIT_ALLOW_ROOT=1` is
  set in the image and `run-isaacsim.sh`'s environment.
- **Can't log in to the web UI.** Confirm `VNC_PW` is set; the entrypoint log
  (instance logs) prints whether the KasmVNC password was set successfully
  and whether `vncserver` started. Also double check you're using the
  *external* port Vast.ai mapped to internal 6901, not 6901 itself.
- **Can't reach the instance at all on the port you expected.** Vast.ai
  Docker templates map ports to random external ports — read the actual
  mapped port off the instance card rather than assuming it matches the
  internal port.
- **`ros2` CLI errors with undefined symbols after running Isaac Sim.** That
  means something registered Isaac's bundled ROS 2 libs globally. Don't add
  Isaac's lib paths to `ldconfig` or a global `LD_LIBRARY_PATH` — keep them
  scoped to the Isaac Sim process as `run-isaacsim.sh` does.
</content>
