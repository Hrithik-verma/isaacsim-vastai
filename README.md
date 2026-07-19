# isaacsim-vastai

A Vast.ai-ready Docker template that runs the **NVIDIA Isaac Sim GUI in a web
browser** via **KasmVNC**, on a **KDE Plasma** desktop, with **ROS 2 Humble**
wired into Isaac Sim's ROS 2 bridge.

**Image:** `hrithik108/isaac-sim-vastai:5.0`

```
ubuntu:22.04
        └── + Miniforge/conda env `env_isaacsim`
        │        └── Isaac Sim installed via pip (isaacsim[all,extscache])
        └── + VirtualGL       → GPU-accelerated rendering into the VNC framebuffer
        └── + KDE Plasma desktop (kwin-x11, Terminator as default terminal)
        └── + KasmVNC 1.4.0   → browser access on port 6901
        └── + ROS 2 Humble    → ros-base, sourced for the isaacsim ros2 bridge
        └── + VS Code, Google Chrome
```

Isaac Sim is installed **via pip into an isolated conda env**, not baked into
the official `nvcr.io/nvidia/isaac-sim` base image, so you can swap versions
with a single `pip install` — no rebuild needed (see
[Isaac Sim version / upgrading](#isaac-sim-version--upgrading)).

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the image |
| `Dockerfile.test` | Fast smoke test of the desktop/entrypoint layer only (no GPU/Isaac Sim/ROS) |
| `entrypoint.sh` | PID 1 — SSH, KasmVNC password, root password, starts KasmVNC + KDE Plasma |
| `run-isaacsim.sh` | Activates `env_isaacsim`, sets ROS 2 bridge env vars, launches Isaac Sim via VirtualGL |
| `vnc/xstartup` | Starts the KDE Plasma (`startplasma-x11`) session inside VNC |
| `vnc/kasmvnc.yaml` | KasmVNC config |
| `vnc/kscreenlockerrc` | Disables KDE's idle screen locker (no way to unlock a session in this VNC-only setup) |
| `vnc/kwalletrc` | Disables KWallet (stops VS Code/Chrome prompting to create a wallet) |
| `vnc/IsaacSim.desktop`, `GoogleChrome.desktop`, `VSCode.desktop`, `Terminator.desktop` | Desktop launcher icons |

## Requirements

- An **RTX-capable NVIDIA GPU** (RTX A-series, L4/L40, A6000, 3090/4090, etc.)
  — Isaac Sim's RTX renderer needs ray-tracing hardware; T4/V100/non-RTX A100
  won't render the viewport.
- NVIDIA Container Toolkit (any Vast.ai GPU offer provides this).

## Run locally

```bash
docker run -d --gpus all \
  --name local_isaacsim_vastai \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -p 6901:6901 \
  -e VNC_PW='choose-a-password' \
  hrithik108/isaac-sim-vastai:5.0
```

Open `https://localhost:6901/` (click through the self-signed cert warning),
log in with `kasm_user` / your `VNC_PW`, then double-click **Isaac Sim** on
the desktop (or run `run-isaacsim.sh` in Terminator). First launch compiles
shaders and can take a minute or two — watch for `Isaac Sim Full Version:
...` and `app ready`.

For a fast smoke test of just the desktop/entrypoint layer (no GPU, no Isaac
Sim, no ROS):

```bash
docker build -f Dockerfile.test -t isaac-kasm-test .
docker run --rm -p 6901:6901 -e VNC_PW=password isaac-kasm-test
```

## Build it yourself

```bash
docker build -t hrithik108/isaac-sim-vastai:5.0 .
docker push hrithik108/isaac-sim-vastai:5.0
```

Default build args target Isaac Sim 5.0.0. To ship Isaac Sim 6.0 instead:

```bash
docker build \
  --build-arg ISAACSIM_PIP_VERSION=6.0.0.1 \
  --build-arg PYTHON_VERSION=3.12 \
  --build-arg TORCH_SPEC=torch==2.11.0 \
  -t hrithik108/isaac-sim-vastai:6.0 .
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

Since Isaac Sim lives in a pip-installed conda env, you can upgrade it
**without rebuilding** by execing into a running container:

```bash
conda activate env_isaacsim
pip install "isaacsim[all,extscache]==<new-version>" --extra-index-url https://pypi.nvidia.com
```

For a durable upgrade, rebuild with `--build-arg
ISAACSIM_PIP_VERSION=<new-version>` (and matching `PYTHON_VERSION`/
`TORCH_SPEC`) instead.

## Deploy as a Vast.ai template

This is a plain **Docker Container template** — Vast.ai maps ports to random
external ports and doesn't provide an Instance Portal/Cloudflare tunnel for
custom images (see
[How this differs from Vast.ai's official desktop template](#how-this-differs-from-vastais-official-desktop-template)).

1. **Templates → New Template.**
2. **Image path:** `hrithik108/isaac-sim-vastai:5.0`.
3. **Launch mode: `docker ENTRYPOINT`** — the image ships its own
   `/usr/local/bin/entrypoint.sh` as `ENTRYPOINT`.
4. **Docker Options:**
   ```
   -p 6901:6901 -p 22:22
   ```
5. **Environment variables:** set `VNC_PW` (required — no secure default).
6. **Recommended disk space:** 30+ GB.
7. Rent an **RTX GPU** offer, then find the **external port mapped to
   internal 6901** on the instance card (it will *not* just be `6901`) and
   open `https://<instance-ip>:<mapped-port>/`.

## How this differs from Vast.ai's official desktop template

Vast.ai's own [Ubuntu Desktop (VM)](https://cloud.vast.ai/template/readme/b522f5577b2c30167c826b54bedffc71)
template runs on [`vastai/kvm`](https://hub.docker.com/r/vastai/kvm), which
boots a full **nested KVM virtual machine** inside the container (a multi-GB
guest disk image plus a proprietary `kaalia-vm-supervisor` binary as
`ENTRYPOINT`). Its Instance Portal, Selkies WebRTC, Guacamole,
`OPEN_BUTTON_TOKEN` auth, and built-in Cloudflare tunnel all run **inside
that guest VM** — Vast.ai's own proprietary tooling, not something any
Docker template gets automatically.

This repo is a plain Docker container (KasmVNC directly on the host kernel,
no nested VM), so none of that applies here. You get the same thing as
`isaacsim-runpod`: a lightweight KasmVNC desktop with Isaac Sim and ROS 2 —
just read the actual mapped port off the instance card instead of assuming
`6901`.

## SSH access

`sshd` runs on port 22 (mapped to a random external port by Vast.ai). Vast.ai
injects your account's SSH public key via `$SSH_PUBLIC_KEY`, which the
entrypoint writes to `/root/.ssh/authorized_keys`.

```bash
ssh -p <mapped_port> root@<instance_ip>
```

ROS 2 is auto-sourced in the shell, and `conda activate env_isaacsim` puts
you in the Isaac Sim Python env.

## Environment variables

| Var | Default | Meaning |
|-----|---------|---------|
| `VNC_PW` | `isaacsim` | KasmVNC password — **set this**. Also set as `root`'s Linux password (needed if KDE's screen locker ever engages despite being disabled by default). |
| `VNC_USER` | `kasm_user` | KasmVNC username |
| `RESOLUTION` | `1920x1080` | Desktop resolution |
| `VNC_PORT` | `6901` | KasmVNC's internal port (Vast.ai maps this to a random external port) |
| `SSH_PUBLIC_KEY` | *(set by Vast.ai)* | Your account's SSH public key, injected automatically |

## Rendering: VirtualGL

Isaac Sim's Vulkan/RTX renderer needs a real GPU render node, but KasmVNC's X
server is software-only. `run-isaacsim.sh` launches Isaac Sim through
**VirtualGL** (`vglrun -d egl0 isaacsim`), redirecting GPU rendering to
`/dev/dri/renderD128` and blitting the result into the VNC framebuffer.
Without it the Kit window renders blank. If no GPU render node is available,
the script falls back to launching Isaac Sim directly (viewport may be
blank).

## ROS 2 Humble

The image installs **`ros-humble-ros-base`** (no rviz/VTK): `ros-humble-desktop`
pulls rviz + VTK, whose `libfreetype6-dev` conflicts with the `libfreetype6`
shipped in Isaac Sim's pip wheels. ros-base gives you `rclcpp`/`rclpy`/`ros2`
CLI and everything the Isaac Sim ROS 2 bridge needs.

System ROS 2 is auto-sourced in interactive shells, but `isaacsim.ros2.bridge`
needs Isaac's **own bundled** ROS 2 Humble libs (system ROS 2 has an ABI
mismatch with the prebuilt bridge). `run-isaacsim.sh` points `LD_LIBRARY_PATH`
at the bridge's bundled libs **scoped to the Isaac Sim process only** — never
registered globally via `ldconfig`, which would break the system `ros2` CLI
(`rclpy` would pick up Isaac's spdlog/fmt and hit an undefined symbol in
`librcl_logging_spdlog.so`).

Verify after starting the ROS 2 bridge in Isaac Sim:

```bash
source /opt/ros/humble/setup.bash
ros2 topic list
```

Want rviz2 / the full desktop anyway? `docker build --build-arg
ROS_PACKAGE=ros-humble-desktop -t ... .` — be ready to resolve the freetype
conflict yourself.

## Troubleshooting

- **Isaac Sim window doesn't render / black viewport.** Confirm
  `/dev/dri/renderD128` is present (`--gpus all` + `NVIDIA_DRIVER_CAPABILITIES=all`)
  and `run-isaacsim.sh` reports `launching via VirtualGL`. Fallback: WebRTC
  streaming (`/isaac-sim/runheadless.webrtc.sh --allow-root`, expose TCP 8211
  + UDP 47995-48012, 49000-49007).
- **First launch is slow.** Isaac Sim compiles shaders / downloads assets.
  Mount `/root/.cache` and `/root/.nvidia-omniverse` to persist across
  restarts.
- **Can't log in to the web UI.** Confirm `VNC_PW` is set; check the
  entrypoint log for KasmVNC password/startup status. Confirm you're using
  the *external* port Vast.ai mapped, not `6901` itself.
- **`ros2` CLI errors with undefined symbols after running Isaac Sim.**
  Something registered Isaac's bundled ROS 2 libs globally — don't add them
  to `ldconfig` or a global `LD_LIBRARY_PATH`; keep them scoped as
  `run-isaacsim.sh` does.
</content>
