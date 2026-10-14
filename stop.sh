#!/usr/bin/env bash
#
# Stop a background build or destroy safely: Terraform finishes the step it's
# on and saves its state, so ./up.sh (or ./down.sh) carries on from there.
#
#   ./stop.sh aws1

set -uo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=$ROOT/.sandboxes

busy() { [[ -e $RUN_DIR/$1/lock ]] && ! flock -n "$RUN_DIR/$1/lock" true 2>/dev/null; }

(($#)) || { echo "Usage: ./stop.sh <sandbox>   (./status.sh shows what's running)"; exit 1; }

for sb in "$@"; do
    if ! busy "$sb"; then
        echo "$sb isn't running."
        continue
    fi
    pid=$(cat "$RUN_DIR/$sb/pid" 2>/dev/null)
    if [[ -z $pid ]] || ! kill -0 "$pid" 2>/dev/null; then
        echo "$sb is running, but not from a background build this script can stop."
        continue
    fi
    others=$(grep -lx "$pid" "$RUN_DIR"/*/pid 2>/dev/null | xargs -n1 dirname | xargs -n1 basename | grep -vx "$sb" | xargs)
    [[ -n $others ]] && echo "$sb was started together with: $others - those stop too."

    # SIGINT to the whole background session = Ctrl-C for Terraform
    kill -INT -- -"$pid" 2>/dev/null || kill -INT "$pid"
    printf "Stopping %s (Terraform is saving its state)" "$sb"
    for _ in $(seq 1 240); do
        busy "$sb" || break
        printf "."
        sleep 1
    done
    echo
    if busy "$sb"; then
        echo "Still stopping - check again with ./status.sh"
    else
        echo "Stopped. ./up.sh $sb continues it later, ./down.sh $sb removes what was built."
    fi
done
