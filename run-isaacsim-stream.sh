#!/usr/bin/env bash
# Launch Isaac Sim headless with Kit's OWN WebRTC livestream -- the fast path.
#
#   Kit renders on GPU -> NVENC -> WebRTC.  No X server, no VirtualGL, no
#   desktop capture, no framebuffer readback.
#
# Measured on an RTX 4050 Laptop: this path runs near the native ~118 FPS,
# where the browser desktop (VirtualGL readback + ximagesrc CPU capture, even
# with NVENC encoding) delivers 15-26 FPS on the same scene. The readback is
# the difference, not the encoder.
#
# View it with the "Isaac Sim WebRTC Streaming Client" desktop app. Use the
# browser desktop on :8080 alongside this for ROS 2, terminals and VS Code --
# they share the same container and run at the same time.
set -u

# Survive the launching terminal going away. Closing the desktop window (or
# dropping the SSH session it was started from) otherwise SIGHUPs Kit and kills
# a sim that took minutes of shader compilation to start -- and the death looks
# like a hang, because the last thing in the log is a shader-compile message.
trap '' HUP

PORT_SIGNALING=49100
PORT_HTTP=8011

# ---------------------------------------------------------------------------
# Refuse to start a second copy. Two Kit instances fight over 49100 and the
# second one fails in a way that reads like a client problem.
# ---------------------------------------------------------------------------
STREAM_LOG=/tmp/isaacsim-stream.log

if (echo > /dev/tcp/127.0.0.1/${PORT_SIGNALING}) >/dev/null 2>&1; then
    echo
    echo "  =============================================================="
    echo "  Isaac Sim is ALREADY streaming on port ${PORT_SIGNALING}."
    echo "  (Started from another window, or before this desktop opened.)"
    echo
    echo "  Connect your WebRTC client to it -- see the addresses below."
    echo "  =============================================================="
    echo
    # Don't dead-end: attach to the running instance's log so this window is
    # still useful for watching progress and errors.
    if [ -f "${STREAM_LOG}" ]; then
        echo "  --- attaching to the running Isaac Sim log (Ctrl-C to detach) ---"
        echo
        tail -n 40 -f "${STREAM_LOG}"
    else
        KITLOG="$(ls -t "${HOME}/.nvidia-omniverse/logs/Kit/Isaac-Sim Streaming/5.0/"*.log 2>/dev/null | head -1)"
        if [ -n "${KITLOG}" ]; then
            echo "  --- attaching to Kit's log (Ctrl-C to detach) ---"
            echo
            tail -n 40 -f "${KITLOG}"
        else
            echo "  No log found for the running instance."
            read -r -p "  Press Enter to close this window. "
        fi
    fi
    exit 0
fi

ISAAC_ENV="${ISAAC_ENV:-env_isaacsim}"
source /opt/conda/etc/profile.d/conda.sh
conda activate "${ISAAC_ENV}"

export ROS_DISTRO=humble
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ACCEPT_EULA=Y PRIVACY_CONSENT=Y OMNI_KIT_ACCEPT_EULA=YES
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-ubuntu}"
mkdir -p "${XDG_RUNTIME_DIR}" && chmod 700 "${XDG_RUNTIME_DIR}" 2>/dev/null || true
unset LD_PRELOAD

# Headless: Kit must not try to open a window on the desktop's X display.
unset DISPLAY

SITE="$(python -c 'import isaacsim, os; print(os.path.dirname(isaacsim.__file__))' 2>/dev/null || true)"
if [ -n "${SITE}" ]; then
    # Glob every isaacsim.ros2.* extension rather than naming one: the layout
    # moved in 6.x. Up to 5.x the bridge .so and the bundled distro libs lived
    # in isaacsim.ros2.bridge/{bin,humble/lib}; from 6.0 the bridge is a
    # meta-extension with no libraries, and they are spread over
    # isaacsim.ros2.{core,nodes,control,tf_viewer}/bin plus
    # isaacsim.ros2.core/humble/lib. Pointing at the old path makes
    # isaacsim.ros2.core log "ROS2 Bridge startup failed".
    ROS2_LIBS=""
    for d in "${SITE}"/exts/isaacsim.ros2.*/bin "${SITE}"/exts/isaacsim.ros2.*/"${ROS_DISTRO}"/lib; do
        [ -d "${d}" ] && ROS2_LIBS="${ROS2_LIBS:+${ROS2_LIBS}:}${d}"
    done
    USD_LIBS="$(ls -d "${SITE}"/extscache/omni.usd.libs-*/bin 2>/dev/null | head -1)"
    export LD_LIBRARY_PATH="${ROS2_LIBS}:${USD_LIBS}:${CONDA_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
fi

EXPERIENCE="${ISAAC_EXPERIENCE:-isaacsim.exp.full.streaming.kit}"
if [ -n "${SITE}" ] && [ ! -f "${SITE}/apps/${EXPERIENCE}" ]; then
    echo "[run-isaacsim-stream] '${EXPERIENCE}' not found. Available experiences:"
    ls -1 "${SITE}/apps/" 2>/dev/null | sed 's/^/    /'
    read -r -p "  Press Enter to close. "
    exit 1
fi

# ---------------------------------------------------------------------------
# Work out what address to type into the streaming client.
#
# Tailscale first: on a tailnet the container has a real routable IP with 1:1
# ports, so Kit's ICE candidates are correct. Under a provider's random
# external port mapping they are NOT -- signaling connects and then the video
# never arrives (the "grey viewport" reports). That is why Tailscale is the
# recommended path on Vast.ai rather than plain -p mapping.
# ---------------------------------------------------------------------------
TS_IP="$(tailscale ip -4 2>/dev/null || sudo-root tailscale ip -4 2>/dev/null || true)"
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
VAST_PORT_VAR="VAST_TCP_PORT_${PORT_SIGNALING}"
VAST_PORT="${!VAST_PORT_VAR:-}"

echo
echo "  =============================================================="
echo "   Isaac Sim -- WebRTC stream (no window here; this is normal)"
echo "  =============================================================="
echo
echo "   Open the 'Isaac Sim WebRTC Streaming Client' app and connect to:"
echo
if [ -n "${TS_IP}" ]; then
    echo "     ${TS_IP}   port ${PORT_SIGNALING}      <-- Tailscale (recommended)"
fi
if [ -n "${VAST_PORT}" ] && [ -n "${PUBLIC_IPADDR:-}" ]; then
    echo "     ${PUBLIC_IPADDR}   port ${VAST_PORT}"
    echo "        (Vast mapped ${PORT_SIGNALING} -> ${VAST_PORT}. If the client connects but the"
    echo "         viewport stays grey, the UDP media port is being remapped too --"
    echo "         set TAILSCALE_AUTHKEY and use the Tailscale address instead.)"
fi
echo "     127.0.0.1   port ${PORT_SIGNALING}      <-- if you published the port locally"
[ -n "${LAN_IP}" ] && echo "     ${LAN_IP}   port ${PORT_SIGNALING}      (container-internal address)"
echo
echo "   Keep the browser desktop on :8080 open alongside this for ROS 2,"
echo "   terminals and VS Code -- same container, both work at once."
echo
echo "  --------------------------------------------------------------"
echo "   Starting Kit. First run compiles shaders and takes a few minutes."
echo

# Progress + readiness reporter.
#
# Kit's own stdout scrolls past below, but on a cold shader cache it can sit on
# one line for minutes and look hung. Print an elapsed-time heartbeat with
# whatever Kit last logged, so it's obvious it's still working, then announce
# the moment the signaling port actually accepts.
(
  start=$(date +%s)
  KITLOG_DIR="${HOME}/.nvidia-omniverse/logs/Kit/Isaac-Sim Streaming/5.0"
  port_announced=0
  for i in $(seq 1 1200); do
      if (echo > /dev/tcp/127.0.0.1/${PORT_SIGNALING}) >/dev/null 2>&1; then
          if [ "${port_announced}" -eq 0 ]; then
              echo
              echo "  [signaling up on ${PORT_SIGNALING} after $(( $(date +%s) - start ))s]"
              port_announced=1
          fi
          # The port accepting is NOT the same as being able to render. On a
          # cold cache Kit keeps compiling RTX shaders (RtPso) for minutes
          # AFTER "app ready", and a client connecting in that window gets a
          # black viewport.
          #
          # Note compilation begins only after "app ready", so "no RtPso lines
          # yet" does NOT mean done -- it usually means not started. Hold for a
          # grace period after app ready before trusting silence, otherwise
          # READY fires within seconds and is wrong (and scrolls away).
          KITLOG="$(ls -t "${KITLOG_DIR}"/*.log 2>/dev/null | head -1)"
          not_ready=1
          # "App is loaded" is Isaac's OWN readiness marker, printed only after
          # isaacsim.app.setup has the viewport handle in hand. Prefer it over
          # the old 'app ready' + RtPso-silence heuristic, which never fired on
          # a busy cloud host: the log there is written continuously, so it is
          # never quiet for 25s and READY was simply unreachable.
          if [ -n "${KITLOG}" ] && grep -q 'App is loaded' "${KITLOG}" 2>/dev/null; then
              not_ready=0
          elif [ -n "${KITLOG}" ] && grep -q 'app ready' "${KITLOG}" 2>/dev/null; then
              if tail -60 "${KITLOG}" 2>/dev/null | grep -q 'Waiting for RtPso'; then
                  if [ -z "$(find "${KITLOG}" -newermt '-25 seconds' 2>/dev/null)" ]; then
                      not_ready=0
                  fi
              elif [ "$(( $(date +%s) - start ))" -ge "${READY_GRACE:-45}" ]; then
                  not_ready=0
              fi
          fi

          # Fail loudly when the GPU cannot open an NVENC session. Isaac logs
          # this and then silently drops every client, so the client reports
          # only "the streamer data channel is closing" and you chase the
          # network for hours. Seen on a Vast.ai host where CUDA worked fine
          # but NVENC could not be opened at all -- not fixable from here; that
          # host cannot stream and you need a different one.
          if [ -n "${KITLOG}" ] && grep -q 'ENCODE_OPEN_FAILED' "${KITLOG}" 2>/dev/null; then
              echo
              echo "  =============================================================="
              echo "  >>> THIS HOST CANNOT ENCODE VIDEO."
              echo "  >>> Isaac reported NVST_DISCONN_SERVER_VIDEO_ENCODER_INIT_"
              echo "  >>> CUDA_ENCODE_OPEN_FAILED: NVENC would not open, although"
              echo "  >>> CUDA itself works. Every client will connect and then be"
              echo "  >>> dropped with 'the streamer data channel is closing'."
              echo "  >>> Nothing in this image can fix it -- rent another host."
              echo "  =============================================================="
              echo
          fi
          if [ "${not_ready}" -eq 0 ]; then
              echo
              echo "  =============================================================="
              echo "  >>> READY after $(( $(date +%s) - start ))s -- shaders compiled, renderer live."
              echo "  >>> Connect the Isaac Sim WebRTC Streaming Client now."
              echo "  =============================================================="
              echo
              exit 0
          fi
      fi
      # Heartbeat every 15s with Kit's most recent line of work.
      if [ $(( i % 15 )) -eq 0 ]; then
          elapsed=$(( $(date +%s) - start ))
          last=""
          KITLOG="$(ls -t "${KITLOG_DIR}"/*.log 2>/dev/null | head -1)"
          if [ -n "${KITLOG}" ]; then
              # Shader (RtPso) compilation is the long pole on a cold cache and
              # emits no extension lines, so surface it explicitly -- otherwise
              # a perfectly healthy 5-minute first launch reads as a hang.
              last="$(grep -oE 'Waiting for RtPso[^*]*|\[ext: [^]]+\]|app ready' "${KITLOG}" 2>/dev/null | tail -1)"
          fi
          echo "  [loading ${elapsed}s] ${last:-starting up...}"
          if [ "${elapsed}" -gt 60 ] && [ $(( i % 60 )) -eq 0 ]; then
              echo "           (compiling the RTX shader cache -- several minutes on a"
              echo "            fresh instance, seconds once it is warm. Not stuck.)"
          fi
      fi
      sleep 1
  done
  echo "  [loading] Gave up waiting after 20 minutes -- check the log above for errors."
# Also append the progress/READY lines to the stream log. Kit prints hundreds
# of lines, so anything shown only on the terminal scrolls out of reach within
# seconds -- and "did it say READY?" then becomes unanswerable.
) 2>&1 | tee -a "${STREAM_LOG}" &

# tee to a predictable path as well as this window, so a second launcher window
# (or `tail -f` from any terminal) can watch the SAME log instead of hunting
# through Kit's timestamped log directory.
isaacsim "${EXPERIENCE}" \
    --no-window \
    --/app/livestream/allowDynamicResize=true \
    --/app/window/drawMouse=true \
    "$@" 2>&1 | tee "${STREAM_LOG}"
rc=${PIPESTATUS[0]}

echo
echo "  Isaac Sim exited (code ${rc})."
read -r -p "  Press Enter to close this window. "
exit "${rc}"
