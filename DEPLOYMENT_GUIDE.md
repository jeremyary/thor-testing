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
- Internal OpenShift registry (included with OSD)
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

### 1.4 Embedded Workload Images (Air-Gapped Operation)

Workload container images are embedded in the bootc image during build, following Red Hat's documented pattern for disconnected MicroShift. No device-side registry needed.

**`config/embedded-images.txt`** lists images to embed:
```
docker.io/vllm/vllm-omni:cosmos3
docker.io/library/python:3.12-slim
docker.io/library/registry:2
```

The Containerfile uses `skopeo copy` to pull them into `/usr/lib/containers/storage/` as `dir:` blobs at build time. A systemd `ExecStartPre` drop-in on `microshift.service` loads them into CRI-O's `containers-storage:` at every boot.

### 1.5 OpenTelemetry Collector (RPM)

The `opentelemetry-collector` RPM from CentOS Stream 10 AppStream is baked into the image. Runs as a systemd service with host-level access to journald, hostmetrics, and GPU telemetry. Config at `/etc/opentelemetry-collector/config.yaml` includes:

- Prometheus receiver: scrapes vLLM `/metrics`
- Journald receiver: MicroShift, CRI-O, flightctl-agent, GPU reset logs
- Host metrics: CPU, memory, disk, load, network
- OTLP receiver: for application traces
- File-storage persistent queue at `/var/lib/otel-queue` for disconnect tolerance
- OTLP/HTTP exporter to hub gateway with `max_elapsed_time: 0` (retry forever)

### 1.6 Deploying to Thor

```bash
# From the internal registry (hub-side build)
bootc switch --transport registry default-route-openshift-image-registry.apps.<cluster>/thor-builds/thor-edge:latest
reboot
```

### 1.7 Known Workarounds

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

### 8.2 Tekton Pipeline (Build + Sign)

The image build uses an OpenShift Pipelines (Tekton) pipeline that clones the repo, cross-builds the arm64 bootc image with buildah, pushes to the internal registry, and signs with cosign + RHTAS Rekor in a single pipeline run. Manifests live in `tekton/`.

**Prerequisites:**
- OpenShift Pipelines operator installed
- RHTAS deployed (Section 9) with cosign keypair generated
- qemu-user-static DaemonSet running (Section 8.1)

**Secrets in `thor-builds` namespace:**
```bash
# GitLab pull secret for the base image
oc create secret docker-registry gitlab-pull-secret \
  --docker-server=registry.gitlab.com \
  --docker-username=$GITLAB_RO_USER \
  --docker-password=$GITLAB_RO_TOKEN \
  -n thor-builds

# Cosign signing key (from the keypair generated in Section 9.3)
oc create secret generic cosign-signing-key \
  --from-file=cosign.key=thor-signing.key \
  --from-file=cosign.pub=thor-signing.pub \
  --from-literal=cosign.password="" \
  -n thor-builds

# Link the pull secret to the pipeline SA
oc secrets link pipeline gitlab-pull-secret --for=pull,mount -n thor-builds
```

**Apply the pipeline manifests:**
```bash
oc apply -f tekton/01-cosign-sign-task.yaml
oc apply -f tekton/02-pipeline.yaml
```

**Trigger a build:**
```bash
oc create -f tekton/03-pipelinerun.yaml
```

The pipeline runs three tasks sequentially:
1. **git-clone** — clones the repo (ClusterTask)
2. **build-and-push** — cross-builds the arm64 image via buildah + qemu, pushes to internal registry (ClusterTask)
3. **sign-image** — signs the pushed image by digest with cosign, uploads signature to RHTAS Rekor

The PipelineRun timeout is set to 3 hours to accommodate the qemu cross-build. Monitor with:
```bash
tkn pipelinerun logs -f -n thor-builds
```

## 9. Trust Plane — RHTAS (Phase 5)

### 9.1 RHTAS Operator

Install from OperatorHub: "Red Hat Trusted Artifact Signer" (stable channel). May require manual InstallPlan approval on OSD.

### 9.2 Securesign CR

```yaml
apiVersion: rhtas.redhat.com/v1alpha1
kind: Securesign
metadata:
  name: securesign
  namespace: trusted-artifact-signer
spec:
  fulcio:
    certificate:
      commonName: fulcio.thor-testing
      organizationName: thor-testing
      organizationEmail: jary@redhat.com
    config:
      OIDCIssuers:
        - Issuer: "https://oauth-openshift.apps.<cluster>"
          IssuerURL: "https://oauth-openshift.apps.<cluster>"
          ClientID: sigstore
          Type: email
    externalAccess:
      enabled: true
  rekor:
    externalAccess:
      enabled: true
  trillian:
    database:
      create: true
  ctlog:
    prefix: trusted-artifact-signer
  tuf:
    externalAccess:
      enabled: true
    keys:
      - name: rekor.pub
      - name: ctfe.pub
      - name: fulcio_v1.crt.pem
```

Note: explicitly list TUF keys without `tsa.certchain.pem` — TSA is not configured, and TUF will hang on "Resolving keys" if it expects one.

### 9.3 Cosign Signing

Generate a keypair and initialize cosign with TUF root:

```bash
cosign generate-key-pair --output-key-prefix=thor-signing
cosign initialize --mirror=$TUF_URL --root=$TUF_URL/root.json
```

Signing is automated as part of the Tekton build pipeline (Section 8.2). The pipeline's `sign-image` task uses the `cosign-signing-key` Secret and logs to Rekor.

To sign manually (e.g., for testing):
```bash
COSIGN_PASSWORD="" cosign sign --key=thor-signing.key \
  --rekor-url=$REKOR_URL \
  --tlog-upload=true \
  -y default-route-openshift-image-registry.apps.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com/thor-builds/thor-edge:latest
```

### 9.4 Device-Side Policy

Three files deployed to Thor (baked into the derived image):

**`/etc/containers/policy.json`** — enforces sigstoreSigned for internal-registry/thor-builds:
```json
{
  "default": [{"type": "insecureAcceptAnything"}],
  "transports": {
    "docker": {
      "internal-registry/thor-builds": [{
        "type": "sigstoreSigned",
        "keyPath": "/etc/pki/containers/cosign-signing.pub",
        "signedIdentity": {"type": "matchRepository"}
      }]
    }
  }
}
```

**`/etc/pki/containers/cosign-signing.pub`** — the cosign public key.

**`/etc/containers/registries.d/quay-jary.yaml`** — enables sigstore attachment discovery:
```yaml
docker:
  internal-registry/thor-builds:
    use-sigstore-attachments: true
```

### 9.5 Verification Tests

Positive test (signed image should pull):
```bash
podman pull default-route-openshift-image-registry.apps.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com/thor-builds/thor-edge:latest  # should succeed
```

Negative test (unsigned tag should be refused):
```bash
podman pull default-route-openshift-image-registry.apps.g4h4d3j7q1c9f7m.cimo.p1.openshiftapps.com/thor-builds/thor-edge:unsigned  # should fail with policy violation
```

## 10. Telemetry (Phase 6)

### 10.1 Hub Operators

Install from OperatorHub:
- **Cluster Observability Operator (COO)** — stable channel, Red Hat Operators
- **Tempo Operator** — bundled with COO install plan

The Red Hat build of OpenTelemetry CRDs are included with COO.

### 10.2 TempoStack

Deploy in the `observability` namespace, backed by MinIO:

```yaml
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: edge-traces
  namespace: observability
spec:
  storage:
    secret:
      name: tempo-minio
      type: s3
  template:
    queryFrontend:
      jaegerQuery:
        enabled: true
        ingress:
          type: route
  storageSize: 10Gi
  retention:
    global:
      traces: 168h
```

MinIO secret references the existing MinIO in `robotics-data` namespace. Create a `tempo-traces` bucket.

### 10.3 Hub OTel Gateway

An `OpenTelemetryCollector` CR in deployment mode with an external route:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: edge-gateway
  namespace: observability
spec:
  mode: deployment
  ingress:
    type: route
    route:
      termination: edge
  config:
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch: {}
      memory_limiter:
        limit_mib: 512
    exporters:
      otlp/tempo:
        endpoint: tempo-edge-traces-distributor.observability.svc:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/tempo]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
```

Exposes routes:
- `otlp-http-edge-gateway-route-observability.apps.<cluster>` — OTLP/HTTP for edge collector
- `otlp-grpc-edge-gateway-route-observability.apps.<cluster>` — OTLP/gRPC

### 10.4 Device OTel Collector

Installed as an RPM in the bootc image (see Section 1.5). Config at `/etc/opentelemetry-collector/config.yaml`. Key features:

- **Connected mode**: telemetry flows to hub in real-time via OTLP/HTTP route
- **Disconnected mode**: `file_storage` extension spools to `/var/lib/otel-queue` on NVMe, `max_elapsed_time: 0` retries indefinitely, drains automatically when connectivity returns
- **Resource attributes**: `device.id`, `device.type`, `model.version` stamped on all signals for Perses/console filtering

### 10.5 Disconnect Tolerance Test

```bash
# On Thor: pull the uplink
ip link set enP2p1s0 down

# Run the flywheel — telemetry spools locally
oc scale deployment robot-sim curator -n flywheel --replicas=1

# After some episodes, restore connectivity
ip link set enP2p1s0 up

# Watch the backfill in the hub's Tempo UI / Perses
```

### 10.6 Visualization

COO provides OpenShift console UI plugins for distributed tracing and log correlation. The Tempo query frontend route provides a Jaeger-compatible UI for trace exploration. For custom dashboards, the Perses (GA in COO 1.5) provides console-integrated dashboards via PersesDashboard CRs. COO UIPlugins add distributed tracing and logging views.

## 11. Decision Log

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
| Image signing | Static cosign keypair + RHTAS Rekor | Full keyless needs OIDC client registration; static keys prove the same trust mechanics with Rekor transparency |
| Trust enforcement | sigstoreSigned in policy.json + registries.d | CRI-O and bootc both enforce policy.json per-registry rules via skopeo/containers-image; unsigned images from internal-registry/thor-builds refused. `registries.d/internal-registry.yaml` with `use-sigstore-attachments: true` is required alongside policy.json (D018). bootc pull-path enforcement confirmed identical to CRI-O via live testing (D019). |
| Air-gapped images | Embedded in bootc via skopeo + systemd loader | Red Hat's documented MicroShift disconnected pattern; no device-side registry needed |
| OTel collector | RPM systemd service (not container) | Upstream contrib container fails on arm64; RPM gives host-level access to journald/GPU telemetry |
| Build output | Internal OpenShift registry | Hub-side source of truth; devices receive images embedded in bootc, not pulled from external registry |
