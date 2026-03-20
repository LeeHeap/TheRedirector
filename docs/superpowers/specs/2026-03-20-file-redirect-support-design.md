# File Redirect Support

**Date:** 2026-03-20
**Status:** Approved

## Summary

Extend TheRedirector to support individual file redirects alongside the existing folder redirects. Files use NTFS symlinks; folders continue using junctions. Both types coexist in the same UI list, differentiated by icon and color. The enable flow for both types gains a "move existing content" prompt when the source already exists.

## Config Format

Add a `type` field to each redirect entry. Existing entries without `type` default to `"Folder"` for backwards compatibility.

```json
{
  "redirects": [
    {
      "name": "PrusaSlicer",
      "type": "Folder",
      "source": "C:\\Users\\Lee\\AppData\\Roaming\\PrusaSlicer",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\PrusaSlicer"
    },
    {
      "name": "SSH Config",
      "type": "File",
      "source": "C:\\Users\\Lee\\.ssh\\config",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\.ssh\\config"
    }
  ]
}
```

**Backwards compatibility:** `Load-Config` assigns `type = "Folder"` to any entry missing the field. `Save-Config` always writes the `type` field.

## Symlink Mechanism

| Type   | Link Kind                          | Create Command                                  | Remove Command                                |
|--------|------------------------------------|-------------------------------------------------|-----------------------------------------------|
| Folder | Junction (unchanged)               | `New-Item -ItemType Junction -Path $s -Target $t` | `[System.IO.Directory]::Delete($s, $false)`   |
| File   | Symbolic link                      | `New-Item -ItemType SymbolicLink -Path $s -Target $t` | `Remove-Item -Force $s`                       |

Junctions are kept for folders because they don't require elevated privileges on all Windows versions and are the established mechanism in the codebase. File symlinks require admin, which the app already enforces.

## Status Detection (`Get-RedirectStatus`)

The same five statuses apply to both types. Detection branches on `$Type`:

| Check             | Folder                              | File                                   |
|-------------------|-------------------------------------|----------------------------------------|
| Source missing    | "Inactive"                          | "Inactive"                             |
| Is a link?        | `LinkType -eq "Junction"`           | `LinkType -eq "SymbolicLink"` and not a directory |
| Target match      | Normalize + case-insensitive compare | Normalize + case-insensitive compare   |
| Target exists     | "Active" / "Broken"                | "Active" / "Broken"                    |
| Target mismatch   | "WrongTarget"                       | "WrongTarget"                          |
| Regular item      | Regular directory = "Unlinked"      | Regular file = "Unlinked"              |

**Function signature change:** `Get-RedirectStatus -Source $s -Target $t -Type $type`

## Enable-Redirect Changes

Unified flow for both types. The `-Type` parameter controls which commands are used.

### Source exists as regular file/folder ("Unlinked")

1. If target already exists at destination:
   - Prompt: "Source already exists as a regular [file/folder]. Delete source and create redirect? Data is already at the target location."
   - On confirm: delete source, create link
   - On cancel: abort

2. If target does NOT exist:
   - Prompt with three options: **Move** / **Delete** / **Cancel**
   - **Move**: `Move-Item $source $target`, then create link
   - **Delete**: `Remove-Item $source` (file) or `Remove-Item $source -Recurse` (folder), then create link
   - **Cancel**: abort

### Source doesn't exist ("Inactive")

1. If target doesn't exist: prompt to create target (empty file or empty directory), then create link
2. If target exists: create link directly

### Link creation

- Folder: `New-Item -ItemType Junction -Path $source -Target $target`
- File: `New-Item -ItemType SymbolicLink -Path $source -Target $target`

Ensure the parent directory of the source exists before creating the link (`New-Item -ItemType Directory -Force` on the parent path).

## Disable-Redirect Changes

- **Folder**: Existing `[System.IO.Directory]::Delete($source, $false)` (unchanged)
- **File**: `Remove-Item -Force $source` (removes symlink only, target file untouched)

**Function signature change:** `Disable-Redirect -Source $s -Target $t -Type $type`

## Toolbar Changes

Replace the single "Add Redirect" button with two buttons:

```
[+ Add Folder]  [+ Add File]  [Edit]  [Remove]  |  [Enable]  [Disable]      [Refresh]
```

- **Add Folder**: Blue button, opens edit dialog in folder mode
- **Add File**: Blue button (slightly different shade or same), opens edit dialog in file mode
- Both call `Show-EditDialog -Type "Folder"` or `Show-EditDialog -Type "File"`

## Card Visual Differentiation

Each card displays a type icon before the status dot:

- **Folder redirect**: Folder icon in muted blue
- **File redirect**: File/document icon in muted purple/teal

The icon sits to the left of the existing status dot in the name row. The status badge pill (Active/Inactive/etc.) is unchanged.

## Show-EditDialog Changes

- New parameter: `-Type` (`"File"` or `"Folder"`)
- Dialog title: "Add [File/Folder] Redirect" or "Edit [File/Folder] Redirect - [name]"
- Type is displayed in the dialog (read-only label) so the user knows which mode they're in
- Browse buttons:
  - Folder mode: `System.Windows.Forms.FolderBrowserDialog` (unchanged)
  - File mode: `System.Windows.Forms.OpenFileDialog`
- Returned object includes `Type` field: `[PSCustomObject]@{ Name; Source; Target; Type }`

When editing an existing redirect, the type is determined from the redirect's stored `type` field and cannot be changed (would need to remove and re-add).

## Save-Config Changes

Include the `type` field in the saved JSON, preserving field order: `name`, `type`, `source`, `target`.

## README Updates

- Update overview to mention file and folder redirects
- Document the `type` field in config format section with file example
- Explain junctions (folders) vs symlinks (files) briefly
- Add a file redirect example to "Getting Started"
- Note backwards compatibility for configs without `type`
- Update version to 1.1.0
