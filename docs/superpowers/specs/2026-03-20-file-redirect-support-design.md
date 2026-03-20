# File Redirect Support

**Date:** 2026-03-20
**Status:** Approved

## Summary

Extend TheRedirector to support individual file redirects alongside the existing folder redirects. Files use NTFS symlinks; folders continue using junctions. Both types coexist in the same UI list, differentiated by icon and color. The enable flow already supports moving existing content for folders; this extends the same behavior to files.

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

**Backwards compatibility:** `Load-Config` assigns `Type = "Folder"` to any entry missing the field. `Save-Config` always writes the `type` field.

**Type propagation:** The `Type` property must be threaded through every place a redirect object is constructed or read:
- `Load-Config` — add `Type` to the PSCustomObject (default `"Folder"` if missing)
- `Save-Config` — include `type` in the ordered hashtable
- `Update-ListView` `$itemData` — include `Type` from the redirect
- `Show-EditDialog` return object — include `Type`
- `btnAdd.Add_Click` — include `Type` when constructing the new redirect
- `config.example.json` — update with a file redirect example and `type` fields

## Symlink Mechanism

| Type   | Link Kind        | Create Command                                           | Remove Command                                |
|--------|------------------|----------------------------------------------------------|-----------------------------------------------|
| Folder | Junction         | `New-Item -ItemType Junction -Path $s -Target $t`        | `[System.IO.Directory]::Delete($s, $false)`   |
| File   | Symbolic link    | `New-Item -ItemType SymbolicLink -Path $s -Target $t`    | `[System.IO.File]::Delete($s)`                |

Junctions are kept for folders because they don't require elevated privileges on all Windows versions and are the established mechanism in the codebase. File symlinks require admin in most configurations (Developer Mode is an exception, but the app already enforces admin elevation).

**Note on file symlink removal:** `[System.IO.File]::Delete($source)` is used instead of `Remove-Item` because `Remove-Item` can follow symlinks in some edge cases. `File.Delete` reliably removes only the link itself, matching the folder pattern's use of `Directory.Delete`.

## Status Detection (`Get-RedirectStatus`)

The same five statuses apply to both types. The function gains a `-Type` parameter and branches accordingly.

**Function signature:** `Get-RedirectStatus -Source $s -Target $t -Type $type`

| Check             | Folder                              | File                                   |
|-------------------|-------------------------------------|----------------------------------------|
| Source missing    | "Inactive"                          | "Inactive"                             |
| Is a link?        | `LinkType -eq "Junction"`           | `LinkType -eq "SymbolicLink"` and source is not a directory |
| Target match      | Normalize + case-insensitive compare | Normalize + case-insensitive compare   |
| Target exists     | "Active" / "Broken"                 | "Active" / "Broken"                    |
| Target mismatch   | "WrongTarget"                       | "WrongTarget"                          |
| Regular item      | Regular directory = "Unlinked"      | Regular file = "Unlinked"              |

### Type mismatch edge cases

If the source exists but is the wrong kind for the redirect type:
- **File redirect but source is a directory** (not a symlink): return "Unlinked". The enable flow will prompt the user to deal with the existing directory before creating the file symlink.
- **Folder redirect but source is a regular file** (not a junction): return "Unlinked". Same treatment — enable flow prompts to move/delete.

This keeps the status model simple (no new statuses) and lets the enable flow handle the mismatch interactively.

## Enable-Redirect Changes

The function continues to accept the whole `$Redirect` object (which now carries `Type`). It branches on `$Redirect.Type` for link creation and deletion commands.

### User-facing messages

All prompts and error messages must be type-aware:
- "junction" becomes "junction" for folders, "symbolic link" for files
- "folder" becomes "folder" for folders, "file" for files
- Example: "A junction already exists..." → "A symbolic link already exists..." for file type

### Source exists as regular file/folder ("Unlinked")

1. If target already exists at destination:
   - Prompt: "Source already exists as a regular [file/folder]. Delete source and create redirect? Data is already at the target location."
   - On confirm: delete source, create link
   - On cancel: abort

2. If target does NOT exist:
   - Prompt with three options: **Move** / **Delete** / **Cancel**
   - **Move**: Ensure target's parent directory exists (`New-Item -ItemType Directory -Force` on parent). Then `Move-Item $source $target`, then create link.
   - **Delete**: `Remove-Item $source` (file) or `Remove-Item $source -Recurse -Force` (folder), then create link
   - **Cancel**: abort

### Source doesn't exist ("Inactive")

1. If target doesn't exist: prompt to create target. For folders: `New-Item -ItemType Directory`. For files: ensure parent directory exists, then `New-Item -ItemType File`. Then create link.
2. If target exists: create link directly.

### Link creation

- Ensure the parent directory of the source exists before creating the link (`New-Item -ItemType Directory -Force` on `Split-Path $source -Parent`).
- Folder: `New-Item -ItemType Junction -Path $source -Target $target`
- File: `New-Item -ItemType SymbolicLink -Path $source -Target $target`

## Disable-Redirect Changes

The function continues to accept the whole `$Redirect` object. It branches on `$Redirect.Type` for the deletion command:

- **Folder**: `[System.IO.Directory]::Delete($source, $false)` (unchanged)
- **File**: `[System.IO.File]::Delete($source)` (removes symlink only, target file untouched)

User-facing messages must also be type-aware:
- "The source path is a regular folder, not a junction point" → for file type: "The source path is a regular file, not a symbolic link"

## Toolbar Changes

Replace the single "Add Redirect" button with two buttons:

```
[+ Add Folder]  [+ Add File]  [Edit]  [Remove]  |  [Enable]  [Disable]      [Refresh]
```

- **Add Folder**: Blue button (`#0078D4`), opens edit dialog in folder mode
- **Add File**: Blue button (`#0078D4`), opens edit dialog in file mode
- Both call `Show-EditDialog -Type "Folder"` or `Show-EditDialog -Type "File"`

## Card Visual Differentiation

Each card displays a type icon as a TextBlock to the left of the existing status dot in the name row:

- **Folder redirect**: Unicode `U+1F4C1` (open folder icon) or fallback `U+2750` — color `#60A5FA` (muted blue)
- **File redirect**: Unicode `U+1F4C4` (document icon) or fallback `U+2630` — color `#A78BFA` (muted purple)

The type icon is a TextBlock with FontSize ~10, placed before the status dot in the horizontal name row StackPanel. The status badge pill (Active/Inactive/etc.) is unchanged.

**Fallback consideration:** If emoji rendering is inconsistent in WPF, use simple text labels ("DIR" / "FILE") or geometric shapes (filled rectangle vs filled circle) in the specified colors instead.

## Show-EditDialog Changes

- New parameter: `-Type` (`"File"` or `"Folder"`)
- Dialog title: "Add [File/Folder] Redirect" or "Edit [File/Folder] Redirect - [name]"
- Type is displayed in the dialog as a read-only label so the user knows which mode they're in
- Browse buttons:
  - Folder mode: `System.Windows.Forms.FolderBrowserDialog` (unchanged)
  - File mode: `System.Windows.Forms.OpenFileDialog` with appropriate filter
- Returned object includes `Type` field: `[PSCustomObject]@{ Name; Source; Target; Type }`

When editing an existing redirect, the type is determined from the redirect's stored `Type` field and cannot be changed (would need to remove and re-add).

## Save-Config Changes

Include the `type` field in the saved JSON, preserving field order: `name`, `type`, `source`, `target`.

## README Updates

- Update overview to mention file and folder redirects
- Document the `type` field in config format section with file example
- Explain junctions (folders) vs symlinks (files) briefly
- Add a file redirect example to "Getting Started"
- Note backwards compatibility for configs without `type`
- Update version to 1.1.0
