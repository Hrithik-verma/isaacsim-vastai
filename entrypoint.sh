#!/usr/bin/env bash
# Entrypoint: configure + launch KasmVNC with an XFCE desktop, then keep the
# container alive by tailing the VNC log. Runs on Vast.ai as PID 1.
set -euo pipefail

: "${VNC_USER:=kasm_user}"      # web login username
: "${VNC_PW:=isaacsim}"         # web login password (CHANGE THIS via the template's env vars)
: "${RESOLUTION:=1920x1080}"    # desktop resolution
: "${VNC_PORT:=6901}"           # KasmVNC web/websocket port
: "${VNC_DISPLAY:=:1}"

export HOME=/root
export DISPLAY="${VNC_DISPLAY}"

# Give root a real Linux password matching VNC_PW. KDE's screen locker can
# still engage on session idle even with autolock disabled below (resume
# from suspend, manual lock, etc.), and with no display manager / "switch
# user" flow in this VNC setup a locked session with no valid root password
# is unrecoverable without restarting the container.
echo "root:${VNC_PW}" | chpasswd

# ---------------------------------------------------------------------------
# Name the GPU render-node group (mounted in by --gpus) so shells don't warn
# "cannot find name for group ID N". GID is host-specific, so read it live.
# ---------------------------------------------------------------------------
if [ -e /dev/dri/renderD128 ]; then
    rgid="$(stat -c '%g' /dev/dri/renderD128)"
    if [ -n "${rgid}" ] && ! getent group "${rgid}" >/dev/null 2>&1; then
        groupadd -g "${rgid}" render >/dev/null 2>&1 || true
    fi
fi

# ---------------------------------------------------------------------------
# SSH (Vast.ai injects your account's SSH public key via $SSH_PUBLIC_KEY)
# ---------------------------------------------------------------------------
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    echo "${SSH_PUBLIC_KEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "[entrypoint] Installed SSH public key from \$SSH_PUBLIC_KEY."
else
    echo "[entrypoint] WARNING: \$SSH_PUBLIC_KEY not set — SSH key auth will fail."
fi
ssh-keygen -A >/dev/null 2>&1 || true
/usr/sbin/sshd
echo "[entrypoint] sshd listening on port 22."

echo "[entrypoint] Configuring KasmVNC user '${VNC_USER}' ..."
# kasmvncpasswd prompts for the password AND a "Verify:" line, so feed it twice.
# Wrapped in set +e so a hiccup here never crash-loops the whole container.
set +e
printf '%s\n%s\n' "${VNC_PW}" "${VNC_PW}" | kasmvncpasswd -u "${VNC_USER}" -wo /root/.kasmpasswd
pw_rc=$?
set -e
if [ "${pw_rc}" -ne 0 ] || [ ! -s /root/.kasmpasswd ]; then
    echo "[entrypoint] ERROR: could not set KasmVNC password (rc=${pw_rc}); web login will fail."
else
    echo "[entrypoint] KasmVNC password set for '${VNC_USER}'."
fi

# Clean any stale lock from a previous run (important for instance restarts).
vncserver -kill "${VNC_DISPLAY}" >/dev/null 2>&1 || true
rm -f "/tmp/.X11-unix/X${VNC_DISPLAY#:}" "/tmp/.X${VNC_DISPLAY#:}-lock" 2>/dev/null || true

echo "[entrypoint] Starting KasmVNC on ${VNC_DISPLAY} (web port ${VNC_PORT}, ${RESOLUTION}) ..."
# ~/.vnc/xstartup exists and ~/.vnc/.de-was-selected is pre-created, so
# select-de.sh short-circuits (no interactive DE prompt) and uses our xstartup.
set +e
vncserver "${VNC_DISPLAY}" \
    -geometry "${RESOLUTION}" \
    -depth 24 \
    -websocketPort "${VNC_PORT}"
vnc_rc=$?
set -e
if [ "${vnc_rc}" -ne 0 ]; then
    echo "[entrypoint] ERROR: vncserver failed to start (rc=${vnc_rc}). Container"
    echo "[entrypoint] will stay up so you can inspect logs / exec in and debug."
fi

echo "[entrypoint] KasmVNC is up."
echo "[entrypoint]   Web UI : http://<host>:${VNC_PORT}/"
echo "[entrypoint]   Login  : ${VNC_USER} / \$VNC_PW"
echo "[entrypoint]   Launch Isaac Sim from the desktop icon, or run:"
echo "[entrypoint]     run-isaacsim.sh"

# Keep PID 1 alive and stream the session log.
LOG="$(ls -t /root/.vnc/*.log 2>/dev/null | head -n1 || true)"
exec tail -F "${LOG:-/dev/null}"
