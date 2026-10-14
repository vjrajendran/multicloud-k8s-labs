# up.sh pipes this into bash after USERS=... and SSH_USERS=... lines:
#   USERS      one "name role ssh-public-key" per line (role: admin | edit | view)
#   SSH_USERS  1 = kubeadm master1 (run there as "ubuntu"): also manage SSH accounts
#              0 = managed cluster (run on your laptop with KUBECONFIG set)
#
# For each user: a ServiceAccount + token bound to a ClusterRole and, on
# kubeadm masters, a Linux account whose SSH key can only open a tunnel to the
# API server. Users no longer listed are removed. Prints "TOKEN <name> <token>".

set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

NS=lab-access
LIST=/etc/lab-access-users     # Linux accounts this script created
declare -A CLUSTER_ROLE=([admin]=cluster-admin [edit]=edit [view]=view)

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

names=()
names_kept=()   # accounts that could not be removed yet
while read -r name role key; do
    [[ -n $name ]] || continue
    names+=("$name")

    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $name
  namespace: $NS
  labels: {lab-access/managed: "true", lab-access/user: "$name"}
---
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: $name-token
  namespace: $NS
  labels: {lab-access/managed: "true", lab-access/user: "$name"}
  annotations: {kubernetes.io/service-account.name: "$name"}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lab-access-$name-$role
  labels: {lab-access/managed: "true", lab-access/user: "$name", lab-access/role: "$role"}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${CLUSTER_ROLE[$role]}
subjects:
- kind: ServiceAccount
  name: $name
  namespace: $NS
YAML
    # Role changed since the last run: drop the old binding
    kubectl delete clusterrolebinding -l "lab-access/user=$name,lab-access/role!=$role" \
        --ignore-not-found >/dev/null

    # Linux account for the SSH tunnel - no shell, no sudo
    ((SSH_USERS)) || continue
    if ! id "$name" >/dev/null 2>&1; then
        sudo useradd --create-home --shell /usr/sbin/nologin "$name"
    elif ! grep -qx "$name" "$LIST" 2>/dev/null; then
        echo "error: '$name' is already an account on master1 - use another name in users.txt" >&2
        exit 1
    fi
    sudo install -d -m 700 -o "$name" -g "$name" "/home/$name/.ssh"
    echo "restrict,port-forwarding,permitopen=\"127.0.0.1:6443\",command=\"/usr/sbin/nologin\" $key" |
        sudo tee "/home/$name/.ssh/authorized_keys" >/dev/null
    sudo chown "$name:$name" "/home/$name/.ssh/authorized_keys"
    sudo chmod 600 "/home/$name/.ssh/authorized_keys"
done <<<"$USERS"

# Revoke everyone who is no longer in users.txt
selector="lab-access/managed=true"
if ((${#names[@]})); then
    selector+=",lab-access/user notin ($(IFS=,; echo "${names[*]}"))"
fi
kubectl -n "$NS" delete serviceaccount,secret -l "$selector" --ignore-not-found >/dev/null
kubectl delete clusterrolebinding -l "$selector" --ignore-not-found >/dev/null

if ((SSH_USERS)); then
    if [[ -f $LIST ]]; then
        while read -r old; do
            if [[ -n $old && " ${names[*]} " != *" $old "* ]]; then
                # --force: their tunnel session may still be closing
                sudo pkill -KILL -u "$old" || true
                if ! sudo userdel --force --remove "$old" 2>/dev/null && id "$old" >/dev/null 2>&1; then
                    echo "warning: could not remove account $old - will retry next run" >&2
                    names_kept+=("$old")
                fi
            fi
        done <"$LIST"
    fi
    printf '%s\n' "${names[@]}" "${names_kept[@]}" | sudo tee "$LIST" >/dev/null
fi

# Tokens are filled in asynchronously by the token controller
for name in "${names[@]}"; do
    token=""
    for _ in $(seq 1 30); do
        token=$(kubectl -n "$NS" get secret "$name-token" -o jsonpath='{.data.token}' | base64 -d)
        [[ -n $token ]] && break
        sleep 1
    done
    [[ -n $token ]] || { echo "error: no token issued for $name" >&2; exit 1; }
    echo "TOKEN $name $token"
done
