# Shared by up.sh and down.sh

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TF_ROOT=$ROOT/terraform
RUN_DIR=$ROOT/.sandboxes               # per-sandbox logs, identity, cloud logins
KEY_DIR=$ROOT/keys
KUBE_DIR=$HOME/.kube/multicloud        # one kubeconfig per cluster
MERGED_KUBECONFIG=$HOME/.kube/multicloud.yaml
LABS_ENV=${LABS_ENV:-$ROOT/labs.env}
CLOUDS=(aws azure gcp)
DETACHED=0
RUN_FAILED=0
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)

# Never pick up credentials from your shell - each sandbox gets its own
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
      ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_TENANT_ID ARM_SUBSCRIPTION_ID AZURE_CONFIG_DIR \
      GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CREDENTIALS CLOUDSDK_CONFIG TF_WORKSPACE

# Tools installed by setup.sh, and Linux CLIs in your home directory, win over
# Windows ones on the WSL PATH
[[ -d $HOME/.local/bin ]] && PATH=$HOME/.local/bin:$PATH
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
    if [[ ${1:-} == --detached ]]; then
        DETACHED=1 # the background half started by run_sandboxes
        shift
    fi
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
            v=$(cfg "$sb" CLOUD_LB) && [[ $v == 1 || $v == true ]] && printf '%s\n' -var "cloud_lb=true"
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

# First run on a new machine: install what's missing (AWS CLI, Terraform,
# kubectl, gcloud for GCP) into ~/.local/bin via setup.sh - no sudo needed
ensure_tools() {
    local -a missing=() args=()
    local sb tool
    for tool in terraform kubectl curl ssh python3 flock; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    for sb in "${SANDBOXES[@]}"; do
        case $(cloud_of "$sb") in
            aws) command -v aws >/dev/null 2>&1 || missing+=(aws) ;;
            gcp)
                if [[ -z $(cfg "$sb" CREDENTIALS) ]] && ! command -v gcloud >/dev/null 2>&1; then
                    missing+=(gcloud)
                    args=(gcp)
                fi
                ;;
        esac
    done
    ((${#missing[@]})) || return 0

    echo "First run on this machine - installing: $(printf '%s\n' "${missing[@]}" | sort -u | xargs)"
    FROM_UP_SH=1 "$ROOT/setup.sh" "${args[@]}" ||
        die "Couldn't install everything - fix what's reported above, then run ./up.sh again"
    PATH=$HOME/.local/bin:$PATH # may not have existed when lib.sh started
    [[ -d $HOME/google-cloud-sdk/bin ]] && PATH=$HOME/google-cloud-sdk/bin:$PATH
    hash -r
    echo
}

sandbox_busy() {
    [[ -e $RUN_DIR/$1/lock ]] && ! flock -n "$RUN_DIR/$1/lock" true 2>/dev/null
}

# Run "$1 <sandbox>" for every selected sandbox in parallel, then "$2" once.
#
# Split in two so a closed or timed-out terminal never kills a build:
#   foreground  installs tools, checks credentials (may ask you to sign in),
#               starts the background half, then shows its progress
#   background  this script again with --detached, in its own session: runs
#               the sandboxes, then "$2", and sends the "done" notification
run_sandboxes() {
    if ((DETACHED)); then
        run_detached "$@"
    else
        run_foreground "$@"
    fi
}

run_foreground() {
    local sb fd rc
    local -a ready=() busy=() fds=()
    FAILED=()
    RUN_FAILED=0

    ensure_tools

    # Already running? Show it instead of starting a second build
    for sb in "${SANDBOXES[@]}"; do
        if sandbox_busy "$sb"; then busy+=("$sb"); fi
    done
    if ((${#busy[@]} == ${#SANDBOXES[@]})); then
        echo "${busy[*]}: already running in the background - showing its progress."
        [[ -t 1 ]] && "$ROOT/watch.sh" "${busy[@]}"
        echo "./status.sh shows every sandbox and cluster."
        exit 0
    elif ((${#busy[@]})); then
        die "${busy[*]} already running in the background - start the others on their own, e.g. ./$(basename "$0") ${SANDBOXES[*]/${busy[0]}/}"
    fi

    # Hold the locks while checking credentials (a new sandbox resets its state)
    for sb in "${SANDBOXES[@]}"; do
        mkdir -p "$RUN_DIR/$sb"
        exec {fd}>"$RUN_DIR/$sb/lock"
        flock -n "$fd" || die "$sb was just started by another up.sh/down.sh"
        fds+=("$fd")
    done

    # Not "if (prepare_sandbox)" - that would switch off set -e inside it
    for sb in "${SANDBOXES[@]}"; do
        set +e
        (prepare_sandbox "$sb")
        rc=$?
        set -e
        if ((rc == 0)); then ready+=("$sb"); else FAILED+=("$sb"); fi
    done
    for fd in "${fds[@]}"; do exec {fd}>&-; done
    ((${#ready[@]})) || return 0

    # The build itself: own session, no terminal - survives a closed window
    local run_log pid i all
    run_log=$RUN_DIR/run-$(IFS=-; echo "${ready[*]}").log
    rm -f "$run_log.failed"
    setsid "$ROOT/$(basename "$0")" --detached "${ready[@]}" </dev/null >"$run_log" 2>&1 &
    pid=$!
    for sb in "${ready[@]}"; do echo "$pid" >"$RUN_DIR/$sb/pid"; done

    # Wait until it holds its locks (or failed straight away)
    for i in $(seq 1 50); do
        all=1
        for sb in "${ready[@]}"; do sandbox_busy "$sb" || all=0; done
        ((all)) && break
        [[ -f $run_log.failed ]] && break
        sleep 0.2
    done

    echo
    echo "Running in the background - closing this terminal won't stop it."
    if [[ -t 1 && -z ${NO_WATCH:-} ]]; then
        WATCH_ATTACHED=1 "$ROOT/watch.sh" "${ready[@]}" || true
    else
        echo "Progress: ./watch.sh   (or tail -f .sandboxes/<sandbox>/log)"
        wait "$pid" || true
    fi

    # View closed with Ctrl-C while the build carries on
    for sb in "${ready[@]}"; do
        if sandbox_busy "$sb"; then
            echo
            echo "Still running in the background:"
            echo "  ./watch.sh           live progress again"
            echo "  ./status.sh          every sandbox and its clusters"
            echo "  ./stop.sh ${ready[0]}      stop it safely"
            exit 0
        fi
    done
    wait "$pid" 2>/dev/null || true
    cat "$run_log"
    [[ -s $run_log.failed ]] && RUN_FAILED=1
    return 0
}

run_detached() {
    local action=$1 finish=${2:-} sb fd run_log
    local -a fds=()
    FAILED=()
    run_log=$RUN_DIR/run-$(IFS=-; echo "${SANDBOXES[*]}").log
    trap 'echo "${FAILED[*]}" >"'"$run_log"'.failed"' EXIT

    for sb in "${SANDBOXES[@]}"; do
        mkdir -p "$RUN_DIR/$sb"
        exec {fd}>"$RUN_DIR/$sb/lock"
        if ! flock -n "$fd"; then
            FAILED+=("$sb")
            die "$sb is already being built or destroyed"
        fi
        fds+=("$fd")
    done

    init_terraform

    declare -A pids ok
    for sb in "${SANDBOXES[@]}"; do
        ("$action" "$sb") >"$RUN_DIR/$sb/log" 2>&1 &
        pids[$sb]=$!
    done
    for sb in "${SANDBOXES[@]}"; do
        if wait "${pids[$sb]}"; then ok[$sb]=1; else ok[$sb]=0; fi
    done

    local summary=""
    for sb in "${SANDBOXES[@]}"; do
        if ((ok[$sb])); then
            echo "✓ $sb done ($(date +%H:%M))"
            summary+="$sb ✓  "
            [[ $action == deploy_sandbox ]] && record_history "$sb"
        else
            echo "✗ $sb failed - last lines of .sandboxes/$sb/log:"
            tail -n 15 "$RUN_DIR/$sb/log" | sed 's/^/    /'
            FAILED+=("$sb")
            summary+="$sb ✗  "
        fi
    done
    [[ -n $finish ]] && "$finish"

    # Release the locks first: the notification lingers for a few seconds and
    # would otherwise keep the sandboxes looking "busy"
    echo "${FAILED[*]}" >"$run_log.failed"
    for fd in "${fds[@]}"; do exec {fd}>&-; done
    "$ROOT/watch.sh" --notify "Kubernetes labs" "$summary"
    return 0
}

# How long a real build took, by shape (cloud + cluster counts), so the
# dashboard's "about N min left" learns from your own runs
record_history() {
    local sb=$1 log start end secs k m
    log=$(sed 's/\x1b\[[0-9;]*m//g' "$RUN_DIR/$sb/log")
    # Only builds that created clusters - a quick re-run would skew the estimate
    grep -qE 'Resources: ([5-9]|[1-9][0-9]+) added' <<<"$log" || return 0
    start=$(sed -n "s/^\[$sb\] \([0-9:]*\) terraform apply.*/\1/p" <<<"$log" | head -1)
    end=$(sed -n "s/^\[$sb\] \([0-9:]*\) done$/\1/p" <<<"$log" | tail -1)
    [[ -n $start && -n $end ]] || return 0
    secs=$(($(date -d "$end" +%s) - $(date -d "$start" +%s)))
    ((secs > 0)) || return 0
    k=$(find "$KUBE_DIR" -maxdepth 1 -name "$sb-k[0-9]*.yaml" | wc -l)
    m=$(($(find "$KUBE_DIR" -maxdepth 1 -name "$sb-*.yaml" | wc -l) - k))
    echo "$(cloud_of "$sb"):k$k:m$m $secs" >>"$RUN_DIR/history"
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
