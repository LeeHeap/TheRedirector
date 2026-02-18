# TheRedirector

A sleek, dark-themed GUI for managing **NTFS junction points** on Windows. Use it to redirect application settings folders to a synced location (OneDrive, Dropbox, etc.) while keeping apps completely unaware.

![Status badges: Active, Not Linked, Inactive, Broken](docs/screenshot.png)

---

## How it works

Windows NTFS supports **junction points** — a type of directory symlink that makes one folder path transparently point to another location. When you redirect, say, `%AppData%\PrusaSlicer` to `OneDrive\Synced Settings\PrusaSlicer`, the app reads and writes to its normal path but the data actually lives on OneDrive.

TheRedirector manages a config file of `name → source → target` mappings and lets you enable or disable each redirect with a single click.

---

## Requirements

- **Windows 10 / 11**
- **PowerShell 5.1** or later (built-in on modern Windows)
- **Administrator privileges** (required to create/remove NTFS junction points)

---

## Getting started

### 1. Clone or download

```
git clone https://github.com/yourusername/TheRedirector.git
```

### 2. Run the app

Double-click **`Run.bat`** — it will request elevation automatically.

Or launch manually from an elevated PowerShell prompt:

```powershell
PowerShell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "TheRedirector.ps1"
```

> **Note:** The script will prompt to restart as administrator if not already elevated.

### 3. Create your config

On first run, a blank `config.json` is created. Use the GUI to add your redirects, or copy `config.example.json` to `config.json` and edit the paths.

---

## Config file (`config.json`)

The config is a simple JSON file stored alongside the script:

```json
{
  "redirects": [
    {
      "name": "PrusaSlicer",
      "source": "C:\\Users\\Lee\\AppData\\Roaming\\PrusaSlicer",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\PrusaSlicer"
    }
  ]
}
```

| Field    | Description                                              |
|----------|----------------------------------------------------------|
| `name`   | Friendly display name shown in the GUI                  |
| `source` | Where the application expects its data (original path)  |
| `target` | Where the data actually lives (your synced folder)       |

The config is updated automatically when you add, edit, or remove entries via the GUI.

---

## Status indicators

Each redirect card shows one of these status badges:

| Badge        | Meaning                                                                 |
|--------------|-------------------------------------------------------------------------|
| **Active**       | Junction point exists and points to the correct target              |
| **Inactive**     | Source path doesn't exist — junction not needed yet                 |
| **Not Linked**   | Source exists as a regular folder — data not yet redirected         |
| **Broken Link**  | Junction exists but the target folder is missing                    |
| **Wrong Target** | Junction exists but points to a different location                  |

---

## Enabling a redirect

When you click **Enable**, the app handles existing data at the source path:

- **Source doesn't exist** → Junction is created immediately (creates target folder if needed)
- **Source is a regular folder, target doesn't exist** → Asks to **Move** data to target, **Delete** it, or **Cancel**
- **Source is a regular folder, target already exists** → Asks to **Delete** source folder (data stays in target), or **Cancel**
- **Source is already a junction** → Shown as Active, Broken, or Wrong Target; no action taken

## Disabling a redirect

Clicking **Disable** removes only the junction point. Your data remains safely in the target folder. The source path simply disappears until you re-enable the redirect.

---

## Keyboard shortcuts

| Key      | Action               |
|----------|----------------------|
| `F5`     | Refresh all statuses |
| `Enter`  | Edit selected item   |
| `Delete` | Remove selected item |

---

## Tips

- **Before enabling** a redirect for the first time, make sure you've already moved your data to the target folder, or let the app move it for you.
- **Before disabling**, ensure the application is closed so it doesn't hold any file handles.
- If you reinstall Windows or set up a new PC, just run TheRedirector and enable all your redirects — your settings are already waiting on OneDrive.
- `config.json` is gitignored by default so your personal paths don't end up in the repo. Use `config.example.json` as a template to share with others.

---

## Project structure

```
TheRedirector/
├── TheRedirector.ps1      # Main application (PowerShell + WPF)
├── config.json            # Your personal redirect config (gitignored)
├── config.example.json    # Example config showing the format
├── Run.bat                # Convenience launcher (requests elevation)
├── .gitignore
└── README.md
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.
