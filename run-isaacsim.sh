#!/usr/bin/env bash
# Launch Isaac Sim (pip/conda) into the streamed XFCE desktop.
#
# Rendering goes through VirtualGL against EGL, so Kit's Vulkan/RTX frames are
# blitted into the Xvfb framebuffer, which Selkies then captures and encodes on
# the GPU with NVENC. Without vglrun the Kit window comes up blank, because
# Xvfb has no GPU-backed GLX of its own.
#
# For maximum FPS with no desktop at all, use run-isaacsim-stream.sh instead --
# that path keeps frames on the GPU end to end.
set -e

ISAAC_ENV="${ISAAC_ENV:-env_isaacsim}"
source /opt/conda/etc/profile.d/conda.sh
conda activate "${ISAAC_ENV}"

export ROS_DISTRO=humble
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ACCEPT_EULA=Y PRIVACY_CONSENT=Y OMNI_KIT_ACCEPT_EULA=YES
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-ubuntu}"
mkdir -p "${XDG_RUNTIME_DIR}" && chmod 700 "${XDG_RUNTIME_DIR}" 2>/dev/null || true

# Don't let Kit block on the (nonexistent) display refresh.
export __GL_SYNC_TO_VBLANK=0

# The joystick interposer is LD_PRELOADed session-wide by the entrypoint for
# games; Kit has no use for it and it only adds dlopen work per process.
unset LD_PRELOAD

# ROS 2 bridge library path (scoped to this process). Globbed to survive version
# bumps (python3.11 vs 3.12, omni.usd.libs hash).
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

echo "[run-isaacsim] env=${ISAAC_ENV} display=${DISPLAY}"

if command -v vglrun >/dev/null 2>&1; then
    echo "[run-isaacsim] launching via VirtualGL: vglrun -d ${VGL_DISPLAY:-egl} isaacsim"
    exec vglrun -d "${VGL_DISPLAY:-egl}" isaacsim "$@"
else
    echo "[run-isaacsim] VirtualGL unavailable; launching isaacsim directly (may render blank)"
    exec isaacsim "$@"
fi
