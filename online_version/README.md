# Road Sign RU

Reads road signs from the phone camera and announces them aloud in Russian.

## Setup

```bash
flutter create --org az.sabuhi --platforms android,ios road_sign_ru
# then replace lib/main.dart and pubspec.yaml with the files from here
cd road_sign_ru
flutter pub get
```

### Android: `android/app/src/main/AndroidManifest.xml`
Add these lines inside `<manifest>`, before `<application>`:
```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<queries>
    <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>
</queries>
```
In `android/app/build.gradle`, set `minSdkVersion 21` or higher.

### iOS: `ios/Runner/Info.plist`
```xml
<key>NSCameraUsageDescription</key>
<string>Камера нужна для распознавания дорожных знаков</string>
```

## Run

```bash
flutter run --release --dart-define=ANTHROPIC_API_KEY=sk-ant-xxxx
# or build an APK:
flutter build apk --release --dart-define=ANTHROPIC_API_KEY=sk-ant-xxxx
```

## In the car
- Mount the phone horizontally, with the camera facing the road.
- Keep it on the charger: the screen stays on.
- Press ▶ to start, ■ to stop, and 🔊 to mute.
- On Android, install a Russian voice: Settings → Language → Text-to-speech → Google → Russian.

## Tuning (top of `main.dart`)
- `scanInterval`: how often frames are captured (2.5 s by default).
- `repeatCooldown`: a sign isn't repeated within this window (20 s).
- `model`: `claude-haiku-5-5` is fast and cheap.

## Limitations
- It needs mobile internet, with about 2–3 s of latency per frame.
- Because it's an assistant, it can miss signs. Don't rely on it instead of your own eyes.
- Cost: one frame every 2.5 s is about 1,400 requests per hour.
