#!/usr/bin/env python3
"""
Обучение детектора дорожных знаков Азербайджана (YOLO -> TFLite).

Знаки Азербайджана построены по той же схеме, что и российские (Венская
конвенция, советский ГОСТ) и имеют ту же нумерацию. Поэтому:

  Этап 1. Предобучение на большом российском датасете RTSD (~180 тыс. знаков).
  Этап 2. Дообучение на кадрах с ВАШЕГО видеорегистратора по дорогам Азербайджана.

Команды:
  rtsd       — сконвертировать RTSD (COCO) в формат YOLO
  train      — обучить модель на data.yaml
  frames     — нарезать кадры из видео регистратора
  autolabel  — предразметить кадры моделью (потом поправить вручную)
  merge      — объединить RTSD + азербайджанские данные (с перевесом AZ)
  export     — экспорт в TFLite + labels.txt для Flutter-приложения

Полный порядок см. в README.md.
"""

import argparse
import json
import os
import random
import shutil
import sys
from pathlib import Path

IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
VID_EXT = {".mp4", ".mov", ".avi", ".mkv", ".ts", ".m4v"}


# ---------------------------------------------------------------------------
# Утилиты
# ---------------------------------------------------------------------------

def link_or_copy(src: Path, dst: Path):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        return
    try:
        os.symlink(src.resolve(), dst)
    except OSError:
        shutil.copy2(src, dst)


def write_yaml(path: Path, root: Path, train, val, names):
    lines = [f"path: {root.resolve()}"]
    lines.append(f"train: {train}")
    lines.append(f"val: {val}")
    lines.append(f"nc: {len(names)}")
    lines.append("names:")
    for i, n in enumerate(names):
        lines.append(f"  {i}: '{n}'")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_names(data_yaml: Path):
    import yaml  # идёт вместе с ultralytics
    d = yaml.safe_load(data_yaml.read_text(encoding="utf-8"))
    names = d["names"]
    if isinstance(names, dict):
        names = [names[k] for k in sorted(names, key=int)]
    return d, list(names)


# ---------------------------------------------------------------------------
# rtsd: COCO -> YOLO
# ---------------------------------------------------------------------------

def cmd_rtsd(a):
    root = Path(a.rtsd_root)
    out = Path(a.out)

    # Индекс всех картинок по имени файла (структура архивов бывает разной)
    index = {}
    for p in root.rglob("*"):
        if p.suffix.lower() in IMG_EXT:
            index.setdefault(p.name, p)
    print(f"Найдено изображений: {len(index)}")

    # Все COCO-файлы разметки в архиве (имена в разных копиях RTSD отличаются)
    coco_files = []
    for j in root.rglob("*.json"):
        try:
            if j.stat().st_size < 100:
                continue
            with open(j, encoding="utf-8") as fh:
                head = fh.read(4096)
            if '"images"' in head or '"annotations"' in head or '"categories"' in head:
                coco_files.append(j)
        except OSError:
            pass
    print("COCO-файлы:", [str(c.relative_to(root)) for c in coco_files])

    def find(fname, keyword):
        f = root / fname
        if f.exists():
            return f
        cand = list(root.rglob(fname)) or [c for c in coco_files if keyword in c.name.lower()]
        if not cand:
            sys.exit(f"Не найден {fname} (или *{keyword}*.json) в {root}")
        return cand[0]

    anno = {}
    for split, fname, kw in (("train", a.train_json, "train"), ("val", a.val_json, "val")):
        f = find(fname, kw)
        print(f"{split}: {f}")
        anno[split] = json.loads(f.read_text(encoding="utf-8"))

    cats = sorted(anno["train"]["categories"], key=lambda c: c["id"])
    cat_to_idx = {c["id"]: i for i, c in enumerate(cats)}
    names = [str(c["name"]) for c in cats]

    for split, coco in anno.items():
        imgs = {im["id"]: im for im in coco["images"]}
        boxes = {}
        for an in coco["annotations"]:
            boxes.setdefault(an["image_id"], []).append(an)
        ok = miss = 0
        for img_id, im in imgs.items():
            src = index.get(Path(im["file_name"]).name)
            if src is None:
                miss += 1
                continue
            W, H = float(im["width"]), float(im["height"])
            dst_img = out / "images" / split / src.name
            link_or_copy(src, dst_img)
            lines = []
            for an in boxes.get(img_id, []):
                x, y, w, h = an["bbox"]
                if w < 2 or h < 2:
                    continue
                cx, cy = (x + w / 2) / W, (y + h / 2) / H
                lines.append(f"{cat_to_idx[an['category_id']]} {cx:.6f} {cy:.6f} {w / W:.6f} {h / H:.6f}")
            lbl = out / "labels" / split / (src.stem + ".txt")
            lbl.parent.mkdir(parents=True, exist_ok=True)
            lbl.write_text("\n".join(lines), encoding="utf-8")
            ok += 1
        print(f"{split}: {ok} изображений, не найдено {miss}")

    write_yaml(out / "data.yaml", out, "images/train", "images/val", names)
    (out / "classes.txt").write_text("\n".join(names) + "\n", encoding="utf-8")
    print(f"Готово: {out / 'data.yaml'} ({len(names)} классов)")


# ---------------------------------------------------------------------------
# train
# ---------------------------------------------------------------------------

def cmd_train(a):
    from ultralytics import YOLO
    model = YOLO(a.weights)
    extra = {"time": a.time} if a.time else {}
    r = model.train(
        **extra,
        data=a.data,
        imgsz=a.imgsz,
        epochs=a.epochs,
        batch=a.batch,
        device=a.device,
        project=a.project,
        name=a.name,
        patience=a.patience,
        fraction=a.fraction,
        # ВАЖНО: зеркалить нельзя — "поворот налево" станет "направо"
        fliplr=0.0,
        flipud=0.0,
        degrees=5.0,
        hsv_v=0.5,
        scale=0.5,
        mosaic=1.0,
        close_mosaic=10,
        cache=a.cache,
        workers=a.workers,
    )
    best = Path(r.save_dir) / "weights" / "best.pt"
    print(f"\nЛучшие веса: {best}")


# ---------------------------------------------------------------------------
# frames: видео -> кадры
# ---------------------------------------------------------------------------

def cmd_frames(a):
    import cv2
    src = Path(a.videos)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    vids = [src] if src.is_file() else [p for p in sorted(src.rglob("*")) if p.suffix.lower() in VID_EXT]
    total = 0
    for v in vids:
        cap = cv2.VideoCapture(str(v))
        fps = cap.get(cv2.CAP_PROP_FPS) or 30
        step = max(1, int(round(fps * a.every)))
        i = saved = 0
        while True:
            ok = cap.grab()
            if not ok:
                break
            if i % step == 0:
                ok, frame = cap.retrieve()
                if ok:
                    if a.max_width and frame.shape[1] > a.max_width:
                        k = a.max_width / frame.shape[1]
                        frame = cv2.resize(frame, None, fx=k, fy=k, interpolation=cv2.INTER_AREA)
                    cv2.imwrite(str(out / f"{v.stem}_{i:07d}.jpg"), frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
                    saved += 1
            i += 1
        cap.release()
        total += saved
        print(f"{v.name}: {saved} кадров")
    print(f"Всего: {total} кадров в {out}")


# ---------------------------------------------------------------------------
# autolabel: предразметка моделью
# ---------------------------------------------------------------------------

def cmd_autolabel(a):
    from ultralytics import YOLO
    model = YOLO(a.weights)
    names = [model.names[i] for i in range(len(model.names))]
    src = Path(a.images)
    out = Path(a.out)
    (out / "images").mkdir(parents=True, exist_ok=True)
    (out / "labels").mkdir(parents=True, exist_ok=True)

    imgs = [p for p in sorted(src.rglob("*")) if p.suffix.lower() in IMG_EXT]
    kept = empty = 0
    for res in model.predict(source=[str(p) for p in imgs], imgsz=a.imgsz, conf=a.conf,
                             stream=True, verbose=False, device=a.device):
        p = Path(res.path)
        lines = []
        for b in res.boxes:
            c = int(b.cls.item())
            cx, cy, w, h = b.xywhn[0].tolist()
            lines.append(f"{c} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")
        if not lines and not a.keep_empty:
            empty += 1
            continue
        shutil.copy2(p, out / "images" / p.name)
        (out / "labels" / (p.stem + ".txt")).write_text("\n".join(lines), encoding="utf-8")
        kept += 1

    (out / "classes.txt").write_text("\n".join(names) + "\n", encoding="utf-8")
    write_yaml(out / "data.yaml", out, "images", "images", names)
    print(f"Предразмечено: {kept}, без знаков пропущено: {empty}")
    print(f"Проверьте и исправьте разметку в {out} (CVAT / Label Studio / Roboflow, формат YOLO).")


# ---------------------------------------------------------------------------
# merge: RTSD + AZ
# ---------------------------------------------------------------------------

def _list_images(d: Path):
    # absolute(), не resolve(): путь должен остаться внутри .../images/...,
    # иначе YOLO не найдёт соседнюю папку labels/ (картинки RTSD — симлинки)
    return [p.absolute() for p in sorted(d.rglob("*")) if p.suffix.lower() in IMG_EXT and "images" in p.parts]


def cmd_merge(a):
    base_yaml = Path(a.base)
    base, names = read_names(base_yaml)
    base_root = Path(base.get("path", base_yaml.parent))

    az = Path(a.az)
    az_names_file = az / "classes.txt"
    if az_names_file.exists():
        az_names = [l.strip() for l in az_names_file.read_text(encoding="utf-8").splitlines() if l.strip()]
        if az_names[: len(names)] != names:
            sys.exit("classes.txt азербайджанских данных не совпадает с классами базовой модели. "
                     "При разметке используйте classes.txt из autolabel без изменения порядка.")
        if len(az_names) > len(names):
            print(f"Новые классы (только в AZ): {az_names[len(names):]}")
            names = az_names

    az_imgs = _list_images(az)
    if not az_imgs:
        sys.exit(f"Нет изображений в {az}/images")
    random.seed(0)
    random.shuffle(az_imgs)
    n_val = max(1, int(len(az_imgs) * a.val_split))
    az_val, az_train = az_imgs[:n_val], az_imgs[n_val:]

    base_train = _list_images(base_root / base["train"])
    if a.base_fraction < 1.0:
        random.shuffle(base_train)
        base_train = base_train[: int(len(base_train) * a.base_fraction)]

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    train = [str(p) for p in base_train] + [str(p) for p in az_train] * a.az_repeat
    random.shuffle(train)
    (out / "train.txt").write_text("\n".join(train) + "\n", encoding="utf-8")
    # Валидация только на азербайджанских данных — именно это нас интересует
    (out / "val.txt").write_text("\n".join(str(p) for p in az_val) + "\n", encoding="utf-8")
    write_yaml(out / "data.yaml", out, "train.txt", "val.txt", names)
    print(f"train: {len(base_train)} RTSD + {len(az_train)}×{a.az_repeat} AZ; val: {len(az_val)} AZ")
    print(f"Готово: {out / 'data.yaml'}")


# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------

def cmd_export(a):
    from ultralytics import YOLO
    model = YOLO(a.weights)
    names = [model.names[i] for i in range(len(model.names))]
    exported = Path(model.export(format="tflite", imgsz=a.imgsz, half=False, int8=False))
    folder = exported.parent
    f16 = sorted(folder.glob("*float16.tflite"))
    f32 = sorted(folder.glob("*float32.tflite"))
    pick = (f16 or f32 or [exported])[0]

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    shutil.copy2(pick, out / "model.tflite")
    (out / "labels.txt").write_text("\n".join(str(n) for n in names) + "\n", encoding="utf-8")
    size = (out / "model.tflite").stat().st_size / 1e6
    print(f"model.tflite ({pick.name}, {size:.1f} МБ) и labels.txt ({len(names)} классов) -> {out}")
    print("Скопируйте их в папку assets/ Flutter-проекта.")


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)

    p = sp.add_parser("rtsd", help="RTSD (COCO) -> YOLO")
    p.add_argument("--rtsd-root", required=True)
    p.add_argument("--out", default="datasets/rtsd_yolo")
    p.add_argument("--train-json", default="train_anno.json")
    p.add_argument("--val-json", default="val_anno.json")
    p.set_defaults(func=cmd_rtsd)

    p = sp.add_parser("train", help="обучение")
    p.add_argument("--data", required=True)
    p.add_argument("--weights", default="yolo11n.pt", help="yolo11n.pt для этапа 1, best.pt этапа 1 для этапа 2")
    p.add_argument("--imgsz", type=int, default=640)
    p.add_argument("--epochs", type=int, default=60)
    p.add_argument("--batch", type=int, default=32)
    p.add_argument("--device", default=None)
    p.add_argument("--project", default="runs")
    p.add_argument("--name", default="signs")
    p.add_argument("--patience", type=int, default=15)
    p.add_argument("--fraction", type=float, default=1.0, help="доля данных (для быстрой проверки)")
    p.add_argument("--cache", default=False, help="ram / disk / False")
    p.add_argument("--workers", type=int, default=8)
    p.add_argument("--time", type=float, default=None, help="лимит обучения в часах (вместо epochs)")
    p.set_defaults(func=cmd_train)

    p = sp.add_parser("frames", help="видео -> кадры")
    p.add_argument("--videos", required=True, help="файл или папка с видео")
    p.add_argument("--out", default="az_raw_frames")
    p.add_argument("--every", type=float, default=0.5, help="секунд между кадрами")
    p.add_argument("--max-width", type=int, default=1920)
    p.set_defaults(func=cmd_frames)

    p = sp.add_parser("autolabel", help="предразметка")
    p.add_argument("--weights", required=True)
    p.add_argument("--images", required=True)
    p.add_argument("--out", default="datasets/az_labeled")
    p.add_argument("--imgsz", type=int, default=640)
    p.add_argument("--conf", type=float, default=0.25)
    p.add_argument("--device", default=None)
    p.add_argument("--keep-empty", action="store_true", help="сохранять кадры без знаков")
    p.set_defaults(func=cmd_autolabel)

    p = sp.add_parser("merge", help="RTSD + AZ")
    p.add_argument("--base", required=True, help="data.yaml RTSD")
    p.add_argument("--az", required=True, help="папка с проверенной AZ-разметкой (images/, labels/, classes.txt)")
    p.add_argument("--out", default="datasets/az_finetune")
    p.add_argument("--az-repeat", type=int, default=5, help="во сколько раз повторить AZ-кадры")
    p.add_argument("--base-fraction", type=float, default=0.3, help="доля RTSD (чтобы не забыть общие знаки)")
    p.add_argument("--val-split", type=float, default=0.15)
    p.set_defaults(func=cmd_merge)

    p = sp.add_parser("export", help="TFLite для телефона")
    p.add_argument("--weights", required=True)
    p.add_argument("--imgsz", type=int, default=640)
    p.add_argument("--out", default="flutter_assets")
    p.set_defaults(func=cmd_export)

    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
