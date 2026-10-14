#!/usr/bin/env bash
#
# Destroy the clusters in one or more sandboxes early (they also expire on their own).
#
#   ./down.sh                every sandbox with credentials in labs.env
#   ./down.sh azure1         just one

set -euo pipefail
source "$(dirname "$0")/lib.sh"

destroy_sandbox() {
    local sb=$1 cloud
    cloud=$(cloud_of "$sb")
    use_sandbox "$sb"
    local -a vars
    mapfile -t vars < <(tf_vars "$sb")

    # Load balancers made by Kubernetes (LoadBalancer Services, e.g. an ingress
    # controller - on EKS/AKS/GKE, and on kubeadm with <SANDBOX>_CLOUD_LB=1) aren't
    # in Terraform's state. Delete them first or they're left behind (on GCP they
    # would even block deleting the network)
    local f ns name
    for f in "$KUBE_DIR/$sb"-*.yaml; do
        [[ -f $f ]] || continue
        kubectl --kubeconfig "$f" --request-timeout=20s get services -A \
            -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null |
            while read -r ns name; do
                [[ -n $name ]] || continue
                echo "[$sb] $(date +%T) deleting load balancer $ns/$name in $(basename "$f" .yaml)"
                kubectl --kubeconfig "$f" -n "$ns" delete service "$name" --timeout=5m || true
            done
    done

    echo "[$sb] $(date +%T) terraform destroy"
    tf_in "$cloud" destroy -auto-approve -input=false "${vars[@]}"
    rm -f "$KUBE_DIR/$sb"-*.yaml
    echo "[$sb] $(date +%T) done"
}

select_sandboxes "$@"
run_sandboxes destroy_sandbox merge_kubeconfigs

if ((${#FAILED[@]})); then
    echo "Failed: ${FAILED[*]}"
fi
((${#FAILED[@]} == 0 && RUN_FAILED == 0)) || exit 1
