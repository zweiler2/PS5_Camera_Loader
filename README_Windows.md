# Installation on Windows

## 1. Download the latest version of the PS5 Camera Loader:

[![Latest Release](https://img.shields.io/github/v/release/zweiler2/PS5_Camera_Loader?label=release&style=flat-square)](https://github.com/zweiler2/PS5_Camera_Loader/releases/latest)

## 2. Install the driver via the InstallDriver.exe file from inside the downloaded and extracted folder.

## 3. Run the PS5 Camera Loader executable file:

### 3.1. Open a command prompt or terminal and navigate to the extracted folder.

(Hint: Inside the PS5_Camera_Loader folder click on the address bar at the top write "cmd" and press enter or shift+right-click and select "Open In Terminal")

### 3.2. Run the executable and upload the new firmware to the camera:

```bat
PS5_Camera_Loader\PS5_Camera_Loader firmware_discord_and_gamma_fix.bin
```

## 4. Now the camera should work!

Note that you need to redo step 3.2 every time you replug your PS5 Camera, because the camera resets to the default firmware on power loss.

## 5. Bonus: Add autorun

For this section, you will need to have administrative privileges.

Copy the extracted PS5_Camera_Loader folder to "C:\\":

```bat
cp -r PS5_Camera_Loader C:\
```

The file structure should then look like:

```
C:\PS5_Camera_Loader
  ├─ firmware.bin
  ├─ firmware_discord_and_gamma_fix.bin
  ├─ InstallDriver.exe
  ├─ PS5_Camera_Loader.exe
  └─ PS5_Camera_Windows_Service.exe
```

Then open a command prompt or terminal as an administrator and run the following command to create a windows service using the "PS5_Camera_Windows_Service.exe" file:

```bat
sc create PS5_Camera_Firmware_Loader start= auto binPath= "C:\PS5_Camera_Loader\PS5_Camera_Windows_Service.exe"
```

Then start the service:

```bat
sc start PS5_Camera_Firmware_Loader
```

That's it! Now it should work automatically when you plug it in.
There's no need to redo step 3.2 every time.

## 6. Bonus: Remove autorun

To remove autorun, you just need to delete the files you copied in step 6 and remove the service.
First stop the service:

```bat
sc stop PS5_Camera_Firmware_Loader
```

Then delete the service:

```bat
sc delete PS5_Camera_Firmware_Loader
```

Finally, remove the files:

```bat
rmdir /s /q C:\PS5_Camera_Loader
```
