#!/usr/bin/env bash
#
# Public demo website: load balancer -> Traefik ingress controller -> Ingress
# -> nginx (3 pods).
#
#   examples/web-demo/demo.sh aws1-eks1           deploy it and print the public URL
#   examples/web-demo/demo.sh aws1-k1             same on a kubeadm cluster (see below)
#   examples/web-demo/demo.sh aws1-eks1 delete    remove it
#
# Traefik's Service is type LoadBalancer everywhere, so Kubernetes asks the
# cloud for a load balancer:
#   EKS / AKS / GKE   the cloud's controller is built in
#   kubeadm (AWS)     needs the AWS cloud controller: set <SANDBOX>_CLOUD_LB=1
#                     in labs.env and run ./up.sh <sandbox> once

set -euo pipefail

TRAEFIK_CHART_VERSION=41.7.1 # Traefik v3.7

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$DIR/../.." && pwd)
ctx=${1:?usage: demo.sh <context> [delete]   e.g. demo.sh aws1-eks1}
action=${2:-up}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/multicloud.yaml}
[[ -d $HOME/.local/bin ]] && PATH=$HOME/.local/bin:$PATH

k() { kubectl --context "$ctx" "$@"; }

sb=${ctx%%-*}
cloud=${sb%%[0-9]*}
helm_args=()

case $ctx in
    *-eks[0-9]*)
        kind=managed
        # an AWS Network Load Balancer (dots in the key must be escaped for --set)
        helm_args=(--set service.spec.type=LoadBalancer
            --set-string 'service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb')
        ;;
    *-aks[0-9]* | *-gke[0-9]*)
        kind=managed
        helm_args=(--set service.spec.type=LoadBalancer)
        ;;
    *-k[0-9]*)
        kind=kubeadm
        if [[ $cloud != aws ]]; then
            echo "$ctx: LoadBalancer Services on kubeadm clusters are set up for AWS only so far."
            exit 1
        fi
        if [[ $action != delete ]] && ! k -n kube-system get daemonset aws-cloud-controller-manager >/dev/null 2>&1; then
            echo "$ctx has no AWS cloud controller yet, so a LoadBalancer Service would stay <pending>."
            echo "Add this to labs.env and run ./up.sh $sb (a few minutes, nothing is rebuilt):"
            echo "    ${sb^^}_CLOUD_LB=1"
            exit 1
        fi
        # same Network Load Balancer as on EKS - created by the cloud controller
        helm_args=(--set service.spec.type=LoadBalancer
            --set-string 'service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=nlb')
        ;;
    *) echo "Unknown context '$ctx' (kubectl config get-contexts lists them)"; exit 1 ;;
esac

if [[ $action == delete ]]; then
    echo "Removing the demo from $ctx..."
    k delete -f "$DIR/web.yaml" --ignore-not-found --wait=true >/dev/null
    helm --kube-context "$ctx" uninstall traefik -n traefik --wait >/dev/null 2>&1 || true
    k delete namespace traefik --ignore-not-found --wait=true >/dev/null
    echo "Done - the load balancer is being deleted."
    exit 0
fi

echo "1/4  Traefik ingress controller, Service type LoadBalancer"
helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
helm repo update traefik >/dev/null
helm upgrade --install traefik traefik/traefik --kube-context "$ctx" \
    --namespace traefik --create-namespace --version "$TRAEFIK_CHART_VERSION" \
    "${helm_args[@]}" --wait --timeout 5m >/dev/null

echo "2/4  Website: 3 nginx pods, a Service and an Ingress"
k apply -f "$DIR/web.yaml" >/dev/null
k -n web-demo rollout status deployment/web --timeout=3m >/dev/null

echo "3/4  Waiting for the load balancer's public address"
addr=""
for _ in $(seq 1 60); do
    addr=$(k -n traefik get service traefik \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}')
    [[ -n $addr ]] && break
    sleep 5
done
if [[ -z $addr ]]; then
    echo "No address after 5 minutes. What Kubernetes says:"
    k -n traefik describe service traefik | sed -n '/Events:/,$p'
    exit 1
fi
url="http://$addr/"
echo "     $(k -n traefik get service traefik --no-headers | awk '{print "type " $2 ", EXTERNAL-IP " $4}')"

echo "4/4  Waiting until $url answers (a new load balancer needs 2-4 minutes for DNS and health checks)"
for i in $(seq 1 72); do
    if curl -fsS --max-time 5 "$url" 2>/dev/null | grep -q 'Hello from Kubernetes'; then
        echo
        echo "✓ Your website is live:  $url"
        echo
        echo "  Refresh it a few times - the pod name changes as requests are spread"
        echo "  over the 3 replicas. From a terminal:"
        echo "    for i in 1 2 3 4 5; do curl -s $url | grep -o 'web-[a-z0-9-]*'; done"
        echo
        echo "  Remove it:  examples/web-demo/demo.sh $ctx delete"
        exit 0
    fi
    ((i % 6 == 0)) && echo "     still waiting ($((i * 5))s)..."
    sleep 5
done
echo "$url isn't answering yet - try it again in a few minutes."
exit 1
