#!/bin/bash
# This project was developed with assistance from AI tools.
# Reset NVIDIA GPU after boot — workaround for Thor GCx issue
# where display module loading leaves the GPU in a bad compute state.

modprobe -r nvidia_uvm 2>/dev/null
modprobe -r nvidia_drm 2>/dev/null
modprobe -r nvidia_modeset 2>/dev/null
modprobe -r nvidia 2>/dev/null
sleep 1
modprobe nvidia
modprobe nvidia_uvm
sleep 2
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>/dev/null
echo "GPU reset complete"
