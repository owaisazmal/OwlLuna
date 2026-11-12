#!/bin/bash
# Usage: wait-for-simulator.sh [seconds]. Waits for $SIMULATOR_UDID to boot, then for the Mac's load to come down:
# a simulator's first boot keeps a runner busy for minutes, and tests with deadlines miss them on a busy one.
set -euo pipefail

limit=${1:-300}
xcrun simctl bootstatus "$SIMULATOR_UDID" > /dev/null
cpus=$(sysctl -n hw.ncpu)
start=$SECONDS
while :; do
  load=$(sysctl -n vm.loadavg | awk '{ print $2 }')
  waited=$((SECONDS - start))
  echo "Load $load on $cpus CPUs, ${waited}s after boot"
  if awk -v load="$load" -v cpus="$cpus" 'BEGIN { exit !(load < cpus * 1.5) }'; then
    break
  fi
  if [ "$waited" -ge "$limit" ]; then
    echo "::notice title=Runner still busy::The load was $load on $cpus CPUs ${waited}s after the simulator booted; the tests start anyway."
    break
  fi
  sleep 15
done
