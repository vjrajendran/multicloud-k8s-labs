#!/usr/bin/env bash
#
# Installs what up.sh needs into ~/.local/bin (no sudo). up.sh runs this by
# itself the first time it finds a tool missing - you don't need to run it.
# Anything already installed is left alone.
#
#   setup.sh            AWS CLI, Terraform, kubectl (+ checks the basics)
#   setup.sh gcp        also the Google Cloud CLI + GKE auth plugin
#
# Azure needs no extra tools when labs.env has the service principal
# (USERNAME / CLIENT_ID / CLIENT_SECRET).

set -euo pipefail

BIN=$HOME/.local/bin
mkdir -p "$BIN"
export PATH=$BIN:$PATH
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

case $(uname -m) in
    x86_64) ARCH=amd64 AWS_ARCH=x86_64 ;;
    aarch64 | arm64) ARCH=arm64 AWS_ARCH=aarch64 ;;
    *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

# unzip, or Python when unzip isn't installed (Python drops the exec bits)
extract() {
    if have unzip; then
        unzip -q -o "$1" -d "$2"
    else
        python3 -I -m zipfile -e "$1" "$2"
    fi
}

# --- basics that come with most Linux images -------------------------------
missing=()
for tool in bash curl ssh ssh-keygen python3 awk sed flock git; do
    have "$tool" || missing+=("$tool")
done
if ((${#missing[@]})); then
    echo "Missing basic tools: ${missing[*]}"
    echo "Install them with your package manager, e.g.:"
    echo "  sudo apt-get update && sudo apt-get install -y curl openssh-client python3 util-linux git"
    exit 1
fi

# --- AWS CLI v2 -------------------------------------------------------------
if have aws; then
    echo "✓ AWS CLI      $(aws --version 2>&1 | cut -d' ' -f1)"
else
    echo "… installing AWS CLI"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$AWS_ARCH.zip" -o "$WORK/awscli.zip"
    extract "$WORK/awscli.zip" "$WORK"
    chmod -R u+x "$WORK/aws"
    "$WORK/aws/install" --install-dir "$HOME/.local/aws-cli" --bin-dir "$BIN" --update >/dev/null
    echo "✓ AWS CLI      $(aws --version 2>&1 | cut -d' ' -f1)"
fi

# --- Terraform --------------------------------------------------------------
if have terraform; then
    echo "✓ Terraform    $(terraform version | head -1)"
else
    echo "… installing Terraform"
    v=$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform |
        python3 -I -c 'import json, sys; print(json.load(sys.stdin)["current_version"])')
    curl -fsSL "https://releases.hashicorp.com/terraform/$v/terraform_${v}_linux_$ARCH.zip" -o "$WORK/terraform.zip"
    extract "$WORK/terraform.zip" "$WORK/tf"
    install -m 0755 "$WORK/tf/terraform" "$BIN/terraform"
    echo "✓ Terraform    $(terraform version | head -1)"
fi

# --- kubectl ----------------------------------------------------------------
if have kubectl; then
    echo "✓ kubectl      $(kubectl version --client 2>/dev/null | head -1)"
else
    echo "… installing kubectl"
    v=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
    curl -fsSL "https://dl.k8s.io/release/$v/bin/linux/$ARCH/kubectl" -o "$WORK/kubectl"
    install -m 0755 "$WORK/kubectl" "$BIN/kubectl"
    echo "✓ kubectl      $(kubectl version --client 2>/dev/null | head -1)"
fi

# --- Google Cloud CLI (only with ./setup.sh gcp) ----------------------------
if [[ ${1:-} == gcp ]]; then
    if have gcloud || [[ -x $HOME/google-cloud-sdk/bin/gcloud ]]; then
        echo "✓ gcloud       already installed"
    else
        echo "… installing Google Cloud CLI"
        curl -fsSL https://sdk.cloud.google.com | bash -s -- --disable-prompts >/dev/null
    fi
    "$HOME/google-cloud-sdk/bin/gcloud" components install gke-gcloud-auth-plugin --quiet >/dev/null 2>&1 || true
    echo "✓ gcloud       $("$HOME/google-cloud-sdk/bin/gcloud" --version 2>/dev/null | head -1)"
fi

echo
if ! grep -qs '.local/bin' "$HOME/.bashrc" "$HOME/.profile"; then
    echo 'export PATH=$HOME/.local/bin:$PATH' >>"$HOME/.bashrc"
    echo "Added ~/.local/bin to your PATH in ~/.bashrc (for aws/kubectl in new terminals)"
fi
[[ -n ${FROM_UP_SH:-} ]] || echo "Ready. Next: cp labs.env.example labs.env (if you haven't), fill it in, then ./up.sh"
