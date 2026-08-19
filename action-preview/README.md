# Robot Action Preview

> [!NOTE]
> This project was developed with assistance from AI tools.

A proof-of-concept demonstrating edge AI inference on NVIDIA Jetson AGX Thor with Red Hat
CentOS Stream 10 bootc. Uses Cosmos3-Edge via vllm-omni to reason about physical scenes,
predict robot action outcomes as video, and verify results — all running on-device with
no cloud dependency.

## Architecture

```
Camera/Image → [Cosmos3-Edge Reasoner] → Scene Understanding (text + visual)
                        ↓
Action Trajectory → [Cosmos3-Edge Forward Dynamics] → Predicted Outcome (video)
                        ↓
Predicted Video → [Cosmos3-Edge Reasoner] → Verification ("Did it work?")
                        ↓
                   Execute / Retry
```

## Stack

- **Hardware:** NVIDIA Jetson AGX Thor (128GB, Blackwell SM_110)
- **OS:** CentOS Stream 10 bootc (kernel 6.12.0-253)
- **Serving:** vllm-omni 0.25.0 + Cosmos3-Edge 4B
- **Container:** `vllm/vllm-omni:cosmos3` (arm64)
- **API:** OpenAI-compatible + omni video/action endpoints

## Quick Start

```bash
# 1. Start Cosmos3-Edge server (see DEPLOYMENT_GUIDE.md for full setup)
# 2. Run the demo
python3 action_preview.py --image workspace.jpg --action "pick up the red block"
```
