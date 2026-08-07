# This project was developed with assistance from AI tools.
import multiprocessing as mp
import os

def child_test():
    """Test CUDA in a spawned child process."""
    import ctypes
    try:
        cuda = ctypes.CDLL("libcuda.so.1")
        r = cuda.cuInit(0)
        count = ctypes.c_int()
        cuda.cuDeviceGetCount(ctypes.byref(count))
        print(f"SPAWN CHILD [pid={os.getpid()}]: cuInit={r} devices={count.value}", flush=True)

        print(f"SPAWN CHILD: /dev/nvidia0 exists={os.path.exists('/dev/nvidia0')}", flush=True)
        print(f"SPAWN CHILD: /dev/nvidiactl exists={os.path.exists('/dev/nvidiactl')}", flush=True)
        print(f"SPAWN CHILD: /dev/nvidia-uvm exists={os.path.exists('/dev/nvidia-uvm')}", flush=True)

        if r == 0 and count.value > 0:
            import torch
            avail = torch.cuda.is_available()
            print(f"SPAWN CHILD: torch.cuda.is_available()={avail}", flush=True)
            if avail:
                x = torch.zeros(1, device="cuda")
                print(f"SPAWN CHILD: torch.zeros OK: {x}", flush=True)
            else:
                print("SPAWN CHILD: torch says no CUDA despite cuInit OK", flush=True)
    except Exception as e:
        print(f"SPAWN CHILD ERROR: {type(e).__name__}: {e}", flush=True)

if __name__ == "__main__":
    mp.set_start_method("spawn")
    print(f"PARENT [pid={os.getpid()}]: spawning child (no CUDA in parent)...", flush=True)
    p = mp.Process(target=child_test)
    p.start()
    p.join(timeout=30)
    print(f"SPAWN CHILD exit code: {p.exitcode}", flush=True)
