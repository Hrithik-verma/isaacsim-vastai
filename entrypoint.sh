#!/bin/bash

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Derived from selkies-project/docker-nvidia-egl-desktop's entrypoint.sh.
# Changes from upstream:
#   - starts XFCE instead of KDE Plasma (Plasma's daemon footprint costs Isaac
#     Sim roughly half its viewport FPS)
#   - starts sshd, optional Tailscale, and a cloudflared fallback tunnel
#   - prints the exact URL to open, resolving Vast.ai's mapped external port
#
# Run by supervisord (see /etc/supervisord.conf in the base image), which also
# runs the Selkies GStreamer/WebRTC pipeline, nginx, dbus, and pipewire.

set -e

trap "echo TRAPed signal" HUP INT QUIT TERM

# Wait for XDG_RUNTIME_DIR
until [ -d "${XDG_RUNTIME_DIR}" ]; do sleep 0.5; done
# Make user directory owned by the default user
chown -f "$(id -nu):$(id -ng)" ~ || sudo-root chown -f "$(id -nu):$(id -ng)" ~ || chown -R -f -h --no-preserve-root "$(id -nu):$(id -ng)" ~ || sudo-root chown -R -f -h --no-preserve-root "$(id -nu):$(id -ng)" ~ || echo 'Failed to change user directory permissions, there may be permission issues'
# Change operating system password to environment variable
(echo "${PASSWD}"; echo "${PASSWD}";) | sudo passwd "$(id -nu)" || (echo "mypasswd"; echo "${PASSWD}"; echo "${PASSWD}";) | passwd "$(id -nu)" || echo 'Password change failed, using default password'
# Remove directories to make sure the desktop environment starts
rm -rf /tmp/.X* ~/.cache || echo 'Failed to clean X11 paths'

# Isaac/Omniverse state dirs. These are the natural mount points for a
# persistent cache volume, and Docker creates a mountpoint for a path that
# doesn't exist in the image as root:root -- which this container, running as
# uid 1000, then can't write ("failed to create the directory
# '~/.nvidia-omniverse/logs' {errno = 13}"). Create and claim them up front so
# a `-v cache:/home/ubuntu/.nvidia-omniverse` just works.
for d in ~/.nvidia-omniverse ~/.cache ~/.local/share/ov; do
    mkdir -p "${d}" 2>/dev/null || sudo-root mkdir -p "${d}" 2>/dev/null || true
    [ -w "${d}" ] || sudo-root chown -R "$(id -u):$(id -g)" "${d}" 2>/dev/null || true
done
# Change time zone from environment variable
ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime && echo "${TZ}" | tee /etc/timezone > /dev/null || echo 'Failed to set timezone'

# Configure joystick interposer
export SELKIES_INTERPOSER='/usr/$LIB/selkies_joystick_interposer.so'
export LD_PRELOAD="${SELKIES_INTERPOSER}${LD_PRELOAD:+:${LD_PRELOAD}}"
export SDL_JOYSTICK_DEVICE=/dev/input/js0
mkdir -pm1777 /dev/input || sudo-root mkdir -pm1777 /dev/input || echo 'Failed to create joystick interposer directory'
touch /dev/input/js0 /dev/input/js1 /dev/input/js2 /dev/input/js3 || sudo-root touch /dev/input/js0 /dev/input/js1 /dev/input/js2 /dev/input/js3 || echo 'Failed to create joystick interposer devices'
chmod 777 /dev/input/js* || sudo-root chmod 777 /dev/input/js* || echo 'Failed to change permission for joystick interposer devices'

# Set default display
export DISPLAY="${DISPLAY:-:20}"
# PipeWire-Pulse server socket path
export PIPEWIRE_LATENCY="128/48000"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-${XDG_RUNTIME_DIR:-/tmp}/pulse}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${PULSE_RUNTIME_PATH:-${XDG_RUNTIME_DIR:-/tmp}/pulse}/native}"

if [ -z "$(ldconfig -N -v $(sed 's/:/ /g' <<< $LD_LIBRARY_PATH) 2>/dev/null | grep 'libEGL_nvidia.so.0')" ] || [ -z "$(ldconfig -N -v $(sed 's/:/ /g' <<< $LD_LIBRARY_PATH) 2>/dev/null | grep 'libGLX_nvidia.so.0')" ]; then
  # Install NVIDIA userspace driver components including X graphic libraries
  export NVIDIA_DRIVER_ARCH="$(dpkg --print-architecture | sed -e 's/arm64/aarch64/' -e 's/armhf/32bit-ARM/' -e 's/i.*86/x86/' -e 's/amd64/x86_64/' -e 's/unknown/x86_64/')"
  if [ -z "${NVIDIA_DRIVER_VERSION}" ]; then
    # Driver version is provided by the kernel through the container toolkit, prioritize kernel driver version if available
    if [ -f "/proc/driver/nvidia/version" ]; then
      export NVIDIA_DRIVER_VERSION="$(head -n1 </proc/driver/nvidia/version | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9\.]+/) {print $i; exit}}')"
    elif command -v nvidia-smi >/dev/null 2>&1; then
      export NVIDIA_DRIVER_VERSION="$(nvidia-smi --version | grep 'DRIVER version' | cut -d: -f2 | tr -d ' ')"
    else
      echo 'Failed to find NVIDIA GPU driver version, container will likely not start because of no NVIDIA container toolkit or NVIDIA GPU driver present'
    fi
  fi
  cd /tmp
  if [ ! -f "/tmp/NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${NVIDIA_DRIVER_VERSION}.run" ]; then
    curl -fsSL -O "https://international.download.nvidia.com/XFree86/Linux-${NVIDIA_DRIVER_ARCH}/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${NVIDIA_DRIVER_VERSION}.run" || curl -fsSL -O "https://international.download.nvidia.com/tesla/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${NVIDIA_DRIVER_VERSION}.run" || echo 'Failed NVIDIA GPU driver download'
  fi
  if [ -f "/tmp/NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${NVIDIA_DRIVER_VERSION}.run" ]; then
    rm -rf "NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${NVIDIA_DRIVER_VERSION}"
    sh "NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${NVIDIA_DRIVER_VERSION}.run" -x
    cd "NVIDIA-Linux-${NVIDIA_DRIVER_ARCH}-${NVIDIA_DRIVER_VERSION}"
    sudo ./nvidia-installer --silent \
                      --no-kernel-module \
                      --install-compat32-libs \
                      --no-nouveau-check \
                      --no-nvidia-modprobe \
                      --no-systemd \
                      --no-rpms \
                      --no-backup \
                      --no-check-for-alternate-installs
    rm -rf /tmp/NVIDIA* && cd ~
  else
    echo 'Unless using non-NVIDIA GPUs, container will likely not work correctly'
  fi
fi

# Run Xvfb server with required extensions.
# XTEST is what Selkies uses to inject mouse/keyboard -- without it the pointer
# renders but never moves. XFIXES is what carries the cursor SHAPE to the client.
/usr/bin/Xvfb "${DISPLAY}" -screen 0 "8192x4096x${DISPLAY_CDEPTH}" -dpi "${DISPLAY_DPI}" +extension "COMPOSITE" +extension "DAMAGE" +extension "GLX" +extension "RANDR" +extension "RENDER" +extension "MIT-SHM" +extension "XFIXES" +extension "XTEST" +iglx +render -nolisten "tcp" -ac -noreset -shmem &

# Wait for X server to start
echo 'Waiting for X Socket' && until [ -S "/tmp/.X11-unix/X${DISPLAY#*:}" ]; do sleep 0.5; done && echo 'X Server is ready'

# Resize the screen to the provided size
/usr/local/bin/selkies-gstreamer-resize "${DISPLAY_SIZEW}x${DISPLAY_SIZEH}"

# Give the root window a real cursor. Without this the pointer over the desktop
# background is the default X "X" bitmap, which reads as a broken cursor.
/usr/bin/xsetroot -cursor_name left_ptr 2>/dev/null || true

# Use VirtualGL to run XFCE with OpenGL if the GPU is available, otherwise use
# OpenGL with llvmpipe
export XDG_SESSION_ID="${DISPLAY#*:}"
export QT_LOGGING_RULES="${QT_LOGGING_RULES:-*.debug=false;qt.qpa.*=false}"
if [ -n "$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | head -n1)" ] || [ -n "$(ls -A /dev/dri 2>/dev/null)" ]; then
  export VGL_FPS="${DISPLAY_REFRESH}"
  /usr/bin/vglrun -d "${VGL_DISPLAY:-egl}" +wm /usr/bin/dbus-launch --exit-with-session /usr/bin/startxfce4 &
else
  /usr/bin/dbus-launch --exit-with-session /usr/bin/startxfce4 &
fi

# ---------------------------------------------------------------------------
# Extras beyond upstream
# ---------------------------------------------------------------------------

# sshd. Vast.ai injects your account's public key as $SSH_PUBLIC_KEY.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    echo "${SSH_PUBLIC_KEY}" > ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    echo '[entrypoint] Installed SSH public key from $SSH_PUBLIC_KEY.'
fi
sudo-root ssh-keygen -A >/dev/null 2>&1 || true
sudo-root mkdir -p /run/sshd 2>/dev/null || true
sudo-root /usr/sbin/sshd 2>/dev/null && echo '[entrypoint] sshd listening on port 22.' \
    || echo '[entrypoint] sshd did not start (no real root available); use the provider console instead.'

# Tailscale.
#
# Mode matters enormously and is easy to get wrong. WebRTC (the browser
# desktop) can only advertise addresses that exist on a kernel interface.
# tailscaled --tun=userspace-networking proxies TCP to localhost but never
# creates one, so gstreamer emits only the docker bridge address (172.17.x)
# and no remote browser can ever reach it -- the session fails as
# "Connection failed" with no obvious cause.
#
# A real TUN needs NET_ADMIN + /dev/net/tun, which many rented-GPU hosts do
# not grant by default. We detect that up front and say so, rather than
# letting it surface as a mystery.
TAILSCALE_MODE="none"
TS_IP=""
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    echo '[entrypoint] Starting Tailscale ...'
    sudo-root mkdir -p /var/run/tailscale /var/lib/tailscale 2>/dev/null || true

    # Prefer a real TUN; fall back to userspace only if we must.
    if [ -c /dev/net/tun ] && [ "${TAILSCALE_TUN:-auto}" != "userspace-networking" ]; then
        TS_TUN="${TAILSCALE_TUN:-tailscale0}"
        [ "${TS_TUN}" = "auto" ] && TS_TUN="tailscale0"
    else
        TS_TUN="userspace-networking"
    fi

    sudo-root tailscaled --tun="${TS_TUN}" \
        --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055 \
        > /tmp/tailscaled.log 2>&1 &
    sleep 3
    # HARD TIMEOUT. `tailscale up` blocks indefinitely when the host cannot
    # reach controlplane.tailscale.com (seen on Vast machines with broken
    # outbound DNS). Without this it hangs the rest of the entrypoint, so the
    # connection banner never prints and the instance looks dead -- the actual
    # failure being invisible is far worse than not having a tailnet.
    if timeout "${TAILSCALE_UP_TIMEOUT:-60}" sudo-root tailscale up \
        --authkey="${TAILSCALE_AUTHKEY}" \
        --hostname="${TAILSCALE_HOSTNAME:-isaacsim-$(hostname)}" \
        --accept-routes >> /tmp/tailscaled.log 2>&1; then
        TS_IP="$(sudo-root tailscale ip -4 2>/dev/null || true)"
        if [ -n "${TS_IP}" ] && ip -4 addr show 2>/dev/null | grep -q "${TS_IP}"; then
            TAILSCALE_MODE="tun"
        else
            TAILSCALE_MODE="userspace"
        fi
    else
        TAILSCALE_MODE="failed"
        echo '[entrypoint] Tailscale login FAILED or timed out; see /tmp/tailscaled.log'
        echo '[entrypoint] Continuing without a tailnet -- desktop and SSH still work.'
    fi
fi

# ---------------------------------------------------------------------------
# Print the exact URL to open. Vast.ai injects $PUBLIC_IPADDR and a
# $VAST_TCP_PORT_<internal_port> variable per mapped port, so resolve the real
# external port here rather than making the user hunt for it on the console.
# ---------------------------------------------------------------------------
WEB_PORT="${NGINX_PORT:-8080}"

# Resolve "what do I type to reach container port N from outside", using the
# per-port variables Vast injects. Echoes "<addr> <port>" or nothing.
ext_for() {  # ext_for <internal_port> [udp]
    local p="$1" proto="${2:-tcp}" var val
    if [ "${proto}" = "udp" ]; then var="VAST_UDP_PORT_${p}"; else var="VAST_TCP_PORT_${p}"; fi
    val="${!var:-}"
    if [ -n "${val}" ] && [ -n "${PUBLIC_IPADDR:-}" ]; then echo "${PUBLIC_IPADDR} ${val}"; fi
}

(
  # Wait for nginx to actually be listening before advertising anything.
  for _ in $(seq 1 120); do
      if (echo > /dev/tcp/127.0.0.1/${WEB_PORT}) >/dev/null 2>&1; then break; fi
      sleep 1
  done

  CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  WEB_EXT="$(ext_for ${WEB_PORT})"
  SSH_EXT="$(ext_for 22)"
  SIG_EXT="$(ext_for 49100)"
  HTTP_EXT="$(ext_for 8011)"
  MEDIA_EXT="$(ext_for 47998 udp)"

  echo ''
  echo '[connect] =================================================================='
  echo '[connect]   ISAAC SIM CONTAINER -- HOW TO CONNECT'
  echo '[connect] =================================================================='

  # Driver check FIRST -- on an R590-branch driver Isaac segfaults in
  # rtx.scenedb.plugin immediately after "app ready", and no container-side
  # setting can help because the driver belongs to the host kernel. Renting a
  # machine and discovering this by crash is expensive; say it up front.
  # Thresholds are from observation, not guesswork:
  #   575.64.03, 580.159.03, 580.173.02  -> verified working
  #   590.48.01                          -> verified working (compiles + streams)
  #   595.71.05, 595.84                  -> verified SEGFAULT in rtx.scenedb.plugin
  # So flag 595+ as broken, and note 590.x as untested-but-seen-working rather
  # than condemning a host that is actually fine.
  DRV="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  DRV_MAJOR="${DRV%%.*}"
  if [ -n "${DRV_MAJOR}" ] && [ "${DRV_MAJOR}" -ge 595 ] 2>/dev/null; then
      echo '[connect]'
      echo "[connect]   *** WARNING: GPU driver ${DRV} (595+). ***"
      echo '[connect]   Isaac Sim 5.0 SEGFAULTS on this branch (crash in'
      echo '[connect]   rtx.scenedb.plugin, exit code 139, right after "app ready").'
      echo '[connect]   This is a host driver issue -- nothing in this container'
      echo '[connect]   can work around it. Destroy the instance and pick a host on'
      echo '[connect]   575.x / 580.x (verified working).'
      echo '[connect]   The desktop and SSH still work; only Isaac will crash.'
  elif [ -n "${DRV}" ]; then
      echo "[connect]   GPU driver ${DRV} -- OK for Isaac Sim 5.0."
  fi
  echo '[connect]'
  if [ "$(echo ${KASMVNC_ENABLE:-true} | tr '[:upper:]' '[:lower:]')" = "true" ]; then
      DESKTOP_KIND="KasmVNC / WebSocket -- works through any port mapping"
  else
      DESKTOP_KIND="Selkies / WebRTC+NVENC -- needs a routable address, fails on Vast"
  fi
  echo "[connect]  1) BROWSER DESKTOP  (ROS 2, terminals, VS Code)"
  echo "[connect]     transport: ${DESKTOP_KIND}"
  echo "[connect]     login: ${SELKIES_BASIC_AUTH_USER:-ubuntu} / \$PASSWD"
  if [ "${TAILSCALE_MODE}" = "tun" ]; then
      echo "[connect]     http://${TS_IP}:${WEB_PORT}/          <-- Tailscale (use this)"
  fi
  if [ -n "${WEB_EXT}" ]; then
      echo "[connect]     http://$(echo ${WEB_EXT} | tr ' ' ':')/"
  else
      echo "[connect]     http://<host>:${WEB_PORT}/"
  fi
  echo '[connect]'
  echo "[connect]  2) ISAAC SIM STREAM  (full speed -- run the desktop icon"
  echo "[connect]     'Isaac Sim - Streaming (fast)', then connect the NVIDIA"
  echo "[connect]     'Isaac Sim WebRTC Streaming Client' 2.0.0+ app to:)"
  if [ "${TAILSCALE_MODE}" = "tun" ]; then
      echo "[connect]     ${TS_IP}   port 49100          <-- Tailscale (use this)"
  fi
  if [ -n "${SIG_EXT}" ]; then
      echo "[connect]     $(echo ${SIG_EXT} | awk '{print $1"   port "$2}')"
      [ -n "${MEDIA_EXT}" ] && echo "[connect]        (media udp 47998 -> $(echo ${MEDIA_EXT} | awk '{print $2}'); a remapped"
      [ -n "${MEDIA_EXT}" ] && echo "[connect]         media port is what causes a grey viewport)"
  fi
  if [ -z "${SIG_EXT}" ] && [ "${TAILSCALE_MODE}" != "tun" ]; then
      echo "[connect]     127.0.0.1   port 49100      (if you published -p 49100:49100)"
      echo "[connect]     ${CONTAINER_IP}   port 49100      (container address)"
  fi
  echo '[connect]'
  echo '[connect]  3) SSH'
  if [ -n "${SSH_EXT}" ]; then
      echo "[connect]     ssh -p $(echo ${SSH_EXT} | awk '{print $2}') $(id -nu)@$(echo ${SSH_EXT} | awk '{print $1}')"
  elif [ "${TAILSCALE_MODE}" = "tun" ]; then
      echo "[connect]     ssh $(id -nu)@${TS_IP}"
  else
      echo "[connect]     docker exec -it <container> bash        (running locally)"
      echo "[connect]     ssh $(id -nu)@${CONTAINER_IP}            (if 22 is published)"
  fi
  echo '[connect]'
  echo '[connect]  NETWORK MODE'
  case "${TAILSCALE_MODE}" in
    tun)
      echo "[connect]     Tailscale: REAL interface (${TS_IP}) -- ports are 1:1."
      echo '[connect]     Both the desktop and the Isaac stream should work.'
      ;;
    failed)
      echo '[connect]     Tailscale did NOT come up (login failed or timed out).'
      echo '[connect]     Check which of these it is:'
      echo '[connect]       getent hosts controlplane.tailscale.com'
      echo '[connect]         -> 0.0.0.0  = this host BLOCKS Tailscale (seen on Vast;'
      echo '[connect]            general internet still works). Nothing to fix here --'
      echo '[connect]            destroy and pick another host.'
      echo '[connect]         -> no answer = broken outbound DNS on the host.'
      echo '[connect]         -> a real IP = the auth key was rejected or used up;'
      echo '[connect]            non-reusable keys work exactly once. Use a reusable key.'
      echo '[connect]     Details in /tmp/tailscaled.log.'
      echo '[connect]     Desktop + SSH work. The Isaac stream has no tailnet to use,'
      echo '[connect]     so try the provider-mapped port and expect a grey viewport.'
      ;;
    userspace)
      echo "[connect]     Tailscale: userspace mode (${TS_IP}) -- normal on Vast.ai,"
      echo '[connect]     which allows only env vars / hostname / ports as docker'
      echo '[connect]     options (no --cap-add or --device), so a real TUN is not'
      echo '[connect]     possible there. The Isaac stream and SSH work over it.'
      if [ "$(echo ${KASMVNC_ENABLE:-true} | tr '[:upper:]' '[:lower:]')" != "true" ]; then
          echo '[connect]     *** The Selkies/WebRTC desktop CANNOT work in this mode. ***'
          echo '[connect]     Set KASMVNC_ENABLE=true for a desktop that does.'
      fi
      ;;
    *)
      if [ -z "${WEB_EXT}" ]; then
          echo '[connect]     Direct/local -- no provider port rewriting detected.'
          echo '[connect]     Ports are 1:1, so both the desktop and the Isaac'
          echo '[connect]     stream should work without Tailscale.'
      else
          echo '[connect]     Provider port rewriting detected, no tailnet.'
          if [ "$(echo ${KASMVNC_ENABLE:-true} | tr '[:upper:]' '[:lower:]')" = "true" ]; then
              echo '[connect]     Desktop uses KasmVNC/WebSocket, so it is unaffected.'
          else
              echo '[connect]     The Selkies/WebRTC desktop will fail here --'
              echo '[connect]     set KASMVNC_ENABLE=true.'
          fi
          echo '[connect]     For the Isaac stream, set TAILSCALE_AUTHKEY if the'
          echo '[connect]     viewport comes up grey on the mapped port.'
      fi
      ;;
  esac
  echo '[connect] =================================================================='
  echo ''

  # cloudflared fallback: no account needed, public HTTPS URL that works
  # without any port mapping. Skipped when the provider already mapped a port.
  if [ -z "${WEB_EXT}" ] && [ "${ENABLE_CLOUDFLARED:-false}" = "true" ]; then
      cloudflared tunnel --url "http://localhost:${WEB_PORT}" --no-autoupdate \
          > /tmp/cloudflared.log 2>&1 &
      for _ in $(seq 1 30); do
          TUNNEL_URL="$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -n1 || true)"
          [ -n "${TUNNEL_URL}" ] && break
          sleep 1
      done
      if [ -n "${TUNNEL_URL:-}" ]; then
          echo "[connect]   Cloudflare tunnel: ${TUNNEL_URL}"
      fi
  fi
# supervisord sends each program's stdout to its own file (stdout_logfile), so
# anything printed here would never reach `docker logs` -- i.e. the Vast.ai
# console, which is exactly where someone starting an instance looks for the
# URL. Duplicate it onto PID 1's stdout so it shows up in both places.
) 2>&1 | tee /proc/1/fd/1 2>/dev/null &

echo "Session Running. Press [Return] to exit."
read
