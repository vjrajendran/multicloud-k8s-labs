#!/usr/bin/env bash
#
# Where everything stands - any time, from any terminal:
# every sandbox this machine has built (building / ready / failed / destroyed)
# and how many nodes of each cluster are Ready right now.
#
#   ./status.sh            all sandboxes
#   ./status.sh aws1       just one

set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=$ROOT/.sandboxes
KUBE_DIR=$HOME/.kube/multicloud
MERGED_KUBECONFIG=$HOME/.kube/multicloud.yaml
[[ -d $HOME/.local/bin ]] && PATH=$HOME/.local/bin:$PATH
[[ -t 1 ]] || exec > >(sed 's/\x1b\[[0-9;]*m//g') # no colour codes in files / pipes

busy() { [[ -e $RUN_DIR/$1/lock ]] && ! flock -n "$RUN_DIR/$1/lock" true 2>/dev/null; }

if (($#)); then
    SANDBOXES=("$@")
else
    SANDBOXES=()
    for d in "$RUN_DIR"/*/; do
        [[ -f $d/identity ]] && SANDBOXES+=("$(basename "$d")")
    done
fi
if ((${#SANDBOXES[@]} == 0)); then
    echo "No sandboxes on this machine yet - start one with ./up.sh"
    exit 0
fi

# Ask every cluster in parallel (an unreachable one only costs a few seconds)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pids=()
for f in "$KUBE_DIR"/*.yaml; do
    [[ -f $f ]] || continue
    (kubectl --kubeconfig "$f" --request-timeout=8s get nodes --no-headers >"$tmp/$(basename "$f" .yaml)" 2>/dev/null ||
        echo UNREACHABLE >"$tmp/$(basename "$f" .yaml)") &
    pids+=($!)
done
((${#pids[@]})) && wait "${pids[@]}" # not a bare wait: that would also wait for the colour filter

echo
for sb in "${SANDBOXES[@]}"; do
    log=$(sed 's/\x1b\[[0-9;]*m//g' "$RUN_DIR/$sb/log" 2>/dev/null)
    last=$(grep -E "^\[$sb\] [0-9:]+ terraform (apply|destroy)" <<<"$log" | tail -1)
    action=$([[ $last == *destroy* ]] && echo destroy || echo build)
    at=$(awk '{ print substr($2, 1, 5) }' <<<"$last")
    finished=$(grep -E "^\[$sb\] [0-9:]+ done$" <<<"$log" | tail -1 | awk '{ print substr($2, 1, 5) }')

    if busy "$sb"; then
        # started = when the background run was launched (the log may still be the previous run's)
        [[ -f $RUN_DIR/$sb/pid ]] && at=$(date -r "$RUN_DIR/$sb/pid" +%H:%M)
        state="\033[36m${action/build/building}\033[0m${action:+ since $at}  (live view: ./watch.sh $sb)"
        state=${state/destroy since/destroying since}
    elif [[ -n $finished && $action == destroy ]]; then
        state="destroyed at $finished"
    elif [[ -n $finished ]]; then
        state="\033[32mready\033[0m (built $finished)"
    elif [[ -n $last ]]; then
        err=$(grep -E '^(│ )?Error: |^\['"$sb"'\] [^0-9]' <<<"$log" | tail -1 | sed 's/^│ //; s/^\['"$sb"'\] //')
        state="\033[31mfailed or stopped\033[0m at ${at}${err:+ - ${err:0:80}}  (re-run: ./up.sh $sb)"
    else
        state="not built yet"
    fi
    printf " \033[1m%-8s\033[0m %b\n" "$sb" "$state"

    for f in "$KUBE_DIR/$sb"-*.yaml; do
        [[ -f $f ]] || continue
        ctx=$(basename "$f" .yaml)
        nodes=$(cat "$tmp/$ctx" 2>/dev/null)
        if [[ $nodes == UNREACHABLE ]]; then
            printf "   \033[33m?\033[0m %-14s unreachable (your IP changed? re-run ./up.sh %s)\n" "$ctx" "$sb"
        else
            total=$(grep -c . <<<"$nodes")
            ready=$(awk '$2 == "Ready"' <<<"$nodes" | grep -c .)
            icon=$([[ $total -gt 0 && $ready == "$total" ]] && echo "\033[32m✓\033[0m" || echo "\033[33m•\033[0m")
            printf "   %b %-14s %s/%s nodes Ready\n" "$icon" "$ctx" "$ready" "$total"
        fi
    done
done
echo
[[ -f $MERGED_KUBECONFIG ]] && echo " export KUBECONFIG=$MERGED_KUBECONFIG   then: kubectl --context <name> get nodes"
