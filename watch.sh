#!/usr/bin/env bash
#
# Live progress for up.sh / down.sh: one line per cluster with its current
# step, elapsed time, an estimate of what's left, and tips while you wait.
#
#   ./watch.sh                every sandbox being built or destroyed right now
#   ./watch.sh aws1 azure1    just these (shows the last state if they're idle)
#
# up.sh runs this automatically when started in a terminal. Closing it never
# stops a build. When everything has finished you get a Windows notification.

set -uo pipefail # no -e: a hiccup while reading a log must never kill the display

ROOT=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=$ROOT/.sandboxes
HISTORY=$RUN_DIR/history # "<cloud>:k<kubeadm>:m<managed> <seconds>" per finished build

EMBEDDED=0 # 1 = started by up.sh/down.sh, which stops us when it's done
NOTIFY_ONLY=0

# ---------------------------------------------------------------
# Desktop notification (Windows toast from WSL, else notify-send) + bell
# ---------------------------------------------------------------

notify() {
    local title=${1//\'/} msg=${2//\'/}
    printf '\a'
    if command -v powershell.exe >/dev/null 2>&1; then
        (powershell.exe -NoProfile -WindowStyle Hidden -Command "
            Add-Type -AssemblyName System.Windows.Forms
            \$n = New-Object System.Windows.Forms.NotifyIcon
            \$n.Icon = [System.Drawing.SystemIcons]::Information
            \$n.Visible = \$true
            \$n.ShowBalloonTip(15000, '$title', '$msg', 'Info')
            Start-Sleep -Seconds 15
            \$n.Dispose()" >/dev/null 2>&1 &)
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "$title" "$msg" 2>/dev/null || true
    fi
}

case ${1:-} in
    --notify)
        notify "${2:-Clusters}" "${3:-Done}"
        exit 0
        ;;
    --embedded)
        EMBEDDED=1
        shift
        ;;
esac

# ---------------------------------------------------------------
# Which sandboxes
# ---------------------------------------------------------------

# Busy = some up.sh/down.sh holds its lock
is_busy() {
    [[ -e $RUN_DIR/$1/lock ]] && ! flock -n "$RUN_DIR/$1/lock" true 2>/dev/null
}

if (($#)); then
    SANDBOXES=("$@")
else
    SANDBOXES=()
    for d in "$RUN_DIR"/*/; do
        sb=$(basename "$d")
        if is_busy "$sb"; then SANDBOXES+=("$sb"); fi
    done
    if ((${#SANDBOXES[@]} == 0)); then
        echo "Nothing is being built or destroyed right now. Start one with ./up.sh"
        exit 0
    fi
fi

# ---------------------------------------------------------------
# Read a sandbox log into a few lines of state:
#   S|<start hh:mm:ss>|<build|destroy>|<status text>|<done 0/1>|<error>
#   C|<cluster>|<kind>|<step>|<steps>|<label>|<elapsed>|<run|ok|fail>
#   D|<resources removed>|<being removed now>
# ---------------------------------------------------------------

read_log() {
    local sb=$1
    sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$RUN_DIR/$sb/log" 2>/dev/null | awk -v sb="$sb" '
    function set(name, kind, s, max, label) {
        if (!(name in kinds)) { order[++n] = name; kinds[name] = kind }
        if (s > step[name] && state[name] != "ok") { step[name] = s; lbl[name] = label }
        steps[name] = max
    }
    BEGIN { action = "build"; status = "starting"; done = 0 }
    {
        line = $0
        # sandbox-level lines written by up.sh / down.sh
        if (index(line, "[" sb "] ") == 1) {
            if (line ~ / terraform apply/)        { start = $2; action = "build"; status = "terraform apply" }
            else if (line ~ / terraform destroy/) { start = $2; action = "destroy"; status = "terraform destroy" }
            else if (line ~ /writing kubeconfigs/) status = "writing kubeconfigs and sharing access"
            else if (line ~ /retrying once/) {
                status = "apply failed - retrying once"
                for (i = 1; i <= n; i++) if (state[order[i]] != "ok") { step[order[i]] = 0; state[order[i]] = "" }
            }
            else if (line ~ /^\[[^]]+\] [0-9:]+ done$/) done = 1
            else if (line !~ /^\[[^]]+\] [0-9:]+ /) { msg = line; sub(/^\[[^]]+\] /, "", msg); err = msg }
            next
        }
        if (line ~ /Apply complete!/) {
            for (i = 1; i <= n; i++) if (existing[order[i]] && state[order[i]] == "") { state[order[i]] = "ok"; lbl[order[i]] = "ready (no changes needed)" }
        }
        if (line ~ /Destruction complete/) removed++
        if (line ~ /Still destroying/ && match(line, /(aws|azurerm|google)_[a-z_]+/)) cur = substr(line, RSTART, RLENGTH)

        if (line ~ /^│ Error: / || line ~ /^Error: /) { pending = line; sub(/^│ /, "", pending); next }

        if (!match(line, /module\.(kubeadm|eks|aks|gke)\["[^"]+"\]/)) next
        mod = substr(line, RSTART, RLENGTH)
        kind = mod; sub(/^module\./, "", kind); sub(/\[.*/, "", kind)
        name = mod; sub(/^[^"]*"/, "", name); sub(/".*/, "", name)

        if (pending != "" && line ~ /with module\./) { state[name] = "fail"; lbl[name] = pending; pending = ""; next }
        if (!(name in kinds)) { set(name, kind, 0, 1, ""); lbl[name] = "waiting to start" }
        if (line ~ /: Refreshing state/ && step[name] == 0 && state[name] == "") {
            full = (kind == "kubeadm" ? 10 : (kind == "eks" ? 3 : 1))
            step[name] = full; steps[name] = full; lbl[name] = "already built - checking for changes"; existing[name] = 1
        }
        if (match(line, /\[[0-9hms]+ elapsed\]/)) { el[name] = substr(line, RSTART + 1, RLENGTH - 10) }

        if (kind == "kubeadm") {
            if (line ~ /(aws_instance|azurerm_linux_virtual_machine|google_compute_instance).*: Creating/) set(name, kind, 1, 10, "creating VMs")
            if (line ~ /bootstrap: Creating|Waiting for cloud-init/)  set(name, kind, 2, 10, "waiting for the VMs to boot")
            if (line ~ /Checking Ansible installation/)                set(name, kind, 3, 10, "installing Ansible")
            if (line ~ /TASK \[common/)                                set(name, kind, 4, 10, "preparing nodes (swap, kernel modules)")
            if (line ~ /TASK \[containerd/)                            set(name, kind, 5, 10, "installing containerd")
            if (line ~ /TASK \[kubernetes/)                            set(name, kind, 6, 10, "installing kubeadm, kubelet, kubectl")
            if (line ~ /TASK \[control-plane/)                         set(name, kind, 7, 10, "kubeadm init (control plane)")
            if (line ~ /TASK \[Install Flannel/)                       set(name, kind, 8, 10, "installing Flannel networking")
            if (line ~ /TASK \[worker/)                                set(name, kind, 9, 10, "joining client1 and client2")
            if (line ~ /Kubernetes Cluster Status/)                    set(name, kind, 10, 10, "waiting for nodes to be Ready")
            if (line ~ /bootstrap: Creation complete/)                 { state[name] = "ok"; step[name] = 10; lbl[name] = "ready" }
        } else if (kind == "eks") {
            if (line ~ /aws_iam_role\..*: Creating/)                   set(name, kind, 1, 3, "IAM roles")
            if (line ~ /aws_eks_cluster\.this: Creating/)              set(name, kind, 2, 3, "EKS control plane - AWS takes 10-15 min")
            if (line ~ /aws_eks_node_group\..*: Creating/)             set(name, kind, 3, 3, "EKS worker nodes - 2-5 min")
            if (line ~ /aws_eks_node_group\..*: Creation complete/)    { state[name] = "ok"; step[name] = 3; lbl[name] = "ready" }
        } else if (kind == "aks") {
            if (line ~ /azurerm_kubernetes_cluster\.this: Creating/)   set(name, kind, 1, 1, "AKS control plane and nodes - 5-10 min")
            if (line ~ /azurerm_kubernetes_cluster\.this: Creation complete/) { state[name] = "ok"; step[name] = 1; lbl[name] = "ready" }
        } else if (kind == "gke") {
            if (line ~ /google_container_cluster\.this: Creating/)     set(name, kind, 1, 1, "GKE control plane and nodes - 5-8 min")
            if (line ~ /google_container_cluster\.this: Creation complete/) { state[name] = "ok"; step[name] = 1; lbl[name] = "ready" }
        }
    }
    END {
        if (pending != "" && err == "") err = pending
        for (i = 1; i <= n; i++) { if (existing[order[i]]) ex++; if (step[order[i]] > 0 && !existing[order[i]]) fresh++ }
        if (n > 0 && ex == n) status = (status == "terraform apply" ? "clusters already built - checking for changes" : status)
        printf "S|%s|%s|%s|%d|%s\n", start, action, status, done, err
        printf "D|%d|%s\n", removed, cur
        for (i = 1; i <= n; i++) {
            c = order[i]
            printf "C|%s|%s|%d|%d|%s|%s|%s\n", c, kinds[c], step[c], steps[c], lbl[c], el[c], (state[c] == "" ? "run" : state[c])
        }
    }'
}

# ---------------------------------------------------------------
# Time estimates: your own last run of the same shape, else typical times
# ---------------------------------------------------------------

typical() { # cloud kind -> seconds
    case $1:$2 in
        aws:kubeadm) echo 420 ;;
        azure:kubeadm) echo 540 ;;
        gcp:kubeadm) echo 480 ;;
        aws:eks) echo 1260 ;;
        azure:aks) echo 660 ;;
        gcp:gke) echo 540 ;;
        *) echo 600 ;;
    esac
}

estimate() { # sandbox kubeadm-count managed-count managed-kind -> seconds
    local sb=$1 k=$2 m=$3 mkind=$4 cloud=${1%%[0-9]*} key t=0 v
    key="$cloud:k$k:m$m"
    v=$(awk -v k="$key" '$1 == k { v = $2 } END { print v }' "$HISTORY" 2>/dev/null)
    if [[ -n $v ]]; then
        echo "$v last"
        return
    fi
    ((k > 0)) && t=$(typical "$cloud" kubeadm)
    if ((m > 0)); then
        v=$(typical "$cloud" "$mkind")
        ((v > t)) && t=$v
    fi
    echo "$t typical"
}

to_secs() { # hh:mm:ss today -> epoch
    date -d "$1" +%s 2>/dev/null || date +%s
}

fmt_dur() { # seconds -> "7m 05s" / "45s"
    local s=$1
    ((s < 0)) && s=0
    if ((s >= 60)); then printf '%dm %02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

bar() { # step steps state -> ━━━━━━━─── (green when ready, cyan while running)
    local step=$1 steps=$2 state=$3 filled i done_part="" todo_part="" colour=36
    ((steps < 1)) && steps=1
    filled=$((step * 12 / steps))
    for ((i = 0; i < 12; i++)); do
        if ((i < filled)); then done_part+="━"; else todo_part+="─"; fi
    done
    case $state in ok) colour=32 ;; fail) colour=31 ;; esac
    printf '\033[%sm%s\033[2m%s\033[0m' "$colour" "$done_part" "$todo_part"
}

# ---------------------------------------------------------------
# Tips while you wait
# ---------------------------------------------------------------

TIPS=(
    "kubectl get events -A --sort-by=.lastTimestamp shows what a cluster is doing right now."
    "kubectl explain deployment.spec.strategy documents any field without leaving the terminal."
    "kubectl get pods -A -o wide shows which node every pod landed on."
    "kubectl auth can-i --list shows exactly what your current user is allowed to do."
    "kubectl debug node/<name> -it --image=busybox gives you a shell on a node without SSH."
    "kubectl top nodes needs metrics-server - a good first add-on to install."
    "kubectl config use-context <name> switches clusters; kubectl config get-contexts lists them."
    "kubectl rollout undo deployment/<name> rolls back to the previous version in seconds."
    "kubectl port-forward svc/<name> 8080:80 reaches a service without exposing it."
    "kubectl get all -n kube-system shows the pieces that make a cluster work."
    "A ServiceAccount token is just a JWT - paste one into jwt.io to see who it says you are."
    "RBAC is additive: there are no deny rules, only more or fewer permissions."
    "kubectl create deployment web --image=nginx --replicas=3 then kubectl expose deployment web --port=80"
    "Pod Security Admission: label a namespace pod-security.kubernetes.io/enforce=restricted to try it."
    "users.txt + ./up.sh shares these clusters with a teammate (admin, edit or view)."
    "./down.sh <sandbox> tears a sandbox down early - otherwise Pluralsight wipes it when it expires."
)
TIPS_KUBEADM=( # only shown while a kubeadm cluster is on screen
    "Flannel gives every node a /24 out of 10.244.0.0/16 and tunnels pod traffic over VXLAN (UDP 8472)."
    "kubeadm writes the control plane as static pods in /etc/kubernetes/manifests on master1."
    "etcd holds the whole cluster state - on master1: sudo ls /var/lib/etcd"
    "containerd is the runtime on the kubeadm nodes; on a node, sudo crictl ps lists the running containers."
)
CONTEXT_TIPS_EKS=(
    "Why is EKS slow? AWS builds a highly available control plane - API servers and etcd spread over 3 availability zones."
    "EKS nodes join through the aws-auth / access-entry mapping of their IAM role - that's the node role Terraform created."
    "EKS tokens are short-lived: kubectl calls 'aws eks get-token' on every request through the exec plugin."
)
CONTEXT_TIPS_KUBEADM=(
    "kubeadm init generates a CA and certificates for every control-plane component under /etc/kubernetes/pki."
    "Workers join with a bootstrap token: kubeadm token create --print-join-command makes a new one any time."
)
CONTEXT_TIPS_MANAGED=(
    "Managed control planes (AKS, GKE) are run by the cloud provider - you never see the master VMs."
)

# ---------------------------------------------------------------
# Render
# ---------------------------------------------------------------

SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
TICK=0
TIP_INDEX=$((RANDOM % ${#TIPS[@]}))
declare -A LAST_PLAIN # for non-terminal output: last line printed per cluster

render() {
    local now sb out="" any_busy=0 phases="" any_kubeadm=0
    now=$(date +%s)
    local width
    width=$(tput cols 2>/dev/null || echo 100)

    local pad=$((width - 33))
    ((pad < 1)) && pad=1
    out+=" ☸  Kubernetes clusters$(printf '%*s' "$pad" '')$(date +%H:%M:%S)\n\n"

    for sb in "${SANDBOXES[@]}"; do
        local s_line d_line start action status done err removed cur busy=0
        local -a clusters=()
        while IFS= read -r l; do
            case $l in
                S\|*) s_line=$l ;;
                D\|*) d_line=$l ;;
                C\|*) clusters+=("$l") ;;
            esac
        done < <(read_log "$sb")
        IFS='|' read -r _ start action status done err <<<"${s_line:-S|||starting|0|}"
        IFS='|' read -r _ removed cur <<<"${d_line:-D|0|}"
        is_busy "$sb" && busy=1
        ((EMBEDDED)) && ((done == 0)) && [[ -z $err ]] && busy=1
        ((busy)) && any_busy=1

        # header line for the sandbox
        local started elapsed="" head
        if [[ -n $start ]]; then
            started=$(to_secs "$start")
            elapsed=$((now - started))
        fi
        if [[ $action == destroy ]]; then
            if ((done)); then
                head="destroyed - $removed resources removed"
            elif ((busy)); then
                head="destroying · $(fmt_dur "${elapsed:-0}") · $removed removed${cur:+ · now: $cur}"
            else
                head="destroy stopped${err:+ - $err}"
            fi
            out+=" \033[1m$sb\033[0m  $head\n"
            continue
        fi

        local k=0 m=0 mkind="" c
        for c in "${clusters[@]}"; do
            IFS='|' read -r _ _ ckind _ <<<"$c"
            if [[ $ckind == kubeadm ]]; then k=$((k + 1)); any_kubeadm=1; else m=$((m + 1)); mkind=$ckind; fi
        done
        if ((done)); then
            head="\033[32mready\033[0m${elapsed:+ · took $(fmt_dur "$elapsed")}"
        elif ((busy)); then
            local est est_s est_src left
            est=$(estimate "$sb" "$k" "$m" "$mkind")
            est_s=${est% *}
            est_src=${est#* }
            left=$((est_s - ${elapsed:-0}))
            head="${start:+started ${start%:*} · }$(fmt_dur "${elapsed:-0}") elapsed"
            if [[ $status == "clusters already built"* ]]; then
                head+=" · $status"
            elif ((${#clusters[@]})); then
                if ((left > 60)); then
                    head+=" · about $(((left + 59) / 60)) min left"
                else
                    head+=" · any minute now"
                fi
                [[ $est_src == last ]] && head+=" (your last run: $(fmt_dur "$est_s"))"
            fi
            [[ $status == *retrying* || $status == *kubeconfigs* ]] && head+=" · $status"
        else
            head="\033[31mstopped\033[0m${err:+ - $err}"
        fi
        out+=" \033[1m$sb\033[0m  $head\n"

        for c in "${clusters[@]}"; do
            local cname ckind step steps label cel cstate icon
            IFS='|' read -r _ cname ckind step steps label cel cstate <<<"$c"
            case $cstate in
                ok) icon="\033[32m✓\033[0m" ;;
                fail) icon="\033[31m✗\033[0m" ;;
                *) if ((busy)); then icon=${SPIN[TICK % ${#SPIN[@]}]}; else icon="\033[33m•\033[0m"; fi ;;
            esac
            local line
            line=$(printf '%-12s %s %2d/%-2d %s' "$cname" "$(bar "$step" "$steps" "$cstate")" "$step" "$steps" "$label")
            [[ $cstate == run && -n $cel ]] && line+="  ($cel)"
            out+="   $icon ${line:0:$((width + 20))}\n"
            phases+=" $label"

            # non-terminal: print each change once
            if [[ ! -t 1 ]]; then
                local plain="$cname $step/$steps $label"
                if [[ ${LAST_PLAIN[$cname]:-} != "$plain" ]]; then
                    echo "$(date +%H:%M:%S) $plain"
                    LAST_PLAIN[$cname]=$plain
                fi
            fi
        done
        out+="\n"
    done

    # tips: every ~12 s, alternating with ones about what's happening now
    if ((TICK % 12 == 0)); then
        local -a ctx=()
        [[ $phases == *"EKS control plane"* ]] && ctx+=("${CONTEXT_TIPS_EKS[@]}")
        [[ $phases == *"kubeadm init"* || $phases == *"joining"* ]] && ctx+=("${CONTEXT_TIPS_KUBEADM[@]}")
        [[ $phases == *"AKS"* || $phases == *"GKE"* ]] && ctx+=("${CONTEXT_TIPS_MANAGED[@]}")
        local -a pool=("${TIPS[@]}")
        ((any_kubeadm)) && pool+=("${TIPS_KUBEADM[@]}")
        if ((${#ctx[@]})) && (((TICK / 12) % 2 == 1)); then
            TIP=${ctx[RANDOM % ${#ctx[@]}]}
        else
            TIP_INDEX=$(((TIP_INDEX + 1) % ${#pool[@]}))
            TIP=${pool[TIP_INDEX]}
        fi
    fi
    if ((any_busy)); then
        local wrapped
        wrapped=$(fold -s -w $((width - 5)) <<<"$TIP" | head -3 | sed '1!s/^/    /')
        out+=" 💡 ${wrapped//$'\n'/\\n}\n\n"
        if ((EMBEDDED)); then
            out+=" \033[2mCtrl-C stops the build safely (Terraform saves its state). Full log: .sandboxes/<sandbox>/log\033[0m\n"
        else
            out+=" \033[2mCtrl-C closes this view - the build keeps running. Full log: .sandboxes/<sandbox>/log\033[0m\n"
        fi
    fi

    RENDER_OUT=$out
    TICK=$((TICK + 1))
    ANY_BUSY=$any_busy
}

draw() { # redraw in place (terminal only)
    [[ -t 1 ]] || return 0
    printf '\033[H'
    printf '%b' "${RENDER_OUT//\\n/\\033[K\\n}"
    printf '\033[J'
}

# ---------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------

TIP=${TIPS[TIP_INDEX]}
ANY_BUSY=1

if [[ -t 1 ]]; then
    tput smcup 2>/dev/null # alternate screen: your scrollback comes back afterwards
    tput civis 2>/dev/null
    trap 'tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; exit 0' INT TERM
    trap 'tput cnorm 2>/dev/null; tput rmcup 2>/dev/null' EXIT
fi

while :; do
    render
    draw
    if ((!EMBEDDED && !ANY_BUSY)); then break; fi
    sleep 1
done

# Finished on its own (standalone): leave the final state on screen and notify
if [[ -t 1 ]]; then
    tput cnorm 2>/dev/null
    tput rmcup 2>/dev/null
    trap - EXIT
    printf '%b' "$RENDER_OUT"
fi
# Started by up.sh/down.sh: they print the results, the build sends the notification
[[ -n ${WATCH_ATTACHED:-} ]] && exit 0

summary=""
for sb in "${SANDBOXES[@]}"; do
    s=$(read_log "$sb" | grep '^S|')
    IFS='|' read -r _ _ action _ done err <<<"$s"
    if ((done)); then
        echo "✓ $sb ${action/build/built}"
        summary+="$sb ✓  "
    else
        echo "✗ $sb did not finish${err:+ - $err}"
        summary+="$sb ✗  "
    fi
done
notify "Kubernetes labs" "$summary"
