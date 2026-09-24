#!/usr/bin/env bash
# One-shot setup for Isaac Sim on a Vast.ai VM instance (NOT their docker
# instances -- those share the GPU between tenants and NVENC then refuses to
# open a session, which is what makes the stream unusable there).
#
#   curl -fsSL <raw-url>/vm-bootstrap.sh | bash
#   ./vm-bootstrap.sh --tailscale-key tskey-auth-...   # also joins your tailnet
#
# What a fresh Vast VM gets wrong, and this fixes:
#
#   1. No NVIDIA container toolkit. `docker run --gpus all` fails with
#      'could not select device driver "" with capabilities: [[gpu]]'.
#
#   2. Kernel module and userspace driver versions DISAGREE. Vast's image boots
#      a baked-in module (e.g. 580.95.05) while apt has the packages for
#      another (580.178.04). CUDA tolerates the mismatch -- so nvidia-smi looks
#      healthy and even NVENC opens -- but VULKAN REFUSES. Isaac then falls
#      back to llvmpipe (software) and dies with "vkAllocateMemory failed",
#      "Failed to allocate a buffer for the streamer". A reboot loads the
#      matching DKMS module. This script detects it and stops rather than
#      letting you chase a phantom Isaac bug.
#
#   3. Nothing checks whether the host can actually stream before you invest
#      an hour in it.
set -euo pipefail

IMAGE="${IMAGE:-hrithik108/isaac-sim-vastai:6.1.0}"
PASSWD_VAL="${PASSWD:-isaacsim123}"
TS_KEY=""
AUTO_REBOOT=0
RUN_CONTAINER=1

while [ $# -gt 0 ]; do
    case "$1" in
        --tailscale-key) TS_KEY="${2:?}"; shift 2 ;;
        --image)         IMAGE="${2:?}";  shift 2 ;;
        --password)      PASSWD_VAL="${2:?}"; shift 2 ;;
        --auto-reboot)   AUTO_REBOOT=1; shift ;;
        --no-run)        RUN_CONTAINER=0; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

say() { printf '\n=== %s\n' "$*"; }

# One at a time. Two copies race on apt and each start their own 40GB pull.
exec 9>/var/lock/isaacsim-bootstrap.lock
if ! flock -n 9; then
    echo "another vm-bootstrap.sh is already running on this host; watch that one instead"
    exit 1
fi
[ "$(id -u)" -eq 0 ] || { echo "run as root (Vast VMs give you root)"; exit 1; }

# ---------------------------------------------------------------------------
say "1/6  Checking this is a VM with a GPU"
if [ -f /.dockerenv ]; then
    echo "  This is a container, not a VM. Use the image directly instead."
    exit 1
fi
command -v nvidia-smi >/dev/null || { echo "  no nvidia-smi -- no GPU driver here"; exit 1; }
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | sed 's/^/  GPU: /'

# ---------------------------------------------------------------------------
say "2/6  Checking kernel module vs userspace driver versions"
KVER="$(sed -n 's/.*Kernel Module *\([0-9.]*\).*/\1/p' /proc/driver/nvidia/version 2>/dev/null | head -1)"
[ -n "${KVER}" ] || KVER="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version 2>/dev/null | head -1)"
UVER="$(ls /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.* 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "  kernel module : ${KVER:-unknown}"
echo "  userspace lib : ${UVER:-unknown}"
if [ -n "${KVER}" ] && [ -n "${UVER}" ] && [ "${KVER}" != "${UVER}" ]; then
    echo
    echo "  *** MISMATCH. Vulkan will not work, and Isaac Sim will fail with"
    echo "  *** 'vkAllocateMemory failed' while CUDA and NVENC look fine."
    echo "  *** A reboot loads the matching DKMS module."
    if [ "${AUTO_REBOOT}" -eq 1 ]; then
        echo "  *** rebooting now; re-run this script once it comes back."
        sleep 3; reboot; exit 0
    fi
    echo "  *** Run:  reboot     then re-run this script."
    exit 1
fi
echo "  versions match"

# ---------------------------------------------------------------------------
say "3/6  Vulkan sanity (Isaac renders with Vulkan, not CUDA)"
command -v vulkaninfo >/dev/null || { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq vulkan-tools >/dev/null 2>&1; }
if vulkaninfo --summary 2>/dev/null | grep -q "driverName *= *NVIDIA"; then
    echo "  NVIDIA Vulkan device present"
else
    echo "  *** Vulkan does NOT see the NVIDIA GPU (only llvmpipe/software)."
    echo "  *** Isaac cannot render here. Usually the mismatch above; try a reboot."
    exit 1
fi

# ---------------------------------------------------------------------------
say "4/6  Docker + NVIDIA container toolkit"
command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; }
if ! command -v nvidia-ctk >/dev/null; then
    echo "  installing nvidia-container-toolkit (without it --gpus all fails)"
    # Pin the driver packages first. Installing the toolkit pulls an apt
    # update, and Ubuntu then happily upgrades nvidia-utils / kernel-source to
    # a newer point release while the OLD module is still loaded. Userspace and
    # kernel then disagree and even nvidia-smi dies with
    # "Failed to initialize NVML: Driver/library version mismatch".
    apt-mark hold 'nvidia-*' 'libnvidia-*' >/dev/null 2>&1 || true
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq nvidia-container-toolkit >/dev/null 2>&1
    nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1
    systemctl restart docker; sleep 5
fi
# Validate GPU passthrough with a 4MB image, NOT the Isaac image: using
# ${IMAGE} here silently pulls 40GB (output suppressed) and looks like the
# script has frozen. busybox is enough -- the failure being checked for is
# dockerd refusing the device request ("could not select device driver"),
# which happens before the container's own filesystem matters.
# Re-check: the apt work above can itself introduce the mismatch.
KVER2="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version 2>/dev/null | head -1)"
UVER2="$(ls /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.* 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -n "${KVER2}" ] && [ -n "${UVER2}" ] && [ "${KVER2}" != "${UVER2}" ]; then
    echo "  *** apt upgraded the driver userspace (${UVER2}) past the running"
    echo "  *** kernel module (${KVER2}). nvidia-smi and docker will both fail"
    echo "  *** until the matching module is loaded."
    if [ "${AUTO_REBOOT}" -eq 1 ]; then
        echo "  *** rebooting; re-run this script when it comes back."
        sleep 3; reboot; exit 0
    fi
    echo "  *** Run:  reboot     then re-run this script."
    exit 1
fi

if docker run --rm --gpus all busybox true >/dev/null 2>&1; then
    echo "  docker can reach the GPU"
else
    echo "  *** docker cannot use the GPU even after installing the toolkit."
    echo "  *** Check: docker run --rm --gpus all busybox true"
    exit 1
fi

# ---------------------------------------------------------------------------
say "5/6  Tailscale (carries the stream's UDP media; SSH tunnels cannot)"
if [ -n "${TS_KEY}" ]; then
    command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
    systemctl enable --now tailscaled >/dev/null 2>&1; sleep 3
    tailscale up --authkey="${TS_KEY}" --hostname="isaacsim-$(hostname)" --accept-routes >/dev/null 2>&1 || true
    TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
    echo "  tailscale IP: ${TS_IP:-failed}"
else
    TS_IP=""
    echo "  skipped (pass --tailscale-key to enable)"
fi

# ---------------------------------------------------------------------------
say "6/6  Isaac Sim container"
if [ "${RUN_CONTAINER}" -eq 0 ]; then echo "  --no-run given; stopping here"; exit 0; fi
echo "  pulling ${IMAGE} (~40GB on a cold VM; progress below)"
docker pull "${IMAGE}"
docker rm -f isaacsim >/dev/null 2>&1 || true
docker run -d --name isaacsim --gpus all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -e PASSWD="${PASSWD_VAL}" \
    --shm-size=8g --restart unless-stopped \
    -p 8080:8080 -p 49100:49100 -p 47998:47998/udp \
    "${IMAGE}" >/dev/null
echo "  waiting for the desktop to come up"
for _ in $(seq 1 30); do
    sleep 5
    curl -s -o /dev/null --max-time 3 http://localhost:8080/ && break
done

echo
echo "=============================================================="
docker logs isaacsim 2>&1 | grep -E "\[connect\].*(NVENC|GPU driver)" | sed 's/^\[connect\]  */  /'
echo
echo "  Desktop : http://${TS_IP:-<host-ip>}:8080    (ubuntu / ${PASSWD_VAL})"
echo "  Stream  : run the 'Isaac Sim - Streaming (fast)' desktop icon,"
echo "            wait for '>>> READY', then point the NVIDIA WebRTC"
echo "            client at ${TS_IP:-<host-ip>}  port 49100"
echo
echo "  If the stream looks slow, it is almost always the network, not the"
echo "  GPU: check the round-trip time and the host's upload bandwidth."
echo "  1080p60 wants ~15-30 Mbps up and RTT under ~60ms. Drop the client"
echo "  to 1280x720 on a thin link."
echo "=============================================================="
