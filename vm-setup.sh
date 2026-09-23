#!/usr/bin/env bash
# Run from YOUR machine. Paste the ssh line Vast gives you; this does the rest.
#
#   ./vm-setup.sh 'ssh -p 15217 root@76.27.73.50'
#   ./vm-setup.sh 'ssh -p 15217 root@76.27.73.50' --tailscale-key tskey-auth-...
#
# Copies vm-bootstrap.sh to the VM and runs it. If the VM needs a reboot to fix
# its driver mismatch (Vast images ship a kernel module that does not match
# their userspace libraries), this waits for the VM to come back and resumes --
# which is the one step that otherwise needs a human watching.
set -euo pipefail

SSH_LINE="${1:?usage: $0 'ssh -p PORT root@HOST' [--tailscale-key KEY] [--password PW]}"
shift || true

# Pull host/port out of whatever the provider handed you, extra flags and all.
PORT="$(grep -oE '\-p +[0-9]+' <<<"${SSH_LINE}" | grep -oE '[0-9]+' | head -1)"
TARGET="$(grep -oE '[A-Za-z0-9_.-]+@[0-9A-Za-z.:-]+' <<<"${SSH_LINE}" | head -1)"
[ -n "${TARGET}" ] || { echo "could not find user@host in: ${SSH_LINE}" >&2; exit 1; }
PORT="${PORT:-22}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -p "${PORT}")

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "${HERE}/vm-bootstrap.sh" ] || { echo "vm-bootstrap.sh not found beside this script" >&2; exit 1; }

echo "==> target: ${TARGET} port ${PORT}"
scp "${SSH_OPTS[@]/-p/-P}" "${HERE}/vm-bootstrap.sh" "${TARGET}:/root/vm-bootstrap.sh" >/dev/null
echo "==> running bootstrap (this pulls ~40GB on a cold VM)"

set +e
ssh "${SSH_OPTS[@]}" "${TARGET}" "chmod +x /root/vm-bootstrap.sh && /root/vm-bootstrap.sh $*"
rc=$?
set -e

# Exit 1 from the bootstrap means the driver mismatch: reboot and resume.
if [ "${rc}" -ne 0 ]; then
    echo "==> bootstrap stopped (exit ${rc}); checking whether a reboot fixes it"
    if ssh "${SSH_OPTS[@]}" "${TARGET}" '
          K=$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+" /proc/driver/nvidia/version 2>/dev/null | head -1)
          U=$(ls /usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.* 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)
          [ -n "$K" ] && [ -n "$U" ] && [ "$K" != "$U" ]' 2>/dev/null; then
        echo "==> driver mismatch confirmed; rebooting the VM"
        ssh "${SSH_OPTS[@]}" "${TARGET}" 'nohup sh -c "sleep 1; reboot" >/dev/null 2>&1 &' || true
        echo -n "==> waiting for it to come back"
        for _ in $(seq 1 60); do
            sleep 10; printf '.'
            if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${TARGET}" true 2>/dev/null; then
                echo " up"
                echo "==> resuming bootstrap"
                ssh "${SSH_OPTS[@]}" "${TARGET}" "/root/vm-bootstrap.sh $*"
                exit $?
            fi
        done
        echo; echo "VM did not come back within 10 minutes" >&2; exit 1
    fi
    exit "${rc}"
fi
