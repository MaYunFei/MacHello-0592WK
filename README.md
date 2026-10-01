# MacHello-0592WK 🍏👁️

**English** | [简体中文](README_zh.md)

> **Native Windows Hello-Grade IR Face Unlock & Presence Detection for macOS (Apple Silicon & Intel)**  
> Engineered for **Dell CN-0592WK (Realtek 0bda:5767)** biometric salvage modules. Written in **100% pure native Swift 6**, completely free of bulky Python runtimes, quietly resident in the menu bar, with zero-latency face unlock.

---

## 🖥️ Verified Operating Environments

This project has been extensively tested, tuned, and verified on real production hardware:

| Node / Role | Operating System | Architecture / Topology | Runtime Stack & Compute Allocation |
| :--- | :--- | :--- | :--- |
| **🍎 Mac Client (Brain)** | **macOS 14+ / Sequoia / macOS 26+** | Apple Silicon (M1/M2/M3/M4) & Intel | **Pure Native Swift 6.0**. Full hardware acceleration via **Apple Neural Engine (16-core NPU)** and Apple Vision framework. Zero green privacy dot flicker, zero `MenuBarAgent` UI lag. |
| **🐧 Linux Gateway (Sensor)** *(Optional)* | **Debian 12/13 / Ubuntu / PVE / Raspberry Pi** | Proxmox VE / Bare metal / LXC (x86_64 / arm64) | **Lightweight Hardware Gateway (Samba philosophy)**. Dynamically tracks Dell 0592WK (`0bda:5767`) USB hotplug status. Camera hardware completely sleeps when idle (**0.0% CPU overhead**). |

---

## 💡 Why Pure Swift Instead of Python?

| Dimension | Python Solutions (e.g. Howdy ports) | MacHello (Native Swift 6) |
| :--- | :--- | :--- |
| **Runtime Footprint** | Requires Python, Conda, PyTorch/dlib (hundreds of MBs) | **Single native Mach-O binary (< 5 MB)** |
| **Memory Footprint** | 200 MB – 500 MB RAM | **Only 15 MB – 25 MB** (micro resident) |
| **UI Integration** | Bulky Tkinter/PyQt windows, pollutes Dock | **Native macOS MenuBarExtra** (Dock-free `LSUIElement = true`) |
| **Biometric Speed** | CPU software emulation (30ms+ per frame) | **Apple Neural Engine (NPU) + Unified Memory (< 5ms)** |
| **System Security** | Injects Python interpreter into `sudo` / PAM | **Native C PAM module + Swift IPC, deadlock-free** |

---

## ✨ Key Features

- 🍏 **Native Menu Bar Utility**:
  - Configured with `LSUIElement = true` — **no Dock icon clutter**, quietly residing in your macOS menu bar.
  - Interactive status capsule, live hardware link monitor, face database manager, and 850nm IR test toggles.
  - **In-App Bilingual Support**: Switch between **System Default**, **English**, and **简体中文** on the fly without restarting the app.

- 🔄 **Dual Deployment Modes: Direct USB or LAN Linux Micro-Service**:
  - 🔌 **Mode 1: Direct USB Mode (Inspired by [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock))**:
    - **100% Zero Camera Activity while working**: When the screen is awake and active, the camera hardware is completely powered off and unallocated. 0% CPU, 0 green privacy dots.
    - Automatic sleep/lock on user idle (15s / 30s / 1m / 3m / 5m / 10m).
    - Intelligent Do-Not-Disturb: Automatically suspends sleep during media playback (YouTube, Netflix, Bilibili) or online conferences (Zoom, Teams, Tencent Meeting).
    - **Instant Face ID on Wake**: Touch your keyboard or mouse to light up the display -> instant 0.5s IR biometric scan -> auto-fills password and returns to desktop -> immediately powers down camera.
    - Terminal `sudo` elevation also triggers a single 0.5s burst scan.
  - 🌐 **Mode 2: Network Linux Hardware Gateway Mode (Samba Philosophy · Compute on Mac NPU)**:
    - Connect the Dell 0592WK module to any Linux device on your LAN (Raspberry Pi, mini-PC, homelab server, NAS, or PVE virtual machine).
    - **Linux acts as a lightweight sensor gateway**: Runs no heavy biometric AI. Idles at **0.0% CPU**, automatically turning off camera LEDs when no client is streaming.
    - **Mac acts as the central brain**: Streams frames into `CVPixelBuffer` across the LAN, feeds directly into the **Apple Neural Engine (ANE/NPU)** to match 512-dimensional facial embeddings.
    - **Zero Green Privacy Dot on Mac**: Because images flow over LAN memory buffers, macOS never registers a local camera session, avoiding `MenuBarAgent` stuttering and privacy banners entirely!

- 🚶 **True Human Presence Detection (HPD - Walk-Away Lock / Approach Wake)**:
  - Low-power continuous presence sensing. When you step away from your desk, calls macOS native `SACLockScreenImmediate()` to securely lock your Mac and sleep displays.
  - **Zero Password Leakage Protection**: Strict atomic validation checks ensure the display is genuinely locked before any simulated keystroke is typed, completely preventing accidental password leakage into desktop apps.

- 🛡️ **Universal macOS Face ID Integration**:
  - ⌨️ **Global Hotkey Password Auto-Fill (`⌘\` / 1Password-Style)**:
    - Press a customizable global shortcut (default **`Command + \`**) anywhere on macOS to instantly trigger Face ID face verification and fill your password into the active input field (browsers, Electron apps, terminals, password dialogs).
    - **Zero Focus Stealing**: Runs entirely in the background without stealing focus from the active text box.
    - **Customizable Shortcut Recorder**: Interactive recorder supporting custom key combinations and presets (`⌘\`, `⌥⌘P`, `⌃⌥Space`, `⌥\`, `⇧⌘\`).
    - **Ephemeral Privacy Clipboard**: Injects password using transient clipboard flags (`org.nspasteboard.TransientType`, `ConcealedType`, `AutoGeneratedType`), ensuring passwords are never indexed by clipboard managers (Raycast, Paste, Maccy) and auto-restored after 800ms.
  - 🔔 **Native macOS System Notifications (`UNUserNotificationCenter`)**:
    - Real-time feedback with native MacHello icon banners and chimes. Click any notification banner to jump straight to the Audit History window.
  - 💻 **Terminal `sudo` Elevation (Direct USB & LAN Linux Gateway)**:
    - Replaces manual password typing with Windows Hello-grade infrared face authentication in terminal sessions.
    - Automatically resolves the invoking user's real preferences via `SUDO_USER` when elevated under root.
  - 🔐 **Admin Elevation Prompts (`SecurityAgent`)**:
    - Automatically verifies system administrator prompt dialogs via Face ID. Auto-focuses and activates SecurityAgent password fields to eliminate synthetic key drops.
  - 🔒 **Rock-Solid Lock Screen Auto-Unlock**:
    - Built on pure hardware HID events (`CGEventSource(stateID: .hidSystemState)` and `.cghidEventTap`) with atomic chunked Unicode injection, dual Return/Enter keystrokes, and non-destructive wake sequence.
    - Protected by atomic session UUIDs, instant timer cancellation, and 4.0s cooldown guards to eliminate lock screen transition racing.
  - 📜 **100% Comprehensive Audit History**:
    - High-precision timestamp, similarity score, and NIR snapshot recorded for every attempt (passes, failures, timeouts, and anti-spoofing intercepts).
  - 🔑 **Apple Keychain Secure Storage**: Credentials encrypted via macOS native Keychain Services.
  - 🧩 **Universal App-Specific Credentials (Bitwarden, 1Password, etc.)**:
    - **Per-App Keychain Isolation**: Securely store custom unlock credentials (master passwords or quick PINs) for any third-party app in dedicated Keychain slots (`com.machello.customApp.<bundleId>`).
    - **Context-Aware Global Hotkey (⌘\)**: When pressing the hotkey in Bitwarden or other registered apps, MacHello automatically detects the active frontmost app via Accessibility API, retrieves its specific credential, and simulates Return to unlock. Defaults back to system login password in all other fields.
    - **Auto-Unlock on Focus**: Optionally triggers Face ID when switching to locked apps (`Cmd+Tab`) and auto-enters the vault upon verification.
    - **Instant Running App Picker & Finder Browser**: Easily select from running GUI apps with app icons, or browse any `.app` in `/Applications`.
    - **Active Deletion & Passive Uninstallation Self-Healing**: Actively removing an app rule immediately purges its Keychain entry. If you uninstall a configured app from your Mac, MacHello automatically detects its absence and cleans up orphaned Keychain credentials, leaving zero residual data.
  - 🧹 **Complete Uninstallation & Full-System Data Erase (Dual-Option Guarantee)**:
    - **Option A (In-App Menu)**: Select *“🧹 Uninstall MacHello & Erase All Data...”* at the bottom of the status bar menu. After confirmation, MacHello automatically unregisters login items, restores PAM configs, erases all Keychain credentials, permanently shreds `~/.machello` (biometric vectors & snapshot history), clears preferences, reveals `MacHello.app` in Finder for dragging to Trash, and terminates.
    - **Option B (Terminal Script)**: Run `sudo ./scripts/uninstall-all.sh` to cleanly stop all processes, restore PAM, delete Keychain items, and purge all directories with zero leftover clutter.
  - 🔊 **Haptic & Audio Feedback**: Plays a pleasant Face ID recognition chime on success.

- 🧪 **Full-Pipeline Hardware Diagnostic Wizard**:
  - Step-by-step diagnostic test:
    1. Visible light (RGB 720P) stream & frame sampling
    2. Realtek UVC Extension Unit (Unit 4) 5-step register handshake
    3. 850nm NIR emitter trigger & night-vision mode switch
    4. Near-infrared physical camera (640x480 YUY2) frame capture
    5. Apple Neural Engine biometric feature extraction & cosine similarity scoring
  - Diagnostic logs and snapshot frame albums with one-click export.

- 👤 **Circular Face ID Enrollment Wizard**:
  - Elegant Apple-style circular progress ring with real-time head pose guidance (Center, Turn Left, Turn Right, Tilt Up).
  - **Dual Appearance Support**: Enrolls both your daily appearance (with glasses) and alternative appearance (without glasses) for 100% reliable unlocks day and night.

---

## 🔌 Hardware Guide (Dell CN-0592WK)

### Where to Buy
The **Dell CN-0592WK (Realtek 0bda:5767)** is an infrared dual-sensor camera salvage module from laptops like Dell Latitude 7490 / 7480. It is widely available worldwide for **$5 – $10 USD**:
- **AliExpress / eBay / Amazon**: Search keywords:
  - `Dell 0592WK`
  - `CN-0592WK`
  - `Dell Latitude 7490 IR camera webcam`
  - `Realtek 0bda:5767 IR camera`

### Pinout & Wiring (USB 2.0 Standard)
The camera board connects via a standard 4-pin or 5-pin JST connector to any standard USB cable:

| Pin | Function | Wire Color (Standard USB) | Notes |
| :---: | :---: | :---: | :--- |
| **Pin 1** | **VCC (+5V)** | Red | Connect to USB 5V |
| **Pin 2** | **USB D-** | White | USB 2.0 Data Negative |
| **Pin 3** | **USB D+** | Green | USB 2.0 Data Positive |
| **Pin 4** | **GND** | Black | Ground |
| *(Shell)* | **Shield GND** | Braided wire | Optional chassis ground |

> **Mounting Tip**: If you mount the camera board upside-down underneath an external monitor, simply toggle **`Inverted Mount Mode (Rotate 180°)`** in the MacHello menu.

---

## 🚀 Quick Start & Installation

### Option 1: Build & Package App (Recommended)

```bash
# Clone the repository
git clone https://github.com/MaYunFei/MacHello-0592WK.git
cd MacHello-0592WK

# Compile and install MacHello.app into /Applications
./scripts/package-app.sh --install
```

After installation, launch **MacHello** from Spotlight or `/Applications`.

### Option 2: Enable Terminal Sudo Face ID

To unlock `sudo` in Terminal using Face ID:

```bash
# Install the native PAM module and sudo configuration
sudo ./scripts/install-pam.sh
```

### Option 3: Clean Complete Uninstallation (Option B)

To completely uninstall MacHello and erase all biometric data, Keychain items, and PAM configuration:

```bash
sudo ./scripts/uninstall-all.sh
```

Now run any `sudo` command in Terminal to experience instant infrared face unlock:
```bash
sudo ls
# [MacHello] Verifying face... ✓ Verified (User: yourname)
```

To uninstall PAM configuration at any time:
```bash
sudo ./scripts/uninstall-pam.sh
```

---

## 🌐 Linux Gateway Setup (Optional - For Network Mode)

If you prefer connecting your camera module to a Linux mini-PC or homelab server:

1. **Connect the module to Linux** and verify detection:
   ```bash
   lsusb | grep 0bda:5767
   # Bus 001 Device 003: ID 0bda:5767 Realtek Semiconductor Corp.
   ```

2. **Deploy the Gateway Service**:
   ```bash
   cd linux-server
   sudo ./install-service.sh
   ```

3. **Connect from Mac**:
   - Click the **MacHello** icon in the macOS menu bar.
   - Under **Deployment Mode**, select **`Linux Gateway`**.
   - Enter your Linux IP address (e.g., `http://192.168.1.100:8765`).
   - Your Mac will immediately establish a low-latency connection with zero local camera green-dot overhead!

---

## 🛠️ CLI Diagnostics & Tools

MacHello includes standalone CLI binaries for scripting and headless diagnostics:

```bash
# Run full hardware inspection and save test snapshots
swift run MacHelloDoctor

# Test infrared night-vision capture in complete darkness
swift run MacHelloDarkTest

# Enroll faces via terminal command line
swift run MacHelloEnroll

# Test real-time human presence detection in terminal
swift run MacHelloPresence
```

---

## 🔒 Security & Privacy

- **100% On-Device & Local**: No images or biometric embeddings ever leave your local machine or local network. No telemetry, no analytics, no cloud calls.
- **Hardware Enclave Encryption**: System passwords are stored exclusively inside macOS native Keychain Services.
- **Auto-Off Infrared Radiation**: 850nm NIR emitters are strictly triggered in microsecond pulses during active authentication and immediately powered off upon completion.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
