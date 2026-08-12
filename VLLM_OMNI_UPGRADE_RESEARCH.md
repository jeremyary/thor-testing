# vLLM-Omni Upgrade Research: Native Cosmos3 FP8 ModelOpt/Diffusers Remapping

> [!NOTE]
> This project was developed with assistance from AI tools.

> [!IMPORTANT]
> **This is a research/proposal document, not a record of a completed change.**
> Nothing in this document has been applied to the live Thor device or any cluster.
> This research environment has **no cluster, SSH, or Thor hardware access** — every
> claim about GPU behavior, inference correctness, or container runtime compatibility
> below is either (a) sourced directly from upstream code/docs/CI configuration with a
> citation, or (b) explicitly flagged as **unverified, pending live validation on Thor**.
> Treat the recommendation in §5 as a candidate for the next maintenance window, not
> something to `git merge` and walk away from.

## 0. Scope and question being answered

`gitops/vllm-cosmos3/deployment.yaml` runs `docker.io/vllm/vllm-omni:cosmos3` to serve
Cosmos3-Edge in `--omni` (Generator/diffusion) mode. Upstream vLLM landed
[PR #48952](https://github.com/vllm-project/vllm/pull/48952) ("Cosmos3 FP8
ModelOpt/Diffusers remapping") on 2026-07-20. The question this doc answers: **does
any real, obtainable `vllm/vllm-omni` image tag give us that capability, and if so,
what changes (if any) does that require in this repo?**

The short answer turned out to be more interesting than "check the release notes":
PR #48952 isn't even the fix that matters for this deployment — it's a fix to
**vanilla vLLM's own** `Cosmos3ForConditionalGeneration` text-reasoning model, in the
`vllm-project/vllm` repo, not the diffusion/world-model path this deployment uses. See
§2.

## 1. `docker.io/vllm/vllm-omni` — what actually exists

### 1.1 It's a real, separate project, not a vanilla-vLLM tag alias

`vllm-project/vllm-omni` is its own GitHub repository (Apache-2.0, ~6.1k stars),
publicly released 2025/11, extending vanilla `vllm-project/vllm` with
non-autoregressive/diffusion serving. It vendors its own model implementations
(`vllm_omni/diffusion/models/cosmos3/...`) and registers them into a vanilla `vllm`
process via vLLM's `vllm.general_plugins` entry-point mechanism — it does **not**
patch or fork vLLM core. Source: `pyproject.toml` at
[vllm-project/vllm-omni@v0.26.0](https://github.com/vllm-project/vllm-omni/blob/v0.26.0/pyproject.toml):

```toml
[project.entry-points."vllm.general_plugins"]
vllm_omni_register_models = "vllm_omni.engine.arg_utils:register_omni_models_to_vllm"
```

This is why this repo's entrypoint script can do `from vllm.scripts import main` (the
**vanilla vLLM** CLI entry point, not `vllm_omni`'s own) and still get `--omni`
support — as long as `vllm-omni` is `pip install`ed in the same environment, vanilla
vLLM's own plugin loader picks it up. This mechanism is unchanged from whatever
version is running today through v0.26.0 (confirmed by reading `pyproject.toml` at
that tag) — nothing about it requires an entrypoint rewrite.

### 1.2 Release cadence: only even-numbered vLLM minors get a stable vllm-omni release

From the [vllm-omni README](https://github.com/vllm-project/vllm-omni/blob/main/README.md)
(2026/06 entry) and confirmed against the actual git tag list
(`GET /repos/vllm-project/vllm-omni/tags`, fetched 2026-08-12):

> "Starting with 0.14.0, vLLM-Omni publishes a stable release aligned with every
> even-numbered upstream vLLM minor version."

Observed tags (release-candidate tags exist for *every* minor; only even minors get
promoted past `rc`):

| vllm-omni tag | Status |
|---|---|
| v0.24.0, v0.24.1 | stable |
| v0.25.0rc1 | **rc only — never stabilized** |
| v0.26.0 | stable, released 2026-08-03 |
| **v0.27.0rc1** | **rc only, exists but is not (and per stated policy will not be) promoted to a stable v0.27.0** |

**This directly contradicts the "v0.27.x-era feature set" framing in the original
ask.** There is no stable vllm-omni v0.27.0 to target, by the project's own stated
versioning policy — the next stable release will be v0.28.0, aligned with whatever
vLLM 0.28.0 ships. Recommending a v0.27.x image tag would mean recommending an
unreleased release-candidate line that the project itself doesn't intend to ship as
stable.

### 1.3 The desired feature is already in the stable v0.26.0 release — no v0.27.x needed

The [v0.26.0 release notes](https://github.com/vllm-project/vllm-omni/releases/tag/v0.26.0)
(released 2026-08-03, i.e. 9 days before this research) list, under Quantization &
Memory Efficiency:

> "Fix loading of ModelOpt FP8 checkpoints for Cosmos3 by @wkutak in #5076"
> "[Bugfix][Quantization] Remap ModelOpt NVFP4 scale tensors by @pst2154 in #5087"
> "Improved ModelOpt checkpoint compatibility with Cosmos3 FP8 loading and NVFP4
> scale-tensor remapping. (#5076, #5087)"

`@wkutak` is the same NVIDIA engineer who authored the vanilla-vLLM PR #48952 cited in
the original task. These are companion fixes in two different repos, for two different
Cosmos3 code paths:

| Fix | Repo | Model path | Relevant to this deployment? |
|---|---|---|---|
| PR #48952 (Jul 20, 2026) | `vllm-project/vllm` | `Cosmos3ForConditionalGeneration` — vanilla-vLLM's own AR text model, used for a standalone Reasoner-only deployment (see `DECISIONS.md` D006 for why this repo doesn't currently run one) | No — this repo runs `--omni` (Generator/diffusion), not a bare Reasoner |
| PR #5076 / #5087 (landed by v0.26.0, Aug 2026) | `vllm-project/vllm-omni` | `Cosmos3OmniDiffusersPipeline` (`vllm_omni/diffusion/models/cosmos3/pipeline_cosmos3.py`) — the diffusion Generator path this deployment actually uses via `--omni` | **Yes — this is the one that matters here** |

Net: the feature this repo actually needs shipped in the already-released, stable
**v0.26.0**, not in some future v0.27.x. Chasing v0.27.x would mean adopting an
unreleased RC line for no additional benefit relevant to this goal (see §1.4 for why
it would also be actively worse).

### 1.4 v0.27.x carries the breaking PyTorch/Triton change; v0.26.0 does not

Confirmed directly against `requirements/cuda.txt` in the **vanilla `vllm-project/vllm`**
repo (which vllm-omni's Dockerfile rebases onto — see §1.5):

| vLLM tag | `torch` pin | `torchvision` pin | `flashinfer-python` pin |
|---|---|---|---|
| [v0.26.0](https://github.com/vllm-project/vllm/blob/v0.26.0/requirements/cuda.txt) | `2.11.0` | `0.26.0` | `0.6.14` |
| [v0.27.0](https://github.com/vllm-project/vllm/blob/v0.27.0/requirements/cuda.txt) | **`2.13.0`** | `0.28.0` | `0.6.16.post3` |

This confirms the PyTorch 2.13.0 bump referenced in the task's context is real and is
specific to the v0.27.x line. **Recommending v0.26.0 instead of v0.27.x sidesteps this
breaking change entirely** — we get the FP8 remapping fix without touching the
PyTorch/Triton/FlashAttention-4 JIT risk area at all. This is a meaningful secondary
finding: the "safe" and "featureful" choices are the same choice here.

### 1.5 What DockerHub tags the official pipeline actually produces — and why `:cosmos3` doesn't fit

`docker.io/vllm/vllm-omni` **is** the real, official DockerHub repo for this project —
confirmed via `.buildkite/release/scripts/publish-release-images.sh` in the vllm-omni
repo, which hardcodes `DOCKERHUB_REPO="vllm/vllm-omni"` and pushes as the `vllmbot`
DockerHub account. Reading that script and its calling pipeline
(`.buildkite/release/release-pipeline.yml`) end to end:

- Images are built from `docker/Dockerfile.cuda`, whose default base image is
  `vllm/vllm-openai:v<matching vLLM version>` (e.g. `v0.26.0`) — i.e. vanilla vLLM's
  own published OpenAI-compatible serving image, not a Jetson/L4T-specific base.
- The release pipeline builds **both** `x86_64` and `aarch64` (`arm64_cpu_queue_release`
  runner) variants from that same Dockerfile, and publishes them as a multi-arch
  manifest list.
- The only tags this pipeline ever produces are: `latest`, `v<version>` (e.g. `v0.26.0`),
  `nightly`, `nightly-<commit-sha>` — plus internal `-x86_64`/`-aarch64` arch-suffixed
  tags that get folded into the manifest lists above.

**There is no `cosmos3` tag anywhere in this pipeline.** The currently-deployed
`docker.io/vllm/vllm-omni:cosmos3` does not match this project's own release-tag
naming scheme at all. Cross-referencing this repo's own `VLLM_ON_THOR.md`
(written from direct, live investigation on the actual Thor hardware, not from this
research session) confirms what `:cosmos3` actually is:

> "The `vllm/vllm-omni:cosmos3` container ships with arm64 support, vLLM 0.25.0, and
> vllm-omni 0.25.0rc2 pre-installed." (`VLLM_ON_THOR.md:321-322`)
>
> "vllm-omni versions are tightly coupled to vLLM versions... Cross-version installs
> fail on import due to internal API changes." (`VLLM_ON_THOR.md:605-606`)

So `:cosmos3` is a **pinned-to-`0.25.0rc2` snapshot** (an unreleased release candidate,
one full stable release behind `v0.26.0`), evidently built and pushed by hand (or by
NVIDIA/community tooling outside vllm-omni's own CI) under a memorable model-name tag
rather than that project's normal versioned scheme — most likely for the Jetson Thor
demo/benchmark NVIDIA published for Cosmos3-Edge (`VLLM_ON_THOR.md:316-317` cites
NVIDIA's own Thor T5000 benchmark numbers for this exact container). This is
**exactly** the situation the task asked us to be suspicious of, and the suspicion
was warranted: `:cosmos3` predates the v0.26.0 rebase that shipped the FP8 fix we
want, so the live deployment genuinely lacks the desired capability today — this
isn't just a version-number technicality.

### 1.6 What we could **not** verify — Docker Hub is unreachable from this environment

Every attempt to reach `hub.docker.com` (both the web UI and the `/v2/` registry API)
from this research environment failed at the transport layer (`curl` through the
configured proxy returned a bare `403` on the `CONNECT` itself; the `webfetch` tool
returned a generic transport error for every `hub.docker.com` URL tried, including a
control test against `https://example.com`, which also failed — `github.com` and
`raw.githubusercontent.com` were reachable throughout, so this looks like an
allowlist limitation of this environment rather than a Docker Hub outage).

Concretely, this means **none of the following could be directly confirmed** and must
be checked from a machine with real registry access before acting on this document:

- That `docker.io/vllm/vllm-omni:v0.26.0` actually exists as a pullable tag today
  (it *should*, per the release pipeline triggering off the `v0.26.0` GitHub release
  tagged 2026-08-03 — but "should, per pipeline definition" is not the same as
  "confirmed present in the registry").
- The exact digest, arch list, and layer history of both `:cosmos3` (currently
  running) and `:v0.26.0` (proposed).
- Whether the `aarch64` variant of `:v0.26.0`, built from vanilla `vllm/vllm-openai`'s
  base image, actually contains Blackwell/SM_110 (Thor) compatible CUDA kernels/cubins,
  as opposed to only targeting server-class aarch64 (e.g. GH200/Grace-Hopper). Thor
  uses NVIDIA's Jetson OpenRM driver stack (`VLLM_ON_THOR.md`'s Step 1-3 material,
  `DECISIONS.md` D002), which is a different runtime target than datacenter aarch64
  GPUs even though both are CUDA/aarch64. This repo's existing deployment pattern
  (bind-mounting the host's `libcuda.so.1` and driver libs into the container — see
  `nvidia-libs` hostPath volume in `deployment.yaml`) is exactly the kind of
  forward-compatibility trick that lets non-Jetson-specific images run on Thor (this
  repo's own `VLLM_ON_THOR.md` documents `nvcr.io/nvidia/vllm:26.07-py3`, a
  non-Jetson-specific NGC image, working on Thor this way), so this risk is
  **moderate, not fatal** — but it is not something this research session can rule
  out with confidence.

**Action required before touching the live cluster:** from a network-unrestricted
machine, run `skopeo inspect docker://docker.io/vllm/vllm-omni:v0.26.0` (and the
`--raw` variant to see the arch list in the manifest) and, ideally, an actual
`podman pull --arch arm64` + smoke-test on Thor or an equivalent Jetson device before
any GitOps merge. This is called out again in §6.

## 2. Does the entrypoint script need to change?

**No functional changes are required.** The custom entrypoint
(`gitops/vllm-cosmos3/entrypoint-configmap.yaml`) exists to work around a specific
vllm-omni quirk documented in `DECISIONS.md` D020: `pipeline_cosmos3.py`'s
`Cosmos3OmniDiffusersPipeline.__init__` computes
`local_files_only = os.path.exists(model_path)` once, from the raw `--model` string,
and reuses it for every `from_pretrained`/`load_config` call. A bare HF repo id like
`nvidia/Cosmos3-Edge` is never a real filesystem path, so this returns `False`, which
breaks `HF_HUB_OFFLINE=1`. The entrypoint's `snapshot_download(..., local_files_only=True)`
pre-resolution step exists specifically to make `os.path.exists()` see an absolute
local path instead.

I verified this against the **v0.26.0** tag directly (not main — the exact tag we're
proposing), by fetching `vllm_omni/diffusion/models/cosmos3/pipeline_cosmos3.py` and
`vllm_omni/engine/stage_init_utils.py` at that ref and diffing every commit that
touched either file between v0.24.0 and v0.26.0 (20 and 38 commits respectively):

- `pipeline_cosmos3.py`: the `local_files_only = os.path.exists(model_path)` line is
  present, **character-for-character identical**, at (now) line 868 — unchanged since
  the very first Cosmos3 commit. None of the 20 commits touching this file between
  v0.24.0 and v0.26.0 touch this logic; only unrelated code above it shifted the line
  number (728 → 868).
- `stage_init_utils.py`'s `_resolve_model_to_local_path()` (the built-in helper D020
  noted vllm-omni already has, but doesn't use by default) is unchanged and is still
  gated behind `model_subdir`/`tokenizer_subdir` stage args, which none of the four
  official Cosmos3 recipe docs (`Cosmos3-Edge.md`, `Cosmos3-Nano.md`,
  `Cosmos3-Super.md`, `Cosmos3-DistOffload.md`) set for a standard launch. The v0.26.0
  `Cosmos3-Edge.md` recipe itself still documents `vllm serve nvidia/Cosmos3-Edge --omni ...`
  with a bare repo id, with no offline-serving caveat.

**Conclusion:** the upstream gap D020 worked around has not been fixed as of v0.26.0.
Keep the entrypoint's pre-resolution step exactly as-is — removing it on the theory
that "a newer image probably fixed this" would be wrong and would silently reintroduce
the `HF_HUB_OFFLINE=1` breakage D020 closed.

The other moving parts of the entrypoint were also checked against v0.26.0 and found
unaffected:

- `--omni`, `--host`, `--port`, `--enforce-eager`, `--gpu-memory-utilization`,
  `--max-model-len`, `--init-timeout`, `--trust-remote-code` — the CLI shape used here
  matches the v0.26.0 `Cosmos3-Edge.md` recipe's own example invocation
  (`vllm serve nvidia/Cosmos3-Edge --omni --host 0.0.0.0 --port 8000 --init-timeout 1800`)
  almost verbatim.
- The `from vllm.scripts import main` / `vllm.general_plugins` integration point
  (§1.1) is unchanged in v0.26.0's `pyproject.toml`.

**One pre-existing (not upgrade-introduced) risk worth flagging while we're in this
file:** the entrypoint's `pip install --upgrade transformers -q` pulls whatever is
latest on PyPI at container start, unpinned, regardless of which vllm-omni image is
underneath. This was already true before any upgrade. v0.26.0's own release notes
mention transformers-version-sensitive bugs (`transformers >= 5.x` breaking Ming's
feature extractor registration, per the changelog). This isn't something the FP8
remapping goal requires touching, but if this upgrade is scheduled, it's a reasonable
time to also pin that `pip install` to a known-good version rather than floating —
called out here as a suggestion, not a blocker.

## 3. Cosmos3 FP8/ModelOpt checkpoint prerequisite

One more thing worth being explicit about, since it's easy to assume "upgrade the
image" alone flips a switch: the FP8 remapping fix (§1.3) makes vLLM-Omni's
`AutoWeightsLoader` correctly *load* a ModelOpt/Diffusers-format FP8 checkpoint by
dropping the ModelOpt-native quantizer buffers it doesn't need
(`*.input_quantizer._amax` etc.) instead of hard-failing. It does not, by itself,
convert `nvidia/Cosmos3-Edge`'s currently-cached BF16 checkpoint into an FP8 one. To
actually exercise this feature end-to-end on Thor, an FP8/ModelOpt-quantized Cosmos3
checkpoint variant would need to exist on HuggingFace and be pulled into the modelcar
pipeline (`tekton/05-modelcar-pipeline.yaml`, `modelcar/Containerfile`) — a separate
piece of work from the image upgrade itself, out of scope for this document, and not
attempted here.

## 4. What did *not* change / non-findings

- The `--omni` CLI flag itself, the `vllm.general_plugins` plugin-loading mechanism,
  and the overall `vllm serve <model> --omni` invocation shape are stable across
  v0.24.0 → v0.26.0.
- No breaking changes were found in the Cosmos3-Edge recipe's defaults (resolution,
  guidance scale, flow shift) between the versions checked.
- `HF_HUB_DISABLE_XET=1`, `VLLM_ENABLE_V1_MULTIPROCESSING=0`, and CUDA pre-init
  (D002/D003) are all Thor/driver-level workarounds unrelated to the vllm-omni
  version and are not expected to be affected either way — but see §6, none of this
  was re-verified on real hardware.

## 5. Recommendation

**Candidate change:** bump `gitops/vllm-cosmos3/deployment.yaml`'s image from
`docker.io/vllm/vllm-omni:cosmos3` (pinned to an undocumented `0.25.0rc2` snapshot,
predates the FP8 fix) to `docker.io/vllm/vllm-omni:v0.26.0` (stable, official, contains
the FP8 remapping fix, avoids the v0.27.x PyTorch/Triton breaking change). This diff is
presented on a separate branch (`research/vllm-omni-v0.26-upgrade`, not merged to
`main`) — see that branch for the exact patch. It is **not applied here** and should
not be merged or synced by Argo CD until the checklist in §6 is closed out.

**Explicitly not recommended:** any `v0.27.x` tag (including `v0.27.0rc1`, which is
the only one that currently exists) — it is a pre-release the project itself does not
plan to stabilize, it carries the PyTorch 2.13.0/Triton breaking-change risk called
out in the original task, and it provides no benefit over v0.26.0 for this specific
goal.

**Also explicitly not recommended:** pinning by digest in this document. This repo's
own convention (D014) is to pin vendor images by digest, and that's the right target
state here too — but resolving `v0.26.0` to a digest requires live registry access
this environment doesn't have (§1.6). The branch diff uses the tag; add a digest pin
as a follow-up once resolved from a machine that can reach Docker Hub.

## 6. Pending live-validation checklist (none of this has been done)

- [ ] Confirm `docker.io/vllm/vllm-omni:v0.26.0` exists and resolve it to a digest
      (`skopeo inspect` / `docker manifest inspect`) from a network-unrestricted host.
- [ ] Confirm the `aarch64` manifest entry actually contains Thor/SM_110-compatible
      CUDA kernels (not just a generic/server-aarch64 build) — pull and smoke-test on
      an actual Jetson device before touching the fleet-managed Thor.
- [ ] Pull the new image on (or for) Thor and confirm the existing CUDA pre-init
      (D002), `VLLM_ENABLE_V1_MULTIPROCESSING=0` (D003), and `HF_HUB_DISABLE_XET=1`
      workarounds are still necessary/sufficient — these were tuned against the
      `0.25.0rc2`/vLLM 0.25.0 stack and have not been re-validated against
      vLLM 0.26.0's engine internals.
- [ ] Confirm `HF_HUB_OFFLINE=1` + the entrypoint's `snapshot_download` pre-resolution
      (D020) still produces a working offline boot against the new image (expected to
      work per §2's source-level analysis, but not executed).
- [ ] Confirm the existing BF16 `nvidia/Cosmos3-Edge` modelcar checkpoint still loads
      correctly under v0.26.0 (the FP8 path is additive, but any checkpoint-loading
      change is worth a real boot-and-generate smoke test, not just a code read).
- [ ] Re-run the Recreate-strategy single-GPU rollout (`strategy.type: Recreate` in
      `deployment.yaml`) end to end and confirm no new `UnexpectedAdmissionError`
      pattern beyond the pre-existing cosmetic one noted in `PROJECT_STATUS.md`.
- [ ] If/when the FP8/ModelOpt Cosmos3-Edge checkpoint itself becomes available,
      validate the actual FP8 remapping path (§3) — this document only establishes
      that the *loader* fix is present in v0.26.0, not that FP8 inference has been
      exercised.
- [ ] Resolve `v0.26.0` to a digest and update the branch diff to pin by digest,
      per this repo's D014 convention, before merging.

## References

- Upstream vLLM PR: <https://github.com/vllm-project/vllm/pull/48952>
- `vllm-project/vllm-omni` README (release cadence policy):
  <https://github.com/vllm-project/vllm-omni/blob/main/README.md>
- `vllm-project/vllm-omni` v0.26.0 release notes:
  <https://github.com/vllm-project/vllm-omni/releases/tag/v0.26.0>
- `vllm-project/vllm-omni` tags (git ref list, confirms v0.25.0 and v0.27.0 never
  stabilized): `GET https://api.github.com/repos/vllm-project/vllm-omni/tags`
- `vllm-project/vllm-omni` release/publish pipeline:
  `.buildkite/release/release-pipeline.yml`,
  `.buildkite/release/scripts/publish-release-images.sh`
- `vllm-project/vllm-omni` Cosmos3-Edge recipe (v0.26.0 tag):
  `recipes/cosmos3/Cosmos3-Edge.md`
- `vllm-project/vllm-omni` Cosmos3 pipeline source (v0.26.0 tag):
  `vllm_omni/diffusion/models/cosmos3/pipeline_cosmos3.py`,
  `vllm_omni/engine/stage_init_utils.py`
- Vanilla vLLM dependency pins:
  `vllm-project/vllm` `requirements/cuda.txt` at tags `v0.26.0` and `v0.27.0`
- This repo: `VLLM_ON_THOR.md` (live hardware investigation, the source for what
  `:cosmos3` actually is), `DECISIONS.md` D002/D003/D006/D014/D020,
  `DEPLOYMENT_GUIDE.md` §5, `gitops/vllm-cosmos3/deployment.yaml`,
  `gitops/vllm-cosmos3/entrypoint-configmap.yaml`
