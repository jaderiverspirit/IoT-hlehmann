# Inception-of-Things — IoT-hlehmann

Implementation of the **42 Inception-of-Things (IoT), subject v4.1** project. It introduces Kubernetes through K3s, Vagrant, K3d and Argo CD, then extends the GitOps setup with a locally hosted GitLab instance.

**Team login:** `hlehmann`  
**Public GitHub repository:** https://github.com/jaderiverspirit/IoT-hlehmann

## 1. Architecture

| Part | Infrastructure | Kubernetes | Purpose |
| --- | --- | --- | --- |
| **P1** | Two Debian 13 VMs created by Vagrant/VirtualBox | K3s server and agent | Cluster provisioning, networking and passwordless SSH |
| **P2** | One Debian 13 VM created by Vagrant/VirtualBox | K3s with Traefik | Three web applications, Services and host-based Ingress |
| **P3** | Debian 13 VirtualBox VM (`hlehmann-P3-Bonus`), without Vagrant | K3d cluster `iot` with Argo CD | Continuous deployment from public GitHub |
| **Bonus** | **Same VM and same K3d cluster as P3** | Existing Argo CD plus local GitLab | Continuous deployment from a local GitLab repository |

The project runs its workloads inside Linux virtual machines. Linux Mint is the workstation operating system and VirtualBox host. P3 and Bonus share **one** K3d cluster, one Argo CD installation and the same deployment in the `dev` namespace; the Bonus changes the Git source of truth rather than creating a second cluster.

```text
Linux Mint workstation (VirtualBox + Vagrant)
├── P1: hlehmannS  (192.168.56.110) ── K3s server
│       hlehmannSW (192.168.56.111) ── K3s agent
├── P2: hlehmannS  (192.168.56.110) ── K3s + Traefik + app1/app2/app3
└── P3 + Bonus: hlehmann-P3-Bonus (Debian 13 VM)
    └── Docker → K3d cluster: iot
        ├── namespace argocd ── Argo CD
        ├── namespace dev    ── wil42/playground
        └── namespace gitlab ── GitLab CE (Bonus)
```

P1 and P2 are separate Vagrant environments but deliberately reuse the VirtualBox name `hlehmannS` and private IP `192.168.56.110`. **Destroy the P1 VMs before creating P2.** Merely halting a VM does not release its registered VirtualBox name.

### Repository structure

```text
.
├── p1/
│   ├── Vagrantfile
│   ├── scripts/
│   └── confs/                # P1 prerequisites checker
├── p2/
│   ├── Vagrantfile
│   ├── scripts/
│   └── confs/                # P2 prerequisites checker
├── p3/
│   ├── scripts/
│   └── confs/                # P3 prerequisites checker
│       └── apps/
├── bonus/
│   ├── scripts/
│   └── confs/                # Bonus prerequisites + static checks in scripts/
└── README.md
```

## 2. Requirements and setup

### Linux Mint workstation (P1/P2)

- VirtualBox and Vagrant, with hardware virtualization enabled.
- Git, SSH, `curl`, `rsync`, Bash and Ruby.
- A self-built **Debian 13 (Trixie)** VirtualBox Vagrant box installed as `IoT-Debian13-virtualbox`.
- Python 3 with PyYAML for the optional project-wide static checks.

The Vagrantfiles in `p1/` and `p2/` use the **locally installed** box. The large `.box` archive is not included in Git; on a different computer, import the box separately before starting Vagrant:

```bash
vagrant box list
# Expected: IoT-Debian13-virtualbox (virtualbox, ...)

# Only if the box has not yet been installed:
vagrant box add --name IoT-Debian13-virtualbox /path/to/IoT-Debian13-virtualbox.box
```

The box was built from Debian's official installation media. The archive is supplied separately, not downloaded automatically by the Vagrantfiles.

From the **repository root on Linux Mint**, check each part before launching it:

```bash
# Before P1
./p1/confs/IoT-prerequisites-P1.sh

# Before P2
./p2/confs/IoT-prerequisites-P2.sh
```

The checkers report installed tools, box availability, Vagrantfile/script syntax and `vagrant status` for **both P1 and P2**. They also identify possible conflicts involving the VirtualBox VM name `hlehmannS`.

**Important:** P1 and P2 are separate Vagrant environments that use the same VirtualBox name `hlehmannS` and IP `192.168.56.110`. A powered-off P2 VM still owns its registered name. Before creating P1, remove the disposable P2 VM if it owns that name; before creating P2, destroy the disposable P1 VMs after completing the P1 demonstration. Perform this cleanup deliberately, not as part of a prerequisites checker.

### Verify Debian version

The project uses Debian 13 (Trixie). To verify the installed Debian point release, run the following command from the `p1/` directory on the Linux Mint host:

```bash
vagrant ssh hlehmannS -c 'cat /etc/debian_version'
```

**Expected result:** The installed Debian 13 point release (for example, `13.7`).

To verify the operating system and codename:

```bash
vagrant ssh hlehmannS -c 'cat /etc/os-release'
```

**Expected:** `VERSION_CODENAME=trixie` and `VERSION_ID="13"`.

Repeat the checks for the worker VM by replacing `hlehmannS` with `hlehmannSW`.

### Combined P3 + Bonus VM

| Setting | Configuration |
| --- | --- |
| VirtualBox name | `hlehmann-P3-Bonus` |
| Guest operating system | Debian 13 (Trixie) |
| CPUs | 4 vCPU |
| Memory | 10 GiB |
| Virtual disk | 60 GiB |
| Container runtime | Docker Engine |
| Kubernetes | K3d, cluster `iot` |
| Namespaces | `argocd`, `dev`, and `gitlab` (Bonus) |

P3 and Bonus use **one Debian VM, one K3d cluster and one Argo CD installation**. This VM is managed with VirtualBox directly, **not with Vagrant**. Use a regular Debian user with `sudo` privileges and sufficient disk space for Docker images, GitLab storage and logs.

From a terminal **inside the Debian VM**, clone the project if it is not already present:

```bash
git clone https://github.com/jaderiverspirit/IoT-hlehmann.git
cd IoT-hlehmann
```

Before installing or running **P3**, execute the read-only preflight inside Debian:

```bash
./p3/confs/IoT-prerequisites-P3.sh
```

The P3 preflight checks the VM environment, project scripts, GitHub reachability and any existing Docker/K3d/Kubernetes setup. Missing Docker or K3d may be reported as informational before installation; follow the P3 setup steps in Section 5.

After P3 has been demonstrated, check the **Bonus** prerequisites, again inside the same Debian VM:

```bash
./bonus/confs/IoT-prerequisites-Bonus.sh
```

The Bonus preflight checks the shared cluster and Argo CD, GitLab manifests and deployment, persistent storage, and GitLab access from Debian. Components not yet installed may appear as warnings; the Bonus setup creates them. The Bonus switches Argo CD's source from public GitHub to local GitLab rather than creating another Kubernetes cluster.

For the optional project-wide static validation, run from the repository root on a machine with Python 3 and PyYAML:

```bash
python3 bonus/scripts/IoT-static-checks.py
```

The prerequisites scripts assess readiness; the `IoT-check.sh` scripts in each part are used later to verify its **running** implementation.

## 3. Part 1 — K3s server and worker with Vagrant

P1 provisions two Debian 13 virtual machines. VirtualBox VM names and guest hostnames follow the 42 login convention, while Kubernetes node names are lowercase to meet Kubernetes naming rules.

| Role | VM / guest hostname | K3s node name | Private IP | CPUs | RAM |
| --- | --- | --- | --- | ---: | ---: |
| Server | `hlehmannS` | `hlehmanns` | `192.168.56.110` | 2 | 2048 MiB |
| Worker | `hlehmannSW` | `hlehmannsw` | `192.168.56.111` | 1 | 1024 MiB |

From the project root on the Linux workstation:

```bash
cd p1
vagrant validate
vagrant up --provider=virtualbox
vagrant status

# Server: both Kubernetes nodes should be Ready.
vagrant ssh hlehmannS -c 'sudo /usr/local/bin/k3s kubectl get nodes -o wide'

# Verify hostnames, networking, and the worker service.
vagrant ssh hlehmannS -c 'hostname; ip -brief address'
vagrant ssh hlehmannSW -c 'hostname; ip -brief address; sudo systemctl is-active k3s-agent'

# Automated checks, including passwordless Vagrant SSH.
./scripts/IoT-check.sh
```

The first machine runs the K3s controller; the second joins as an agent. The Vagrantfile generates `p1/.iot-join-token` locally with restricted permissions and synchronizes it to the guests for cluster joining. This token is ignored by Git and must never be committed.

An optional small-resource profile is available through `IOT_P1_TINY=1`, although the default server allocation is more suitable for current K3s releases.

<!-- EVAL-MANUAL-TESTS-P1-START -->
### Manual functional testing — P1

**Objective:** Prove that Vagrant created two independent Debian VMs, the first runs the K3s server, and the second joined it as a K3s agent. **P1 does not require a user application or an Ingress.** Execute these checks on the **Linux Mint host**, from `p1/`, after `vagrant up`.

| Check | Run | Expected evidence |
| --- | --- | --- |
| VM provisioning | `vagrant status` | `hlehmannS` and `hlehmannSW` are both `running`. |
| Guest identity | `vagrant ssh hlehmannS -c hostname` and `vagrant ssh hlehmannSW -c hostname` | Hostnames are `hlehmannS` and `hlehmannSW`; SSH works without an interactive password. |
| Network configuration | `vagrant ssh hlehmannS -c 'ip -4 -brief address'` and `vagrant ssh hlehmannSW -c 'ip -4 -brief address'` | The server has `192.168.56.110` and the worker has `192.168.56.111` on the private network. NAT (`10.0.2.15`) and other interface addresses may also appear. |
| Server and agent services | Commands below | `active` on both respective services. |
| Cluster membership | Commands below | Exactly two K3s nodes; both `Ready`, server `control-plane`, worker joined as an agent. |
| Automated cross-check | `./scripts/IoT-check.sh` | Exits successfully, with no failures. |

```bash
# Run from the Linux Mint host, inside p1/.
vagrant ssh hlehmannS -c 'sudo systemctl is-active k3s'
vagrant ssh hlehmannSW -c 'sudo systemctl is-active k3s-agent'

vagrant ssh hlehmannS -c 'sudo /usr/local/bin/k3s kubectl get nodes -o wide'
vagrant ssh hlehmannS -c 'sudo /usr/local/bin/k3s kubectl get pods -A -o wide'
```

**Result:** The server provides the Kubernetes control plane, the agent registers with it using the locally generated join token, and the private IPs allow communication between the guests. A `Ready` worker is evidence that it successfully joined the cluster. The `flannel.1`, `cni0` and `veth*` interfaces in `ip` output are Kubernetes networking interfaces, not extra Vagrant VMs. Their addresses do **not** replace the required `.110` and `.111` addresses.

**If a check fails:** Inspect `vagrant status`, then `sudo systemctl status k3s` on the server or `k3s-agent` on the worker, and check the private network and locally generated `.iot-join-token`. Resolve failures before moving to P2. The P1 and P2 Vagrant machines cannot coexist under the same VirtualBox name `hlehmannS`.
<!-- EVAL-MANUAL-TESTS-P1-END -->

**Move to P2:** from inside `p1/`, remove the disposable P1 machines to free the shared VirtualBox VM name:

```bash
vagrant destroy -f
cd ..
```

This does not delete the installed Vagrant base box.

## 4. Part 2 — K3s, three applications and Traefik Ingress

P2 provisions one Debian 13 VM called `hlehmannS` (`192.168.56.110`) with K3s, Traefik and three nginx-based applications.

| HTTP request hostname | Target | Desired replicas |
| --- | --- | ---: |
| `app1.com` | `iot-app1` | 1 |
| `app2.com` | `iot-app2` | 3 |
| Any other hostname | `iot-app3` | 1 |

The Ingress configuration uses hostname rules for app1/app2 and a catch-all route for app3. Send HTTP `Host` headers explicitly; no public DNS changes are required.

```bash
cd p2
vagrant validate
vagrant up --provider=virtualbox
vagrant status

vagrant ssh hlehmannS -c 'sudo /usr/local/bin/k3s kubectl get deployments,pods,services,ingress -o wide'
./scripts/IoT-check.sh

# Run on the Linux Mint workstation:
curl --noproxy '*' -H 'Host: app1.com' http://192.168.56.110/
curl --noproxy '*' -H 'Host: app2.com' http://192.168.56.110/
curl --noproxy '*' -H 'Host: unknown.example' http://192.168.56.110/
```

Expected page messages: `Hello from app1.`, `Hello from app2.`, and `Hello from app3.`, respectively. Check that the deployment replica counts are `1`, `3`, and `1`.

To inspect routing from within the guest:

```bash
vagrant ssh hlehmannS -c 'sudo /usr/local/bin/k3s kubectl describe ingress iot-routing'
```

<!-- EVAL-MANUAL-TESTS-P2-START -->
### Manual functional testing — P2

**Objective:** Demonstrate that a single K3s node hosts **three separate web applications** and routes HTTP traffic through **Traefik Ingress** by hostname. Execute on the **Linux Mint host** after the P2 VM has started.

```bash
# Run from p2/ on Linux Mint.
vagrant status
vagrant ssh hlehmannS -c 'sudo /usr/local/bin/k3s kubectl get nodes -o wide'
vagrant ssh hlehmannS -c 'sudo /usr/local/bin/k3s kubectl get deployments,pods,services,ingress -o wide'
```

Expected: the VM is `running`; the single K3s node is `Ready`; `iot-app1`, `iot-app2` and `iot-app3` exist. Their Deployment `READY` counts must be **1/1, 3/3 and 1/1**, respectively. Services must target the applications, and the Ingress must include the two hostname-specific rules and a default route.

```bash
# Send explicit HTTP Host headers from Linux Mint; no DNS entries are needed.
curl --noproxy '*' -i -H 'Host: app1.com' http://192.168.56.110/
curl --noproxy '*' -i -H 'Host: app2.com' http://192.168.56.110/
curl --noproxy '*' -i -H 'Host: unknown.example' http://192.168.56.110/

# Inspect the routing definition inside the guest.
vagrant ssh hlehmannS -c 'sudo /usr/local/bin/k3s kubectl describe ingress iot-routing'
./scripts/IoT-check.sh
```

| Request | Expected HTTP result | Why it matters |
| --- | --- | --- |
| `Host: app1.com` | HTTP 200; `Hello from app1.` | First explicit Ingress host rule. |
| `Host: app2.com` | HTTP 200; `Hello from app2.` | Second host rule; the application has three replicas. |
| `Host: unknown.example` | HTTP 200; `Hello from app3.` | Catch-all fallback works for other hostnames. |

**Result:** Traefik receives the request on the VM's port 80, matches the HTTP `Host` header to an Ingress rule, then forwards through a Kubernetes Service to a Pod. Three replicas mean three instances of app2, **not** three different URLs. If the HTTP calls fail, first check pod readiness, Traefik, the Ingress rules, and the `.110` private-network address. Do not move on until all three responses are correct.
<!-- EVAL-MANUAL-TESTS-P2-END -->

When finished, stop the P2 VM to free workstation resources:

```bash
vagrant halt
cd ..
```
## 5. Part 3 — K3d, Argo CD and public GitHub GitOps

Part 3 demonstrates continuous deployment from a public GitHub repository using K3d and Argo CD.

**Unlike P1 and P2, P3 does not use Vagrant.** A Debian 13 virtual machine must be created and configured manually in VirtualBox before running any P3 installation scripts.

The Bonus uses this **same VM and Kubernetes cluster**. There is no need to create a second VM for GitLab.

### 5.1 Create the P3 + Bonus virtual machine

**Run these steps on the Linux Mint workstation.**

1. Open VirtualBox and select **New**.
2. Name the virtual machine `hlehmann-P3-Bonus`.
3. Download the official [Debian 13 installation ISO](https://www.debian.org/distrib/netinst/).
4. Select the downloaded ISO as the installation medium.
5. Select **Skip Unattended Installation**, if offered.
6. Configure the virtual machine as follows:

| Setting | Configuration |
| --- | --- |
| VM name | `hlehmann-P3-Bonus` |
| Operating system | Debian 13 (Trixie), 64-bit |
| CPUs | 4 vCPU |
| Memory | 10,240 MB |
| Virtual disk | 60 GB, dynamically allocated |
| Network adapter | NAT |
| Virtualization | Hardware virtualization enabled |

**Resource requirements:** The VM needs enough memory and disk space for Docker, K3d, Argo CD and the Bonus GitLab instance. The Bonus requires a persistent volume claim of 25 GiB, so a small virtual disk is insufficient.

The 10 GiB allocation assumes that the Linux Mint workstation has sufficient available memory. Avoid running the P1/P2 VMs concurrently with the P3 + Bonus VM on a resource-constrained computer.

### 5.2 Install Debian 13 inside VirtualBox

Start the newly created VM and follow the Debian installer.

- Select **Graphical install**.
- Configure your preferred language, keyboard and timezone.
- Create a regular user account.
- Leave the root password empty during installation if you want the installer to configure the first user with `sudo` privileges.
- Use guided disk partitioning unless a custom layout is required.
- Install a Debian desktop environment (a lightweight desktop such as Xfce is suitable) and standard system utilities.
- Install the GRUB bootloader when requested.

After installation, restart the VM, remove the installation ISO if necessary, and log in.

Open a terminal **inside Debian**, not on Linux Mint.

### 5.3 Verify Debian and prepare the environment

**All commands from this point until explicitly stated otherwise must run inside the Debian VM.**

Verify the operating system:

```bash
cat /etc/os-release
cat /etc/debian_version
```

Expected: Debian GNU/Linux 13 (`trixie`). The exact point-release number depends on the installation image and installed updates.

Install the tools required to retrieve the project:

```bash
sudo apt update
sudo apt install -y git curl ca-certificates
curl --version
```

Verify administrator privileges and Internet connectivity:

```bash
sudo -v
curl -I https://github.com
```

Clone the repository **inside the Debian VM**:

```bash
cd ~
git clone https://github.com/jaderiverspirit/IoT-hlehmann.git
cd IoT-hlehmann
```

Verify the project structure:

```bash
ls
```

Expected directories: `p1`, `p2`, `p3`, `bonus`, together with `README.md`.

> **Important:** The Linux Mint checkout and the Debian VM checkout are separate. P3 and Bonus scripts must run in the Debian VM because that is where Docker and the K3d Kubernetes cluster are installed.

### 5.4 Install Docker, K3d and kubectl

From the repository root **inside Debian**:

```bash
./p3/scripts/IoT-install-tools.sh
```

The installation script installs the container and Kubernetes tools needed for P3.

After installation, activate Docker group membership by logging out and back in, or by starting a new group shell:

```bash
newgrp docker
```

Verify the installation:

```bash
docker info
k3d version
kubectl version --client
```

**Expected results:**

- Docker reports server information without a permission error.
- K3d prints its installed version.
- kubectl prints its client version.

If Docker reports a permission error, check group membership with `groups` and log out of the Debian desktop session and back in.

### 5.5 Create the Kubernetes cluster

Still inside the Debian VM:

```bash
./p3/scripts/IoT-create-cluster.sh
```

Verify the cluster:

```bash
k3d cluster list
kubectl config current-context
kubectl get nodes
kubectl get namespaces
```

**Expected results:**

- A K3d cluster named `iot` exists.
- The active Kubernetes context is `k3d-iot`.
- Kubernetes nodes report `Ready`.
- The `dev` namespace exists.

The script reuses an existing `iot` cluster when appropriate.

### 5.6 Install Argo CD

Run:

```bash
./p3/scripts/IoT-install-argocd.sh
```

Verify the installation:

```bash
kubectl -n argocd get pods
kubectl -n argocd get services
```

**Expected:** Argo CD components are deployed in the `argocd` namespace, and their Pods become `Running` and `Ready`.

### 5.7 Configure GitHub GitOps

Connect Argo CD to the project's public GitHub repository:

```bash
./p3/scripts/IoT-configure-github.sh \
  https://github.com/jaderiverspirit/IoT-hlehmann.git
```

Verify the Argo CD application:

```bash
kubectl -n argocd get application iot-github
kubectl -n dev get deployments,pods,services
./p3/scripts/IoT-check.sh
```

**Expected:**

- Argo CD application `iot-github` is `Synced` and `Healthy`.
- Deployment `iot-playground` is running in namespace `dev`.
- Argo CD tracks branch `main` and the manifests in `p3/confs/apps`.

### 5.8 Manual functional testing — GitHub to Kubernetes

The aim is to demonstrate that a Git commit triggers an automatic deployment update.

**Terminal A — Debian VM**

Expose the playground application:

```bash
kubectl -n dev port-forward svc/iot-playground 8888:8888
```

Keep this terminal running.

**Terminal B — Debian VM**

Check the application response:

```bash
curl http://127.0.0.1:8888/
```

Expected initial response:

```json
{"status":"ok","message":"v1"}
```

**Terminal C — Linux Mint workstation, with GitHub push access**

From a checkout of the public repository on branch `main`, change the deployment version:

```bash
./p3/scripts/IoT-set-version.sh v2

git add p3/confs/apps/IoT-deployment.yaml
git commit -m "Update playground to v2 via GitOps"
git push origin main
```

**Back inside the Debian VM**, verify automatic reconciliation:

Before checking the Kubernetes rollout, wait until Argo CD reports `Synced` and `Healthy` for the exact Git revision pushed to GitHub. Verify the revision using the following command:

```bash
kubectl -n argocd get application iot-github -o jsonpath='{.status.sync.revision}'; echo
```

```bash
kubectl -n argocd get application iot-github
kubectl -n dev rollout status deployment/iot-playground --timeout=300s
kubectl -n dev get deployment iot-playground \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

Once the new deployment is ready, restart the port-forward if the previous connection was interrupted, and check the response:

```bash
curl http://127.0.0.1:8888/
```

Expected response:

```json
{"status":"ok","message":"v2"}
```

**Pass criteria:** The change in GitHub results in an updated running application without manually modifying the Kubernetes Deployment.

For a repeatable evaluation, return the GitHub deployment manifest to `v1` and allow Argo CD to synchronize it before the next demonstration.

### 5.9 Continue to Bonus

Keep the Debian VM and the `iot` K3d cluster running.

**Do not delete or rebuild the Kubernetes cluster.** The Bonus deploys a local GitLab instance into this existing cluster and switches Argo CD to the GitLab repository instead of GitHub.

## 6. Bonus — local GitLab in the same P3 cluster

The Bonus extends **the existing P3 K3d cluster `iot`**. It deploys GitLab CE into the dedicated `gitlab` namespace and switches the existing Argo CD workflow from a public GitHub source to a **local GitLab repository**.

There is **no second Kubernetes cluster and no second Argo CD installation**. The same application remains in `dev`.

```text
P3:    GitHub (public) ───► Argo CD (argocd) ───► playground (dev)
Bonus: GitLab (local) ───► Argo CD (argocd) ───► playground (dev)
                             same cluster: k3d-iot
```

The GitLab container uses the official GitLab CE image with a specific version tag defined in `bonus/confs/IoT-gitlab.yaml`. It has persistent storage (PVC request: 25 GiB). Upgrades of an initialized GitLab instance must follow GitLab's supported version-specific upgrade path; changing the image tag alone is not a substitute for a supported migration.

The P3 and Bonus environment was tested with Debian 13.8, Docker 29.10.1, K3d 5.9.0, K3s 1.35.5 and GitLab CE 19.5.9. These are tested versions, not mandatory version requirements.

### Install GitLab and configure access

From the project root **inside the same Debian VM as P3**:

```bash
kubectl config current-context  # Expected: k3d-iot
./bonus/scripts/IoT-install-gitlab.sh
./bonus/scripts/IoT-start-gitlab-access.sh
```

The GitLab service URL is:

```text
http://gitlab.gitlab.svc.cluster.local:8081
```

Inside the cluster, this name resolves via Kubernetes DNS. From the Debian VM, the access script uses a local hosts entry and a loopback `kubectl port-forward` to reach the same URL. GitLab's initial credentials and bootstrap token are stored privately under `~/.config/iot/`, **not** in Git.

### Switch Argo CD to local GitLab

Repeated bootstrap execution preserves existing GitLab repository history and the version defined in the repository. The script validates the working tree and Application deletion finalizers, then verifies the exact Git revision, expected image, Argo CD synchronization, health and Kubernetes rollout.

```bash
./bonus/scripts/IoT-bootstrap-local-repo.sh
./bonus/scripts/IoT-check.sh
```

Bootstrap creates a public-to-the-lab GitLab project at `root/iot-gitops`, seeds it with a `v1` copy of the P3 Kubernetes manifests, and creates a separate local working tree at `~/IoT-GitLab-worktree`. It removes the `iot-github` Argo CD Application and registers `iot-gitlab` instead, preventing two Applications from managing the same Kubernetes Deployment concurrently. It does **not** alter the original GitHub remote.

Verify the source:

```bash
kubectl -n argocd get application iot-gitlab \
  -o jsonpath='{.spec.source.repoURL}'; echo
# Expected:
# http://gitlab.gitlab.svc.cluster.local:8081/root/iot-gitops.git
```

### Demonstrate local GitLab continuous deployment

Before starting the demonstration, establish the initial v1 state:

```bash
./bonus/scripts/IoT-set-local-version.sh v1
```

After each version change, restart the playground port-forward if the previous connection was interrupted by Pod replacement.

Keep the playground port-forward running in one terminal:

```bash
kubectl -n dev port-forward svc/iot-playground 8888:8888
```

In another terminal, push version changes **to local GitLab** using the project script:

```bash
./bonus/scripts/IoT-set-local-version.sh v2
curl http://127.0.0.1:8888/  # "message":"v2"

./bonus/scripts/IoT-set-local-version.sh v1
curl http://127.0.0.1:8888/  # "message":"v1"

./bonus/scripts/IoT-check.sh
```

The update must propagate **local GitLab → existing Argo CD → existing Kubernetes Deployment**. No GitHub commit or push is required for the Bonus demonstration.

<!-- EVAL-MANUAL-TESTS-Bonus-START -->
### Manual functional testing — Bonus (local GitLab → Argo CD → K3d)

**Objective:** Demonstrate the **same Kubernetes cluster and application** being managed from a **locally hosted GitLab** repository instead of public GitHub. Run these checks **inside the combined Debian P3 + Bonus VM** after executing the Bonus installation and bootstrap steps above.

**1. Prove that GitLab is local, running and persistent.**

```bash
kubectl config current-context              # Expected: k3d-iot
kubectl -n gitlab get deployment,pods,services,pvc
kubectl -n argocd get application
kubectl -n argocd get application iot-gitlab \
  -o jsonpath='{.spec.source.repoURL}{"\n"}'
# Expected: http://gitlab.gitlab.svc.cluster.local:8081/root/iot-gitops.git

# The working-tree remote should be the locally hosted GitLab repository.
git -C ~/IoT-GitLab-worktree remote -v
```

Expected: the GitLab Pod is **Ready**, the GitLab PersistentVolumeClaim is **Bound**, `iot-gitlab` is **Synced / Healthy**, and `iot-github` is **absent**. The remote and Application URL must point to **local GitLab**, not `github.com`. The `dev` namespace and `iot-playground` Deployment are the **same ones as in P3**.

**2. Demonstrate a local GitLab commit changing the running application.** Keep the playground port-forward running in one Debian terminal; restart it if a previous one ended.

```bash
# Terminal A (Debian VM):
kubectl -n dev port-forward svc/iot-playground 8888:8888
```

```bash
# Terminal B (Debian VM):
./bonus/scripts/IoT-set-local-version.sh v1
kubectl -n dev rollout status deployment/iot-playground --timeout=300s
curl http://127.0.0.1:8888/                    # Expected message: v1

./bonus/scripts/IoT-set-local-version.sh v2
kubectl -n argocd get application iot-gitlab
kubectl -n dev rollout status deployment/iot-playground --timeout=300s
kubectl -n dev get deployment iot-playground \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
curl http://127.0.0.1:8888/                    # Expected message: v2
git -C ~/IoT-GitLab-worktree log -1 --oneline
```

The change is **local GitLab commit → existing Argo CD → existing Kubernetes Deployment → live HTTP result**. **No GitHub push is required for the Bonus.** The local GitLab worktree must remain separate from the public GitHub checkout.

**3. Demonstrate rollback and final verification.**

```bash
./bonus/scripts/IoT-set-local-version.sh v1
kubectl -n dev rollout status deployment/iot-playground --timeout=300s
curl http://127.0.0.1:8888/                    # Expected message: v1
./bonus/scripts/IoT-check.sh
```

**Result:** GitLab runs as a Pod inside the K3d cluster; its persistent volume keeps repository data across container restarts. Argo CD watches its internal service URL and reconciles the same application previously managed from GitHub. Do not expose or commit GitLab passwords, personal access tokens or local bootstrap files. If the source switch or update fails, inspect Argo CD sync status, GitLab Pod readiness, PVC state and the local port-forward logs.
<!-- EVAL-MANUAL-TESTS-Bonus-END -->

## 7. Verification reference

| Part | Command | What to confirm |
| --- | --- | --- |
| P1 | `cd p1 && ./scripts/IoT-check.sh` | Two guests; server and worker; two Ready nodes; SSH and IPs |
| P2 | `cd p2 && ./scripts/IoT-check.sh` | Three deployments; replicas 1/3/1; Ingress returns the correct pages |
| P3 | `./p3/scripts/IoT-check.sh` | `k3d-iot`, Argo CD and `dev` resources; GitHub source and current image |
| Bonus | `./bonus/scripts/IoT-check.sh` | Local GitLab namespace, PVC and Argo CD GitLab source |
| Source checks | `python3 bonus/scripts/IoT-static-checks.py` | Kubernetes YAML structure, Vagrantfile and shell syntax |

For the static checker, install PyYAML if needed (for example, through your distribution's `python3-yaml` package). Static validation does not replace live VM and Kubernetes checks.

## 8. Troubleshooting

**Vagrant cannot find the Debian box.** Check `vagrant box list`. Import the self-built archive using the exact box name `IoT-Debian13-virtualbox`. A fresh Git clone alone does not contain the box archive.

**P1 or P2 VM name already exists.** P1 and P2 both use the VirtualBox name `hlehmannS`. Run `vagrant status` in each environment to identify which registered Vagrant machine owns it. Only destroy a disposable VM from its **own** Vagrant directory; a `vagrant halt` does not release the registered name.

```bash
vagrant status
VBoxManage list vms
vagrant global-status --prune
```

**P1 worker does not join.** Check the server at `192.168.56.110`, worker at `192.168.56.111`, the locally generated `/vagrant/.iot-join-token`, K3s services and TCP port 6443 between guests.

**Kubernetes node names differ from guest hostnames.** This is intentional: Vagrant guest names include the subject-required capitals (`hlehmannS`, `hlehmannSW`); Kubernetes node names are lowercase (`hlehmanns`, `hlehmannsw`).

**P2 HTTP requests fail.** Check `kubectl get ingress,svc,pods`, Traefik and ServiceLB in `kube-system`, the guest's port 80 and the VirtualBox private network. Use `curl --noproxy '*'` to bypass host proxy settings.

**Docker reports permission denied.** Re-enter the Docker group with `newgrp docker` or log out and in again. Membership in the Docker group gives root-equivalent access to the VM.

**Argo CD stays OutOfSync or cannot fetch Git.** Check `kubectl -n argocd describe application iot-github` (or `iot-gitlab`), repository URL, `main` branch, `p3/confs/apps` path and repo-server logs. Use `kubectl config current-context` to confirm `k3d-iot`.

**GitLab pod is Pending or not Ready.** Check VM memory/disk, PVC state, pod events and logs:

```bash
kubectl -n gitlab get pods,pvc,svc
kubectl -n gitlab describe deployment iot-gitlab
kubectl -n gitlab logs deployment/iot-gitlab --tail=150
```

**Local GitLab cannot be reached from the VM.** Rerun `./bonus/scripts/IoT-start-gitlab-access.sh`; inspect `~/.config/iot/gitlab-portforward.log` and the local `/etc/hosts` mapping. The port-forward must remain active.

**A version change does not affect the application.** Confirm whether `iot-github` (P3) or `iot-gitlab` (Bonus) is the active Argo CD Application, then inspect its Git source, synchronization state, Deployment image and Pod rollout.

## 9. Security and useful references

Do not commit K3s join tokens, GitLab root passwords, GitLab personal access tokens, `.env` files or generated Kubernetes credentials. The Debian Vagrant `.box` archive and runtime state are deliberately excluded from Git. GitLab is configured for a private teaching lab, not exposed as a production service.

- [Project repository](https://github.com/jaderiverspirit/IoT-hlehmann)
- [Debian](https://www.debian.org/distrib/)
- [Vagrant machine configuration](https://developer.hashicorp.com/vagrant/docs/vagrantfile/machine_settings)
- [K3s documentation](https://docs.k3s.io/)
- [K3d documentation](https://k3d.io/stable/)
- [Argo CD documentation](https://argo-cd.readthedocs.io/en/stable/)
- [GitLab Docker installation](https://docs.gitlab.com/install/docker/installation/)
- [GitLab upgrade paths](https://docs.gitlab.com/update/upgrade_paths/)
