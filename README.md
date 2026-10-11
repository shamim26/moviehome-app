<div align="center">

# 🎬 Movie Home

**A sleek, high-performance media discovery and cinema streaming application built with Flutter.**

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS-3DDC84?logo=android&logoColor=white)](#supported-platforms)
[![License](https://img.shields.io/badge/License-MIT-red.svg)](LICENSE)
[![Size](https://img.shields.io/badge/Release%20Size-~35MB-brightgreen)](#performance--battery)

<p align="center">
  <img src="assets/images/app_logo.png" width="128" height="128" alt="Movie Home Logo" />
</p>

</div>

---

## 🌟 Overview

**Movie Home** is an all-in-one entertainment hub designed for movie and series enthusiasts. Crafted with an uncompromising focus on visual aesthetics, battery efficiency, and playback fluidity, Movie Home delivers an immersive theater experience directly on mobile devices.

---

## ✨ Features

### 🎥 Cinema-Grade Video Player
* **Hardware-Accelerated Decoding:** Powered by native `MediaCodec` pipelines for buttery-smooth playback up to 4K resolution.
* **Smart Server Switching:** Seamlessly switch between multiple streaming servers with zero playback friction.
* **Dynamic Resolution Selection:** Toggle between Auto, 1080p, 720p, and standard definition on the fly.
* **Full Subtitle Support:** Automatic multi-language subtitle detection with synchronized WebVTT cues and track switching.
* **Multi-Audio Track Support:** Select between original and dubbed audio streams directly from the controls panel.
* **Aspect Ratio Controls:** Tailor the video viewport with one tap:
  * `Fit` (Default native aspect ratio)
  * `Zoom` (Edge-to-edge crop/fill)
  * `Stretch` (Full display stretch)
  * `16:9` & `4:3` (Classic aspect presets)
* **Intuitive Gestures:**
  * Swipe vertically on the **left side** to adjust display brightness.
  * Swipe vertically on the **right side** to adjust media volume.
  * Tap to show/hide controls; double-tap forward or backward to seek.
* **Smart Episode Navigation:** Effortlessly jump to the next episode with automatic progress reset to start from the beginning.

### 📱 Modern Discovery Experience
* **Rich Catalog Exploration:** Browse trending movies, popular television series, top-rated gems, and ongoing releases.
* **Instant Search:** Debounced real-time search with instant filtering by title, release year, and genre.
* **Personal Watchlist:** Save favorite movies and series locally for quick access.
* **Resume Watch History:** Automatically records watch progress down to the second across seasons and episodes.
* **OLED Dark Theme:** Deep `#000000` pitch-black design tailored for high-contrast immersion and battery conservation.

### ⚡ Battery & Thermal Optimization
* **Zero-Rebuild Playback:** During playback, state updates run quietly in memory without rebuilding the UI layer, reducing CPU usage to near-idle levels.
* **Optimized Buffering:** Smart network readahead prevents Wi-Fi and mobile data chipsets from spinning continuously.
* **Power-Efficient Refresh Rate:** Aligned display frame rates prevent unnecessary GPU overhead during 24fps/30fps film playback.
* **No-Internet Protection:** Built-in network guard alerts users and protects app state if internet access is unavailable.

---

## 📐 Tech Stack

| Component | Technology |
| :--- | :--- |
| **Framework** | [Flutter](https://flutter.dev) (Dart 3.x) |
| **State Management** | [Riverpod](https://riverpod.dev) |
| **Media Player Engine** | [media_kit](https://github.com/media-kit/media-kit) (libmpv + MediaCodec) |
| **Local Storage** | [SharedPreferences](https://pub.dev/packages/shared_preferences) |
| **Iconography** | [Lucide Icons](https://lucide.dev) |
| **Design System** | Custom OLED Cinematic Dark Palette |

---

## 📦 Getting Started

### Prerequisites
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (`^3.13` or newer)
* Android SDK (`minSdkVersion 21`, `targetSdkVersion 34+`)
* Java Development Kit (JDK 17)

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/shamim26/moviehome-app.git
   cd moviehome-app
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Configure Environment Keys:**
   Create an `env.json` file in the root directory:
   ```json
   {
     "TMDB_API_KEY": "your_tmdb_api_key_here"
   }
   ```

4. **Run on Connected Device:**
   ```bash
   flutter run --dart-define-from-file=env.json
   ```

---

## 🚀 Building for Release

### Architecture-Specific APK (Recommended for smallest size ~35 MB)
```bash
flutter build apk --release --split-per-abi --dart-define-from-file=env.json
```
Output directory: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

### Universal APK (All architectures ~98 MB)
```bash
flutter build apk --release --dart-define-from-file=env.json
```
Output directory: `build/app/outputs/flutter-apk/app-release.apk`

---

## 🔒 Security & Privacy

* Movie Home does not collect personal identity information.
* Watch history and watchlist items are stored strictly on the local device.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
