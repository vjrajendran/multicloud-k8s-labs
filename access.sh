# Sharing the clusters with other people - sourced by up.sh.
#
# users.txt, one person per line:
#   <name>  <role>  <public ip or CIDR, comma-separated>  <ssh public key>
# role: admin (cluster-admin) | edit (change workloads) | view (read-only)

USERS_FILE=$ROOT/users.txt
ACCESS_DIR=$RUN_DIR/access             # tokens per cluster
SHARE_DIR=$ROOT/share                  # bundles to send to each person

USER_NAMES=() USER_ROLES=() USER_IPS=() USER_KEYS=()

load_users() {
    [[ -f $USERS_FILE ]] || return 0
    local line name role ips key n=0 reserved=" root ubuntu admin sudo daemon bin sys sync nobody sshd syslog lxd www-data "
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        line=${line%%#*}
        read -r name role ips key <<<"$line"
        [[ -n ${name:-} ]] || continue

        [[ $name =~ ^[a-z][a-z0-9-]{1,30}$ && $reserved != *" $name "* ]] ||
            die "users.txt line $n: name '$name' must be lowercase letters/digits/-, and not a system account"
        [[ $role == admin || $role == edit || $role == view ]] ||
            die "users.txt line $n: role must be admin, edit or view (got '$role')"
        [[ $ips =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?,?)+$ ]] ||
            die "users.txt line $n: '$ips' is not an IPv4 address or CIDR"
        [[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+ ]] ||
            die "users.txt line $n: the last field must be an SSH public key (ssh-ed25519 AAAA...)"
        [[ " ${USER_NAMES[*]} " != *" $name "* ]] || die "users.txt line $n: '$name' is listed twice"

        USER_NAMES+=("$name") USER_ROLES+=("$role") USER_IPS+=("$ips") USER_KEYS+=("$key")
    done <"$USERS_FILE"
}

# Terraform list of every shared user's IP as a /32 (or the CIDR given)
shared_cidrs_json() {
    local ips ip out=()
    for ips in "${USER_IPS[@]}"; do
        for ip in ${ips//,/ }; do
            [[ $ip == */* ]] || ip=$ip/32
            out+=("\"$ip\"")
        done
    done
    echo "[$(IFS=,; echo "${out[*]}")]"
}

access_payload() {
    local ssh_users=$1 users="" i
    for i in "${!USER_NAMES[@]}"; do
        users+="${USER_NAMES[i]} ${USER_ROLES[i]} ${USER_KEYS[i]}"$'\n'
    done
    printf 'USERS=%q\nSSH_USERS=%s\n' "$users" "$ssh_users"
    cat "$ROOT/remote/grant-access.sh"
}

save_tokens() {
    local ctx=$1 out=$2
    mkdir -p "$ACCESS_DIR"
    (umask 077 && grep '^TOKEN ' <<<"$out" | cut -d' ' -f2- >"$ACCESS_DIR/$ctx.tokens" || true)
    echo "[$ctx] access shared with ${#USER_NAMES[@]} user(s)"
}

# kubeadm: runs on master1 over SSH (also creates the tunnel-only SSH accounts).
# A failure only skips sharing for this cluster.
grant_kubeadm_access() {
    local ctx=$1 ip=$2 pem=$3 out
    if out=$(access_payload 1 | ssh -i "$pem" "${SSH_OPTS[@]}" "ubuntu@$ip" 'bash -s'); then
        save_tokens "$ctx" "$out"
    else
        echo "[$ctx] WARNING: could not share access - see the error above"
    fi
}

# EKS / AKS / GKE: runs here with the cluster's admin kubeconfig
grant_managed_access() {
    local ctx=$1 out
    if out=$(access_payload 0 | KUBECONFIG=$KUBE_DIR/$ctx.yaml bash -s); then
        save_tokens "$ctx" "$out"
    else
        echo "[$ctx] WARNING: could not share access - see the error above"
    fi
}

# Local port each person's tunnel uses for a kubeadm cluster:
# 16000 + cloud (aws 1, azure 2, gcp 3) x 100 + sandbox x 10 + cluster, e.g. gcp2-k1 -> 16321
tunnel_port() {
    local ctx=$1 sb cloud k c
    sb=${ctx%%-*}
    cloud=${sb%%[0-9]*}
    k=${ctx##*-k}
    case $cloud in aws) c=1 ;; azure) c=2 ;; gcp) c=3 ;; esac
    echo $((16000 + c * 100 + ${sb#"$cloud"} * 10 + k))
}

# share/<name>/: kubeconfig.yaml, tunnel.sh, README.txt
build_bundles() {
    rm -rf "${SHARE_DIR:?}"
    ((${#USER_NAMES[@]})) || return 0

    local i name role file ctx server ca token port clusters users contexts tunnels first kubeadm_ctx managed_ctx
    for i in "${!USER_NAMES[@]}"; do
        name=${USER_NAMES[i]} role=${USER_ROLES[i]}
        clusters="" users="" contexts="" tunnels="" first="" kubeadm_ctx="" managed_ctx=""

        for file in "$KUBE_DIR"/*.yaml; do
            [[ -f $file ]] || continue
            ctx=$(basename "$file" .yaml)
            token=$(awk -v n="$name" '$1 == n { print $2 }' "$ACCESS_DIR/$ctx.tokens" 2>/dev/null)
            [[ -n $token ]] || continue
            server=$(awk '$1 == "server:" { print $2; exit }' "$file")
            ca=$(awk '$1 == "certificate-authority-data:" { print $2; exit }' "$file")
            first=${first:-$ctx}

            users+="- name: $ctx-$name
  user:
    token: $token
"
            if grep -q 'tls-server-name: kubernetes' "$file"; then
                # kubeadm: direct + SSH tunnel through master1
                local ip=${server#https://}
                ip=${ip%:6443}
                port=$(tunnel_port "$ctx")
                kubeadm_ctx+=" $ctx"
                clusters+="- name: $ctx
  cluster:
    server: $server
    tls-server-name: kubernetes
    certificate-authority-data: $ca
- name: $ctx-tunnel
  cluster:
    server: https://127.0.0.1:$port
    tls-server-name: kubernetes
    certificate-authority-data: $ca
"
                contexts+="- name: $ctx
  context: {cluster: $ctx, user: $ctx-$name}
- name: $ctx-tunnel
  context: {cluster: $ctx-tunnel, user: $ctx-$name}
"
                tunnels+="ssh \"\${OPTS[@]}\" -L $port:127.0.0.1:6443 $name@$ip &   # $ctx-tunnel
"
            else
                # EKS / AKS / GKE: direct only
                managed_ctx+=" $ctx"
                clusters+="- name: $ctx
  cluster:
    server: $server
    certificate-authority-data: $ca
"
                contexts+="- name: $ctx
  context: {cluster: $ctx, user: $ctx-$name}
"
            fi
        done
        [[ -n $first ]] || continue

        local dir=$SHARE_DIR/$name
        (
            umask 077
            mkdir -p "$dir"
            cat >"$dir/kubeconfig.yaml" <<KUBE
apiVersion: v1
kind: Config
clusters:
${clusters}users:
${users}contexts:
${contexts}current-context: $first
KUBE

            if [[ -n $tunnels ]]; then
                cat >"$dir/tunnel.sh" <<TUNNEL
#!/usr/bin/env bash
# Opens an SSH tunnel to every kubeadm cluster so the "-tunnel" contexts work.
# Keep it running; Ctrl-C closes the tunnels.
#   ./tunnel.sh [path to your SSH private key]
KEY=\${1:-\$HOME/.ssh/id_ed25519}
OPTS=(-i "\$KEY" -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
trap 'kill 0' EXIT
${tunnels}echo "Tunnels open - use the -tunnel contexts. Ctrl-C to close."
wait
TUNNEL
                chmod 700 "$dir/tunnel.sh"
            fi

            {
                echo "Kubernetes access for $name (role: $role) - generated $(date '+%Y-%m-%d %H:%M')"
                echo
                echo "These clusters run in temporary lab sandboxes. Expect a new bundle each day."
                echo "Keep kubeconfig.yaml private - it contains your access tokens."
                echo
                echo "    export KUBECONFIG=\$PWD/kubeconfig.yaml"
                echo "    kubectl config get-contexts"
                echo "    kubectl --context $first get nodes"
                echo
                echo "Access is allowed from: ${USER_IPS[i]}"
                [[ -n $managed_ctx ]] && echo "Managed clusters (EKS/AKS/GKE):$managed_ctx"
                if [[ -n $kubeadm_ctx ]]; then
                    echo "kubeadm clusters:$kubeadm_ctx"
                    echo
                    echo "If a kubeadm context says \"x509: certificate signed by unknown authority\""
                    echo "or times out (common on corporate VPNs that inspect TLS), use the SSH tunnel:"
                    echo
                    echo "    ./tunnel.sh ~/.ssh/<your private key>     # keep it running"
                    echo "    kubectl --context <name>-tunnel get nodes  # in another terminal"
                    echo
                    echo "SSH only allows the tunnel - there is no shell on the servers."
                fi
            } >"$dir/README.txt"
        )
    done
}

print_bundles() {
    ((${#USER_NAMES[@]})) || return 0
    local total i got
    total=$(find "$KUBE_DIR" -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l)
    echo
    echo "Shared access (send each person their folder):"
    for i in "${!USER_NAMES[@]}"; do
        got=$(grep -lw "^${USER_NAMES[i]}" "$ACCESS_DIR"/*.tokens 2>/dev/null | wc -l)
        if [[ -f $SHARE_DIR/${USER_NAMES[i]}/kubeconfig.yaml ]]; then
            printf "  %-12s %-6s share/%s/  (%s of %s clusters)\n" "${USER_NAMES[i]}" "${USER_ROLES[i]}" "${USER_NAMES[i]}" "$got" "$total"
        else
            printf "  %-12s %-6s (no clusters - check the logs)\n" "${USER_NAMES[i]}" "${USER_ROLES[i]}"
        fi
    done
}
