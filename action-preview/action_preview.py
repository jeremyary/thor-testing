# This project was developed with assistance from AI tools.
"""Robot Action Preview — edge AI inference with Cosmos3-Edge on Jetson Thor."""

import argparse
import base64
import json
import sys
import time
from pathlib import Path

import requests

DEFAULT_BASE_URL = "http://localhost:8000"


def encode_image(path: str) -> str:
    """Read an image file and return a base64 data URL."""
    data = Path(path).read_bytes()
    suffix = Path(path).suffix.lower().lstrip(".")
    mime = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png"}.get(
        suffix, "image/jpeg"
    )
    return f"data:{mime};base64,{base64.b64encode(data).decode()}"


def reason(base_url: str, prompt: str, image_path: str | None = None) -> str:
    """Ask Cosmos3-Edge to reason about a scene or video."""
    content = []
    if image_path:
        content.append(
            {"type": "image_url", "image_url": {"url": encode_image(image_path)}}
        )
    content.append({"type": "text", "text": prompt})

    resp = requests.post(
        f"{base_url}/v1/chat/completions",
        json={
            "model": "nvidia/Cosmos3-Edge",
            "messages": [{"role": "user", "content": content}],
            "max_tokens": 300,
            "temperature": 0.7,
        },
        timeout=120,
    )
    resp.raise_for_status()
    content = resp.json()["choices"][0]["message"]["content"]
    if isinstance(content, list):
        texts = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text":
                    texts.append(item["text"])
                elif item.get("type") == "image_url":
                    texts.append("[generated image]")
            elif isinstance(item, str):
                texts.append(item)
        return "\n".join(texts) if texts else str(content)
    return str(content)


def generate_video(
    base_url: str,
    prompt: str,
    image_path: str | None = None,
    num_frames: int = 49,
    fps: int = 12,
    width: int = 480,
    height: int = 272,
) -> bytes:
    """Generate a video using Cosmos3-Edge forward dynamics."""
    data = {
        "prompt": prompt,
        "model": "nvidia/Cosmos3-Edge",
        "num_frames": num_frames,
        "fps": fps,
        "width": width,
        "height": height,
        "num_inference_steps": 30,
        "guidance_scale": 7.0,
    }

    files = {}
    if image_path:
        files["image_reference"] = (
            Path(image_path).name,
            Path(image_path).read_bytes(),
            "image/jpeg",
        )

    print(f"  Generating video ({num_frames} frames, {width}x{height})...", flush=True)
    t0 = time.time()

    resp = requests.post(
        f"{base_url}/v1/videos/sync",
        data=data,
        files=files if files else None,
        timeout=600,
    )
    resp.raise_for_status()

    elapsed = time.time() - t0
    print(f"  Video generated in {elapsed:.1f}s", flush=True)
    return resp.content


def run_pipeline(
    base_url: str,
    image_path: str | None,
    action_description: str,
    output_dir: str,
):
    """Run the full action preview pipeline."""
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    # Step 1: Scene understanding
    print("\n=== Step 1: Scene Understanding ===", flush=True)
    if image_path:
        scene = reason(
            base_url,
            "Describe this workspace scene. What objects are present? "
            "What is the current state of the environment? Be concise.",
            image_path,
        )
    else:
        scene = "No image provided — using text-only mode."
    print(f"  Scene: {scene[:200]}...", flush=True)
    (out / "01_scene_understanding.txt").write_text(scene)

    # Step 2: Action planning
    print("\n=== Step 2: Action Planning ===", flush=True)
    plan_prompt = (
        f"A robot arm needs to: {action_description}\n\n"
        f"Scene context: {scene[:200]}\n\n"
        "Describe step by step what the robot arm should do. "
        "Be specific about gripper positions and movements."
    )
    plan = reason(base_url, plan_prompt)
    print(f"  Plan: {plan[:200]}...", flush=True)
    (out / "02_action_plan.txt").write_text(plan)

    # Step 3: Generate prediction video
    print("\n=== Step 3: Video Prediction ===", flush=True)
    video_prompt = (
        f"A robot arm performing the following action: {action_description}. "
        "Show the complete motion from approach to completion. "
        "Smooth, realistic robot motion in an industrial workspace."
    )
    try:
        video_bytes = generate_video(
            base_url,
            video_prompt,
            image_path=image_path,
            num_frames=49,
            width=480,
            height=272,
        )
        video_path = out / "03_predicted_action.mp4"
        video_path.write_bytes(video_bytes)
        print(f"  Saved: {video_path} ({len(video_bytes)} bytes)", flush=True)
    except Exception as e:
        print(f"  Video generation failed: {e}", flush=True)
        print("  Continuing with text-only verification...", flush=True)
        video_path = None

    # Step 4: Verify the predicted outcome
    print("\n=== Step 4: Outcome Verification ===", flush=True)
    verify_prompt = (
        f"The robot was asked to: {action_description}\n"
        f"The planned approach was: {plan[:200]}\n\n"
        "Based on this plan, what is the likely outcome? "
        "Would this action succeed? What could go wrong? "
        "Rate confidence as HIGH, MEDIUM, or LOW."
    )
    verification = reason(base_url, verify_prompt)
    print(f"  Verification: {verification[:200]}...", flush=True)
    (out / "04_verification.txt").write_text(verification)

    # Summary
    print("\n=== Pipeline Complete ===", flush=True)
    print(f"  Outputs saved to: {out}/", flush=True)
    print(f"  Files: {[f.name for f in sorted(out.iterdir())]}", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Robot Action Preview on Jetson Thor")
    parser.add_argument("--image", type=str, help="Input workspace image (jpg/png)")
    parser.add_argument(
        "--action",
        type=str,
        default="pick up the red block and place it on the blue platform",
        help="Action description",
    )
    parser.add_argument(
        "--base-url", type=str, default=DEFAULT_BASE_URL, help="Cosmos3-Edge server URL"
    )
    parser.add_argument(
        "--output", type=str, default="output", help="Output directory"
    )
    args = parser.parse_args()

    print("Robot Action Preview — Cosmos3-Edge on Jetson AGX Thor", flush=True)
    print(f"  Server: {args.base_url}", flush=True)
    print(f"  Action: {args.action}", flush=True)
    if args.image:
        print(f"  Image:  {args.image}", flush=True)

    # Health check
    try:
        r = requests.get(f"{args.base_url}/health", timeout=5)
        r.raise_for_status()
        print("  Server: HEALTHY\n", flush=True)
    except Exception:
        print(f"  ERROR: Cannot reach server at {args.base_url}", flush=True)
        sys.exit(1)

    run_pipeline(args.base_url, args.image, args.action, args.output)


if __name__ == "__main__":
    main()
