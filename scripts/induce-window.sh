#!/usr/bin/env bash
# Open or close a node unavailability window in one AZ.
# This is the low-friction path (no IAM); fis/ has the FIS equivalent.
#
# `open` DRAINS every node in the AZ: it cordons them (node.spec.unschedulable:
# true) AND evicts their running pods, honouring PodDisruptionBudgets as it
# goes. Draining — not a bare cordon — is what actually empties the zone: a
# cordon alone only blocks NEW pods and leaves the running ones in place, so
# the zone never goes to zero and no drift appears. Eviction models real
# instance loss (Spot interruption, managed node group upgrade, node
# termination), where the pods genuinely go away and must reschedule onto the
# surviving AZs.
#
# Usage:
#   ./induce-window.sh open  [az]     # default az: us-east-1c
#   ./induce-window.sh close [az]
set -euo pipefail

ACTION="${1:?usage: induce-window.sh open|close [az]}"
AZ="${2:-us-east-1c}"

NODES=$(kubectl get nodes -l "topology.kubernetes.io/zone=${AZ}" -o name)
[ -n "$NODES" ] || { echo "No nodes found in ${AZ}" >&2; exit 1; }

case "$ACTION" in
  open)
    echo "==> $(date -u +%H:%M:%SZ) Opening window: draining all nodes in ${AZ}"
    echo "    (cordon + evict running pods, honouring PodDisruptionBudgets)"
    # --ignore-daemonsets: DaemonSet pods (CNI, kube-proxy) can't be rescheduled
    #   and are expected to stay; draining refuses without this flag.
    # --delete-emptydir-data: allow eviction of pods using emptyDir volumes
    #   (the web tier does not, but load-generator-style pods may).
    # --timeout: don't hang forever if a PDB blocks progress; surfaces the stall.
    for n in $NODES; do
      kubectl drain "$n" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --timeout=300s
    done
    ;;
  close)
    echo "==> $(date -u +%H:%M:%SZ) Closing window: uncordoning all nodes in ${AZ}"
    for n in $NODES; do kubectl uncordon "$n"; done
    ;;
  *)
    echo "unknown action: $ACTION (use open|close)" >&2; exit 1
    ;;
esac

kubectl get nodes -L topology.kubernetes.io/zone | grep -E "NAME|${AZ}"
