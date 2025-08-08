# PS5 Camera Loader

## Installation on Windows

### 1. Download the latest version of the PS5 Camera Loader:

[![Latest Release](https://img.shields.io/github/v/release/zweiler2/PS5_Camera_Loader?label=release&style=flat-square)](https://github.com/zweiler2/PS5_Camera_Loader/releases/latest)

### 2. Install the driver via the InstallDriver.exe file from inside the downloaded and extracted folder.

### 3. Run the PS5 Camera Loader executable file:

3.1. Open a command prompt or terminal and navigate to the extracted folder.
(Hint: Inside the PS5_Camera_Loader folder click on the address bar at the top write "cmd" and press enter or shift+right-click and select "Open In Terminal")

3.2. Run the executable and upload the new firmware to the camera:

```bat
PS5_Camera_Loader\PS5_Camera_Loader firmware_discord_and_gamma_fix.bin
```

### 4. Now the camera should work!

Note that you need to redo step 3.2 every time you replug your PS5 Camera, because the camera resets to the default firmware on power loss.

## Installation on Linux

### 1. Download the latest version of the PS5 Camera Loader:

[![Latest Release](https://img.shields.io/github/v/release/zweiler2/PS5_Camera_Loader?label=release&style=flat-square)](https://github.com/zweiler2/PS5_Camera_Loader/releases/latest)

### 2. Add your user to the plugdev group:

2.1. Check if the group exists:

```bash
getent group plugdev
```

And if it doesn't exist, create it:

```bash
sudo groupadd plugdev
```

2.2. Add your user to the plugdev group:

```bash
sudo usermod -aG plugdev "$USER"
```

2.3. Log out and log back in for the group membership to take effect.

### 3. Add udev rule:

3.1. Copy the udev rule file to `/etc/udev/rules.d/`:

```bash
sudo cp PS5_Camera_Loader/100-playstation-camera.rules /etc/udev/rules.d/
```

3.2. Reload the udev rules:

```bash
sudo udevadm control --reload && sudo udevadm trigger
```

### 4. Run the PS5 Camera Loader executable file:

4.1. Open a command prompt or terminal and navigate to the extracted directory.
(Hint: Inside the PS5_Camera_Loader directory, right-click and select "Open Command Prompt Here")

4.2. Run the executable and upload the new firmware to the camera:

```bash
./PS5_Camera_Loader/PS5_Camera_Loader firmware_discord_and_gamma_fix.bin
```

### 5. Now the camera should work!

Note that you need to redo step 4.2 every time you replug your PS5 Camera, because the camera resets to the default firmware on power loss.
