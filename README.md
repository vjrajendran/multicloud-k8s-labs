# Multicloud K8s Labs

One command builds Kubernetes clusters in any mix of Pluralsight **AWS, Azure and GCP** sandboxes. Each sandbox can run self-built **kubeadm** clusters, **managed** clusters (EKS, AKS, GKE), or both.

Sandboxes are named after the cloud and the team member: `aws1`, `aws2`, `aws3`, `azure1` … `gcp3`. Fill in the ones you started today and leave the rest empty.

## What fits in one sandbox

These are Pluralsight's limits and the cluster sizes this project uses:

| Cloud | Sandbox limit | kubeadm cluster (master1 + 2 workers) | Managed node | Examples that fit |
| ----- | ------------- | ------------------------------------- | ------------ | ----------------- |
| AWS | 9 EC2 instances (stopped count) | 3 × t3.medium = 3 instances | t3.medium = 1 instance | `KUBEADM=3` · `KUBEADM=2 MANAGED=1 NODES=3` · `MANAGED=3 NODES=3` |
| Azure | 10 VMs, 10 vCPU, 2 scale sets | B2s + 2 × B1ms = 4 vCPU | B2s = 2 vCPU, max 2 AKS | `KUBEADM=2` · `KUBEADM=1 MANAGED=1 NODES=2` · `MANAGED=2 NODES=2` |
| GCP | 10 VMs, 12 vCPU | 3 × e2-medium = 6 vCPU | e2-medium = 2 vCPU | `KUBEADM=2` · `KUBEADM=1 MANAGED=1 NODES=3` · `MANAGED=2 NODES=3` |

Terraform checks these limits before creating anything, so a layout that doesn't fit fails with a message instead of tripping Pluralsight's abuse monitoring.

With 3 members in each cloud, kubeadm alone gives up to **9 AWS + 6 Azure + 6 GCP = 21 clusters** a day.

## Daily use

1. Start the sandboxes you want.
2. Paste their credentials into `labs.env`. The first time, create it with `cp labs.env.example labs.env`.
3. Run:

   ```bash
   ./up.sh                # every sandbox filled in in labs.env
   ./up.sh aws1 gcp2      # or just some
   ```

`up.sh` first checks each sandbox's credentials, one at a time, because Azure or GCP may need a browser sign-in. Then it builds every sandbox in parallel, which takes roughly 10–20 minutes (EKS is the slowest). Follow one sandbox with `tail -f .sandboxes/aws1/log`.

When it finishes:

```bash
export KUBECONFIG=~/.kube/multicloud.yaml
kubectl config get-contexts         # aws1-k1, aws1-eks1, azure1-aks1, gcp2-k1, ...
kubectl --context gcp2-k1 get nodes
```

Context names are `<sandbox>-<type><n>`, where the type is `k` (kubeadm), `eks`, `aks` or `gke`.

| Command | What it does |
| ------- | ------------ |
| `./up.sh` again | Safe to re-run. Existing clusters are kept; changed counts are applied |
| `./down.sh azure1` | Destroy a sandbox's clusters early. Sandboxes also clean themselves up when they expire |

## Credentials per cloud

| Cloud | Put in `labs.env` | Tools needed locally |
| ----- | ----------------- | -------------------- |
| AWS | `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY` | `aws` CLI |
| Azure (usual) | `USERNAME`, `CLIENT_ID`, `CLIENT_SECRET`: the sandbox page's Username, Application Client ID and Secret. The password isn't needed. `up.sh` looks up the tenant (from the username's domain), the subscription and the resource group | none |
| Azure, no client ID on the page | `LOGIN=device`. `up.sh` shows a code for microsoft.com/devicelogin, where you sign in with the sandbox user | Linux Azure CLI (see below) |
| GCP | `PROJECT` (the sandbox project ID). `up.sh` prints a sign-in link for the sandbox user. You can instead set `CREDENTIALS` to a service-account JSON key | `gcloud` CLI, plus `gke-gcloud-auth-plugin` for GKE |

Each sandbox keeps its own Azure and GCP login under `.sandboxes/<sandbox>/`, so several sandboxes of the same cloud never mix up accounts.

Installing the CLIs inside WSL (no sudo needed):

```bash
# Azure CLI (the Windows az on your PATH can't keep separate logins)
python3 -m venv ~/.venvs/azure-cli && ~/.venvs/azure-cli/bin/pip install azure-cli

# Google Cloud CLI + GKE auth plugin
curl -sSL https://sdk.cloud.google.com | bash -s -- --disable-prompts
~/google-cloud-sdk/bin/gcloud components install gke-gcloud-auth-plugin --quiet
```

The scripts find both install locations automatically.

## Sharing the clusters

Give a developer or tester access to every cluster in every sandbox:

1. Ask them for their **public IP** (for example from `curl https://checkip.amazonaws.com`) and their **SSH public key** (the contents of `~/.ssh/id_ed25519.pub`). If they don't have a key yet, they can create one with `ssh-keygen -t ed25519`.
2. Add a line to `users.txt`. The first time, create it with `cp users.txt.example users.txt`:

   ```text
   # name     role    ip              key
   alice      admin   203.0.113.10    ssh-ed25519 AAAAC3Nza... alice@laptop
   ```

3. Run `./up.sh`. When the clusters already exist it only updates firewalls and accounts.
4. Send them the folder `share/<name>/`, privately, because it contains their tokens. Inside:
   - `kubeconfig.yaml`, with one context per cluster
   - `tunnel.sh`
   - `README.txt`

| | kubeadm clusters | EKS / AKS / GKE |
| - | ---------------- | --------------- |
| Kubernetes account | ServiceAccount `lab-access/<name>` + token, bound to a ClusterRole | Same, created from your laptop with the cluster's admin kubeconfig |
| Network | Their IP is allowed on SSH and 6443 (security group, NSG or firewall rule) | Their IP is added to the API allow-list (EKS public access CIDRs, AKS authorized IP ranges, GKE authorized networks) |
| SSH | A tunnel-only account on `master1` (no shell, no sudo) plus a `<cluster>-tunnel` context, for networks that intercept TLS | No SSH. Direct access only |

**Roles.** Change the role in `users.txt` and re-run `./up.sh`:

| Role | ClusterRole | Can do |
| ---- | ----------- | ------ |
| `admin` | `cluster-admin` | Everything |
| `edit` | `edit` | Create and change workloads. No RBAC, nodes or namespaces |
| `view` | `view` | Read-only. No secrets |

**Revoking access.** Delete the person's line and re-run `./up.sh`. Their token stops working, and their SSH account (which ends any open tunnel), firewall entry and bundle are removed.

**Each day:** new sandboxes mean new IPs and tokens. After the morning `./up.sh`, send the regenerated `share/` folders again.

If sharing fails for one cluster, `up.sh` logs a warning and carries on, and the summary shows `N of M clusters` for each person. This usually happens when your own `kubectl` can't reach a managed cluster, for example on a TLS-inspecting VPN.

## How it works

- **One Terraform root per cloud** (`terraform/aws`, `terraform/azure`, `terraform/gcp`) and **one workspace per sandbox**. All three roots produce the same outputs, so `up.sh` treats every cloud the same way.
- **kubeadm on every cloud.** Ubuntu 24.04 VMs with a user named `ubuntu`. Terraform SSHes into `master1`, clones [k8-cluster-automation](https://github.com/rvinodrajendran/k8-cluster-automation) and runs its `deploy.sh` (containerd, kubeadm, Flannel, worker join). This step is shared by all three clouds in `terraform/modules/kubeadm-bootstrap`. The output is also saved to `~/deploy.log` on `master1`.
- **Managed clusters:**
  - **EKS:** standard-support versions only, as Pluralsight requires. Nodes come from a managed node group.
  - **AKS:** Free tier, in the sandbox's only resource group, which is detected automatically.
  - **GKE:** Standard (Pluralsight doesn't allow Autopilot), zonal, so a node count of 3 means 3 nodes and not 3 per zone.
- **New-sandbox detection.** `up.sh` remembers each sandbox's AWS account, Azure subscription or GCP project. When it changes, the old state, keys and kubeconfigs are discarded, because Pluralsight has already deleted those resources.
- **Access.** SSH and the Kubernetes APIs are open only to your current public IP. If your IP changes, re-run `./up.sh`.
- **Kubeconfigs.** One file per cluster goes in `~/.kube/multicloud/`, all merged into `~/.kube/multicloud.yaml`. Your `~/.kube/config` is never touched.
  - EKS contexts call `aws eks get-token` with that sandbox's keys.
  - GKE contexts call `gke-gcloud-auth-plugin` with that sandbox's login.
  - kubeadm contexts connect to the master's public IP and check the certificate against the name `kubernetes`, because the certificate only lists the private IP.

## Untested parts

The AWS side has been checked with `terraform plan` against a live sandbox. The Azure and GCP roots pass `terraform validate` but haven't been run against a live sandbox yet. These are the most likely surprises:

| Possible issue | What you'd see | Fix |
| -------------- | -------------- | --- |
| AKS can't use a managed identity in the sandbox | AKS create fails with an identity or role-assignment error | Use AKS with the sandbox's service principal |
| GCP enforces OS Login | kubeadm bootstrap can't SSH to the nodes | Switch the GCP nodes to OS Login keys |
| Azure needs MFA for CLI logins | `az login` asks for MFA | Use the service-principal fields if the page shows them |
| Resource group auto-detection picks the wrong group | Resources land in the wrong group, or none is found | Set `AZUREn_RESOURCE_GROUP` |

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `AWS rejected the keys` | Paste today's keys into `labs.env` |
| `This needs N ... allows M` | Lower `_KUBEADM`, `_MANAGED` or `_NODES` for that sandbox |
| `not enough room: N other instance(s)` (AWS) | Terminate the other instances in that sandbox, or lower its counts |
| A kubeadm cluster fails during deploy | `ssh -i keys/<sandbox>.pem ubuntu@<master ip> cat deploy.log`, then `./up.sh <sandbox>` |
| `kubectl` times out | Your public IP changed. Re-run `./up.sh` |
| `x509: certificate signed by unknown authority` | A VPN or firewall is intercepting TLS. Turn off the VPN, or for kubeadm clusters SSH-tunnel to `master1`. Managed clusters can't be tunnelled, so use them off VPN |
| A shared user gets `N of M clusters` | See the `WARNING` lines in `.sandboxes/<sandbox>/log`, then re-run `./up.sh` |

## Layout

```text
up.sh / down.sh / lib.sh          entry points
labs.env.example                  template (labs.env is git-ignored)
users.txt.example                 template for shared users (users.txt is git-ignored)
access.sh                         users.txt -> accounts, firewall entries, share/ bundles
remote/grant-access.sh            ServiceAccounts + RBAC (+ tunnel-only SSH users on kubeadm masters)
terraform/aws|azure|gcp/          one root per cloud: network, SSH key, limit checks, clusters
terraform/modules/
  kubeadm-bootstrap/              deploy.sh on master1 (shared by all clouds)
  aws-kubeadm/  aws-eks/
  azure-kubeadm/  azure-aks/
  gcp-kubeadm/  gcp-gke/
keys/  .sandboxes/  share/        generated: SSH keys, logs, logins, tokens, bundles (git-ignored)
```
