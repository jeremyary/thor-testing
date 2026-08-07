# This project was developed with assistance from AI tools.

# Physical AI Edge Flywheel — Deployment Guide

> [!NOTE]
> This project was developed with assistance from AI tools.

This document captures every step needed to recreate the Physical AI Edge Flywheel stack from scratch: a Jetson AGX Thor as a managed edge device running Cosmos3-Edge inference under MicroShift, connected to an OSD hub cluster running ACM, RHEM, Argo CD, MinIO, and Kafka — with a full GitOps pipeline delivering workloads to the device with zero inbound connections.

## Prerequisites

- NVIDIA Jetson AGX Thor developer kit running CentOS Stream 10 bootc (from sidecar team's image)
- OpenShift Dedicated (OSD) cluster on AWS with cluster-admin access
- SSH access to the Thor (`ssh root@thor`)
- GitHub account with `gh` CLI authenticated
- Quay.io account with a robot account for push access
- GitLab read token for the base image registry

## 1. Derived Bootc Image (Phase 1)

### 1.1 Containerfile

The derived image (`derived-image/Containerfile`) layers onto the sidecar team's CentOS Stream 10 Thor image and adds:

- **unbound-libs** — runtime dependency for el9 OVS on CS10
- **MicroShift 4.22** — el9 RPMs installed with `--nodeps` for el9/el10 cross
- **CRI-O 1.35** + cri-tools + OVS 3.5 + microshift-networking — from OCP deps mirror
- **flightctl-agent** — from flightctl EPEL10 repo
- **oc CLI** — from OCP mirror
- **NVIDIA GPU reset service** — systemd oneshot that reloads nvidia modules after boot (Thor GCx workaround)
- **Greenboot health checks** — MicroShift running + GPU accessibility
- **Sigstore policy placeholder** — permissive `policy.json`
- **MicroShift config** — minimal: dns.baseDomain=thor.local, node.hostnameOverride=thor
- **Day-0 manifests** — nvidia-device-plugin DaemonSet
- **Persistent directories** — `/var/lib/models`, `/var/lib/episodes`, `/var/lib/checkpoints`

Key RPM sources:
- MicroShift: `mirror.openshift.com/pub/openshift-v4/aarch64/microshift/ocp/latest-4.22/el9/os`
- CRI-O/OVS: `mirror.openshift.com/pub/openshift-v4/aarch64/dependencies/rpms/4.22-el9-beta`
- flightctl-agent: `rpm.flightctl.io/flightctl-epel10.repo`

### 1.2 GPU Reset Service

Thor requires an NVIDIA module reload after boot because display module loading leaves the GPU in a bad compute state (GCx issue). The service at `config/nvidia-gpu-reset.service` runs after `nv-load-display-modules.service` and before `crio.service`:

```
modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia
modprobe nvidia && modprobe nvidia_uvm
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

### 1.3 Building the Image

The image is arm64 and must be built natively or cross-built with qemu. An OpenShift BuildConfig handles this (see Section 8).

### 1.4 Deploying to Thor

```bash
bootc switch --transport registry quay.io/jary/thor-edge:latest
reboot
```

### 1.5 Known Workarounds

- **CUDA pre-initialization**: `torch.zeros(1, device="cuda")` must be called before importing vLLM. Without this, vLLM's config creation breaks CUDA.
- **vLLM v1 multiprocessing**: `VLLM_ENABLE_V1_MULTIPROCESSING=0` — the EngineCore subprocess can't see the GPU through CDI/CRI-O.
- **HuggingFace XET**: `HF_HUB_DISABLE_XET=1` — xet download parser fails on some model repos.
- **NVIDIA device plugin**: Use `envvar` strategy, not CDI — Jetson doesn't support the CDI device-list mode. Requires hostPath mount of `/usr/lib64/nvidia`.

## 2. Hub Foundation (Phase 2)

### 2.1 ACM 2.17

Install via OperatorHub: Advanced Cluster Management for Kubernetes. Create the MultiClusterHub CR in `open-cluster-management` namespace. Wait for all components to become ready.

### 2.2 RHEM (flightctl)

Install via Helm:

```bash
helm repo add flightctl https://flightctl.github.io/flightctl
helm install flightctl flightctl/flightctl -n flightctl --create-namespace
```

**RBAC fix required (flightctl v1.1.0 bug):** The `flightctl-admin` role is silently dropped when it comes from a per-org RoleBinding. The admin role is treated as global-only, requiring `system:cluster-admins` group (OSD uses `cluster-admins` instead). Workaround:

```bash
# Label the namespace for org mapping
oc label ns flightctl io.flightctl/instance=flightctl

# Create org-admin ClusterRole (admin without the silent-drop bug)
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: flightctl-org-admin-flightctl
rules:
- apiGroups: [flightctl.io]
  resources: ['*']
  verbs: ['*']
EOF

# Bind to user and cluster-admins group
oc create rolebinding flightctl-org-admin-jary \
  --clusterrole=flightctl-org-admin-flightctl \
  --user=jary@redhat.com -n flightctl

oc create rolebinding flightctl-org-admin-cluster-admins \
  --clusterrole=flightctl-org-admin-flightctl \
  --group=cluster-admins -n flightctl
```

### 2.3 MinIO

Deploy in `robotics-data` namespace with routes for API and console:

- API route: `minio-api-robotics-data.apps.<cluster>/`
- Console route: `minio-console-robotics-data.apps.<cluster>/`
- Credentials: set via `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` env vars

### 2.4 Kafka (AMQ Streams)

Kafka cluster `fleet` in `fleet-ops` namespace with:
- Internal plain listener (9092)
- Internal TLS listener (9093)
- External route listener (9094, TLS)
- Topic: `episode-manifests` (3 partitions, 1 replica)

### 2.5 OpenShift GitOps (Argo CD)

Already installed (v1.21.1). Used for delivering workloads to Thor via the ACM pull model.

## 3. Thor Enrollment

### 3.1 RHEM Enrollment

Generate an enrollment certificate via the flightctl CLI:

```bash
flightctl login <api-url> --token $(oc whoami -t) --insecure-skip-tls-verify
flightctl certificate request --name thor-enrollment --signer flightctl.io/enrollment \
  --output embedded --output-dir ./enrollment-out > agent-config.yaml
```

Deploy to Thor:

```bash
scp agent-config.yaml root@thor:/etc/flightctl/config.yaml
ssh root@thor "rm -rf /var/lib/flightctl; systemctl restart flightctl-agent"
```

Approve the enrollment request:

```bash
flightctl approve enrollmentrequest <device-id>
```

### 3.2 ACM ManagedCluster

Create the ManagedCluster resource on the hub:

```yaml
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: thor
  labels:
    environment: edge
    device: jetson-thor
spec:
  hubAcceptsClient: true
```

Extract and apply import manifests on Thor's MicroShift:

```bash
oc get secret thor-import -n thor -o jsonpath='{.data.crds\.yaml}' | base64 -d | \
  ssh root@thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig oc apply -f -"
oc get secret thor-import -n thor -o jsonpath='{.data.import\.yaml}' | base64 -d | \
  ssh root@thor "KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig oc apply -f -"
```

Enable the application-manager addon:

```yaml
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: application-manager
  namespace: thor
spec:
  installNamespace: open-cluster-management-agent-addon
```

### 3.3 ACM-GitOps Integration

```bash
# Bind ManagedClusterSet to gitops namespace
oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: default
  namespace: openshift-gitops
spec:
  clusterSet: default
EOF

# Placement selecting edge devices
oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: edge-devices
  namespace: openshift-gitops
spec:
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            environment: edge
EOF

# GitOpsCluster connecting placement to Argo CD
oc apply -f - <<EOF
apiVersion: apps.open-cluster-management.io/v1beta1
kind: GitOpsCluster
metadata:
  name: edge-gitops
  namespace: openshift-gitops
spec:
  argoServer:
    cluster: local-cluster
    argoNamespace: openshift-gitops
  placementRef:
    kind: Placement
    apiVersion: cluster.open-cluster-management.io/v1beta1
    name: edge-devices
EOF
```

This registers Thor as an Argo CD destination via the ACM cluster-proxy tunnel (outbound from Thor, zero inbound connections).

## 4. GitOps Workload Delivery

### 4.1 Git Repository

`github.com/jeremyary/thor-testing` — manifests in `gitops/` subdirectories:

```
gitops/
  edge-workloads/     # smoke test ConfigMap
  vllm-cosmos3/       # Cosmos3-Edge deployment, service, entrypoint, SCC
  flywheel/           # robot-sim, curator, sync-agent
```

### 4.2 ApplicationSets

Each workload directory gets an ApplicationSet using the ACM cluster generator:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: <name>
  namespace: openshift-gitops
spec:
  generators:
    - clusterDecisionResource:
        configMapRef: acm-placement
        labelSelector:
          matchLabels:
            cluster.open-cluster-management.io/placement: edge-devices
        requeueAfterSeconds: 180
  template:
    metadata:
      name: '<name>-{{name}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/jeremyary/thor-testing.git
        path: gitops/<directory>
        targetRevision: main
      destination:
        server: '{{server}}'
        namespace: <namespace>
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

### 4.3 Secrets (not in Git)

These secrets must be created manually on Thor's MicroShift before workloads deploy:

```bash
# HuggingFace token for model downloads
KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
oc create secret generic hf-credentials --from-literal=token=$HF_TOKEN -n vllm

# Hub credentials for flywheel sync-agent
KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
oc create secret generic hub-credentials \
  --from-literal=s3-access-key=<minio-user> \
  --from-literal=s3-secret-key=<minio-password> -n flywheel
```

## 5. Cosmos3-Edge Inference (Phase 3)

Cosmos3-Edge runs via vLLM-Omni as a MicroShift Deployment:

- **Image**: `docker.io/vllm/vllm-omni:cosmos3`
- **Mode**: Generator (omni) — `--omni` flag means all requests go through diffusion, not text reasoning
- **Port**: NodePort 30800
- **GPU**: nvidia.com/gpu: 1 (privileged, hostPath nvidia libs)
- **Model cache**: `/var/lib/models/huggingface` (persistent across OS updates)
- **Entrypoint**: ConfigMap-mounted script with CUDA pre-init + `vllm.scripts.main()`

Reasoner vs Generator are separate container images — you cannot switch modes per-request with the omni container.

## 6. Data Flywheel (Phase 3 — brief)

Three workloads in the `flywheel` namespace, defaulting to `replicas: 0`:

### robot-sim
Generates episodes at 1 Hz (5 ticks/episode) by calling Cosmos3-Edge. 30% failure injection rate. Writes episodes to `/var/lib/episodes/raw/`.

### curator
Watches raw episodes, scores them on heuristic quality signals (failure flag, latency budget, inference errors). Passes clean episodes to `/var/lib/episodes/curated/`, rejects to `/var/lib/episodes/rejected/`. No model-based scoring — Cosmos3 in omni mode can't do text scoring.

### sync-agent
Uploads curated episodes to MinIO bucket `episodes-curated`, publishes JSON manifests to Kafka topic `episode-manifests`. Runs continuously, idles when no new curated data.

**Start/stop the flywheel:**
```bash
KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
oc scale deployment robot-sim curator -n flywheel --replicas=1  # start

KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig \
oc scale deployment robot-sim curator -n flywheel --replicas=0  # stop
```

Argo won't fight manual scaling — manifests default to `replicas: 0`.

**Validated contract**: rejected episodes (failure-injected) stay on-device and never reach MinIO.

## 7. Connectivity Model

All flows are outbound from Thor — zero inbound connections required:

| Flow | Direction | Mechanism |
|------|-----------|-----------|
| RHEM agent → hub | Thor → hub | flightctl-agent polls |
| ACM klusterlet → hub | Thor → hub | klusterlet heartbeat |
| Argo workload sync | Hub → Thor via cluster-proxy | ACM cluster-proxy tunnel (outbound from Thor) |
| Episode upload | Thor → hub | sync-agent → MinIO S3 route |
| Kafka manifests | Thor → hub | sync-agent → Kafka external route |
| Image pulls | Thor → registry | CRI-O/bootc → Quay/Docker Hub |

## 8. Arm64 Image Build Pipeline

### 8.1 qemu-user-static (cluster-wide)

Deploy a DaemonSet to register aarch64 binfmt handlers on all OSD nodes:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: qemu-user-static
  namespace: openshift-operators
spec:
  selector:
    matchLabels:
      app: qemu-user-static
  template:
    metadata:
      labels:
        app: qemu-user-static
    spec:
      serviceAccountName: qemu-binfmt
      initContainers:
        - name: register
          image: docker.io/multiarch/qemu-user-static:latest
          args: ["--reset", "-p", "yes"]
          securityContext:
            privileged: true
      containers:
        - name: sleep
          image: registry.access.redhat.com/ubi9/ubi-micro:latest
          command: ["sleep", "infinity"]
      tolerations:
        - operator: Exists
```

Requires a ServiceAccount with privileged SCC:
```bash
oc create sa qemu-binfmt -n openshift-operators
oc adm policy add-scc-to-user privileged -z qemu-binfmt -n openshift-operators
```

### 8.2 OpenShift BuildConfig

```yaml
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: thor-edge-image
  namespace: thor-builds
spec:
  source:
    type: Git
    git:
      uri: https://github.com/jeremyary/thor-testing.git
      ref: main
    contextDir: derived-image
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Containerfile
      buildArgs:
        - name: BASE_IMAGE
          value: registry.gitlab.com/redhat/rhel/sst/orin-sidecar/nvidia-jetson-sidecar/rhel-stream10:a66617e5-thor
      pullSecret:
        name: gitlab-pull-secret
  output:
    to:
      kind: DockerImage
      name: quay.io/jary/thor-edge:latest
    pushSecret:
      name: quay-push-secret
```

Registry secrets in `thor-builds` namespace:
```bash
oc create secret docker-registry quay-push-secret \
  --docker-server=quay.io --docker-username=$QUAY_ROBOT_USER --docker-password=$QUAY_ROBOT_TOKEN
oc create secret docker-registry gitlab-pull-secret \
  --docker-server=registry.gitlab.com --docker-username=$GITLAB_RO_USER --docker-password=$GITLAB_RO_TOKEN
oc secrets link builder quay-push-secret gitlab-pull-secret
```

Trigger a build: `oc start-build thor-edge-image -n thor-builds`

## 9. Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Edge K8s | MicroShift 4.22 (el9 RPMs on CS10) | SNO requires RHCOS; MicroShift layers onto existing bootc OS |
| GPU plugin | k8s-device-plugin with envvar strategy | Jetson doesn't support CDI mode; GPU Operator too heavy for MicroShift |
| Model serving | vLLM-Omni (Generator mode) | Cosmos3-Edge is omni-modal; Reasoner vs Generator is per-container, not per-request |
| On-device curation | Heuristic (failure/latency/error signals) | Cosmos3 omni mode can't do text scoring — all requests trigger diffusion |
| RHEM RBAC | org-admin role workaround | flightctl v1.1.0 bug drops flightctl-admin from per-org RoleBindings |
| Argo delivery | ACM cluster-proxy (push via tunnel) | Zero inbound connections; cluster-proxy tunnel is outbound from Thor |
| Arm64 builds | OpenShift BuildConfig + qemu-user-static | No Graviton machinepools on OSD; RHEM ImageBuild API only injects flightctl-agent |
| Flywheel default | replicas: 0 | GPU coil whine during continuous inference; scale up manually for testing/demo |
