# Road Sign Offline (Azerbaijan → Russian voice)

> An older online version (sends frames to the Claude API, needs internet) is in [`online_version/`](online_version/).

Detects road signs **on the phone itself** (YOLO + TFLite) and announces them in Russian with the phone's built-in voice. No internet needed while driving.

## Quick start (no computer setup needed)

### 1. Install the APK
On your phone open **https://github.com/ANUBlS/signreader/releases/tag/apk-latest** and tap
`signreader-offline.apk` (or `signreader-online.apk`). Allow "Install unknown apps" when asked.
GitHub rebuilds the APKs automatically on every push.

### 2. Train the starter model (one time, ~5 hours, runs on GitHub)
1. Create a free account on **kaggle.com** → *Settings* → *API* → **Create New Token**. This downloads `kaggle.json`.
2. In this repo go to **Settings → Secrets and variables → Actions → New repository secret** and add:
   - `KAGGLE_USERNAME` = the `username` value from `kaggle.json`
   - `KAGGLE_KEY` = the `key` value from `kaggle.json`
3. Go to **Actions → Train model → Run workflow**.

When it finishes, the model appears under **Releases → model-latest**. "Build APK" then runs
automatically and the new `signreader-offline.apk` can read signs. Reinstall it from step 1.

This starter model trains on Russian signs only, on a CPU, for a few hours. It recognises
common signs, but for good accuracy on Azerbaijani roads do stage 2 below with your own dashcam video.

---

```
signreader/
├── lib/
│   ├── main.dart          camera, UI, confirmation logic, speech queue
│   ├── detector.dart      background isolate: YUV/BGRA → letterbox → TFLite → NMS
│   └── sign_phrases.dart  sign code (3.24, 2.1 …) → Russian phrase
├── assets/                ← put model.tflite + labels.txt here (from training)
├── training/az_signs.py   whole training pipeline
├── online_version/       Claude API version (needs internet)
├── .github/workflows/     build-apk.yml (APK) · train-model.yml (model)
└── pubspec.yaml
```

---

## 1. Train the model (Google Colab, free GPU)

There is no public Azerbaijani sign dataset, but Azerbaijani signs use the same
Vienna-convention / ex-Soviet designs **and the same numbering** as Russian ones.
So training is two stages:

| Stage | Data | Purpose |
|---|---|---|
| 1 | RTSD — Russian Traffic Sign Dataset (~180k labelled signs) | learns sign shapes and classes |
| 2 | Frames from **your dashcam in Azerbaijan** | adapts to local signs, lighting, roads |

Open https://colab.research.google.com → *Runtime → Change runtime type → T4 GPU*.

```python
!pip install -q ultralytics kaggle
# upload az_signs.py and your kaggle.json (kaggle.com → Settings → API → Create token)
!mkdir -p ~/.kaggle && cp kaggle.json ~/.kaggle/ && chmod 600 ~/.kaggle/kaggle.json
!kaggle datasets download -d watchman/rtsd-dataset -p /content/rtsd --unzip
```
> If that Kaggle slug has moved, search Kaggle for "RTSD". Any COCO-format copy works.
> Use `--train-json` / `--val-json` if its annotation files have different names.

### Stage 1: pre-train on RTSD
```python
!python az_signs.py rtsd  --rtsd-root /content/rtsd --out /content/ds/rtsd
!python az_signs.py train --data /content/ds/rtsd/data.yaml --weights yolo11n.pt \
                          --imgsz 640 --epochs 40 --batch 32 --name rtsd --cache disk
```
This takes a few hours on a free T4. Colab may disconnect, so save `runs/` to Google Drive.
To do a quick dry run first, add `--fraction 0.1 --epochs 5`.

### Stage 2: fine-tune on Azerbaijani roads
1. **Record**: drive around Baku, highways and regions, with the phone or dashcam facing the road.
   Get day, evening and rain. 1–2 hours of video is a good start.
2. **Extract frames** (one every 0.5 s):
   ```python
   !python az_signs.py frames --videos /content/az_videos --out /content/az_frames --every 0.5
   ```
3. **Auto-label** with the stage-1 model. It keeps only frames where it sees a sign:
   ```python
   !python az_signs.py autolabel --weights runs/rtsd/weights/best.pt \
                                 --images /content/az_frames --out /content/az_labeled
   ```
4. **Correct the labels by hand**. Upload `az_labeled/` to **CVAT** (cvat.ai, free), **Label Studio** or **Roboflow** as *YOLO* format, using `classes.txt`.
   - Fix wrong classes, add missed signs, delete false boxes.
   - **Don't reorder classes.** New Azerbaijan-only classes go at the **end** of `classes.txt`.
   - Export back as YOLO (`images/`, `labels/`, `classes.txt`).
   - 1,500–3,000 corrected frames already make a big difference.
5. **Merge and fine-tune**:
   ```python
   !python az_signs.py merge --base /content/ds/rtsd/data.yaml --az /content/az_labeled_fixed \
                             --out /content/ds/az --az-repeat 5 --base-fraction 0.3
   !python az_signs.py train --data /content/ds/az/data.yaml --weights runs/rtsd/weights/best.pt \
                             --imgsz 640 --epochs 30 --name az
   ```
   Validation then runs only on Azerbaijani frames, so mAP shows how well it works on your roads.
   Repeat steps 1–5 whenever you notice it missing signs. Each round makes it better.

### Export for the phone
```python
!python az_signs.py export --weights runs/az/weights/best.pt --imgsz 640 --out /content/flutter_assets
```
Download `model.tflite` and `labels.txt` and copy them into `assets/`.

> **Mirroring is disabled in training on purpose** (`fliplr=0`), because a flipped
> "turn left" becomes "turn right". Don't re-enable it.

---

## 2. Build the app (Android)

The `android/` project is already in the repo, with camera, wake-lock and TTS permissions,
`minSdk 26` and uncompressed `.tflite` set. You need **Flutter 3.47+** (`flutter upgrade`).

```bash
git clone https://github.com/ANUBlS/signreader.git
cd signreader
# copy your trained model.tflite + labels.txt into assets/
flutter pub get
flutter run --release        # phone connected via USB with USB debugging on
# or build an APK to install:
flutter build apk --release  # → build/app/outputs/flutter-apk/app-release.apk
```

The app builds even without a model. It then shows "Модель не загружена" (model not loaded)
on screen, which is useful to check that the camera and voice work.

> On an older Flutter, regenerate the Android folder: `rm -rf android && flutter create --platforms android .`,
> then re-add the CAMERA / WAKE_LOCK permissions, the TTS `<queries>` intent, `minSdk = 26`
> and `androidResources { noCompress.add("tflite") }` (compare with this repo's `android/`).

**iOS** isn't included. Run `flutter create --platforms ios .` and add to `ios/Runner/Info.plist`:
```xml
<key>NSCameraUsageDescription</key>
<string>Камера нужна для распознавания дорожных знаков</string>
```

---

## 3. Russian voice offline (important)

The app uses the phone's own TTS, so the Russian voice must be **downloaded** to work without internet:

- **Android:** Settings → System → Language → **Text-to-speech output** → Google → ⚙ →
  **Install voice data** → **Russian** → download. Pick a voice that doesn't say "network".
- **iOS:** Settings → Accessibility → Spoken Content → Voices → **Russian** → download (e.g. Milena).

The 🗣 button plays a test phrase. If it's silent or the accent is wrong, the voice isn't installed.
An orange warning on screen means no offline Russian voice was found.

---

## 4. In the car

- Mount the phone **horizontally, with the camera on the left** (landscape-left), facing the road.
- Keep it on the charger; the screen stays on.
- ▶ starts, ■ stops, 🔊 mutes, 🗣 tests the voice.
- Yellow boxes show what the model sees, which is useful for checking accuracy.

### Tuning (top of `lib/main.dart`)
| Setting | Default | Meaning |
|---|---|---|
| `kConf` | 0.55 | raise if it speaks false signs, lower if it misses them |
| `kConfirmFrames` | 2 | sign must be seen N frames in a row before speaking |
| `kCooldown` | 15 s | the same sign isn't repeated within this time |
| `kRoi` | 1.0 | `0.6` = look only at the right 60% of the frame. Signs are on the right in Azerbaijan, so this is faster and has fewer false hits |
| `kUseGpu` | false | try `true` for more FPS; turn it off again if the app crashes |
| `kSpeakPlates` | false | announce 8.x plates |

To change what's said for a class, edit `assets/labels.txt`:
```
3_24_n60|Скорость шестьдесят
5_19_1|Внимание, пешеходный переход
```
An empty phrase after `|` silences that class.

### Expected speed (yolo11n, 640 px, CPU)
Recent mid-range Android phones run about 4–8 frames per second, which is enough at city speeds.
For more speed, train and export with `--imgsz 480` (small far signs get worse) or turn on the GPU.

## Limitations
- This is a driver **assistant**. It will sometimes miss or misread signs, so keep your eyes on the road.
- Accuracy on Azerbaijani roads depends mostly on stage 2. The more of your own corrected frames, the better.
