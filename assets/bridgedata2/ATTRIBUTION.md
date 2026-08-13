# BridgeData2 Subset — Attribution and License

## Source

The five JPEG first-frames in `frames/` are extracted from
`nvidia/BridgeData2-Subset-Synthetic-Captions`, a subset of **BridgeData V2**
packaged by NVIDIA for supervised fine-tuning and video generation workflows.

- NVIDIA dataset card: <https://huggingface.co/datasets/nvidia/BridgeData2-Subset-Synthetic-Captions>
- Upstream project (RAIL, UC Berkeley): <https://rail-berkeley.github.io/bridgedata/>
- Upstream paper: Walke et al. 2023, "BridgeData V2: A Dataset for Robot Learning at Scale", arXiv:2308.12952

## License

**OpenMDW License Agreement Version 1.1** — commercial and non-commercial use
permitted. Full terms: <https://openmdw.ai/license/>

## What is stored here

| File | Source clip | Scene archetype |
|---|---|---|
| `frames/pick_place.jpg` | `episode_000015_clip000` | Pick and place — tray + gripper |
| `frames/sort_objects.jpg` | `episode_000036_clip000` | Sort / arrange objects |
| `frames/open_close.jpg` | `episode_000062_clip000` | Kitchen manipulation (stovetop) |
| `frames/push_sweep.jpg` | `episode_000165_clip000` | Push / sweep beads |
| `frames/pour.jpg` | `episode_000487_clip000` | Gather / reposition almonds |

These are **first-frames only** (single 256×256 RGB JPEG per clip), used as
real-world visual conditioning for Cosmos3-Edge Forward Dynamics inference.
They are not used as training data and are not presented as ground-truth
labels for any safety-critical task.

## Usage in this repository

These frames serve as conditioning images in the `robot-sim` control loop:
the robot-sim selects one frame per episode, passes it to the Cosmos3-Edge
world model (Reasoner mode for action prediction, Forward Dynamics mode for
rollout preview), and records the result as an episode. The frames ground the
"dream before deploy" Forward Dynamics video in real robot imagery rather
than purely synthetic generation.

## Citation

```bibtex
@inproceedings{walke2023bridgedata,
  title={BridgeData V2: A Dataset for Robot Learning at Scale},
  author={Walke, Homer Rich and Black, Kevin and Zhao, Tony Z. and Vuong, Quan
          and Zheng, Chongyi and Hansen-Estruch, Philippe and He, Andre Wang
          and Myers, Vivek and Kim, Moo Jin and Du, Max and Lee, Abraham and
          Fang, Kuan and Finn, Chelsea and Levine, Sergey},
  booktitle={Conference on Robot Learning (CoRL)},
  year={2023}
}
```

## Scope note

The BridgeData V2 dataset card explicitly states these clips "should not be
treated as verified ground truth for physical reasoning, robot state
estimation, or safety-critical deployment." This repository treats them
accordingly — as conditioning imagery for a demonstration PoC, not as
validated robot-learning ground truth.
