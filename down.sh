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
