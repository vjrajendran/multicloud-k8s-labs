# Shared by up.sh and down.sh

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TF_ROOT=$ROOT/terraform
RUN_DIR=$ROOT/.sandboxes               # per-sandbox logs, identity, cloud logins
KEY_DIR=$ROOT/keys
KUBE_DIR=$HOME/.kube/multicloud        # one kubeconfig per cluster
MERGED_KUBECONFIG=$HOME/.kube/multicloud.yaml
LABS_ENV=${LABS_ENV:-$ROOT/labs.env}
CLOUDS=(aws azure gcp)
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)

# Never pick up credentials from your shell - each sandbox gets its own
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
      ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_TENANT_ID ARM_SUBSCRIPTION_ID AZURE_CONFIG_DIR \
      GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CREDENTIALS CLOUDSDK_CONFIG TF_WORKSPACE

# Linux CLIs installed in your home directory win over Windows ones on the WSL PATH
[[ -x $HOME/.venvs/azure-cli/bin/az ]] && PATH=$HOME/.venvs/azure-cli/bin:$PATH
[[ -d $HOME/google-cloud-sdk/bin ]] && PATH=$HOME/google-cloud-sdk/bin:$PATH

die() {
    echo "$*" >&2
    exit 1
}

if [[ ! -f $LABS_ENV ]]; then
    die "labs.env not found - run: cp labs.env.example labs.env  and fill in today's sandboxes"
fi
# Only comments, blank lines and NAME=value (no spaces, $ or backticks in the
# value) - catches terminal output or other text pasted into the file
bad=$(grep -nvE '^[[:space:]]*(#.*)?$|^[A-Za-z_][A-Za-z0-9_]*=('"'"'[^'"'"']*'"'"'|"[^"$`]*"|[^[:space:]'"'"'"$`]*)[[:space:]]*(#.*)?$' "$LABS_ENV" | cut -c1-70 || true)
if [[ -n $bad ]]; then
    echo "$LABS_ENV has lines that aren't NAME=value - remove them and run again:" >&2
    echo "$bad" | sed 's/^/    line /' >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$LABS_ENV"

cloud_of() { echo "${1%%[0-9]*}"; }

# cfg aws1 ACCESS_KEY_ID  ->  value of AWS1_ACCESS_KEY_ID
cfg() {
    local v="${1^^}_$2"
    echo "${!v:-}"
}

tf_in() {
    local cloud=$1
    shift
    terraform -chdir="$TF_ROOT/$cloud" "$@"
}

sandbox_enabled() {
    case $(cloud_of "$1") in
        aws) [[ -n $(cfg "$1" ACCESS_KEY_ID) ]] ;;
        azure) [[ -n $(cfg "$1" CLIENT_ID) || $(cfg "$1" LOGIN) == device ]] ;;
        gcp) [[ -n $(cfg "$1" PROJECT) ]] ;;
        *) return 1 ;;
    esac
}

# Sandboxes named on the command line, or every one with credentials in labs.env
select_sandboxes() {
    SANDBOXES=()
    local sb c n
    if (($#)); then
        for sb in "$@"; do
            case $(cloud_of "$sb") in
                aws | azure | gcp) ;;
                *) die "Unknown sandbox '$sb' - names are aws1, azure2, gcp3, ..." ;;
            esac
            sandbox_enabled "$sb" || die "$sb has no credentials in labs.env"
            SANDBOXES+=("$sb")
        done
    else
        for c in "${CLOUDS[@]}"; do
            for n in $(seq 1 9); do
                if sandbox_enabled "$c$n"; then SANDBOXES+=("$c$n"); fi
            done
        done
    fi
    ((${#SANDBOXES[@]})) || die "No sandboxes with credentials in labs.env"
}

# Point the cloud CLIs and Terraform at one sandbox (call inside a subshell)
use_sandbox() {
    local sb=$1 dir=$RUN_DIR/$1 key
    export TF_WORKSPACE=$sb
    case $(cloud_of "$sb") in
        aws)
            export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION
            AWS_ACCESS_KEY_ID=$(cfg "$sb" ACCESS_KEY_ID)
            AWS_SECRET_ACCESS_KEY=$(cfg "$sb" SECRET_ACCESS_KEY)
            AWS_REGION=$(cfg "$sb" REGION)
            AWS_REGION=${AWS_REGION:-us-east-1}
            ;;
        azure)
            if [[ -n $(cfg "$sb" CLIENT_ID) ]]; then
                export ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_TENANT_ID
                ARM_CLIENT_ID=$(cfg "$sb" CLIENT_ID)
                ARM_CLIENT_SECRET=$(cfg "$sb" CLIENT_SECRET)
                ARM_TENANT_ID=$(cfg "$sb" TENANT_ID)
                [[ -n $ARM_TENANT_ID ]] || ARM_TENANT_ID=$(cat "$dir/tenant" 2>/dev/null || true)
            else
                export AZURE_CONFIG_DIR=$dir/azure
            fi
            export ARM_SUBSCRIPTION_ID
            ARM_SUBSCRIPTION_ID=$(cat "$dir/subscription" 2>/dev/null || cfg "$sb" SUBSCRIPTION_ID)
            ;;
        gcp)
            key=$(cfg "$sb" CREDENTIALS)
            export CLOUDSDK_CONFIG=$dir/gcloud
            export GOOGLE_APPLICATION_CREDENTIALS=${key:-$CLOUDSDK_CONFIG/application_default_credentials.json}
            ;;
    esac
}

# Terraform -var arguments from labs.env, one per line
tf_vars() {
    local sb=$1 v
    v=$(cfg "$sb" KUBEADM) && [[ -n $v ]] && printf '%s\n' -var "kubeadm_clusters=$v"
    v=$(cfg "$sb" MANAGED) && [[ -n $v ]] && printf '%s\n' -var "managed_clusters=$v"
    v=$(cfg "$sb" NODES) && [[ -n $v ]] && printf '%s\n' -var "managed_node_count=$v"
    case $(cloud_of "$sb") in
        aws)
            v=$(cfg "$sb" REGION) && [[ -n $v ]] && printf '%s\n' -var "region=$v"
            ;;
        azure)
            v=$(cfg "$sb" REGION) && [[ -n $v ]] && printf '%s\n' -var "location=$v"
            v=$(cfg "$sb" RESOURCE_GROUP)
            [[ -n $v ]] || v=$(cat "$RUN_DIR/$sb/resource_group" 2>/dev/null || true)
            [[ -n $v ]] && printf '%s\n' -var "resource_group=$v"
            ;;
        gcp)
            printf '%s\n' -var "project=$(cfg "$sb" PROJECT)"
            v=$(cfg "$sb" REGION) && [[ -n $v ]] && printf '%s\n' -var "region=$v"
            ;;
    esac
    return 0
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$2"
}

# --- Azure lookups for a service principal (curl only, no Azure CLI) ---

# Tenant ID for a domain, e.g. the part after @ in the sandbox username
azure_tenant_for() {
    curl -fs --max-time 15 "https://login.microsoftonline.com/$1/v2.0/.well-known/openid-configuration" |
        python3 -I -c 'import json, sys; print(json.load(sys.stdin)["issuer"].split("/")[3])' 2>/dev/null
}

# ARM access token for a service principal (the secret goes in on stdin, not argv)
azure_sp_token() {
    local tenant=$1 client_id=$2 secret=$3
    printf '%s' "$secret" |
        curl -fs --max-time 20 "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" \
            --data-urlencode "client_id=$client_id" \
            --data-urlencode "client_secret@-" \
            --data-urlencode "scope=https://management.azure.com/.default" \
            --data-urlencode "grant_type=client_credentials" |
        python3 -I -c 'import json, sys; print(json.load(sys.stdin)["access_token"])' 2>/dev/null
}

azure_arm_get() {
    printf 'Authorization: Bearer %s\n' "$1" |
        curl -fsS --max-time 20 -H @- "https://management.azure.com$2"
}

# Pluralsight wipes a sandbox when it expires, so its old state is useless
reset_sandbox() {
    local sb=$1
    rm -f "$TF_ROOT/$(cloud_of "$sb")/terraform.tfstate.d/$sb"/terraform.tfstate*
    rm -f "$KEY_DIR/$sb.pem" "$KUBE_DIR/$sb"-*.yaml "$RUN_DIR/access/$sb"-*.tokens
    rm -rf "${RUN_DIR:?}/$sb/gcloud"
}

# Check credentials (signing in where a cloud needs a browser), and start
# from clean state when the credentials belong to a new sandbox.
# Runs one sandbox at a time because it may prompt.
prepare_sandbox() {
    local sb=$1 cloud dir identity tenant az_path
    cloud=$(cloud_of "$sb")
    dir=$RUN_DIR/$sb
    mkdir -p "$dir"
    use_sandbox "$sb"

    case $cloud in
        aws)
            need aws "Install the AWS CLI (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)"
            # Catch keys mangled by copy/paste (e.g. shortened with "…" in a chat app)
            [[ $AWS_ACCESS_KEY_ID =~ ^[A-Z0-9]{20}$ ]] ||
                die "$sb: ${sb^^}_ACCESS_KEY_ID should be 20 letters/digits - it has ${#AWS_ACCESS_KEY_ID}. Copy it again from the sandbox page."
            local odd=${AWS_SECRET_ACCESS_KEY//[A-Za-z0-9\/+]/}
            [[ $AWS_SECRET_ACCESS_KEY =~ ^[A-Za-z0-9/+]{40}$ ]] ||
                die "$sb: ${sb^^}_SECRET_ACCESS_KEY should be 40 characters - it has ${#AWS_SECRET_ACCESS_KEY}${odd:+, including '$odd'}. It was probably shortened when copied - copy it again from the sandbox page."
            identity=$(aws sts get-caller-identity --query Account --output text) ||
                die "$sb: AWS rejected the keys - paste today's keys into labs.env"
            ;;
        azure)
            rm -f "$dir/resource_group" # looked up again below
            if [[ -n ${ARM_CLIENT_ID:-} ]]; then
                [[ -n $ARM_CLIENT_SECRET ]] || die "$sb: ${sb^^}_CLIENT_SECRET is empty in labs.env"

                # Tenant: from labs.env, else from the sandbox username's domain
                tenant=$(cfg "$sb" TENANT_ID)
                if [[ -z $tenant ]]; then
                    local user
                    user=$(cfg "$sb" USERNAME)
                    [[ $user == *@* ]] ||
                        die "$sb: add ${sb^^}_USERNAME (the sandbox username, e.g. cloud_user_...@domain) to labs.env"
                    tenant=$(azure_tenant_for "${user#*@}") ||
                        die "$sb: could not look up the Azure tenant for ${user#*@} - check ${sb^^}_USERNAME"
                fi
                echo "$tenant" >"$dir/tenant"

                local token
                token=$(azure_sp_token "$tenant" "$ARM_CLIENT_ID" "$ARM_CLIENT_SECRET") ||
                    die "$sb: Azure rejected the client ID / secret - copy them again from the sandbox page"

                identity=$(cfg "$sb" SUBSCRIPTION_ID)
                [[ -n $identity ]] || identity=$(azure_arm_get "$token" "/subscriptions?api-version=2022-12-01" |
                    python3 -I -c 'import json, sys; s = [x["subscriptionId"] for x in json.load(sys.stdin)["value"]]; print(s[0]) if len(s) == 1 else sys.exit(f"expected 1 subscription, found {len(s)}")') ||
                    die "$sb: could not find the sandbox subscription - set ${sb^^}_SUBSCRIPTION_ID in labs.env"

                # The sandbox's one usable resource group (AKS adds MC_* ones)
                if [[ -z $(cfg "$sb" RESOURCE_GROUP) ]]; then
                    azure_arm_get "$token" "/subscriptions/$identity/resourcegroups?api-version=2021-04-01" |
                        python3 -I -c 'import json, sys
g = [x["name"] for x in json.load(sys.stdin)["value"] if not x["name"].startswith("MC_") and x["name"] != "NetworkWatcherRG"]
print(g[0]) if len(g) == 1 else sys.exit(f"expected 1 resource group, found {len(g)}: {g}")' >"$dir/resource_group" ||
                        die "$sb: could not pick the sandbox resource group - set ${sb^^}_RESOURCE_GROUP in labs.env"
                fi
            else
                az_path=$(command -v az || true)
                if [[ -z $az_path || $az_path == /mnt/* ]]; then
                    die "$sb: needs the Linux Azure CLI (the Windows one can't keep separate logins per sandbox):
    python3 -m venv ~/.venvs/azure-cli && ~/.venvs/azure-cli/bin/pip install azure-cli"
                fi
                if ! az account get-access-token --output none 2>/dev/null; then
                    echo ">>> $sb: sign in with this Azure sandbox's username and password"
                    tenant=$(cfg "$sb" TENANT_ID)
                    az login --use-device-code ${tenant:+--tenant "$tenant"} --output none
                fi
                identity=$(cfg "$sb" SUBSCRIPTION_ID)
                [[ -n $identity ]] || identity=$(az account show --query id --output tsv)
            fi
            echo "$identity" >"$dir/subscription"
            ;;
        gcp)
            identity=$(cfg "$sb" PROJECT)
            ;;
    esac

    if [[ "$(cat "$dir/identity" 2>/dev/null)" != "$cloud:$identity" ]]; then
        echo "$sb: new sandbox ($cloud:$identity) - starting from clean state"
        reset_sandbox "$sb"
        echo "$cloud:$identity" >"$dir/identity"
    fi

    if [[ $cloud == gcp ]]; then
        if [[ -n $(cfg "$sb" CREDENTIALS) ]]; then
            [[ -f $GOOGLE_APPLICATION_CREDENTIALS ]] || die "$sb: $GOOGLE_APPLICATION_CREDENTIALS not found"
        else
            need gcloud "$sb: needs the Google Cloud CLI:
    curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts
    ~/google-cloud-sdk/bin/gcloud components install gke-gcloud-auth-plugin --quiet"
            if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
                echo ">>> $sb: sign in with this GCP sandbox's username and password"
                gcloud auth application-default login --no-launch-browser
            fi
        fi
    fi
}

init_terraform() {
    local cloud sb
    mkdir -p "$RUN_DIR"
    for cloud in $(printf '%s\n' "${SANDBOXES[@]}" | sed 's/[0-9]*$//' | sort -u); do
        tf_in "$cloud" init -input=false >/dev/null
        for sb in "${SANDBOXES[@]}"; do
            if [[ $(cloud_of "$sb") == "$cloud" && ! -d $TF_ROOT/$cloud/terraform.tfstate.d/$sb ]]; then
                tf_in "$cloud" workspace new "$sb" >/dev/null
            fi
        done
        tf_in "$cloud" workspace select default >/dev/null
    done
}

# Prepare every selected sandbox, then run "$1 <sandbox>" for the ready ones
# in parallel, each logging to .sandboxes/<sandbox>/log
run_sandboxes() {
    local action=$1 sb
    local -a ready=()
    FAILED=()

    # Not "if (prepare_sandbox)" - that would switch off set -e inside it
    local rc
    for sb in "${SANDBOXES[@]}"; do
        set +e
        (prepare_sandbox "$sb")
        rc=$?
        set -e
        if ((rc == 0)); then ready+=("$sb"); else FAILED+=("$sb"); fi
    done
    ((${#ready[@]})) || return 0

    init_terraform

    echo
    echo "Started $(date +%H:%M). Progress: tail -f .sandboxes/<sandbox>/log"
    declare -A pids
    for sb in "${ready[@]}"; do
        ("$action" "$sb") >"$RUN_DIR/$sb/log" 2>&1 &
        pids[$sb]=$!
        echo "  $sb -> .sandboxes/$sb/log"
    done

    for sb in "${ready[@]}"; do
        if wait "${pids[$sb]}"; then
            echo "✓ $sb done ($(date +%H:%M))"
        else
            echo "✗ $sb failed - last lines of .sandboxes/$sb/log:"
            tail -n 15 "$RUN_DIR/$sb/log" | sed 's/^/    /'
            FAILED+=("$sb")
        fi
    done
}

# Rebuild ~/.kube/multicloud.yaml from the per-cluster files
merge_kubeconfigs() {
    local files
    files=$(find "$KUBE_DIR" -maxdepth 1 -name '*.yaml' 2>/dev/null | sort | paste -sd:)
    if [[ -z $files ]]; then
        rm -f "$MERGED_KUBECONFIG"
        return
    fi
    (umask 077 && KUBECONFIG=$files kubectl config view --flatten >"$MERGED_KUBECONFIG")
}
