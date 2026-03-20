# File Redirect Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend TheRedirector to support individual file redirects (NTFS symlinks) alongside the existing folder redirects (NTFS junctions), with type-aware UI, config, and enable/disable logic.

**Architecture:** Single-file PowerShell/WPF app. All changes are in `TheRedirector.ps1` plus `config.example.json` and `README.md`. The `Type` property ("File" or "Folder") is added to every redirect object and threaded through config, status detection, enable/disable, dialog, and card rendering. No new files are created.

**Tech Stack:** PowerShell 5.1, WPF (XAML + code-behind), NTFS junctions (folders), NTFS symlinks (files)

**Spec:** `docs/superpowers/specs/2026-03-20-file-redirect-support-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `TheRedirector.ps1` | Modify | All application logic — config, status, enable/disable, UI, event handlers |
| `config.example.json` | Modify | Add `type` fields to existing entries, add a file redirect example |
| `README.md` | Modify | Document file redirects, type field, symlinks vs junctions |

---

### Task 1: Config Layer — Add Type Field to Load-Config and Save-Config

**Files:**
- Modify: `TheRedirector.ps1:22` (version), `TheRedirector.ps1:78-79` (Load-Config), `TheRedirector.ps1:96-99` (Save-Config)

- [ ] **Step 1: Update version number**

In `TheRedirector.ps1` line 22, change:
```powershell
$script:Version      = "1.0.0"
```
to:
```powershell
$script:Version      = "1.1.0"
```

- [ ] **Step 2: Add Type to Load-Config**

In `TheRedirector.ps1` lines 78-79, the PSCustomObject in `Load-Config` currently has `Name`, `Source`, `Target`. Change to:
```powershell
$script:Redirects = @($json.redirects | ForEach-Object {
    [PSCustomObject]@{
        Name   = $_.name
        Type   = if ($_.type) { $_.type } else { "Folder" }
        Source = $_.source
        Target = $_.target
    }
})
```
This defaults missing `type` fields to `"Folder"` for backwards compatibility.

- [ ] **Step 3: Add Type to Save-Config**

In `TheRedirector.ps1` lines 96-99, change the ordered hashtable to include `type`:
```powershell
function Save-Config {
    $obj = @{
        redirects = @($script:Redirects | ForEach-Object {
            [ordered]@{ name = $_.Name; type = $_.Type; source = $_.Source; target = $_.Target }
        })
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content $script:ConfigPath -Encoding UTF8
}
```
Note the `[ordered]` cast to preserve field order in the JSON output.

- [ ] **Step 4: Verify**

Run the app. It should load existing config (which has no `type` field) without error. Check the debug log. Close the app, then inspect `config.json` — each entry should now have `"type": "Folder"` in the saved JSON.

- [ ] **Step 5: Commit**
```bash
git add TheRedirector.ps1
git commit -m "feat: add Type field to config layer (Load-Config, Save-Config)"
```

---

### Task 2: Status Detection — Add -Type Parameter to Get-RedirectStatus

**Files:**
- Modify: `TheRedirector.ps1:107-128` (Get-RedirectStatus)

- [ ] **Step 1: Update Get-RedirectStatus signature and logic**

Replace the entire `Get-RedirectStatus` function (lines 107-128) with:
```powershell
function Get-RedirectStatus {
    param([string]$Source, [string]$Target, [string]$Type = "Folder")

    $item = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    if (-not $item) { return "Inactive" }

    if ($Type -eq "File") {
        # File redirect: check for symbolic link (not directory)
        if ($item.LinkType -eq "SymbolicLink" -and -not $item.PSIsContainer) {
            $lt = $item.Target
            if ($lt) { $lt = $lt[0] }
            try {
                $normLt  = [System.IO.Path]::GetFullPath($lt).TrimEnd('\')
                $normTgt = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
                if ($normLt -ieq $normTgt) {
                    return $(if (Test-Path -LiteralPath $Target) { "Active" } else { "Broken" })
                } else {
                    return "WrongTarget"
                }
            } catch { return "Broken" }
        } else {
            return "Unlinked"   # regular file, directory, or wrong link type
        }
    } else {
        # Folder redirect: check for junction (existing logic)
        if ($item.LinkType -eq "Junction") {
            $jt = $item.Target
            if ($jt) { $jt = $jt[0] }
            try {
                $normJt  = [System.IO.Path]::GetFullPath($jt).TrimEnd('\')
                $normTgt = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
                if ($normJt -ieq $normTgt) {
                    return $(if (Test-Path -LiteralPath $Target) { "Active" } else { "Broken" })
                } else {
                    return "WrongTarget"
                }
            } catch { return "Broken" }
        } else {
            return "Unlinked"   # regular folder, file, or wrong link type
        }
    }
}
```

- [ ] **Step 2: Update all call sites to pass -Type**

There are three call sites that need `-Type` added:

**a) `Enable-Redirect` (line 147):**
```powershell
$status = Get-RedirectStatus -Source $source -Target $target -Type $Redirect.Type
```

**b) `Disable-Redirect` (line 264):**
```powershell
$status = Get-RedirectStatus -Source $source -Target $Redirect.Target -Type $Redirect.Type
```

**c) `Update-ListView` (line 887):**
```powershell
$status = Get-RedirectStatus -Source $r.Source -Target $r.Target -Type $r.Type
```

- [ ] **Step 3: Verify**

Run the app. Existing folder redirects should show the same statuses as before (Active, Inactive, etc.). No errors in the debug log.

- [ ] **Step 4: Commit**
```bash
git add TheRedirector.ps1
git commit -m "feat: add -Type parameter to Get-RedirectStatus with file symlink detection"
```

---

### Task 3: Enable-Redirect — Type-Aware Link Creation and Messages

**Files:**
- Modify: `TheRedirector.ps1:142-258` (Enable-Redirect)

- [ ] **Step 1: Add type-aware label variables at the top of Enable-Redirect**

After the existing `$source` and `$target` lines (145-146), add:
```powershell
    $isFile   = $Redirect.Type -eq "File"
    $typeWord = if ($isFile) { "file" } else { "folder" }
    $linkWord = if ($isFile) { "symbolic link" } else { "junction" }
```

- [ ] **Step 2: Update the Get-RedirectStatus call (already done in Task 2)**

Confirm line 147 passes `-Type $Redirect.Type`.

- [ ] **Step 3: Update "WrongTarget" message (lines 160-163)**

Change the message from hardcoded "junction" to use `$linkWord`:
```powershell
        "WrongTarget" {
            $item   = Get-Item -LiteralPath $source -Force
            $actual = if ($item.Target) { $item.Target[0] } else { "unknown" }
            [System.Windows.MessageBox]::Show(
                "A $linkWord already exists at the source but points elsewhere:`n  $actual`n`nPlease disable it first, or remove it manually.",
                "Cannot Enable", [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return $false
        }
```

- [ ] **Step 4: Update "Broken" message (lines 166-171)**

Change to type-aware:
```powershell
        "Broken" {
            [System.Windows.MessageBox]::Show(
                "A $linkWord exists at the source but the target $typeWord is missing:`n  $target`n`nPlease restore the target $typeWord or disable this redirect.",
                "Broken $linkWord", [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return $false
        }
```

- [ ] **Step 5: Update "Unlinked" branch — target exists case (lines 177-191)**

Change folder-specific messages and use type-aware delete:
```powershell
        "Unlinked" {
            $targetExists = Test-Path -LiteralPath $target

            if ($targetExists) {
                $ans = [System.Windows.MessageBox]::Show(
                    "The source $typeWord has existing data, and the target already exists too.`n`nSource: $source`nTarget: $target`n`nTo proceed, the source must be deleted (your data lives in the target).`n`nDelete the source $typeWord and create the $($linkWord)?",
                    "Data Conflict - Confirm",
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning)

                if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return $false }

                try {
                    if ($isFile) { Remove-Item -LiteralPath $source -Force }
                    else         { Remove-Item -LiteralPath $source -Recurse -Force }
                }
                catch {
                    [System.Windows.MessageBox]::Show("Could not delete source $($typeWord):`n$_", "Error",
                        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                    return $false
                }
```

- [ ] **Step 6: Update "Unlinked" branch — target doesn't exist case (lines 192-223)**

Change to type-aware messages and delete:
```powershell
            } else {
                $ans = [System.Windows.MessageBox]::Show(
                    "The source $typeWord contains data. What should happen to it?`n`nSource: $source`nTarget: $target`n`nYes    - Move data to the target location`nNo     - Delete source data (data will be lost!)`nCancel - Do nothing",
                    "Existing Data Found",
                    [System.Windows.MessageBoxButton]::YesNoCancel,
                    [System.Windows.MessageBoxImage]::Question)

                switch ($ans) {
                    ([System.Windows.MessageBoxResult]::Yes) {
                        try {
                            $parentDir = Split-Path -Parent $target
                            if ($parentDir -and -not (Test-Path $parentDir)) {
                                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                            }
                            Move-Item -LiteralPath $source -Destination $target -Force
                        } catch {
                            [System.Windows.MessageBox]::Show("Could not move data:`n$_", "Error",
                                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                            return $false
                        }
                    }
                    ([System.Windows.MessageBoxResult]::No) {
                        try {
                            if ($isFile) { Remove-Item -LiteralPath $source -Force }
                            else         { Remove-Item -LiteralPath $source -Recurse -Force }
                        }
                        catch {
                            [System.Windows.MessageBox]::Show("Could not delete source $($typeWord):`n$_", "Error",
                                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                            return $false
                        }
                    }
                    default { return $false }
                }
            }
        }
```

- [ ] **Step 7: Update "Inactive" branch — target creation (lines 225-242)**

Change to handle file vs folder target creation:
```powershell
        "Inactive" {
            $targetExists = Test-Path -LiteralPath $target
            if (-not $targetExists) {
                $ans = [System.Windows.MessageBox]::Show(
                    "The target $typeWord doesn't exist yet:`n  $target`n`nCreate it and the $($linkWord)?",
                    "Target Missing",
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question)
                if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return $false }
                try {
                    if ($isFile) {
                        $parentDir = Split-Path -Parent $target
                        if ($parentDir -and -not (Test-Path $parentDir)) {
                            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                        }
                        New-Item -ItemType File -Path $target -Force | Out-Null
                    } else {
                        New-Item -ItemType Directory -Path $target -Force | Out-Null
                    }
                }
                catch {
                    [System.Windows.MessageBox]::Show("Could not create target $($typeWord):`n$_", "Error",
                        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
                    return $false
                }
            }
        }
```

- [ ] **Step 8: Update link creation at the bottom (lines 245-257)**

Change to branch on type for junction vs symlink:
```powershell
    # --- Create the link ---
    try {
        $parentDir = Split-Path -Parent $source
        if ($parentDir -and -not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        if ($isFile) {
            New-Item -ItemType SymbolicLink -Path $source -Target $target | Out-Null
        } else {
            New-Item -ItemType Junction -Path $source -Target $target | Out-Null
        }
        return $true
    } catch {
        [System.Windows.MessageBox]::Show("Failed to create $($linkWord):`n$_", "Error",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        return $false
    }
```

- [ ] **Step 9: Verify**

Run the app with an existing folder redirect. Enable/disable should work identically to before. No errors.

- [ ] **Step 10: Commit**
```bash
git add TheRedirector.ps1
git commit -m "feat: make Enable-Redirect type-aware (file symlinks + folder junctions)"
```

---

### Task 4: Disable-Redirect — Type-Aware Link Removal

**Files:**
- Modify: `TheRedirector.ps1:260-290` (Disable-Redirect)

- [ ] **Step 1: Replace Disable-Redirect with type-aware version**

Replace the entire function (lines 260-290) with:
```powershell
function Disable-Redirect {
    param($Redirect)

    $source   = $Redirect.Source
    $isFile   = $Redirect.Type -eq "File"
    $typeWord = if ($isFile) { "file" } else { "folder" }
    $linkWord = if ($isFile) { "symbolic link" } else { "junction" }
    $status   = Get-RedirectStatus -Source $source -Target $Redirect.Target -Type $Redirect.Type

    if ($status -eq "Inactive") {
        [System.Windows.MessageBox]::Show(
            "No $linkWord found at the source path. Nothing to disable.",
            "Not Active", [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information) | Out-Null
        return $false
    }
    if ($status -eq "Unlinked") {
        [System.Windows.MessageBox]::Show(
            "The source path is a regular $typeWord, not a $linkWord. Cannot disable.",
            "Not a Link", [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return $false
    }

    # Remove only the link, not the target contents
    try {
        if ($isFile) {
            [System.IO.File]::Delete($source)
        } else {
            [System.IO.Directory]::Delete($source, $false)
        }
        return $true
    } catch {
        [System.Windows.MessageBox]::Show("Failed to remove $($linkWord):`n$_", "Error",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        return $false
    }
}
```

- [ ] **Step 2: Update the Disable button click handler message (line 1089)**

Change the confirmation dialog to be type-aware:
```powershell
$script:btnDisable.Add_Click({
    if (-not $script:SelectedItem) { return }
    $redirect  = $script:SelectedItem.Redirect
    $typeWord  = if ($redirect.Type -eq "File") { "symbolic link" } else { "junction" }
    $ans = [System.Windows.MessageBox]::Show(
        "Disable the $typeWord for '$($redirect.Name)'?`n`nThe $typeWord will be removed. Your data remains safely at:`n  $($redirect.Target)",
        "Confirm Disable",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)

    if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
        Set-Status "Disabling '$($redirect.Name)'..." "#9CA3AF"
        $ok = Disable-Redirect -Redirect $redirect
        Update-ListView
        Set-Status $(if ($ok) { "Disabled: $($redirect.Name)" } else { "Disable failed." }) `
                   $(if ($ok) { "#FBBF24" } else { "#F87171" })
    }
})
```

- [ ] **Step 3: Verify**

Run the app. Disable should work on existing folder redirects. Messages should say "junction" for folder types.

- [ ] **Step 4: Commit**
```bash
git add TheRedirector.ps1
git commit -m "feat: make Disable-Redirect type-aware (File.Delete for symlinks, Directory.Delete for junctions)"
```

---

### Task 5: Toolbar — Split Add Button into Add Folder + Add File

**Files:**
- Modify: `TheRedirector.ps1:464` (XAML toolbar), `TheRedirector.ps1:696` (FindName), `TheRedirector.ps1:487` (empty state text)

- [ ] **Step 1: Replace the single Add button in XAML toolbar (line 464)**

Change:
```xml
<Button x:Name="btnAdd"     Content="＋  Add Redirect"  Style="{StaticResource BtnPrimary}"   Margin="0,0,8,0"/>
```
to:
```xml
<Button x:Name="btnAddFolder" Content="＋  Add Folder"  Style="{StaticResource BtnPrimary}"   Margin="0,0,8,0"/>
<Button x:Name="btnAddFile"   Content="＋  Add File"    Style="{StaticResource BtnPrimary}"   Margin="0,0,8,0"/>
```

- [ ] **Step 2: Update the header subtitle (line 444)**

Change:
```xml
<TextBlock Text="NTFS Junction Point Manager"
```
to:
```xml
<TextBlock Text="NTFS Junction &amp; Symlink Manager"
```

- [ ] **Step 3: Update the empty state help text (line 487)**

Change:
```xml
<TextBlock Text="Click '＋ Add Redirect' in the toolbar to get started."
```
to:
```xml
<TextBlock Text="Click '＋ Add Folder' or '＋ Add File' in the toolbar to get started."
```

- [ ] **Step 4: Update FindName section (line 696)**

Change:
```powershell
$script:btnAdd     = $script:Window.FindName('btnAdd')
```
to:
```powershell
$script:btnAddFolder = $script:Window.FindName('btnAddFolder')
$script:btnAddFile   = $script:Window.FindName('btnAddFile')
```

- [ ] **Step 5: Remove the old btnAdd click handler to prevent null reference crash**

The old `$script:btnAdd.Add_Click(...)` block (around line 1018-1027) references `$script:btnAdd` which no longer exists after renaming to `btnAddFolder`/`btnAddFile`. Comment it out or delete it now — it will be replaced with the new handlers in Task 7:

Delete this entire block:
```powershell
# Add
$script:btnAdd.Add_Click({
    $r = Show-EditDialog
    if ($r) {
        $script:Redirects += [PSCustomObject]@{ Name = $r.Name; Source = $r.Source; Target = $r.Target }
        try { Save-Config } catch { Set-Status "Warning: config save failed: $_" "#FBBF24" }
        Update-ListView
        Set-Status "Added: $($r.Name)" "#4ADE80"
    }
})
```

- [ ] **Step 6: Verify**

Run the app. Two blue buttons should appear: "Add Folder" and "Add File". They don't do anything yet (event handlers wired in Task 7). The rest of the toolbar should be unchanged. No crash on startup.

- [ ] **Step 7: Commit**
```bash
git add TheRedirector.ps1
git commit -m "feat: split Add button into Add Folder and Add File in toolbar"
```

---

### Task 6: Show-EditDialog — Add -Type Parameter and File Picker

**Files:**
- Modify: `TheRedirector.ps1:920-1012` (Show-EditDialog)

- [ ] **Step 1: Add -Type parameter to Show-EditDialog**

Change the function signature (line 921-923) to:
```powershell
function Show-EditDialog {
    param(
        [PSCustomObject]$Existing = $null,   # $null = Add mode
        [string]$Type = "Folder"             # "File" or "Folder"
    )
```

- [ ] **Step 2: Update dialog title (line 928)**

Change:
```powershell
$dlg.Title = if ($Existing) { "Edit Redirect - $($Existing.Name)" } else { "Add Redirect" }
```
to:
```powershell
$effectiveType = if ($Existing) { $Existing.Type } else { $Type }
$dlg.Title = if ($Existing) { "Edit $effectiveType Redirect - $($Existing.Name)" } else { "Add $effectiveType Redirect" }
```

- [ ] **Step 3: Add a read-only type label inside the dialog body**

The spec requires "Type is displayed in the dialog as a read-only label." After `$dlg.Owner = $script:Window` and the title assignment, add a TextBlock to the dialog showing the type. Insert it as the first child of the dialog's Grid, above the "Display Name" field.

After `$dlg.Title = ...` and before `$txtName = $dlg.FindName('txtName')`, add:
```powershell
# Add a read-only type label at the top of the dialog
$dlgGrid = $dlg.Content
$typeLbl = New-Object System.Windows.Controls.TextBlock
$typeLbl.Text       = "Type: $effectiveType"
$typeLbl.FontSize   = 11
$typeLbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6B7280")
$typeLbl.Margin     = [System.Windows.Thickness]::new(0, 0, 0, 4)
$typeLbl.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
[System.Windows.Controls.Grid]::SetRow($typeLbl, 0)
[System.Windows.Controls.Grid]::SetColumnSpan($typeLbl, 2)
# Place it in the same row as the Name field but right-aligned — it floats visually above
[void]$dlgGrid.Children.Add($typeLbl)
```

This adds a subtle "Type: Folder" or "Type: File" label in the top-right of the dialog. It doesn't require XAML changes — it's injected dynamically.

- [ ] **Step 4: Update Browse Source handler to support file picker (lines 950-957)**

Replace the `$btnBS.Add_Click` handler:
```powershell
$btnBS.Add_Click({
    if ($effectiveType -eq "File") {
        $fd = New-Object System.Windows.Forms.OpenFileDialog
        $fd.Title = "Select Source File"
        $initPath = $txtSource.Text
        if ($initPath -and (Test-Path (Split-Path $initPath -Parent -ErrorAction SilentlyContinue))) {
            $fd.InitialDirectory = Split-Path $initPath -Parent
            $fd.FileName = Split-Path $initPath -Leaf
        }
        if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtSource.Text = $fd.FileName
        }
    } else {
        $fd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fd.Description  = "Select Source Path"
        $fd.SelectedPath = $txtSource.Text
        if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtSource.Text = $fd.SelectedPath
        }
    }
}.GetNewClosure())
```

- [ ] **Step 5: Update Browse Target handler to support file picker (lines 959-966)**

Replace the `$btnBT.Add_Click` handler:
```powershell
$btnBT.Add_Click({
    if ($effectiveType -eq "File") {
        $fd = New-Object System.Windows.Forms.OpenFileDialog
        $fd.Title = "Select Target File"
        $fd.CheckFileExists = $false
        $initPath = $txtTarget.Text
        if ($initPath -and (Test-Path (Split-Path $initPath -Parent -ErrorAction SilentlyContinue))) {
            $fd.InitialDirectory = Split-Path $initPath -Parent
            $fd.FileName = Split-Path $initPath -Leaf
        }
        if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtTarget.Text = $fd.FileName
        }
    } else {
        $fd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fd.Description  = "Select Target Path"
        $fd.SelectedPath = $txtTarget.Text
        if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtTarget.Text = $fd.SelectedPath
        }
    }
}.GetNewClosure())
```

Note: `$fd.CheckFileExists = $false` on the target picker because the target file may not exist yet.

- [ ] **Step 6: Update the DlgResult to include Type (line 996)**

Change:
```powershell
$script:DlgResult = [PSCustomObject]@{ Name = $n; Source = $s; Target = $t }
```
to:
```powershell
$script:DlgResult = [PSCustomObject]@{ Name = $n; Type = $effectiveType; Source = $s; Target = $t }
```

- [ ] **Step 7: Verify**

This can't be fully tested yet (event handlers not wired), but the function compiles without error. Will verify in Task 7.

- [ ] **Step 8: Commit**
```bash
git add TheRedirector.ps1
git commit -m "feat: add -Type parameter to Show-EditDialog with file picker support"
```

---

### Task 7: Event Handlers — Wire Up New Buttons and Thread Type

**Files:**
- Modify: `TheRedirector.ps1:1018-1027` (Add handler), `TheRedirector.ps1:1030-1042` (Edit handler), `TheRedirector.ps1:1044-1067` (Remove handler)

- [ ] **Step 1: Replace btnAdd click handler with btnAddFolder + btnAddFile handlers**

Remove the existing `$script:btnAdd.Add_Click` block (lines 1018-1027) and replace with:
```powershell
# Add Folder
$script:btnAddFolder.Add_Click({
    $r = Show-EditDialog -Type "Folder"
    if ($r) {
        $script:Redirects += [PSCustomObject]@{ Name = $r.Name; Type = $r.Type; Source = $r.Source; Target = $r.Target }
        try { Save-Config } catch { Set-Status "Warning: config save failed: $_" "#FBBF24" }
        Update-ListView
        Set-Status "Added: $($r.Name)" "#4ADE80"
    }
})

# Add File
$script:btnAddFile.Add_Click({
    $r = Show-EditDialog -Type "File"
    if ($r) {
        $script:Redirects += [PSCustomObject]@{ Name = $r.Name; Type = $r.Type; Source = $r.Source; Target = $r.Target }
        try { Save-Config } catch { Set-Status "Warning: config save failed: $_" "#FBBF24" }
        Update-ListView
        Set-Status "Added: $($r.Name)" "#4ADE80"
    }
})
```

- [ ] **Step 2: Update Edit handler to pass Type**

In the Edit button handler (lines 1030-1042), the `Show-EditDialog -Existing $redirect` call already works because `$redirect` now carries `Type`, and the dialog reads `$Existing.Type` (from Task 6 Step 2). No change needed to the call itself.

However, when the dialog returns, we should NOT allow the Type to change (it's read-only in the dialog), so `$redirect.Type` stays the same. No code change needed here — the edit handler only updates Name, Source, Target:
```powershell
$redirect.Name   = $r.Name
$redirect.Source = $r.Source
$redirect.Target = $r.Target
```
This is correct — Type is not updated from the dialog result (it was already set on the redirect object).

- [ ] **Step 3: Update Remove handler message to be type-aware (lines 1044-1067)**

Change the `$extra` message (line 1050-1052) to use type-aware wording:
```powershell
$script:btnRemove.Add_Click({
    if (-not $script:SelectedItem) { return }
    $name     = $script:SelectedItem.Name
    $status   = $script:SelectedItem.Status
    $linkWord = if ($script:SelectedItem.Redirect.Type -eq "File") { "symbolic link" } else { "junction point" }

    $extra = if ($status -eq "Active") {
        "`n`nNote: The $linkWord will NOT be automatically removed. Disable it first if you want to unlink it."
    } else { "" }

    $ans = [System.Windows.MessageBox]::Show(
        "Remove '$name' from the configuration?$extra",
        "Confirm Remove",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)

    if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
        $redirect = $script:SelectedItem.Redirect
        $script:Redirects = @($script:Redirects | Where-Object { $_ -ne $redirect })
        try { Save-Config } catch { Set-Status "Warning: config save failed: $_" "#FBBF24" }
        Update-ListView
        Set-Status "Removed: $name" "#FBBF24"
    }
})
```

- [ ] **Step 4: Verify**

Run the app. Click "Add Folder" — should open the dialog with folder pickers and title "Add Folder Redirect". Click "Add File" — should open with file pickers and title "Add File Redirect". Add a test file redirect and verify it appears in the list and persists in `config.json` with `"type": "File"`.

- [ ] **Step 5: Commit**
```bash
git add TheRedirector.ps1
git commit -m "feat: wire up Add Folder/File buttons and thread Type through event handlers"
```

---

### Task 8: Card Visual — Add Type Icon to Redirect Cards

**Files:**
- Modify: `TheRedirector.ps1:743-744` (New-RedirectCard parameter comment), `TheRedirector.ps1:800-812` (name row construction)

- [ ] **Step 1: Add Type to the $itemData in Update-ListView (line 891)**

In `Update-ListView`, the `$itemData` PSCustomObject (lines 891-900) needs `Type`:
```powershell
$itemData = [PSCustomObject]@{
    Name        = $r.Name
    Type        = $r.Type
    Source      = $r.Source
    Target      = $r.Target
    Status      = $status
    StatusText  = $meta.Text
    StatusColor = $meta.Color
    StatusBG    = $meta.BG
    Redirect    = $r
}
```

- [ ] **Step 2: Add type icon TextBlock in New-RedirectCard before the status dot**

In `New-RedirectCard`, after the `$nameRow` is created (line 804) and before the `$dot` is created (line 806), insert a type icon:
```powershell
    # Type icon
    $typeIcon = New-Object System.Windows.Controls.TextBlock
    if ($Item.Type -eq "File") {
        $typeIcon.Text       = [char]0x1F4C4   # document icon
        $typeIcon.Foreground = Get-Brush "#A78BFA"
    } else {
        $typeIcon.Text       = [char]0x1F4C1   # folder icon
        $typeIcon.Foreground = Get-Brush "#60A5FA"
    }
    $typeIcon.FontSize   = 12
    $typeIcon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $typeIcon.Margin = [System.Windows.Thickness]::new(0,0,8,0)
    [void]$nameRow.Children.Add($typeIcon)
```

This goes immediately before the existing `$dot` block — so the name row becomes: [type icon] [status dot] [name text].

**WPF emoji fallback:** If the emoji characters don't render in WPF's default font, change to Segoe UI Emoji:
```powershell
    $typeIcon.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI Emoji")
```

- [ ] **Step 3: Verify**

Run the app. Each card should show a folder or file icon before the status dot. Folder redirects show a blue folder icon; file redirects show a purple document icon.

If the emoji icons don't render properly in WPF, fall back to simple text labels by changing the icon block to:
```powershell
    if ($Item.Type -eq "File") {
        $typeIcon.Text       = "FILE"
        $typeIcon.Foreground = Get-Brush "#A78BFA"
    } else {
        $typeIcon.Text       = "DIR"
        $typeIcon.Foreground = Get-Brush "#60A5FA"
    }
    $typeIcon.FontSize   = 9
    $typeIcon.FontWeight = [System.Windows.FontWeights]::Bold
```

- [ ] **Step 4: Commit**
```bash
git add TheRedirector.ps1
git commit -m "feat: add type icon (folder/file) to redirect cards"
```

---

### Task 9: Update config.example.json

**Files:**
- Modify: `config.example.json`

- [ ] **Step 1: Update config.example.json with type fields and a file example**

Replace the entire file with:
```json
{
  "_comment": "Copy this file to config.json and update the paths to match your setup.",
  "redirects": [
    {
      "name": "PrusaSlicer",
      "type": "Folder",
      "source": "C:\\Users\\Lee\\AppData\\Roaming\\PrusaSlicer",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\PrusaSlicer"
    },
    {
      "name": "KeePass",
      "type": "Folder",
      "source": "C:\\Users\\Lee\\AppData\\Roaming\\KeePass",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\KeePass"
    },
    {
      "name": "Everything (Search Tool)",
      "type": "Folder",
      "source": "C:\\Users\\Lee\\AppData\\Roaming\\Everything",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\Everything"
    },
    {
      "name": "Notepad++",
      "type": "Folder",
      "source": "C:\\Users\\Lee\\AppData\\Roaming\\Notepad++",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\Notepad++"
    },
    {
      "name": "PowerToys",
      "type": "Folder",
      "source": "C:\\Users\\Lee\\AppData\\Local\\Microsoft\\PowerToys",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\PowerToys"
    },
    {
      "name": "SSH Config",
      "type": "File",
      "source": "C:\\Users\\Lee\\.ssh\\config",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\.ssh\\config"
    },
    {
      "name": "Git Config",
      "type": "File",
      "source": "C:\\Users\\Lee\\.gitconfig",
      "target": "C:\\Users\\Lee\\OneDrive\\PC Stuff\\Synced Settings\\.gitconfig"
    }
  ]
}
```

- [ ] **Step 2: Commit**
```bash
git add config.example.json
git commit -m "feat: add type fields and file redirect examples to config.example.json"
```

---

### Task 10: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the README**

Key changes (apply these edits to the existing README):

**a) Update the opening description (line 3):**
```markdown
A sleek, dark-themed GUI for managing **NTFS junction points** and **symbolic links** on Windows. Use it to redirect application settings folders — or individual config files — to a synced location (OneDrive, Dropbox, etc.) while keeping apps completely unaware.
```

**b) Update "How it works" section (lines 9-13):**
```markdown
## How it works

Windows NTFS supports **junction points** (directory symlinks) and **symbolic links** (file symlinks) that make one path transparently point to another location. When you redirect, say, `%AppData%\PrusaSlicer` to `OneDrive\Synced Settings\PrusaSlicer`, the app reads and writes to its normal path but the data actually lives on OneDrive.

TheRedirector manages a config file of `name → type → source → target` mappings and lets you enable or disable each redirect with a single click. It supports both:

- **Folder redirects** — using NTFS junction points (same as before)
- **File redirects** — using NTFS symbolic links (new in v1.1)
```

**c) Update "Getting Started" step 3 (line 47):**

Change:
```markdown
On first run, a blank `config.json` is created. Use the GUI to add your redirects, or copy `config.example.json` to `config.json` and edit the paths.
```
to:
```markdown
On first run, a blank `config.json` is created. Use the GUI to add folder or file redirects, or copy `config.example.json` to `config.json` and edit the paths. The example config includes both folder and file redirect entries.
```

**d) Update "Requirements" to mention symlinks (line 21):**
```markdown
- **Administrator privileges** (required to create/remove junction points and symbolic links)
```

**e) Update "Config file" section (lines 51-74) with type field:**
```markdown
## Config file (`config.json`)

The config is a simple JSON file stored alongside the script:

\```json
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
\```

| Field    | Description                                                      |
|----------|------------------------------------------------------------------|
| `name`   | Friendly display name shown in the GUI                           |
| `type`   | `"Folder"` for directory junctions, `"File"` for file symlinks   |
| `source` | Where the application expects its data (original path)           |
| `target` | Where the data actually lives (your synced folder or file)       |

The `type` field is optional — entries without it default to `"Folder"` for backwards compatibility. The config is updated automatically when you add, edit, or remove entries via the GUI.
```

**f) Update "Status indicators" section (lines 77-88) — add file wording:**
```markdown
## Status indicators

Each redirect card shows one of these status badges:

| Badge        | Meaning                                                                      |
|--------------|------------------------------------------------------------------------------|
| **Active**       | Link exists and points to the correct target                             |
| **Inactive**     | Source path doesn't exist — link not created yet                         |
| **Not Linked**   | Source exists as a regular file/folder — data not yet redirected          |
| **Broken Link**  | Link exists but the target is missing                                    |
| **Wrong Target** | Link exists but points to a different location                           |
```

**g) Update "Enabling a redirect" section (lines 91-98):**
```markdown
## Enabling a redirect

When you click **Enable**, the app handles existing data at the source path:

- **Source doesn't exist** → Link is created immediately (creates target file/folder if needed)
- **Source exists, target doesn't exist** → Asks to **Move** data to target, **Delete** it, or **Cancel**
- **Source exists, target already exists** → Asks to **Delete** source (data stays in target), or **Cancel**
- **Source is already linked** → Shown as Active, Broken, or Wrong Target; no action taken
```

**h) Update "Disabling a redirect" section (lines 100-103):**
```markdown
## Disabling a redirect

Clicking **Disable** removes only the junction point or symbolic link. Your data remains safely in the target location. The source path simply disappears until you re-enable the redirect.
```

- [ ] **Step 2: Verify**

Read through the updated README for consistency. Ensure all references to "junction" are either generalized or mention both types where appropriate.

- [ ] **Step 3: Commit**
```bash
git add README.md
git commit -m "docs: update README for file redirect support (v1.1)"
```

---

### Task 11: Final BOM + Deploy + Push

- [ ] **Step 1: Apply UTF-8 BOM to TheRedirector.ps1**

```powershell
$path = 'c:\code\TheRedirector\TheRedirector.ps1'
$content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($path, $content, $utf8Bom)
```

- [ ] **Step 2: Copy to OneDrive deployment location**

```powershell
Copy-Item $path 'C:\Users\Lee\OneDrive\PC Stuff\Synced Settings\_Setup\TheRedirector\TheRedirector.ps1' -Force
```

- [ ] **Step 3: Full end-to-end verification**

1. Launch the app via `Run.bat`
2. Verify existing folder redirects load with correct status
3. Add a new folder redirect — verify folder picker, card icon, config.json
4. Add a new file redirect — verify file picker, card icon, config.json has `"type": "File"`
5. Enable the file redirect — verify symlink is created
6. Disable the file redirect — verify symlink is removed
7. Edit a redirect — verify type is preserved (title shows "Edit File/Folder Redirect")
8. Remove a redirect — verify type-aware confirmation message

- [ ] **Step 4: Push all commits**

```bash
git push
```
