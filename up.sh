#!/usr/bin/env bash
#
# Build Kubernetes clusters in every Pluralsight sandbox filled in in labs.env
# (AWS, Azure and GCP; kubeadm and/or EKS/AKS/GKE).
#
#   ./up.sh                  every sandbox with credentials in labs.env
#   ./up.sh aws1 gcp2        just these
#
# Re-running is safe: an unchanged sandbox is brought up to date, a new one
# starts from clean state.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/access.sh"

# Stay under Pluralsight's 9 EC2 instance cap (stopped instances count too)
check_aws_capacity() {
    local sb=$1 kubeadm managed nodes total=0 ours=0 r
    local states=Name=instance-state-name,Values=pending,running,stopping,stopped
    kubeadm=$(cfg "$sb" KUBEADM)
    managed=$(cfg "$sb" MANAGED)
    nodes=$(cfg "$sb" NODES)
    local needed=$((${kubeadm:-3} * 3 + ${managed:-0} * ${nodes:-2}))

    for r in us-east-1 us-west-2; do
        total=$((total + $(aws ec2 describe-instances --region "$r" --filters "$states" \
            --query 'length(Reservations[].Instances[])' --output text)))
        # Ours = tagged with this sandbox, or an EKS node of one of its clusters
        # (EKS launches node instances itself, without our tags)
        ours=$((ours + $(aws ec2 describe-instances --region "$r" --filters "$states" \
            --query "length(Reservations[].Instances[] | [?Tags[?(Key=='Sandbox' && Value=='$sb') || (Key=='eks:cluster-name' && starts_with(Value, '$sb-'))]])" \
            --output text)))
    done
    local others=$((total - ours))
    if ((others + needed > 9)); then
        echo "[$sb] not enough room: $others other instance(s) already in this sandbox + $needed needed > 9."
        echo "[$sb] Terminate the other instances or lower ${sb^^}_KUBEADM / ${sb^^}_MANAGED in labs.env."
        return 1
    fi
}

# kubeadm: the API certificate only lists the private IP, so connect to the
# public IP and verify the cert as "kubernetes", a name kubeadm always includes.
write_kubeadm_kubeconfig() {
    local ctx=$1 ip=$2 pem=$3 conf
    # -n: don't let ssh read the caller's while-loop input
    conf=$(ssh -n -i "$pem" "${SSH_OPTS[@]}" "ubuntu@$ip" cat .kube/config)
    field() { awk -v k="$1:" '$1 == k { print $2; exit }' <<<"$conf"; }

    write_kubeconfig "$ctx" "https://$ip:6443" "$(field certificate-authority-data)" "    tls-server-name: kubernetes" "
    client-certificate-data: $(field client-certificate-data)
    client-key-data: $(field client-key-data)"
}

# EKS / AKS / GKE, from the "managed" Terraform output
write_managed_kubeconfig() {
    local ctx=$1 kind=$2 region=$3 server=$4 ca=$5 cert=$6 key=$7 user
    case $kind in
        aks)
            user="
    client-certificate-data: $cert
    client-key-data: $key"
            ;;
        eks)
            user="
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args: [eks, get-token, --cluster-name, $ctx, --region, $region, --output, json]
      env:
      - name: AWS_ACCESS_KEY_ID
        value: \"$AWS_ACCESS_KEY_ID\"
      - name: AWS_SECRET_ACCESS_KEY
        value: \"$AWS_SECRET_ACCESS_KEY\"
      interactiveMode: Never"
            ;;
        gke)
            user="
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: gke-gcloud-auth-plugin
      args: [--use_application_default_credentials]
      env:
      - name: GOOGLE_APPLICATION_CREDENTIALS
        value: \"$GOOGLE_APPLICATION_CREDENTIALS\"
      provideClusterInfo: true
      interactiveMode: Never"
            ;;
    esac
    write_kubeconfig "$ctx" "$server" "$ca" "" "$user"
}

write_kubeconfig() {
    local ctx=$1 server=$2 ca=$3 extra_cluster=$4 user=$5
    mkdir -p "$KUBE_DIR"
    (
        umask 077
        cat >"$KUBE_DIR/$ctx.yaml" <<KUBE
apiVersion: v1
kind: Config
clusters:
- name: $ctx
  cluster:
    server: $server
    certificate-authority-data: $ca
${extra_cluster}
users:
- name: $ctx-admin
  user:${user}
contexts:
- name: $ctx
  context:
    cluster: $ctx
    user: $ctx-admin
current-context: $ctx
KUBE
    )
}

deploy_sandbox() {
    local sb=$1 cloud name ip kind region server ca cert key
    cloud=$(cloud_of "$sb")
    use_sandbox "$sb"
    local -a vars
    mapfile -t vars < <(tf_vars "$sb")
    vars+=(-var "shared_cidrs=$(shared_cidrs_json)")

    if [[ $cloud == aws ]]; then
        check_aws_capacity "$sb"
    fi

    echo "[$sb] $(date +%T) terraform apply ${vars[*]}"
    if ! tf_in "$cloud" apply -auto-approve -input=false "${vars[@]}"; then
        # Usually a dropped SSH session during a kubeadm bootstrap. Its install
        # is safe to re-run, so give everything one more go.
        echo "[$sb] $(date +%T) apply failed - retrying once"
        tf_in "$cloud" apply -auto-approve -input=false "${vars[@]}"
    fi

    echo "[$sb] $(date +%T) writing kubeconfigs and sharing access"
    rm -f "$KUBE_DIR/$sb"-*.yaml "$ACCESS_DIR/$sb"-*.tokens
    while read -r name ip || [[ -n $name ]]; do  # last line has no newline
        write_kubeadm_kubeconfig "$name" "$ip" "$KEY_DIR/$sb.pem"
        grant_kubeadm_access "$name" "$ip" "$KEY_DIR/$sb.pem" </dev/null
    done < <(tf_in "$cloud" output -raw kubeadm)
    while read -r name kind region server ca cert key || [[ -n $name ]]; do
        write_managed_kubeconfig "$name" "$kind" "$region" "$server" "$ca" "$cert" "$key"
        grant_managed_access "$name" </dev/null
    done < <(tf_in "$cloud" output -raw managed)

    echo "[$sb] $(date +%T) done"
}

# Runs at the end of the background build: kubeconfigs, bundles, summary
finish_up() {
    merge_kubeconfigs
    build_bundles

    echo
    if [[ -f $MERGED_KUBECONFIG ]]; then
        echo "Clusters (kubeconfig: $MERGED_KUBECONFIG)"
        for ctx in $(KUBECONFIG=$MERGED_KUBECONFIG kubectl config get-contexts -o name | sort); do
            nodes=$(KUBECONFIG=$MERGED_KUBECONFIG kubectl --context "$ctx" --request-timeout=15s \
                get nodes --no-headers 2>/dev/null || true)
            printf "  %-14s %s/%s nodes Ready\n" "$ctx" \
                "$(awk '$2 == "Ready"' <<<"$nodes" | grep -c . || true)" "$(grep -c . <<<"$nodes" || true)"
        done
        echo
        echo "  export KUBECONFIG=$MERGED_KUBECONFIG"
        echo "  kubectl --context <name> get nodes"
    fi
    print_bundles
}

select_sandboxes "$@"
load_users
run_sandboxes deploy_sandbox finish_up

if ((${#FAILED[@]})); then
    echo
    echo "Failed: ${FAILED[*]} - fix labs.env if needed, then re-run: ./up.sh ${FAILED[*]}"
fi
((${#FAILED[@]} == 0 && RUN_FAILED == 0)) || exit 1
