# isaacsim-vastai

Isaac Sim 6.1 + ROS 2 Humble in a container, built for rented GPUs (Vast.ai,
RunPod). Two independent paths, split on purpose:

| Path | Transport | Route | Measured |
|---|---|---|---|
| **Isaac Sim viewport** | Kit → NVENC → WebRTC (UDP) | Tailscale | **118 FPS** (RTX 3090 and RTX 4050 Laptop) |
| **Browser desktop** (ROS 2, terminals, VS Code) | KasmVNC / WebSocket (TCP only) | provider's mapped port | fine for tooling |

```
ghcr.io/selkies-project/nvidia-egl-desktop:22.04
        └── KasmVNC: nginx :8080 -> :8081, kasmxproxy mirrors the :20 display
        └── Xvfb + VirtualGL (EGL)
        └── + XFCE desktop (replaces the base image's KDE Plasma)
        └── + Miniforge/conda env `env_isaacsim`
        │        └── Isaac Sim 6.1 installed via pip (isaacsim[all,extscache], any version)
        └── + ROS 2 Humble    → ros-base, sourced for the isaacsim ros2 bridge
        └── + Tailscale       → carries Isaac's UDP stream past port rewriting
        └── + VS Code, Google Chrome, Terminator
```

**One-click deploy:** [Isaac Sim 5.0 template](https://cloud.vast.ai?ref_id=612261&template_id=cf1a15d66acb6141e231ccbb24c5e19c)
, [Isaac Sim 6.1 template](https://cloud.vast.ai?ref_id=612261&template_id=2da1504ccddd5e8c363ba64d363080c2)

## Why it's split this way

Both problems below come from the same root cause: **Vast.ai rewrites container
ports to random external ports**, and WebRTC works by advertising an address
the far end must be able to reach.

**The desktop uses KasmVNC, not WebRTC.** The base image's Selkies desktop
(GStreamer → NVENC → WebRTC) is faster in principle, but it cannot work on
Vast. It advertises whatever address it can see — the docker bridge IP — and no
remote browser can reach that. Tailscale would fix it, except Vast permits only
*"Environment variables, Hostname, and Ports"* as docker options: no
`--cap-add`, no `--device`, so tailscaled can only run
`--tun=userspace-networking`, which never puts an address on a kernel
interface. There is no configuration of Selkies that works there. KasmVNC has
no ICE, no TURN and no UDP — just one proxied TCP port — so it is immune.

**Isaac's own stream is unaffected**, because Kit's livestream doesn't depend
on gathering a routable local candidate the same way. It runs at full speed,
and Tailscale carries its UDP cleanly.

A useful side effect: since KasmVNC never touches NVENC, any encoder session
you see belongs to Isaac.

```bash
nvidia-smi --query-gpu=encoder.stats.sessionCount,encoder.stats.averageFps --format=csv
```

## Quick start (local)

```bash
./build.sh                 # Isaac Sim 6.1.0.0 -> hrithik108/isaac-sim-vastai:6.1.0.0

docker run -d --name isaacsim --gpus all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PASSWD=secret \
    -p 8080:8080 \
    --shm-size=8g \
    -v isaac-cache:/home/ubuntu/.cache \
    -v isaac-ov:/home/ubuntu/.nvidia-omniverse \
    hrithik108/isaac-sim-vastai:6.1.0.0

docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' isaacsim
```

1. Desktop: <http://localhost:8080>, log in `ubuntu` / `$PASSWD`
2. Click **Isaac Sim — Streaming (fast)**, wait for `>>> READY`
3. Connect the streaming client to the **container IP** from the command above
   (e.g. `172.17.0.3`) on port `49100`

Use the container's own IP locally, **not `127.0.0.1`**. On one machine the
client and server otherwise share interfaces, ICE validates one address while
media arrives from another, and every packet is dropped — a connected session
with a black viewport, and `Received non-STUN packet from unknown address` in
the client log. The bridge IP gives them distinct addresses.

The volumes persist the shader/Omniverse caches, so only the first launch is
slow. Mount them; the entrypoint fixes their ownership.

### The streaming client

A separate NVIDIA desktop app — there is **no browser client** in Isaac Sim 5.0/6.x
(port 8011 serves only a session API). Get it from the
[Isaac Sim download page](https://docs.isaacsim.omniverse.nvidia.com/latest/installation/download.html).
Version **2.0.0+** matters: it's the first that lets you enter a port.

```bash
sudo apt-get install -y ./isaacsim-webrtc-streaming-client-2.0.0-linux-x86_64.deb
```

## Vast.ai

```
-p 8080:8080 -p 22:22 -p 49100:49100 -p 8011:8011 -p 47998:47998/udp
-e PASSWD=<strong-password>
-e TAILSCALE_AUTHKEY=tskey-auth-...
```

Expose **8080 as HTTP**, **22 as TCP**. Disk **60 GB+**. Launch mode
**Entrypoint** — in SSH or Jupyter mode Vast replaces the image's ENTRYPOINT
and supervisord never runs (if you must use SSH mode, put `/usr/bin/supervisord`
in the on-start script).

The container prints a banner to the instance log with every address resolved:

```
[connect]  1) BROWSER DESKTOP  (ROS 2, terminals, VS Code)
[connect]     transport: KasmVNC / WebSocket -- works through any port mapping
[connect]     http://<public-ip>:<mapped-8080>/
[connect]  2) ISAAC SIM STREAM ...
[connect]  3) SSH ...
[connect]  NETWORK MODE ...
```

- **Desktop**: the printed URL. Plain TCP, so the mapped port just works.
- **Isaac stream**: click the desktop icon, then point the client at the
  **Tailscale IP** on port `49100`. Try the mapped public port first — if the
  viewport is grey, the UDP media port is being rewritten, and the tailnet is
  the fix.

## Tuning

| Env var | Default | Notes |
|---|---|---|
| `PASSWD` | `mypasswd` | **change this** — web login and account password |
| `TAILSCALE_AUTHKEY` | unset | needed for the Isaac stream on Vast |
| `KASMVNC_ENABLE` | `true` | `false` switches to Selkies/NVENC WebRTC — better quality, but only where ports are *not* rewritten |
| `DISPLAY_SIZEW` / `H` | `1920` / `1080` | |
| `DISPLAY_REFRESH` | `60` | KasmVNC max frame rate |
| `SELKIES_ENABLE_RESIZE` | `false` | `true` makes the desktop follow the browser window |
| `KASMVNC_THREADS` | `0` | 0 = auto |

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the image |
| `build.sh` | Version-aware build wrapper (`-v`, `--list`, `--push`, `--clean`) |
| `entrypoint.sh` | supervisord-launched: Xvfb, XFCE, sshd, Tailscale, connect banner |
| `run-isaacsim-stream.sh` | **Native WebRTC stream** — the fast path |
| `run-isaacsim.sh` | Isaac Sim into the browser desktop via VirtualGL/EGL |
| `selkies-turn-wrapper.sh` | TURN address fix, only used when `KASMVNC_ENABLE=false` |
| `desktop/*.desktop` | Desktop launcher icons |

## Troubleshooting

```bash
docker exec isaacsim tail -50 /tmp/isaacsim-stream.log   # Isaac stream (stable path)
docker exec isaacsim tail -50 /tmp/entrypoint.log        # desktop session + banner
docker exec isaacsim supervisorctl status
nvidia-smi --query-gpu=encoder.stats.sessionCount,encoder.stats.averageFps --format=csv
```

**Isaac segfaults during extension startup.** Driver. The R590 branch (595.x)
is incompatible with the Omniverse RTX renderer; Isaac Sim 5.0+ wants R580
(580.65.06+). Containers use the host's driver, so this bites inside the
container too.

**Client connects, viewport black, `encoder averageFps = 0`.** No frames are
being produced. Check `--/app/livestream/allowDynamicResize=true` is on the
command line — without it Kit rejects the client's resize and never gets a
valid viewport size.

**Client connects, viewport black, `Received non-STUN packet from unknown
address`.** Media is arriving but ICE negotiated a different address. Locally,
connect to the container's bridge IP; on Vast, use the Tailscale IP.

**Browser shows the old Selkies page.** It's cached — hard-reload or use a
private window. The KasmVNC page has `<title>KasmVNC</title>`.

**Streaming icon shows "ALREADY streaming".** Something else already holds
49100; the window attaches to that instance's log instead of starting a second
one.

## Running on a Vast.ai VM (rather than their docker instances)

Paste the ssh line the provider gives you into `./vm-setup.sh`, from your own
machine, and it does the rest:

```bash
./vm-setup.sh 'ssh -p 15217 root@76.27.73.50' --tailscale-key tskey-auth-...
```

It pulls host and port out of that line (extra flags like `-L 8080:...` are
ignored), copies `vm-bootstrap.sh` over, runs it, and -- if the VM needs the
reboot described below -- waits for it to come back and resumes. Typing the
host by hand is the main way this goes wrong: a one-digit typo just hangs on a
TCP connect and looks like the script is stuck.

To run it on the VM directly instead:

```bash
scp -P <port> vm-bootstrap.sh root@<host>:/root/
ssh -p <port> root@<host> '/root/vm-bootstrap.sh --tailscale-key tskey-auth-...'
```

It installs the NVIDIA container toolkit, checks the driver, brings up
Tailscale, pulls this image and starts it, then prints the connect details and
the NVENC verdict.

**Why a VM and not a docker instance.** Vast's docker hosts share one GPU
between tenants. GeForce cards cap concurrent NVENC sessions, and you cannot
see other tenants' sessions from inside your container -- so the stream fails
with `NVST_DISCONN_SERVER_VIDEO_ENCODER_INIT_CUDA_ENCODE_OPEN_FAILED` while
CUDA works perfectly. Measured on five separate hosts. The same GeForce class
in a VM, with the GPU to itself, opens an encode session immediately. The
browser desktop is unaffected either way; it encodes on the CPU.

**Two things a fresh Vast VM gets wrong**, both handled by the script:

- No NVIDIA container toolkit, so `docker run --gpus all` fails with
  `could not select device driver "" with capabilities: [[gpu]]`.
- The booted kernel module and the apt userspace driver are different versions
  (seen: module 580.95.05, libraries 580.178.04). CUDA tolerates it -- so
  `nvidia-smi` looks fine and NVENC even opens -- but **Vulkan refuses**, and
  Isaac falls back to llvmpipe and dies with `vkAllocateMemory failed` /
  `Failed to allocate a buffer for the streamer`. Rebooting loads the matching
  DKMS module. The script stops and tells you, rather than letting that surface
  as a phantom Isaac bug.

**Pick the host on network, not just GPU.** A working host can still stream
badly. Measured on a 4060 Ti VM in England from India: NVENC encoding at 59
FPS, GPU at 40% -- and it still felt slow, because the link was **160 ms RTT
and 7.4 Mbps** (a home broadband line). 1080p60 wants roughly 15-30 Mbps up and
RTT under ~60 ms. Check the listing's *Net up* and location before renting, and
drop the client to 1280x720 on a thin link.

## Isaac Sim version / upgrading

Isaac Sim is pip-installed into an isolated conda env, so the version is just a
build argument. `build.sh` is the supported way in — it maps the Isaac Sim
version to the Python ABI and PyTorch wheel that release actually supports, and
refuses versions NVIDIA does not publish before you spend an hour building:

```bash
./build.sh --list                    # every version on pypi.nvidia.com
./build.sh                           # the default (6.1.0.0)
./build.sh -v 5.1.0.0                # any other release
./build.sh -v 6.1.0.0 --latest --push
./build.sh -v 6.1.0.0 --no-torch     # smaller image, GUI-only
./build.sh --clean -v 6.1.0.0        # prune build cache + dangling images first
```

| Isaac Sim | Python | Default torch |
|---|---|---|
| 6.x | 3.12 | `torch==2.11.0` (cu128) |
| 5.x | 3.11 | `torch==2.7.0` |
| 4.x | 3.10 | `torch==2.5.1` / `2.4.0` |

The Python column is not a preference. Isaac Sim wheels are built for exactly
one CPython ABI (`Requires-Python: ==3.12.*` for 6.x), so a 6.x build on Python
3.11 dies at pip resolve time with a misleading "no matching distribution".

Building by hand works too, as long as you keep the three knobs in sync:

```bash
docker build \
    --build-arg ISAACSIM_PIP_VERSION=5.1.0.0 \
    --build-arg PYTHON_VERSION=3.11 \
    --build-arg TORCH_SPEC=torch==2.7.0 \
    -t isaacsim-selkies:5.1 .
```

To swap versions inside an already-running container (same ABI only):

```bash
conda activate env_isaacsim
pip install "isaacsim[all,extscache]==<version>" --extra-index-url https://pypi.nvidia.com
```

## Disk space

Each image is ~30 GB and the build cache grows fast. To reclaim safely:

```bash
docker builder prune -af    # build cache
docker image prune -f       # dangling layers only
```

Avoid `docker image prune -a` — it deletes every image not currently attached
to a container, including unrelated ones you still want.
