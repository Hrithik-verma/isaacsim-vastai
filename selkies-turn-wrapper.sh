#!/bin/bash
# Wrapper around the base image's Selkies entrypoint that fixes the TURN
# address BEFORE Selkies starts.
#
# WHY THIS EXISTS
# ---------------
# Selkies' bundled coturn is told one port number, and uses it for two
# different things: the port it BINDS locally, and the port it ADVERTISES to
# the browser. That is fine anywhere ports aren't rewritten. On Vast.ai they
# are: the instance publishes container 3478 on a random external port (e.g.
# 50330), so
#   - advertise 3478  -> the browser dials a port nothing is published on
#   - advertise 50330 -> coturn binds 50330 internally, and Vast's
#                        external:50330 -> container:3478 mapping now points
#                        at nothing
# Either way the browser can't reach TURN, no relay candidate is offered, and
# the session dies as "Connection failed".
#
# A tailnet has no such rewriting -- 3478 is 3478 on both sides -- so when a
# real Tailscale interface exists we pin TURN to that address and everything
# lines up. That is the only configuration of this that actually works on a
# port-rewriting host.
#
# IMPORTANT: it must be a REAL interface. tailscaled in userspace-networking
# mode proxies TCP to localhost but never puts the 100.x address on the kernel,
# so gstreamer cannot bind or advertise it and still emits only the docker
# bridge address. See the capability check in entrypoint.sh.

set -u

ORIG=/etc/selkies-gstreamer-entrypoint.orig.sh

# Warnings here explain why the desktop won't connect, so they must reach
# `docker logs` (the Vast.ai console) and not just supervisord's per-program
# log file.
log() {
    echo "[selkies-turn] $*"
    echo "[selkies-turn] $*" > /proc/1/fd/1 2>/dev/null || true
}

# Only override when the user hasn't configured TURN explicitly.
if [ -z "${SELKIES_TURN_HOST:-}" ]; then
    # Wait briefly for tailscaled to finish coming up (entrypoint starts it in
    # parallel with us).
    TS_IP=""
    for _ in $(seq 1 20); do
        TS_IP="$(tailscale ip -4 2>/dev/null || sudo-root tailscale ip -4 2>/dev/null || true)"
        [ -n "${TS_IP}" ] && break
        [ -z "${TAILSCALE_AUTHKEY:-}" ] && break
        sleep 1
    done

    # Only usable if the address is actually on an interface.
    if [ -n "${TS_IP}" ] && ip -4 addr show 2>/dev/null | grep -q "${TS_IP}"; then
        export SELKIES_TURN_HOST="${TS_IP}"
        export SELKIES_TURN_PORT="${SELKIES_TURN_PORT:-3478}"
        export SELKIES_TURN_PROTOCOL="${SELKIES_TURN_PROTOCOL:-udp}"
        log "TURN pinned to Tailscale interface ${TS_IP}:${SELKIES_TURN_PORT} (ports are 1:1 on a tailnet)."
    elif [ -n "${TS_IP}" ]; then
        log "WARNING: Tailscale IP ${TS_IP} is NOT on a kernel interface"
        log "         (userspace-networking). WebRTC cannot use it -- gstreamer"
        log "         can only advertise the docker bridge address, which no"
        log "         remote browser can reach. The desktop will fail to connect."
        log "         Relaunch with:  --cap-add=NET_ADMIN --device=/dev/net/tun"
    elif [ -n "${VAST_TCP_PORT_3478:-}" ]; then
        log "WARNING: running on Vast.ai without a usable tailnet. TURN is"
        log "         published on a rewritten external port"
        log "         (3478 -> ${VAST_TCP_PORT_3478}), which Selkies cannot express."
        log "         The browser desktop will likely fail to connect."
        log "         Set TAILSCALE_AUTHKEY and add --cap-add=NET_ADMIN --device=/dev/net/tun."
        log "         The Isaac Sim native stream is unaffected."
    fi
else
    log "Using explicitly configured SELKIES_TURN_HOST=${SELKIES_TURN_HOST}."
fi

exec "${ORIG}" "$@"
