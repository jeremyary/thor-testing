# Dream comparison assets (canonical)

The matched "dream before deploy" pair used by the demo dashboard and the RHOAI
MLflow experiment. Both are Forward Dynamics rollouts generated at **identical
params — 256×256, seed 42, `pick_place` BridgeData2 frame + the `good` 16-step
action chunk** — so the *only* variable is the model.

| File | What | Model | Signed modelcar digest |
|------|------|-------|------------------------|
| `dream_diag_base.mp4` | v1 dream | base (untuned Cosmos3-Edge) | `sha256:5c990c93…` (snapshot `2a00e87e…`) |
| `dream_diag_v2graft.mp4` | v2 dream | 500-iter Vision SFT + action graft | `sha256:69da94f2…` (snapshot `bfaf37f2…`) |
| `conditioning_frame.jpg` | the 256×256 seed frame | — | — |
| `loss_curve.json` | 50-pt training loss window from `run500.log` | v2 | — |

`dream_temporal_stability` (mean grayscale frame-to-frame diff, lower = smoother):
base **0.044** vs v2 **0.017** (~61% smoother).

On Thor these are pinned immutable at
`/var/lib/dreams/zzz-showcase-cosmos3-edge-v{1,2}.mp4` and served by the dashboard
Dream v1/v2 buttons. See `DEMO_RUNBOOK.md` (§ Reproducing the Pinned Dreams,
§ Experiment Tracking) and `DECISIONS.md` D034 for full provenance.

> **Resolution matters:** generate at 256×256 to match the square frame. The
> dreamer's default 320×192 produces visibly degraded, incoherent rollouts (D034-C).
