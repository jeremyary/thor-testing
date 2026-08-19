# Dream comparison assets (canonical)

The matched "dream before deploy" pair used by the demo dashboard and the RHOAI
MLflow experiment. Both are Forward Dynamics rollouts from the same **256×256,
seed 42, `pick_place` BridgeData2 frame + the `good` 16-step action chunk**,
each generated against its own model checkpoint.

Regenerate either with `gen_dream.py` on Thor (see "Re-pinning" below).

| File | What | Model | Signed modelcar digest |
|------|------|-------|------------------------|
| `dream_diag_base.mp4` | v1 dream | base (untuned Cosmos3-Edge) | `sha256:5c990c93…` (snapshot `2a00e87e…`) |
| `dream_diag_v2graft.mp4` | v2 dream | 500-iter Vision SFT + action graft | `sha256:69da94f2…` (snapshot `bfaf37f2…`) |
| `conditioning_frame.jpg` | the 256×256 seed frame | — | — |
| `loss_curve.json` | 50-pt training loss window from `run500.log` | v2 | — |

`dream_temporal_stability` (mean grayscale frame-to-frame diff, lower = smoother):
base **0.047** vs v2 **0.018** (~61% smoother).

On Thor these are pinned immutable at
`/var/lib/dreams/zzz-showcase-cosmos3-edge-v{1,2}.mp4` and served by the dashboard
Dream v1/v2 buttons. See `DEMO_RUNBOOK.md` (§ Reproducing the Pinned Dreams,
§ Experiment Tracking) and `DECISIONS.md` D034 for full provenance.

> **Resolution matters:** generate at 256×256 to match the square frame. The
> dreamer's default 320×192 produces visibly degraded, incoherent rollouts (D034-C).

## Re-pinning

`gen_dream.py` (run on Thor) regenerates a dream deterministically against
whichever checkpoint vLLM-Omni is currently serving. To update a pinned file:

```bash
# 1. ensure the intended checkpoint is served (blue=base / green=v2)
# 2. generate
python3 gen_dream.py v2            # -> /tmp/dream_v2.mp4
# 3. pin it (path is immutable; unlock, replace, re-lock)
chattr -i /var/lib/dreams/zzz-showcase-cosmos3-edge-v2.mp4
cp /tmp/dream_v2.mp4 /var/lib/dreams/zzz-showcase-cosmos3-edge-v2.mp4
chmod 444 /var/lib/dreams/zzz-showcase-cosmos3-edge-v2.mp4
chattr +i /var/lib/dreams/zzz-showcase-cosmos3-edge-v2.mp4
```
