# Isaac Sim 6.1 (pip/conda) + ROS 2 Humble, streamed over WebRTC with NVENC.
#
# WHY THIS BASE IMAGE
# -------------------
# The previous revision of this file rendered with VirtualGL into an Xvnc
# framebuffer and let KasmVNC CPU-encode JPEG/WebP from X11 damage rects. That
# path costs two full-frame CPU copies plus a software encode every frame and
# caps out around 15-20 FPS at 1080p no matter how big the GPU is -- the GPU is
# idle during the expensive part.
#
# selkies-project/nvidia-egl-desktop replaces the encode+transport stage with
# GStreamer -> NVENC (nvh264enc) -> WebRTC, which is the same shape as AWS DCV.
# It also brings, already solved and tested:
#   - Xvfb with the extension set Selkies' XTEST input injection needs
#   - VirtualGL preconfigured for EGL (VGL_DISPLAY=egl), no X GPU driver needed
#   - a bundled coturn TURN server with external-IP autodetection (WebRTC in a
#     container is unusable without one)
#   - nginx on a SINGLE tcp port (8080) fronting signaling + web UI with basic
#     auth, which is exactly what Vast.ai / RunPod HTTP port mapping wants
#   - runtime autoinstall of the matching NVIDIA userspace driver
#
# We layer XFCE (see the DE note below), ROS 2 Humble, and Isaac Sim on top and
# swap only the desktop-environment line of the entrypoint.
#
#   Build: ./build.sh -v 6.1.0.0        (or: docker build -t <you>/isaacsim-selkies:6.1 .)
#   Run:   docker run --gpus all -e NVIDIA_DRIVER_CAPABILITIES=all \
#              -p 8080:8080 -e PASSWD=secret <img>
#   Web:   http://<host>:8080   (login: ubuntu / $PASSWD)
FROM ghcr.io/selkies-project/nvidia-egl-desktop:22.04

# ---- Isaac Sim version knobs ------------------------------------------------
# Prefer ./build.sh -- it derives PYTHON_VERSION and TORCH_SPEC from the Isaac
# Sim version for you, and refuses versions NVIDIA does not publish:
#   ./build.sh -v 6.1.0.0            # or --list to see what is available
#
# Building by hand means keeping these three in sync. Isaac Sim wheels target
# exactly one CPython ABI, so the Python version is not a free choice:
#   6.x -> python 3.12    5.x -> python 3.11    4.x -> python 3.10
ARG ISAACSIM_PIP_VERSION=6.1.0.0
ARG PYTHON_VERSION=3.12
# TORCH_SPEC empty = don't install torch (the GUI alone doesn't need it; the
# RL / replicator extras do). Installed from TORCH_CUDA_INDEX before Isaac Sim.
ARG TORCH_SPEC=torch==2.11.0
ARG TORCH_CUDA_INDEX=https://download.pytorch.org/whl/cu128
ARG ROS_PACKAGE=ros-humble-ros-base
ARG DEBIAN_FRONTEND=noninteractive

# The base image builds as USER 1000 with `sudo` aliased to fakeroot; go to real
# root for apt work. The container still RUNS as uid 1000 (set again at the end).
USER 0
SHELL ["/bin/bash", "-c"]

# ---------------------------------------------------------------------------
# 1. XFCE desktop (replaces the base image's KDE Plasma session)
#
# XFCE, not KDE: side-by-side testing showed KDE's much larger footprint (many
# more background daemons -- baloo_file indexing, kglobalaccel, polkit agent,
# xembedsniproxy, kioslave5 helpers) meaningfully reduced Isaac Sim's viewport
# FPS at identical resolution/hardware -- roughly 2x lower FPS and 6x fewer
# Omniverse Kit worker threads running concurrently. The base image ships KDE;
# we install XFCE alongside and point the entrypoint at startxfce4 instead.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install --no-install-recommends -y \
        xfce4 xfce4-terminal terminator dbus-x11 \
        openssh-server \
        net-tools iputils-ping iproute2 \
        nano vim git less wget \
    && (apt-get purge -y xfce4-power-manager light-locker xfce4-screensaver 2>/dev/null || true) \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. Isaac Sim runtime libraries (Vulkan / X client libs Kit dlopen()s)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install --no-install-recommends -y \
        libvulkan1 vulkan-tools libgl1 libglu1-mesa libegl1 libglib2.0-0 \
        libsm6 libxext6 libxrender1 libxi6 libxrandr2 libxcursor1 \
        libxinerama1 libxkbcommon0 libxcomposite1 libxdamage1 libxtst6 \
        libnss3 libasound2 libxcb-xinerama0 libxcb-cursor0 libgomp1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# NVIDIA Vulkan + EGL ICDs. The container runtime normally drops these in via
# NVIDIA_DRIVER_CAPABILITIES=all; belt-and-suspenders for hosts where it doesn't.
RUN mkdir -p /etc/vulkan/icd.d /usr/share/glvnd/egl_vendor.d && \
    printf '{\n  "file_format_version": "1.0.0",\n  "ICD": {\n    "library_path": "libGLX_nvidia.so.0",\n    "api_version": "1.3"\n  }\n}\n' \
        > /etc/vulkan/icd.d/nvidia_icd.json && \
    printf '{\n  "file_format_version": "1.0.0",\n  "ICD": {\n    "library_path": "libEGL_nvidia.so.0"\n  }\n}\n' \
        > /usr/share/glvnd/egl_vendor.d/10_nvidia.json

# ---------------------------------------------------------------------------
# 3. ROS 2 Humble (system install; sourced for the Isaac Sim ros2 bridge)
# ---------------------------------------------------------------------------
RUN add-apt-repository universe -y \
    && apt-get update \
    && ROS_APT_SOURCE_VERSION=$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | grep -F '"tag_name"' | awk -F'"' '{print $4}') \
    && curl -L -o /tmp/ros2-apt-source.deb \
        "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.jammy_all.deb" \
    && apt-get install -y /tmp/ros2-apt-source.deb \
    && apt-get update \
    && apt-get install --no-install-recommends -y ${ROS_PACKAGE} ros-dev-tools \
    && rm -f /tmp/ros2-apt-source.deb \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 4. VS Code + Chrome (dev convenience inside the streamed desktop)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --batch --yes --dearmor -o /usr/share/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list \
    && curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --batch --yes --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install --no-install-recommends -y code google-chrome-stable \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    # Chrome's and Electron's sandboxes need user namespaces the container
    # doesn't get; shadow both binaries with wrappers earlier in PATH so the
    # desktop icons just work.
    && printf '#!/bin/bash\nexec /usr/bin/google-chrome-stable --no-sandbox --user-data-dir="${HOME}/.config/google-chrome" "$@"\n' > /usr/local/bin/chrome \
    && printf '#!/bin/bash\nexec /usr/bin/code --no-sandbox "$@"\n' > /usr/local/bin/code \
    && chmod +x /usr/local/bin/chrome /usr/local/bin/code

# ---------------------------------------------------------------------------
# 5. cloudflared + Tailscale
#
# cloudflared: gives every instance a public HTTPS URL without hunting for the
# provider's randomly-mapped external port.
#
# Tailscale: the important one. WebRTC wants UDP, and neither Vast.ai nor
# RunPod give you a predictable public UDP port. On a tailnet the container is
# reachable directly, so media flows peer-to-peer over WireGuard and the TURN
# relay fallback (and Isaac's hardcoded livestream ports, see
# run-isaacsim-stream.sh) stop being a problem. Opt in with TAILSCALE_AUTHKEY.
# ---------------------------------------------------------------------------
RUN curl -L -o /usr/local/bin/cloudflared \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    && chmod +x /usr/local/bin/cloudflared \
    && curl -fsSL https://tailscale.com/install.sh | sh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 6. Miniforge + Isaac Sim (pip) in an isolated conda env  ->  version freedom
# Miniforge defaults to conda-forge (free, no Anaconda ToS/commercial license).
#
# Installed as uid 1000, not root: the base image already chowns / to ubuntu, so
# /opt is writable and we avoid a duplicated ~20GB chown layer.
# ---------------------------------------------------------------------------
USER 1000
RUN wget -qO /tmp/miniforge.sh https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh \
    && bash /tmp/miniforge.sh -b -p /opt/conda \
    && rm /tmp/miniforge.sh \
    && /opt/conda/bin/conda create -y -n env_isaacsim python=${PYTHON_VERSION} \
    && /opt/conda/bin/conda clean -afy

# PyTorch (CUDA) first if requested, then Isaac Sim.
RUN source /opt/conda/etc/profile.d/conda.sh && conda activate env_isaacsim \
    && if [ -n "${TORCH_SPEC}" ]; then pip install --no-cache-dir "${TORCH_SPEC}" --index-url "${TORCH_CUDA_INDEX}"; fi \
    && pip install --no-cache-dir "isaacsim[all,extscache]==${ISAACSIM_PIP_VERSION}" --extra-index-url https://pypi.nvidia.com

# NOTE: the isaacsim.ros2.bridge deps are made discoverable by a SCOPED
# LD_LIBRARY_PATH inside run-isaacsim.sh (Isaac process only). We deliberately
# do NOT register them via global ldconfig -- that pollutes the loader cache and
# breaks the system `ros2` CLI (rclpy picks up Isaac's spdlog/fmt -> undefined
# symbol in librcl_logging_spdlog.so).

# conda AVAILABLE but not auto-activated (clean default shell).
RUN /opt/conda/bin/conda config --set auto_activate_base false \
    && echo 'source /opt/conda/etc/profile.d/conda.sh' >> /home/ubuntu/.bashrc \
    && echo '# Isaac Sim lives in the env_isaacsim conda env: conda activate env_isaacsim' >> /home/ubuntu/.bashrc \
    && echo 'source /opt/ros/humble/setup.bash' >> /home/ubuntu/.bashrc

# ---------------------------------------------------------------------------
# 7. Our entrypoint (XFCE instead of KDE + sshd/tailscale/cloudflared) and
#    launchers. supervisord.conf from the base image is kept as-is; it calls
#    /etc/entrypoint.sh, which is the file we override here.
# ---------------------------------------------------------------------------
USER 0
COPY --chown=1000:1000 entrypoint.sh /etc/entrypoint.sh
COPY --chown=1000:1000 run-isaacsim.sh /usr/local/bin/run-isaacsim.sh
COPY --chown=1000:1000 run-isaacsim-stream.sh /usr/local/bin/run-isaacsim-stream.sh
COPY --chown=1000:1000 desktop/ /home/ubuntu/Desktop/

# Interpose on the base image's Selkies entrypoint so TURN gets a reachable
# address before Selkies starts. supervisord launches Selkies independently of
# /etc/entrypoint.sh, so it cannot inherit exports from there -- wrapping the
# script is the only place the fix can live. See selkies-turn-wrapper.sh.
COPY --chown=1000:1000 selkies-turn-wrapper.sh /etc/selkies-turn-wrapper.sh
RUN mv /etc/selkies-gstreamer-entrypoint.sh /etc/selkies-gstreamer-entrypoint.orig.sh \
    && cp /etc/selkies-turn-wrapper.sh /etc/selkies-gstreamer-entrypoint.sh \
    && chown 1000:1000 /etc/selkies-gstreamer-entrypoint.sh /etc/selkies-gstreamer-entrypoint.orig.sh \
    && chmod 755 /etc/selkies-gstreamer-entrypoint.sh /etc/selkies-gstreamer-entrypoint.orig.sh

RUN chmod 755 /etc/entrypoint.sh /usr/local/bin/run-isaacsim.sh \
              /usr/local/bin/run-isaacsim-stream.sh /home/ubuntu/Desktop/*.desktop

# Point the session at XFCE. The base image's KDE-specific vars are overridden
# rather than removed so nothing in it trips over an empty value.
ENV DESKTOP_SESSION=xfce \
    XDG_SESSION_DESKTOP=xfce \
    XDG_CURRENT_DESKTOP=XFCE \
    XDG_SESSION_TYPE=x11 \
    KDE_FULL_SESSION= \
    KDE_SESSION_VERSION=

# Browser desktop transport.
#
# KasmVNC (WebSocket over the single TCP port 8080), NOT Selkies' WebRTC, is
# the default -- because WebRTC cannot work on Vast.ai. It must advertise an
# address the remote browser can reach, and on Vast:
#   - container ports are rewritten to random external ports, so any address
#     it advertises is wrong, and
#   - Tailscale can only run --tun=userspace-networking (Vast permits only
#     "Environment variables, Hostname, and Ports" as docker options -- no
#     --cap-add/--device), so there is never a routable interface to advertise.
# The result is a desktop that connects, offers only 172.17.x candidates, and
# dies as "Connection failed".
#
# KasmVNC has no ICE, no TURN and no UDP: nginx proxies 8080 -> 8081 and that
# is the whole path. kasmxproxy mirrors the real :20 display, so Isaac, XFCE
# and VirtualGL are untouched.
#
# Trade-off: VNC-quality desktop rather than 60 FPS NVENC. That is the right
# call here because Isaac Sim itself streams through its OWN client at full
# speed (~118 FPS measured on a 3090); this desktop only carries terminals,
# VS Code and ROS 2.
#
# Set KASMVNC_ENABLE=false to switch back to Selkies/NVENC WebRTC -- worth it
# on a host where ports are NOT rewritten (local docker, or anywhere the
# container has a genuinely routable address).
ENV KASMVNC_ENABLE=true \
    SELKIES_ENCODER=nvh264enc \
    SELKIES_FRAMERATE=60 \
    SELKIES_VIDEO_BITRATE=16000 \
    SELKIES_ENABLE_RESIZE=false \
    KASMVNC_THREADS=0 \
    DISPLAY_SIZEW=1920 \
    DISPLAY_SIZEH=1080 \
    DISPLAY_REFRESH=60

# Omniverse EULA + GPU capabilities (graphics needed for Vulkan/RTX rendering)
ENV ACCEPT_EULA=Y \
    PRIVACY_CONSENT=Y \
    OMNI_KIT_ACCEPT_EULA=YES \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all

USER 1000
ENV SHELL=/bin/bash \
    USER=ubuntu \
    HOME=/home/ubuntu

#  8080/tcp  Selkies web UI + signaling (nginx, basic auth)
#  3478      TURN relay -- only needed if the browser can't reach the container
#            directly; irrelevant when you connect over Tailscale
#    22/tcp  sshd
EXPOSE 8080 3478/tcp 3478/udp 22
ENTRYPOINT ["/usr/bin/supervisord"]
