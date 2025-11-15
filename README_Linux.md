# Installation on Linux

## 1. Download the latest version of the PS5 Camera Loader:

[![Latest Release](https://img.shields.io/github/v/release/zweiler2/PS5_Camera_Loader?label=release&style=flat-square)](https://github.com/zweiler2/PS5_Camera_Loader/releases/latest)

## 2. Add your user to the plugdev group:

### 2.1. Check if the group exists:

```bash
getent group plugdev
```

And if it doesn't exist, create it:

```bash
sudo groupadd -r plugdev
```

### 2.2. Add your user to the plugdev group:

```bash
sudo usermod -aG plugdev "$USER"
```

### 2.3. Log out and log back in for the group membership to take effect.

## 3. Add the udev rule:

### 3.1. Copy the udev rule file to `/etc/udev/rules.d/`:

```bash
sudo cp PS5_Camera_Loader/100-playstation-camera.rules /etc/udev/rules.d/
```

### 3.2. Reload the udev rules:

```bash
sudo udevadm control --reload && sudo udevadm trigger
```

## 4. Run the PS5 Camera Loader executable file:

### 4.1. Open a command prompt or terminal and navigate to the extracted directory.

(Hint: Inside the PS5_Camera_Loader directory, right-click and select "Open Command Prompt Here")

### 4.2. Run the executable and upload the new firmware to the camera:

```bash
./PS5_Camera_Loader/PS5_Camera_Loader firmware_discord_and_gamma_fix.bin
```

## 5. Now the camera should work!

Note that you need to redo step 4.2 every time you replug your PS5 Camera, because the camera resets to the default firmware on power loss.

## 6. Bonus: Add autorun

This makes the camera work automatically when you plug it in.
The executable and the firmware must be in the right location (The one specified in the `100-playstation-camera.rules` file).

```bash
sudo cp PS5_Camera_Loader/PS5_Camera_Loader /usr/bin/PS5_Camera_Loader
```

```bash
sudo cp PS5_Camera_Loader/firmware_discord_and_gamma_fix.bin /usr/lib/firmware/ps5-camera-firmware.bin
```

That's it! Now it should work automatically when you plug it in.
There's no need to redo step 4.2 every time.

## 7. Bonus: Remove autorun

To remove autorun, you just need to delete the files you copied in step 6.

```bash
sudo rm /usr/bin/PS5_Camera_Loader
```

```bash
sudo rm /usr/lib/firmware/ps5-camera-firmware.bin
```
