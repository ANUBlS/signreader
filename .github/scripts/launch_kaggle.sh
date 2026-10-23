#!/usr/bin/env bash
# Builds the Kaggle notebook (az_signs.py + kaggle_driver.py) and pushes it.
# Env: KAGGLE_USERNAME, KAGGLE_KEY, HOURS, IMGSZ, STAMP
set -uo pipefail
# no `set -x`: it would print the Kaggle key

echo "== install kaggle"
pip install -q kaggle || exit 10

[ -n "${KAGGLE_USERNAME:-}" ] || { echo "KAGGLE_USERNAME missing"; exit 11; }
if [ -z "${KAGGLE_KEY:-}" ]; then echo "KAGGLE_KEY missing"; exit 12; fi
echo "secrets present (key length ${#KAGGLE_KEY})"

echo "== build notebook"
rm -rf kernel && mkdir -p kernel

python3 - <<'PY' || exit 13
import os
src = open("training/az_signs.py", encoding="utf-8").read()
tail = 'if __name__ == "__main__":\n    main()'
s = src.rstrip()
assert s.endswith(tail), "unexpected az_signs.py ending"
s = s[: -len(tail)]
drv = open("training/kaggle_driver.py", encoding="utf-8").read()
drv = (drv.replace("__HOURS__", os.environ["HOURS"])
          .replace("__IMGSZ__", os.environ["IMGSZ"])
          .replace("__STAMP__", os.environ["STAMP"]))
open("kernel/kernel.py", "w", encoding="utf-8").write(s + "\n\n" + drv)
print("kernel.py written")
PY

python3 -m py_compile kernel/kernel.py || exit 14
rm -rf kernel/__pycache__

python3 - <<'PY' || exit 15
import json, os
meta = {
    "id": f"{os.environ['KAGGLE_USERNAME']}/signreader-train",
    "title": "signreader-train",
    "code_file": "kernel.py",
    "language": "python",
    "kernel_type": "script",
    "is_private": True,
    "enable_gpu": True,
    "enable_internet": True,
    "dataset_sources": ["watchman/rtsd-dataset"],
    "competition_sources": [],
    "kernel_sources": [],
}
json.dump(meta, open("kernel/kernel-metadata.json", "w"), indent=2)
print(json.dumps({k: v for k, v in meta.items() if k != "id"}, indent=2))
PY

ls -la kernel

echo "== push to kaggle"
kaggle kernels push -p kernel
rc=$?
echo "push exit code: $rc"
[ $rc -eq 0 ] || exit 16

sleep 30
kaggle kernels status "${KAGGLE_USERNAME}/signreader-train"
exit 0
