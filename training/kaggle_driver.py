# --- Kaggle GPU driver (appended to az_signs.py by .github/workflows/train-gpu.yml) ---
# Runs inside a Kaggle notebook with GPU + internet and the RTSD dataset attached.
# Writes model.tflite, labels.txt, rtsd_best.pt, results.csv, stamp.txt to /kaggle/working/out

import os as _os
import shutil as _sh
import subprocess as _sp
import sys as _sys
import time as _time
from pathlib import Path as _P

HOURS = "__HOURS__"
IMGSZ = "__IMGSZ__"
STAMP = "__STAMP__"

OUT = _P("/kaggle/working/out")
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "stamp.txt").write_text(STAMP + "\n")
_log = open(OUT / "progress.log", "a", buffering=1)


def say(msg):
    line = f"{_time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    _log.write(line + "\n")


say("installing ultralytics")
_sp.run([_sys.executable, "-m", "pip", "install", "-q", "ultralytics"], check=True)

import torch as _torch  # noqa: E402

if not _torch.cuda.is_available():
    say("ERROR: no GPU. Kaggle account must be phone-verified and the notebook needs GPU enabled.")
    raise SystemExit(1)
say(f"GPU: {_torch.cuda.get_device_name(0)} x{_torch.cuda.device_count()}")

# Find the RTSD dataset wherever Kaggle mounted it
roots = [p.parent for p in _P("/kaggle/input").rglob("label_map.json")]
if not roots:
    say("ERROR: RTSD dataset not found under /kaggle/input")
    raise SystemExit(1)
rtsd = roots[0]
say(f"RTSD at {rtsd}")


def run(*args):
    say("az_signs " + " ".join(args))
    _sys.argv = ["az_signs.py", *args]
    main()


run("rtsd", "--rtsd-root", str(rtsd), "--out", "/tmp/ds")
say("dataset ready")

# Weights go straight into /kaggle/working so they are part of the notebook output,
# even if the session is stopped early. The TFLite export happens later on GitHub.
devices = "0"  # single GPU: simpler and reliable (no DDP)
try:
    run("train", "--data", "/tmp/ds/data.yaml", "--weights", "yolo11n.pt",
        "--imgsz", IMGSZ, "--batch", "64", "--workers", "4", "--device", devices,
        "--time", HOURS, "--epochs", "300", "--patience", "30",
        "--project", "/kaggle/working/runs", "--name", "rtsd")
finally:
    w = _P("/kaggle/working/runs/rtsd/weights")
    for name in ("best.pt", "last.pt"):
        if (w / name).exists():
            _sh.copy2(w / name, OUT / ("rtsd_best.pt" if name == "best.pt" else "rtsd_last.pt"))
    try:
        _sh.copy2("/kaggle/working/runs/rtsd/results.csv", OUT / "results.csv")
    except OSError:
        pass
    say("weights saved to output")
say("DONE")
