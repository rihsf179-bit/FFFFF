<#
.NOTES
    Product        : LucaXShop
    Edition        : Secure Blue
    Version        : 1.0.0
    Protection     : URL byte-obfuscation, integrity hooks, single-instance guard
#>

param (
    [string]$Config,
    [ValidateSet("Standard", "Minimal", "Advanced", "")]
    [string]$Preset,
    [switch]$Offline
)

# ---------------------------------------------------------------------------
# LucaXShop Secure Bootstrap
# ---------------------------------------------------------------------------
# PowerShell code running locally cannot be made 100% uncrackable. This layer
# removes unsafe remote fallback execution, obscures public URLs, provides
# SHA-256/integrity primitives, and prepares the client for server-signed
# licensing without embedding a private signing secret in the client.
# ---------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$LucaXShopSecurityVersion = "1.0.0"

function ConvertFrom-LucaXShopBytes {
    param([Parameter(Mandatory)][int[]]$Bytes)
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    return $utf8.GetString([byte[]]$Bytes)
}

# Public URLs stored as UTF-8 byte values instead of plain URL literals.
$LucaXShopWebsiteBytes = @(104,116,116,112,115,58,47,47,119,119,119,46,108,117,99,97,120,115,104,111,112,46,99,111,109)
$LucaXShopDiscordBytes = @(104,116,116,112,115,58,47,47,100,105,115,99,111,114,100,46,103,103,47,108,117,99,97,120,115,104,111,112)

$LucaXShopWebsiteUrl = ConvertFrom-LucaXShopBytes -Bytes $LucaXShopWebsiteBytes
$LucaXShopDiscordUrl = ConvertFrom-LucaXShopBytes -Bytes $LucaXShopDiscordBytes

function Get-LucaXShopSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "LucaXShop integrity check failed: file not found."
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-LucaXShopIntegrity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSha256 = ""
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        # A hash stored in the same editable .ps1 is not a real DRM boundary.
        return $true
    }
    $actual = Get-LucaXShopSha256 -Path $Path
    return [string]::Equals(
        $actual,
        $ExpectedSha256.Trim().ToUpperInvariant(),
        [System.StringComparison]::Ordinal
    )
}

function Get-LucaXShopMachineFingerprint {
    # Non-secret identifier for future server-side licensing.
    $parts = @(
        $env:COMPUTERNAME
        (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID
        (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    $raw = ($parts -join "|").Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return "" }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-LucaXShopRuntime {
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw "LucaXShop cannot run because PowerShell is not in FullLanguage mode."
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "LucaXShop requires Windows PowerShell 5.1 or newer."
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "LucaXShop requires a 64-bit Windows installation."
    }
}

function Enter-LucaXShopSingleInstance {
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, "Global\LucaXShop_Secure_Installer", [ref]$created)
    if (-not $created) {
        try { $mutex.Dispose() } catch {}
        throw "LucaXShop is already running."
    }
    return $mutex
}

Test-LucaXShopRuntime
$LucaXShopMutex = Enter-LucaXShopSingleInstance
$PARAM_OFFLINE = $false

if ($Offline) {
    $PARAM_OFFLINE = $true
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "LucaXShop is unable to run on your system. PowerShell execution is restricted by security policies." -ForegroundColor Red
    return
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "LucaXShop needs to be run as Administrator. Attempting to relaunch."
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    if (-not $PSCommandPath -or -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
        Write-Error "LucaXShop cannot relaunch because the local script path is unavailable. Run the LucaXShop .ps1 file directly."
        return
    }

    $script = "& { & `"$PSCommandPath`" $($argList -join ' ') }"

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.version = "1.0.0"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
$sync.ProcessRunning = $false
$sync.Win11ISOProcessRunning = $false
$sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Install"

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$winutildir = "$env:LocalAppData\LucaXShop"
$sync.winutildir = $winutildir

$logdir = "$winutildir\logs"
$sync.logPath = "$logdir\LucaXShop_$dateTime.log"
$sync.transcriptPath = $sync.logPath
Start-Transcript -Path $sync.logPath -Append -NoClobber | Out-Null

# Publisher can populate this during a release build. Do not treat a hash
# embedded in the same editable script as the only anti-tamper mechanism.
$LucaXShopExpectedSha256 = ""
if ($PSCommandPath -and -not (Test-LucaXShopIntegrity -Path $PSCommandPath -ExpectedSha256 $LucaXShopExpectedSha256)) {
    throw "LucaXShop integrity verification failed. The installer appears to have been modified."
}

$Host.UI.RawUI.WindowTitle = "LucaXShop"
Clear-Host
function Add-SelectedAppsMenuItem {
    <#
    .SYNOPSIS
        This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

    .Parameter name
        The actual Name of an App like "Chrome" or "Brave"
        This name is contained in the "Content" property inside the applications.json
    .PARAMETER key
        The key which identifies an app object in applications.json
        For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
    #>

    param ([string]$name, [string]$key)

    $selectedAppGrid = New-Object Windows.Controls.Grid

    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

    # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
    # With the tooltip, you can still read the whole entry on hover
    $selectedAppLabel = New-Object Windows.Controls.Label
    $selectedAppLabel.Content = $name
    $selectedAppLabel.ToolTip = $name
    $selectedAppLabel.HorizontalAlignment = "Left"
    $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
    $selectedAppGrid.Children.Add($selectedAppLabel)

    $selectedAppRemoveButton = New-Object Windows.Controls.Button
    $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
    $selectedAppRemoveButton.Content = [string]([char]0xE711)
    $selectedAppRemoveButton.HorizontalAlignment = "Center"
    $selectedAppRemoveButton.Tag = $key
    $selectedAppRemoveButton.ToolTip = "Remove the App from Selection"
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

    # Highlight the Remove icon on Hover
    $selectedAppRemoveButton.Add_MouseEnter({ $this.Foreground = "Red" })
    $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
    $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all necessary changes to update the UI
    })
    [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
    $selectedAppGrid.Children.Add($selectedAppRemoveButton)
    # Add new Element to Popup
    $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
}

function Close-WinUtilRunspacePool {
    if ($null -eq $sync -or -not $sync.ContainsKey("runspace") -or $null -eq $sync.runspace) {
        return
    }

    try {
        if ($sync.runspace.RunspacePoolStateInfo.State -notin @(
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closed,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closing,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Broken
        )) {
            $sync.runspace.Close()
        }
    } finally {
        $sync.runspace.Dispose()
        $sync.Remove("runspace")
    }
}

function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Filters the Install tab entries by search text and by category

        .DESCRIPTION
            Search text and categories are independent filters that both have to pass. An entry is
            shown when its name, description, or application preset key matches the search text, and
            when its category is in the selected set. An empty search matches everything, and an empty
            category set matches every category.

            While either filter is active the matching categories are expanded, since a collapsed
            category would otherwise hide the very results that were asked for. With no filter at
            all the collapsed state the user set is restored.

        .PARAMETER SearchString
            The string to search for. Wildcards are treated as literal characters.

        .PARAMETER Categories
            The categories to show. An empty or missing array shows all of them.

        .NOTES
            - Uses module-scope $sync (no parameter needed; inherits from caller's scope)
            - Safely handles missing hashtable keys and null UI elements
            - Protected by try/catch to prevent UI thread crashes
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = "",

        [Parameter(Mandatory = $false)]
        [string[]]$Categories = @()
    )

    # Validate that $sync exists and has required structure
    if ($null -eq $sync) {
        Write-Warning "Find-AppsByNameOrDescription: Global `$sync not found. Aborting search."
        return
    }

    if ($null -eq $sync.ItemsControl) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.ItemsControl not initialized. Aborting search."
        return
    }

    if ($null -eq $sync.configs -or $null -eq $sync.configs.applicationsHashtable) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.configs.applicationsHashtable not initialized. Aborting search."
        return
    }

    # Categories that filtering expanded on the user's behalf, so clearing the filter can undo it
    if ($null -eq $sync.AppCategoryAutoExpanded) {
        $sync.AppCategoryAutoExpanded = @{}
    }

    try {
        $activeCategories = @($Categories | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $hasSearch = -not [string]::IsNullOrWhiteSpace($SearchString)
        $hasCategories = $activeCategories.Count -gt 0

        # Nothing is filtered, so put every entry back and leave the collapsed categories collapsed
        if (-not $hasSearch -and -not $hasCategories) {
            $sync.ItemsControl.Items | ForEach-Object {
                $_.Visibility = [Windows.Visibility]::Visible

                if ($_.Children.Count -ge 2) {
                    $categoryLabel = $_.Children[0]
                    $wrapPanel = $_.Children[1]

                    $categoryLabel.Visibility = [Windows.Visibility]::Visible

                    # A category that filtering expanded goes back to how the user left it
                    $categoryName = $categoryLabel.Content -replace '^[+-] ', ''
                    if ($sync.AppCategoryAutoExpanded.ContainsKey($categoryName)) {
                        $categoryLabel.Content = $categoryLabel.Content -replace "^- ", "+ "
                        $sync.AppCategoryAutoExpanded.Remove($categoryName)
                    }

                    if ($categoryLabel.Content -like "+*") {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                    }
                    else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    }

                    $wrapPanel.Children | ForEach-Object {
                        $_.Visibility = [Windows.Visibility]::Visible
                    }
                }
            }
            return
        }

        # Escape wildcard characters for literal matching
        $escapedSearchString = [System.Management.Automation.WildcardPattern]::Escape($SearchString)

        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]
                $categoryHasMatch = $false

                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                foreach ($appControl in $wrapPanel.Children) {
                    $appTag = $appControl.Tag
                    $appEntry = $null

                    if (-not [string]::IsNullOrWhiteSpace($appTag) -and $sync.configs.applicationsHashtable.ContainsKey($appTag)) {
                        $appEntry = $sync.configs.applicationsHashtable[$appTag]
                    }

                    if ($null -ne $appEntry) {
                        $categoryMatch = -not $hasCategories -or $activeCategories -contains $appEntry.Category
                        $textMatch = -not $hasSearch -or
                            $appEntry.Content -like "*$escapedSearchString*" -or
                            $appEntry.Description -like "*$escapedSearchString*" -or
                            $appTag -like "*$escapedSearchString*"

                        if ($categoryMatch -and $textMatch) {
                            $appControl.Visibility = [Windows.Visibility]::Visible
                            $categoryHasMatch = $true
                        }
                        else {
                            $appControl.Visibility = [Windows.Visibility]::Collapsed
                        }
                    }
                    else {
                        # Hide app if no entry found (data integrity issue)
                        $appControl.Visibility = [Windows.Visibility]::Collapsed
                    }
                }

                if ($categoryHasMatch) {
                    $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    $_.Visibility = [Windows.Visibility]::Visible
                    # Expand it, otherwise the matches stay hidden behind a collapsed header.
                    # Remember that it was collapsed so clearing the filter can put it back.
                    if ($categoryLabel.Content -like "+*") {
                        $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                        $sync.AppCategoryAutoExpanded[($categoryLabel.Content -replace '^- ', '')] = $true
                    }
                }
                else {
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        Write-Warning "Find-AppsByNameOrDescription: An error occurred during search: $_"
        # Fail gracefully - do not crash the UI thread
        return
    }
}

function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .DESCRIPTION
            Filters tweak entries by name or description using literal string matching (no wildcard expansion).
            Respects collapsed category state and handles null $sync gracefully.
            Safe for rapid keystroke events; no terminal spam on error conditions.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .NOTES
            - Uses module-scope $sync (resolved via global/script fallback if needed)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing UI elements and null properties
            - Protected by try/catch to prevent UI thread crashes
            - PowerShell 5.1 compatible (no ternary operators, no advanced language features)
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = ""
    )

    # ------------------------------------------------------------------------------
    # 1. RESOLVE $SYNC WITH MULTI-LEVEL FALLBACK
    # ------------------------------------------------------------------------------

    if ($null -eq $Sync) {
        $Sync = $global:sync
        if ($null -eq $Sync) {
            $Sync = $script:sync
        }
    }

    # Validate that $Sync exists and has required structure
    if ($null -eq $Sync) {
        # Silent return - function called on every keystroke; no warning spam
        return
    }

    if ($null -eq $Sync.Form) {
        # Silent return - form not yet initialized
        return
    }

    # ------------------------------------------------------------------------------
    # 2. GET REFERENCE TO TWEAKS OR APPX PANEL
    # ------------------------------------------------------------------------------

    $panelName = "tweakspanel"
    if ($null -ne $Sync.currentTab -and $Sync.currentTab -eq "AppX") {
        $panelName = "appxpanel"
    }

    $tweaksPanel = $null
    try {
        $tweaksPanel = $Sync.Form.FindName($panelName)
    }
    catch {
        # Silent return - panel not found or disposed
        return
    }

    if ($null -eq $tweaksPanel) {
        # Silent return - panel doesn't exist
        return
    }

    # ------------------------------------------------------------------------------
    # 3. HANDLE EMPTY/WHITESPACE SEARCH STRING - RESET TO DEFAULT STATE
    # ------------------------------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        try {
            $tweaksPanel.Children | ForEach-Object {
                $categoryBorder = $_

                # Safely set visibility
                if ($null -ne $categoryBorder) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }

                # Process each category
                if ($categoryBorder -is [Windows.Controls.Border]) {
                    $dockPanel = $null
                    if ($null -ne $categoryBorder.Child) {
                        $dockPanel = $categoryBorder.Child
                    }

                    if ($dockPanel -is [Windows.Controls.DockPanel]) {
                        $container = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] -or $_ -is [Windows.Controls.StackPanel] -or $_ -is [Windows.Controls.ScrollViewer] -or $_.GetType().Name -eq "ItemsControl" } | Select-Object -First 1

                        if ($null -ne $container) {
                            $targetPanel = if ($container.PSObject.Properties['Content'] -and $null -ne $container.Content) { $container.Content } else { $container }
                            $items = $null
                            if ($targetPanel -is [Windows.Controls.ItemsControl] -or $targetPanel.GetType().Name -eq "ItemsControl") {
                                $items = $targetPanel.Items
                            }
                            else {
                                $items = $targetPanel.Children
                            }
                            # Show all items in the category
                            foreach ($item in $items) {
                                if ($null -ne $item) {
                                    # Check if it's a category label (first Label in the container)
                                    if ($item -is [Windows.Controls.Label] -or $item.GetType().Name -eq "Label") {
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                    elseif ($item -is [Windows.Controls.DockPanel] -or $item -is [Windows.Controls.StackPanel] -or $item.GetType().Name -eq "DockPanel" -or $item.GetType().Name -eq "StackPanel") {
                                        # Show all checkbox containers
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            # Silent catch - UI element may be disposed
            $null = $_
        }

        return
    }

    # ------------------------------------------------------------------------------
    # 4. PERFORM LITERAL SEARCH (NO WILDCARD EXPANSION)
    # ------------------------------------------------------------------------------

    try {
        # Normalize search term once for the entire operation
        $searchTerm = $SearchString
        if ($null -eq $searchTerm) {
            $searchTerm = ""
        }

        # Iterate through all categories
        $tweaksPanel.Children | ForEach-Object {
            $categoryBorder = $_
            $categoryHasMatch = $false

            if ($categoryBorder -is [Windows.Controls.Border]) {
                $dockPanel = $null
                if ($null -ne $categoryBorder.Child) {
                    $dockPanel = $categoryBorder.Child
                }

                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $container = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] -or $_ -is [Windows.Controls.StackPanel] -or $_ -is [Windows.Controls.ScrollViewer] -or $_.GetType().Name -eq "ItemsControl" } | Select-Object -First 1

                    if ($null -ne $container) {
                        $categoryLabel = $null

                        $targetPanel = if ($container.PSObject.Properties['Content'] -and $null -ne $container.Content) { $container.Content } else { $container }
                        $items = $null
                        if ($targetPanel -is [Windows.Controls.ItemsControl] -or $targetPanel.GetType().Name -eq "ItemsControl") {
                            $items = $targetPanel.Items
                        }
                        else {
                            $items = $targetPanel.Children
                        }
                        # Process all items (checkboxes, labels, panels) in the container
                        foreach ($item in $items) {
                            if ($null -eq $item) {
                                continue
                            }

                            # ------------------------------------------------------------
                            # Check if this is a category label (usually first Label)
                            # ------------------------------------------------------------

                            if ($item -is [Windows.Controls.Label] -or $item.GetType().Name -eq "Label") {
                                $categoryLabel = $item
                                # Initially hide category label; show it only if matches found
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }

                            # ------------------------------------------------------------
                            # Check if this is a DockPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.DockPanel] -or $item.GetType().Name -eq "DockPanel") {
                                $checkbox = $null
                                $label = $null

                                # Safely extract checkbox and label
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -or $_.GetType().Name -eq "CheckBox" } | Select-Object -First 1
                                $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] -or $_.GetType().Name -eq "Label" } | Select-Object -First 1

                                # Check if tweak matches search criteria
                                $itemMatches = $false

                                if ($null -ne $label) {
                                    $labelContent = $label.Content
                                    $labelToolTip = $label.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $labelContent) {
                                        $labelContent = ""
                                    }
                                    if ($null -eq $labelToolTip) {
                                        $labelToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $labelContentStr = [string]$labelContent
                                    $labelToolTipStr = [string]$labelToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $labelContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $labelToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }

                            # ------------------------------------------------------------
                            # Check if this is a StackPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.StackPanel] -or $item.GetType().Name -eq "StackPanel") {
                                $checkbox = $null
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -or $_.GetType().Name -eq "CheckBox" } | Select-Object -First 1

                                $itemMatches = $false

                                if ($null -ne $checkbox) {
                                    $checkboxContent = $checkbox.Content
                                    $checkboxToolTip = $checkbox.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $checkboxContent) {
                                        $checkboxContent = ""
                                    }
                                    if ($null -eq $checkboxToolTip) {
                                        $checkboxToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $checkboxContentStr = [string]$checkboxContent
                                    $checkboxToolTipStr = [string]$checkboxToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $checkboxContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $checkboxToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }
                        }

                        # ------------------------------------------------------------
                        # Update category label visibility and expanded/collapsed state
                        # ------------------------------------------------------------

                        if ($categoryHasMatch) {
                            # Show category label
                            if ($null -ne $categoryLabel) {
                                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                                # Update category label to expanded state (change "+" to "-")
                                $labelContent = $categoryLabel.Content
                                if ($null -ne $labelContent) {
                                    $labelStr = [string]$labelContent

                                    # Safe string replacement without -replace regex
                                    if ($labelStr.StartsWith("+ ")) {
                                        $expandedLabel = "- " + $labelStr.Substring(2)
                                        $categoryLabel.Content = $expandedLabel
                                    }
                                }
                            }
                        }
                    }
                }

                # ----------------------------------------------------------------
                # Set category border visibility based on whether it has matches
                # ----------------------------------------------------------------

                if ($categoryHasMatch) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }
                else {
                    $categoryBorder.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        # Silent catch - UI elements may be disposed or in unexpected state
        # Do not log to terminal as this function is called on every keystroke
        $null = $_
    }
}

function Get-WinUtilEntryToolTip {
    <#
        .SYNOPSIS
            Builds the tooltip string for an app/tweak/feature entry: its description plus its preset JSON key

        .PARAMETER Description
            The entry's description from the config JSON. May be null or empty.

        .PARAMETER Key
            The entry's JSON key as used in preset files (e.g. WPFInstallbrave, WPFTweaksTele).
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Description,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Description)) {
        return "Preset key: $Key"
    }

    return "$Description`n`nPreset key: $Key"
}

function Get-WinUtilInstalledAPPX {
    <#

    .SYNOPSIS
        Gets the names of AppX packages installed for all users

    #>

    # AppX module auto-loading can leave PowerShell 7 dependent on a temporary Windows PowerShell
    # compatibility proxy. Run the query in Windows PowerShell 5.1 so it remains available after
    # those temporary proxy files are removed.
    $ps5Command = {
        Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -ExpandProperty Name
    }

    $packageOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failureDetails = ($packageOutput | Out-String).Trim()
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "Failed to get installed AppX packages: $failureDetails"
        return @()
    }

    return @($packageOutput)
}

function Get-WinUtilPackageLogSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$Preference
    )

    @($Packages | ForEach-Object {
        $package = $_
        $packageName = @($package.Name, $package.Description, $package.winget, $package.choco) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and $_ -ne "na" } |
            Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace([string]$packageName)) {
            $packageName = "Unknown package"
        }

        if ($Preference -eq "Choco" -and -not [string]::IsNullOrWhiteSpace([string]$package.choco) -and $package.choco -ne "na") {
            "$packageName (choco: $($package.choco))"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$package.winget) -and $package.winget -ne "na") {
            "$packageName (winget: $($package.winget))"
        } else {
            "$packageName (no package id)"
        }
    })
}

function Get-WinUtilRegistryComboState {
    <#
    .SYNOPSIS
        Finds the configured combo-box state matching the current registry values.

    .PARAMETER Registry
        Registry settings containing a value mapping for each supported state.

    .OUTPUTS
        The name of the matching state.
    #>
    param(
        [Parameter(Mandatory)]
        $Registry
    )

    foreach ($state in $Registry[0].Values.PSObject.Properties) {
        $stateMatches = $true
        foreach ($setting in @($Registry)) {
            $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
            $actualValue = if ($currentValue.Exists -and $null -ne $currentValue.Value) { $currentValue.Value } else { $setting.DefaultValue }
            $configuredValue = $setting.Values.PSObject.Properties[$state.Name].Value
            # Removal represents the effective Windows default when matching the current state.
            $expectedValue = if ($configuredValue -eq "<RemoveEntry>") { $setting.DefaultValue } else { $configuredValue }
            if ([string]$actualValue -ne [string]$expectedValue) {
                $stateMatches = $false
                break
            }
        }
        if ($stateMatches) {
            return $state.Name
        }
    }

    throw "Registry values do not match a supported state."
}

function Get-WinUtilRegistryComboValue {
    <#
    .SYNOPSIS
        Reads one registry value for a registry-backed combo-box state.

    .PARAMETER Setting
        The registry setting from the combo-box configuration.
    #>
    param(
        [Parameter(Mandatory)]
        $Setting
    )

    try {
        $item = Get-ItemProperty -Path $Setting.Path -Name $Setting.Name -ErrorAction Stop
        $property = $item.PSObject.Properties[$Setting.Name]
        return [pscustomobject]@{ Exists = $null -ne $property; Value = $property.Value }
    } catch [System.Management.Automation.PSArgumentException] {
        # The registry provider uses PSArgumentException when a named value is absent.
        return [pscustomobject]@{ Exists = $false; Value = $null }
    } catch [System.Management.Automation.ItemNotFoundException] {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
}

function Get-WinUtilSelectedPackages {

     param(
         [Parameter(Mandatory = $true)]
         [object] $PackageList,

         [Parameter(Mandatory = $true)]
         [string] $Preference
     )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packages = @{
        Winget = $packagesWinget
        Choco = $packagesChoco
    }

    function Add-PackageId {
        param(
            [System.Collections.ArrayList]$Target,
            $PackageId
        )

        if ([string]::IsNullOrWhiteSpace([string]$PackageId) -or $PackageId -eq "na") {
            return
        }

        if (-not $Target.Contains($PackageId)) {
            $null = $Target.Add($PackageId)
        }
    }

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if ([string]::IsNullOrWhiteSpace([string]$package.choco) -or $package.choco -eq "na") {
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget
                } else {
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco
                }
            }
            "Winget" {
                Add-PackageId -Target $packagesWinget -PackageId $package.winget
            }
        }
    }

    return $packages
}

Function Get-WinUtilToggleStatus ($ToggleSwitch) {

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry

    if ($null -eq $sync.ToggleStatusCache) {
        $sync.ToggleStatusCache = @{}
    }

    if ($sync.ToggleStatusCache.ContainsKey($ToggleSwitch)) {
        return [bool]$sync.ToggleStatusCache[$ToggleSwitch]
    }

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
    }

    foreach ($regentry in $ToggleSwitchReg) {

        if (Test-Path $regentry.Path) {
            $regstate = (Get-ItemProperty -Path $regentry.Path).$($regentry.Name)
        } else {
            $regstate = $null
        }

        if ($null -eq $regstate) {
            switch ([string]$regentry.DefaultState) {
                "true"  { $regstate = $regentry.Value }
                "false" { $regstate = $regentry.OriginalValue }
            }
        }

        if ($regstate -ne $regentry.Value) {
            $sync.ToggleStatusCache[$ToggleSwitch] = $false
            return $false
        }
    }

    $sync.ToggleStatusCache[$ToggleSwitch] = $true
    return $true
}

function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            }
            catch {
                $null = $_
            }
        }
        return $output
    }
    return $keys
}

    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

            .PARAMETER TargetElement
                The element to which the AppArea should be added

        #>
        param($TargetElement)
        $targetGrid = $sync.Form.FindName($TargetElement)
        $null = $targetGrid.Children.Clear()

        # Create the outer Border for the aren where the apps will be placed
        $Border = New-Object Windows.Controls.Border
        $Border.VerticalAlignment = "Stretch"
        $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")
        # Add a ScrollViewer, because the ItemsControl does not support scrolling by itself
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true
        $Border.Child = $scrollViewer

        ## Create the ItemsControl, which will be the parent of all the app entries
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'
        $scrollViewer.Content = $itemsControl

        # Use WrapPanel to create dynamic columns based on AppEntryWidth and window width
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel])
        $factory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal)
        $factory.SetValue([Windows.Controls.WrapPanel]::HorizontalAlignmentProperty, [Windows.HorizontalAlignment]::Left)
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Add the Border containing the App Area to the target Grid
        $targetGrid.Children.Add($Border) | Out-Null

        return $itemsControl
    }

function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the install tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER appKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $appKey
        )

        $app = $sync.configs.applicationsHashtable.$appKey

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = Get-WinUtilEntryToolTip -Description $app.description -Key $appKey
        $border.Add_MouseLeftButtonUp({
            # Resolve through $sync because the border's child is a layout Grid for FOSS entries
            $childCheckbox = $sync.$($this.Tag)
            $childCheckbox.IsChecked = -not $childCheckbox.IsChecked
        })
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        $border.Add_MouseRightButtonUp({
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        })

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        # The checkbox sits inside the entry layout Grid, so the border is one level further up
        $checkbox.Add_Checked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Tag
            $borderElement = $this.Parent.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Tag
            $borderElement = $this.Parent.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })

        $contentPanel = New-Object Windows.Controls.StackPanel
        $contentPanel.Orientation = "Horizontal"
        $contentPanel.VerticalAlignment = [Windows.VerticalAlignment]::Center

        $icon = New-Object Windows.Controls.Grid
        $icon.SetResourceReference([Windows.FrameworkElement]::WidthProperty, "AppEntryIconSize")
        $icon.SetResourceReference([Windows.FrameworkElement]::HeightProperty, "AppEntryIconSize")
        $icon.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
        $fallback = New-Object Windows.Controls.TextBlock
        $fallback.Text = $app.content.TrimStart(".").Substring(0, 1).ToUpper()
        $fallback.FontWeight = "Bold"; $fallback.HorizontalAlignment = "Center"; $fallback.VerticalAlignment = "Center"
        if ($app.link) { $fallback.Visibility = "Collapsed" }
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "AppEntryFontSize")
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ToggleButtonOnColor")
        [void]$icon.Children.Add($fallback)
        if ($app.link) {
            $logo = New-Object Windows.Controls.Image
            $logo.Stretch = [Windows.Media.Stretch]::Uniform
            $logo.Source = "https://www.google.com/s2/favicons?sz=64&domain_url=$([uri]::EscapeDataString($app.link))"
            $logo.Add_ImageFailed({ $this.Visibility = "Collapsed"; $this.Parent.Children[0].Visibility = "Visible" })
            [void]$icon.Children.Add($logo)
        }
        [void]$contentPanel.Children.Add($icon)

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $app.content
        [void]$contentPanel.Children.Add($appName)
        $checkBox.Content = $contentPanel

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)

        # Keep the same layout for every entry so the checkbox handlers can reach the border
        $entryLayout = New-Object Windows.Controls.Grid
        [void]$entryLayout.Children.Add($checkBox)

        # Mark FOSS apps with a corner badge, bled into the border padding so it sits on the edge
        if ($app.foss -eq $true) {
            $fossBadge = New-WinUtilFossBadge
            $fossBadge.HorizontalAlignment = "Right"
            $fossBadge.VerticalAlignment = "Top"
            $fossBadge.Margin = New-Object Windows.Thickness(0, -4, -6, 0)

            [void]$entryLayout.Children.Add($fossBadge)
        }
        $border.Child = $entryLayout
        if ($sync.selectedApps -contains $appKey) {
            $checkBox.IsChecked = $true
        }
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }

function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )

        # Pre-group apps by category before creating WPF controls.
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps.$appKey.Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = @()
            }
            $appsByCategory[$category] += $appKey
        }
        $sync.InstallAppRenderQueue = [System.Collections.Queue]::new()

        foreach ($category in $($appsByCategory.Keys | Sort-Object)) {
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            [System.Windows.Automation.AutomationProperties]::SetName($categoryContainer, $Category)

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $Category"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            $sync.$Category = $toggleButton

            # Add click handler to toggle category visibility
            $toggleButton.Add_MouseLeftButtonUp({
                param($categoryToggle)

                # Find the parent StackPanel (categoryContainer)
                $categoryContainer = $categoryToggle.Parent
                if ($categoryContainer -and $categoryContainer.Children.Count -ge 2) {
                    # The WrapPanel is the second child
                    $wrapPanel = $categoryContainer.Children[1]

                    # An explicit click wins over anything filtering expanded automatically
                    if ($sync.AppCategoryAutoExpanded) {
                        $sync.AppCategoryAutoExpanded.Remove(($categoryToggle.Content -replace '^[+-] ', ''))
                    }

                    # Toggle visibility
                    if ($wrapPanel.Visibility -eq [Windows.Visibility]::Visible) {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                        # Change - to +
                        $categoryToggle.Content = $categoryToggle.Content -replace "^- ", "+ "
                    } else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                        # Change + to -
                        $categoryToggle.Content = $categoryToggle.Content -replace "^\+ ", "- "
                    }
                }
            })

            $null = $categoryContainer.Children.Add($toggleButton)

            # Add wrap panel for apps to container
            $wrapPanel = New-Object Windows.Controls.WrapPanel
            $wrapPanel.Orientation = "Horizontal"
            $wrapPanel.HorizontalAlignment = "Left"
            $wrapPanel.VerticalAlignment = "Top"
            $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $wrapPanel.Visibility = [Windows.Visibility]::Visible
            $wrapPanel.Tag = "CategoryWrapPanel_$category"

            $null = $categoryContainer.Children.Add($wrapPanel)

            # Add the entire category container to the target element
            $null = $TargetElement.Items.Add($categoryContainer)

            $sync.InstallAppRenderQueue.Enqueue([pscustomobject]@{
                Category = $category
                TargetElement = $wrapPanel
                AppKeys = @($appsByCategory[$category] | Sort-Object)
            })
        }

        Start-WinUtilInstallAppRendering
    }

function Initialize-WinUtilRunspacePool {
    if ($sync.runspace -and $sync.runspace.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
        return $sync.runspace
    }

    if ($sync.runspace) {
        Close-WinUtilRunspacePool
    }

    # Set the maximum number of threads for the RunspacePool to the number of threads on the machine.
    $maxthreads = [Math]::Max([int]$env:NUMBER_OF_PROCESSORS, 1)

    # Create a new session state for parsing variables into our runspace.
    $hashVars = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null
    $offlineVar = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_OFFLINE', $PARAM_OFFLINE, $null
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    $initialSessionState.Variables.Add($hashVars)
    $initialSessionState.Variables.Add($offlineVar)

    # Get every WinUtil/WPF function and add it to the session state.
    $functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|WPF' }
    foreach ($function in $functions) {
        $functionDefinition = Get-Content function:\$($function.Name)
        $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $function.Name, $functionDefinition
        $initialSessionState.Commands.Add($functionEntry)
    }

    $sync.runspace = [runspacefactory]::CreateRunspacePool(
        1,                      # Minimum thread count
        $maxthreads,            # Maximum thread count
        $initialSessionState,   # Initial session state
        $Host                   # Machine to create runspaces on
    )

    $sync.runspace.Open()
    return $sync.runspace
}

function Initialize-WinUtilTabContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TabName
    )

    if ($null -eq $sync.InitializedTabs) {
        $sync.InitializedTabs = @{}
    }

    if ($sync.InitializedTabs[$TabName]) {
        return
    }

    switch ($TabName) {
        "Install" {
            Initialize-WPFUI -targetGridName "appscategory"

            Initialize-WPFUI -targetGridName "appspanel"
        }
        "Tweaks" {
            Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2
        }
        "Config" {
            Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2
        }
        "AppX" {
            Invoke-WPFUIElements -configVariable $sync.configs.appx -targetGridName "appxpanel" -columncount 2
        }
        "Win11ISO" {
            if ($sync.Form -and $sync.Form.Dispatcher) {
                $sync.Form.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Invoke-WinUtilISOCheckExistingWork }) | Out-Null
            }
        }
    }

    $sync.InitializedTabs[$TabName] = $true

    # Sync freshly built controls to any selections already in $sync.selected* (import/preset).
    Reset-WPFCheckBoxes -doToggles $true
}

function Initialize-WinUtilTaskbarOverlayAssets {
    param(
        [bool]$IncludeLogo = $true,
        [bool]$IncludeStatusAssets = $true
    )

    if ($IncludeLogo -and -not $sync["logorender"]) {
        $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["checkmarkrender"]) {
        $sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["warningrender"]) {
        $sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)
    }
}

function Install-WinUtilAPPX {
    <#

    .SYNOPSIS
        Registers a local AppX package or installs it from the Microsoft Store

    .PARAMETER Name
        The AppX package name to install

    .PARAMETER StoreId
        The optional Microsoft Store product ID used when no local manifest is available

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$StoreId
    )

    Write-WinUtilLog -Component "AppX" -Message "Installing AppX package: $Name"

    # AppX and DISM cmdlets are more reliable in Windows PowerShell 5.1. Query both installed and
    # provisioned package metadata because either can expose a local manifest that can be registered.
    $ps5Command = {
        $packageName = $args[0]
        $manifestPaths = [System.Collections.Generic.List[string]]::new()

        Get-AppxPackage -AllUsers -Name $packageName -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -EQ $packageName |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        $manifestPath = $manifestPaths |
            Select-Object -Unique |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1

        if ($null -ne $manifestPath) {
            Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction Stop
            Write-Output $manifestPath
        }
    }

    $manifestOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $Name 2>&1
    if ($LASTEXITCODE -eq 0 -and $null -ne $manifestOutput) {
        $manifestPath = ($manifestOutput | Select-Object -Last 1).ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
            Write-WinUtilLog -Component "AppX" -Message "Registered local AppX manifest for $Name`: $manifestPath"
            return
        }
    }

    if ($LASTEXITCODE -ne 0) {
        $failureDetails = ($manifestOutput | Out-String).Trim()
        Write-WinUtilLog -Level "WARN" -Component "AppX" -Message "Local AppX registration failed for $Name`: $failureDetails"
    }

    if ([string]::IsNullOrWhiteSpace($StoreId)) {
        $errorMessage = "Unable to install $Name because no local manifest or Microsoft Store ID is available."
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message $errorMessage
        throw $errorMessage
    }

    Write-WinUtilLog -Component "AppX" -Message "No usable local manifest found for $Name. Installing Microsoft Store product $StoreId."
    Install-WinUtilWinget
    Install-WinUtilProgramWinget -Action Install -Programs @("msstore:$StoreId")
}

function Install-WinUtilChoco {
    if (-not (Get-Command -Name choco)) {
      Write-Host "Chocolatey is not installed. Installing now..."
      $installScript = Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing
      Invoke-Command -ScriptBlock ([scriptblock]::Create($installScript.Content))
    }
}

function Install-WinUtilProgramChoco {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    if ($Action -eq 'Install') {
        $arguments = "install $Programs -y"
    } else {
        $arguments = "uninstall $Programs -y"
    }

    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s): $($Programs -join ', ')"
    $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s) completed: $($Programs -join ', ') (exit code: $($process.ExitCode))"
}

Function Install-WinUtilProgramWinget {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    foreach ($program in $Programs) {
        if ([string]::IsNullOrWhiteSpace($program) -or $program -eq "na") {
            continue
        }

        $source = "winget"
        if ($program.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $program = $program.Substring("msstore:".Length)
        }

        if ($Action -eq 'Install') {
            $arguments = @("install", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--silent")
        } else {
            $arguments = @("uninstall", "--id", $program, "--source", $source, "--silent")
        }

        Write-WinUtilLog -Component "Package" -Message "$Action winget package: $program (source: $source)"
        $process = Start-Process -FilePath winget -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        Write-WinUtilLog -Component "Package" -Message "$Action winget package completed: $program (exit code: $($process.ExitCode))"
    }
}

function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs WinGet if not already installed.

    .DESCRIPTION
        installs winGet if needed
    #>
    if ((Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    Write-Host "WinGet is not installed. Installing now..." -ForegroundColor Red

    Install-PackageProvider -Name NuGet -Force
    Install-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers
}

function Invoke-WinUtilAppCategoryChip {
    <#
        .SYNOPSIS
            Handles a click on an Install tab category chip

        .DESCRIPTION
            The chip carries its category in Tag, so every chip shares this handler. Holding ctrl
            adds the category to the current selection instead of replacing it.

        .PARAMETER Chip
            The chip that was clicked
    #>
    param(
        [Parameter(Mandatory)]
        $Chip
    )

    $ctrlDown = [bool]([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)
    Set-WinUtilAppCategoryFilter -Category $Chip.Tag -Additive:$ctrlDown
}

function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  if ($render -and $null -ne $sync) {
      if ($null -eq $sync.RenderedAssetCache) {
          $sync.RenderedAssetCache = @{}
      }

      $cacheKey = "$(([string]$type).ToLowerInvariant())|$Size"
      if ($sync.RenderedAssetCache.ContainsKey($cacheKey)) {
          return $sync.RenderedAssetCache[$cacheKey]
      }
  }

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          $LogoPathData1 = @"
M 18.00,14.00
C 18.00,14.00 45.00,27.74 45.00,27.74
45.00,27.74 57.40,34.63 57.40,34.63
57.40,34.63 59.00,43.00 59.00,43.00
59.00,43.00 59.00,83.00 59.00,83.00
55.35,81.66 46.99,77.79 44.72,74.79
41.17,70.10 42.01,59.80 42.00,54.00
42.00,51.62 42.20,48.29 40.98,46.21
38.34,41.74 25.78,38.60 21.28,33.79
16.81,29.02 18.00,20.20 18.00,14.00 Z
"@
          $LogoPath1 = New-Object Windows.Shapes.Path
          $LogoPath1.Data = [Windows.Media.Geometry]::Parse($LogoPathData1)
          $LogoPath1.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData2 = @"
M 107.00,14.00
C 109.01,19.06 108.93,30.37 104.66,34.21
100.47,37.98 86.38,43.10 84.60,47.21
83.94,48.74 84.01,51.32 84.00,53.00
83.97,57.04 84.46,68.90 83.26,72.00
81.06,77.70 72.54,81.42 67.00,83.00
67.00,83.00 67.00,43.00 67.00,43.00
67.00,43.00 67.99,35.63 67.99,35.63
67.99,35.63 80.00,28.26 80.00,28.26
80.00,28.26 107.00,14.00 107.00,14.00 Z
"@
          $LogoPath2 = New-Object Windows.Shapes.Path
          $LogoPath2.Data = [Windows.Media.Geometry]::Parse($LogoPathData2)
          $LogoPath2.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData3 = @"
M 19.00,46.00
C 21.36,47.14 28.67,50.71 30.01,52.63
31.17,54.30 30.99,57.04 31.00,59.00
31.04,65.41 30.35,72.16 33.56,78.00
38.19,86.45 46.10,89.04 54.00,93.31
56.55,94.69 60.10,97.20 63.00,97.22
65.50,97.24 68.77,95.36 71.00,94.25
76.42,91.55 84.51,87.78 88.82,83.68
94.56,78.20 95.96,70.59 96.00,63.00
96.01,60.24 95.59,54.63 97.02,52.39
98.80,49.60 103.95,47.87 107.00,47.00
107.00,47.00 107.00,67.00 107.00,67.00
106.90,87.69 96.10,93.85 80.00,103.00
76.51,104.98 66.66,110.67 63.00,110.52
60.33,110.41 55.55,107.53 53.00,106.25
46.21,102.83 36.63,98.57 31.04,93.68
16.88,81.28 19.00,62.88 19.00,46.00 Z
"@
          $LogoPath3 = New-Object Windows.Shapes.Path
          $LogoPath3.Data = [Windows.Media.Geometry]::Parse($LogoPathData3)
          $LogoPath3.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#a3a4a6")

          $canvas.Children.Add($LogoPath1) | Out-Null
          $canvas.Children.Add($LogoPath2) | Out-Null
          $canvas.Children.Add($LogoPath3) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()
      if ($bitmapImage.CanFreeze) {
          $bitmapImage.Freeze()
      }

      if ($null -ne $sync -and $sync.ContainsKey("RenderedAssetCache")) {
          $sync.RenderedAssetCache[$cacheKey] = $bitmapImage
      }

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}

Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            $packageId = ($_.Value.choco -split ";")[-1].Trim()
            if ($packageId -ne "na" -and $packageId -in $apps) {
                Write-Output $_.Key
            }
        }
    }

    if ($checkbox -eq "winget") {
        $originalEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
            $installedProgramOutput = @(winget list --accept-source-agreements --disable-interactivity 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "winget list failed with exit code $LASTEXITCODE."
            }
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
        $installedProgramText = $installedProgramOutput -join "`n"

        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            $packageId = (($_.Value.winget -split ";")[-1] -replace "^msstore:", "").Trim()
            if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -eq "na") {
                return
            }

            $packagePattern = "(?im)[^\S\r\n]{2,}$([regex]::Escape($packageId))(?=[^\S\r\n]{2,}|$)"
            if ($installedProgramText -match $packagePattern) {
                Write-Output $_.Key
            }
        }
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $entryType = $entry.Type

            if (($registryKeys -or $serviceKeys) -and $entryType -ne "Combobox") {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            }
        }
    }
}

function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}

function Invoke-WinUtilFeatureInstall ($CheckBox) {
    Write-WinUtilLog -Component "Feature" -Message "Applying feature action: $CheckBox"

    if ($sync.configs.feature.$CheckBox.feature) {
        foreach ($feature in $sync.configs.feature.$CheckBox.feature) {
            Write-Host "Installing $feature"
            Write-WinUtilLog -Component "Feature" -Message "Enabling Windows optional feature: $feature"
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Enabled Windows optional feature: $feature"
        }
    }

    if ($sync.configs.feature.$CheckBox.InvokeScript) {
        foreach ($script in $sync.configs.feature.$CheckBox.InvokeScript) {
            Write-Host "Running Script for $CheckBox"
            Write-WinUtilLog -Component "Feature" -Message "Running feature script for: $CheckBox"
            Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Completed feature script for: $CheckBox"
        }
    }
    Write-WinUtilLog -Component "Feature" -Message "Feature action completed: $CheckBox"
}

function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "AppEntryFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Store the scale factor so it can be reapplied after theme changes
    $sync.FontScaleFactor = $ScaleFactor

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }
}

function Invoke-WinUtilInstallPSProfile {
    if (-not (Get-Command wt)) {
        Write-Host "Windows Terminal not found. Installing..."
        Install-WinUtilWinget
        winget install Microsoft.WindowsTerminal --source winget --silent
    }

    if (-not (Get-Command pwsh)) {
        Write-Host "PowerShell 7 not found. Installing..."
        Install-WinUtilWinget
        winget install Microsoft.PowerShell --source winget --installer-type wix --silent
    }

    wt new-tab pwsh -NoExit -Command "Write-Host LucaXShop: external profile installation is disabled. -ForegroundColor Cyan"
}

function Write-WinUtilISOLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $logLine = "[$ts] $Message"
    $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
        $current = $sync["WPFWin11ISOStatusLog"].Text
        if ($current -eq "Ready. Please select a Windows 11 ISO to begin.") {
            $sync["WPFWin11ISOStatusLog"].Text = $logLine
        } else {
            $sync["WPFWin11ISOStatusLog"].Text += "`n$logLine"
        }
        $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
        $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
    })
}

function Invoke-WinUtilISOBrowse {
    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title            = "Select Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso|All files (*.*)|*.*"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $isoPath    = $dlg.FileName
    $fileSizeGB = [math]::Round((Get-Item $isoPath).Length / 1GB, 2)

    $sync["WPFWin11ISOPath"].Text           = $isoPath
    $sync["WPFWin11ISOFileInfo"].Text       = "File size: $fileSizeGB GB"
    $sync["WPFWin11ISOFileInfo"].Visibility = "Visible"
    $sync["WPFWin11ISOMountSection"].Visibility       = "Visible"
    $sync["WPFWin11ISOVerifyResultPanel"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility      = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility      = "Collapsed"

    Write-WinUtilISOLog "ISO selected: $isoPath  ($fileSizeGB GB)"
}

function Invoke-WinUtilISOMountAndVerify {
    $isoPath = $sync["WPFWin11ISOPath"].Text

    if ([string]::IsNullOrWhiteSpace($isoPath) -or $isoPath -eq "No ISO selected...") {
        [System.Windows.MessageBox]::Show("Please select an ISO file first.", "No ISO Selected", "OK", "Warning")
        return
    }

    Write-WinUtilISOLog "Mounting ISO: $isoPath"
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Mounting ISO..." -Percent 10
    $sync["WPFWin11ISOBrowseButton"].IsEnabled = $false
    $sync["WPFWin11ISOMountButton"].IsEnabled = $false
    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    Invoke-WPFRunspace -ParameterList @(,('isoPath', $isoPath)) -ScriptBlock {
        param($isoPath)

        try {
            Mount-DiskImage -ImagePath $isoPath

            do {
                Start-Sleep -Milliseconds 500
            } until ((Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter)

            $driveLetter = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter + ":"
            Write-WinUtilISOLog "Mounted at drive $driveLetter"

            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Verifying ISO contents..." -Percent 30

            $wimPath = Join-Path $driveLetter "sources\install.wim"
            $esdPath = Join-Path $driveLetter "sources\install.esd"

            if (-not (Test-Path $wimPath) -and -not (Test-Path $esdPath)) {
                Dismount-DiskImage -ImagePath $isoPath
                Write-WinUtilISOLog "ERROR: install.wim/install.esd not found - not a valid Windows ISO."
                Invoke-WPFUIThread {
                    [System.Windows.MessageBox]::Show(
                        "This does not appear to be a valid Windows ISO.`n`ninstall.wim / install.esd was not found.",
                        "Invalid ISO", "OK", "Error")
                }
                return
            }

            $activeWim = if (Test-Path $wimPath) { $wimPath } else { $esdPath }

            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Reading image metadata..." -Percent 55
            $imageInfo = Get-WindowsImage -ImagePath $activeWim | Select-Object ImageIndex, ImageName

            if (-not ($imageInfo | Where-Object { $_.ImageName -match "Windows 11" })) {
                Dismount-DiskImage -ImagePath $isoPath
                Write-WinUtilISOLog "ERROR: No 'Windows 11' edition found in the image."
                Invoke-WPFUIThread {
                    [System.Windows.MessageBox]::Show(
                        "No Windows 11 edition was found in this ISO.`n`nOnly official Windows 11 ISOs are supported.",
                        "Not a Windows 11 ISO", "OK", "Error")
                }
                return
            }

            $sync["Win11ISOImageInfo"] = $imageInfo
            $sync["Win11ISODriveLetter"] = $driveLetter
            $sync["Win11ISOWimPath"]     = $activeWim
            $sync["Win11ISOImagePath"]   = $isoPath

            Invoke-WPFUIThread {
                $sync["WPFWin11ISOMountDriveLetter"].Text = "Mounted at: $driveLetter   |   Image file: $(Split-Path $activeWim -Leaf)"
                $sync["WPFWin11ISOEditionComboBox"].Items.Clear()
                foreach ($img in $imageInfo) {
                    [void]$sync["WPFWin11ISOEditionComboBox"].Items.Add("$($img.ImageIndex): $($img.ImageName)")
                }
                if ($sync["WPFWin11ISOEditionComboBox"].Items.Count -gt 0) {
                    $proIndex = -1
                    for ($i = 0; $i -lt $sync["WPFWin11ISOEditionComboBox"].Items.Count; $i++) {
                        if ($sync["WPFWin11ISOEditionComboBox"].Items[$i] -match "Windows 11 Pro(?![\w ])") {
                            $proIndex = $i; break
                        }
                    }
                    $sync["WPFWin11ISOEditionComboBox"].SelectedIndex = if ($proIndex -ge 0) { $proIndex } else { 0 }
                }
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Visible"
                $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
            }

            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "ISO verified" -Percent 100
            Write-WinUtilISOLog "ISO verified OK.  Editions found: $($imageInfo.Count)"
        } catch {
            $errorMessage = $_
            Write-WinUtilISOLog "ERROR during mount/verify: $errorMessage"
            Invoke-WPFUIThread {
                [System.Windows.MessageBox]::Show(
                    "An error occurred while mounting or verifying the ISO:`n`n$errorMessage",
                    "Error", "OK", "Error")
            }
        } finally {
            Start-Sleep -Milliseconds 800
            Set-WinUtilTweaksProgressIndicator -Visible $false
            Invoke-WPFUIThread {
                $sync["WPFWin11ISOBrowseButton"].IsEnabled = $true
                $sync["WPFWin11ISOMountButton"].IsEnabled = $true
                $sync["Win11ISOProcessRunning"] = $false
            }
        }
    }
}

function Invoke-WinUtilISOModify {
    $isoPath     = $sync["Win11ISOImagePath"]
    $driveLetter = $sync["Win11ISODriveLetter"]
    $wimPath     = $sync["Win11ISOWimPath"]

    if (-not $isoPath) {
        [System.Windows.MessageBox]::Show(
            "No verified ISO found. Please complete Steps 1 and 2 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    $selectedItem     = $sync["WPFWin11ISOEditionComboBox"].SelectedItem
    $selectedWimIndex = 1
    if ($selectedItem -and $selectedItem -match '^(\d+):') {
        $selectedWimIndex = [int]$Matches[1]
    } elseif ($sync["Win11ISOImageInfo"]) {
        $selectedWimIndex = $sync["Win11ISOImageInfo"][0].ImageIndex
    }
    $selectedEditionName = if ($selectedItem) { ($selectedItem -replace '^\d+:\s*', '') } else { "Unknown" }
    Write-WinUtilISOLog "Selected edition: $selectedEditionName (Index $selectedWimIndex)"

    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOModifying"] = $true
    $sync["Win11ISOProcessRunning"] = $true

    $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if (Test-Path $workDir) {
        $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(([guid]::NewGuid()).ToString('N').Substring(0, 8))"
    }

    $autounattendContent = if ($WinUtilAutounattendXml) {
        $WinUtilAutounattendXml
    } else {
        $toolsXml = Join-Path $PSScriptRoot "..\..\tools\autounattend.xml"
        if (Test-Path $toolsXml) { Get-Content $toolsXml -Raw } else { "" }
    }

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $injectDrivers = $sync["WPFWin11ISOInjectDrivers"].IsChecked -eq $true
    $runspace.SessionStateProxy.SetVariable("sync",                $sync)
    $runspace.SessionStateProxy.SetVariable("isoPath",             $isoPath)
    $runspace.SessionStateProxy.SetVariable("driveLetter",         $driveLetter)
    $runspace.SessionStateProxy.SetVariable("wimPath",             $wimPath)
    $runspace.SessionStateProxy.SetVariable("workDir",             $workDir)
    $runspace.SessionStateProxy.SetVariable("selectedWimIndex",    $selectedWimIndex)
    $runspace.SessionStateProxy.SetVariable("selectedEditionName", $selectedEditionName)
    $runspace.SessionStateProxy.SetVariable("autounattendContent", $autounattendContent)
    $runspace.SessionStateProxy.SetVariable("injectDrivers",       $injectDrivers)

    $isoScriptFuncDef   = "function Invoke-WinUtilISOScript {`n" + ${function:Invoke-WinUtilISOScript}.ToString() + "`n}"
    $win11ISOLogFuncDef = "function Write-WinUtilISOLog {`n"     + ${function:Write-WinUtilISOLog}.ToString()     + "`n}"
    $runspace.SessionStateProxy.SetVariable("isoScriptFuncDef",   $isoScriptFuncDef)
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($isoScriptFuncDef))
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        function Get-WinUtilEditionIdFromName {
            param([string]$EditionName)

            $normalizedName = ($EditionName -replace '^Windows\s+11\s+', '').Trim()
            switch -Regex ($normalizedName) {
                '^Home Single Language$'      { return 'CoreSingleLanguage' }
                '^Home N$'                    { return 'CoreN' }
                '^Home$'                      { return 'Core' }
                '^Pro for Workstations N$'    { return 'ProfessionalWorkstationN' }
                '^Pro for Workstations$'      { return 'ProfessionalWorkstation' }
                '^Pro Education N$'           { return 'ProfessionalEducationN' }
                '^Pro Education$'             { return 'ProfessionalEducation' }
                '^Pro N$'                     { return 'ProfessionalN' }
                '^Pro$'                       { return 'Professional' }
                '^Education N$'               { return 'EducationN' }
                '^Education$'                 { return 'Education' }
                '^Enterprise LTSC N$'         { return 'EnterpriseSN' }
                '^Enterprise LTSC$'           { return 'EnterpriseS' }
                '^Enterprise N$'              { return 'EnterpriseN' }
                '^Enterprise$'                { return 'Enterprise' }
                default                       { return '' }
            }
        }

        try {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
            })

            Log "Creating working directory: $workDir"
            $isoContents = Join-Path $workDir "iso_contents"
            New-Item -ItemType Directory -Path $isoContents -Force
            SetProgress "Copying ISO contents..." 10

            Log "Copying ISO contents from $driveLetter to $isoContents..."
            & robocopy $driveLetter $isoContents /E /NFL /NDL /NJH /NJS
            Log "ISO contents copied."
            SetProgress "Preparing setup media..." 25

            $sourceImageFileName = Split-Path $wimPath -Leaf
            $localWim = Join-Path $isoContents "sources\$sourceImageFileName"
            if (-not (Test-Path $localWim)) {
                throw "Copied ISO image file not found: sources\$sourceImageFileName"
            }
            $selectedEditionId = Get-WinUtilEditionIdFromName -EditionName $selectedEditionName

            Log "Writing autounattend.xml and edition selection..."
            Invoke-WinUtilISOScript -ISOContentsDir $isoContents -AutoUnattendXml $autounattendContent -InjectCurrentSystemDrivers $injectDrivers -InstallImagePath $localWim -InstallImageIndex $selectedWimIndex -InstallEditionId $selectedEditionId -Log { param($m) Log $m }

            SetProgress "Preserving install image..." 70
            if ($injectDrivers) {
                Log "Added current-system drivers to $sourceImageFileName index $selectedWimIndex with one mount and commit."
            } else {
                Log "Preserved the original $sourceImageFileName without mounting, exporting, or modifying it."
            }

            SetProgress "Dismounting source ISO..." 80
            Log "Dismounting original ISO..."
            Dismount-DiskImage -ImagePath $isoPath

            $sync["Win11ISOWorkDir"]     = $workDir
            $sync["Win11ISOContentsDir"] = $isoContents

            SetProgress "Modification complete" 100
            Log "install.wim modification complete. Choose an output option in Step 4."

            $sync["WPFWin11ISOOutputSection"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"
            })
        } catch {
            Log "ERROR during modification: $_"

            try {
                $mountedISO = Get-DiskImage -ImagePath $isoPath
                if ($mountedISO -and $mountedISO.Attached) {
                    Log "Cleaning up: dismounting source ISO..."
                    Dismount-DiskImage -ImagePath $isoPath
                }
            } catch { Log "Warning: could not dismount ISO during cleanup: $_" }

            try {
                if (Test-Path $workDir) {
                    Log "Cleaning up: removing temp directory $workDir..."
                    Remove-Item -Path $workDir -Recurse -Force
                }
            } catch { Log "Warning: could not remove temp directory during cleanup: $_" }

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "An error occurred during install.wim modification:`n`n$_",
                    "Modification Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOModifying"] = $false
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
                if ($sync["WPFWin11ISOOutputSection"].Visibility -ne "Visible") {
                    $sync["WPFWin11ISOSelectSection"].Visibility = "Visible"
                    $sync["WPFWin11ISOMountSection"].Visibility  = "Visible"
                    $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                }
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOCheckExistingWork {
    if ($sync["Win11ISOContentsDir"] -and (Test-Path $sync["Win11ISOContentsDir"])) { return }

    # Check if ISO modification is currently in progress
    if ($sync["Win11ISOModifying"]) {
        return
    }

    $existingWorkDir = Get-Item -Path (Join-Path $env:TEMP "WinUtil_Win11ISO*") |
        Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $existingWorkDir) { return }

    $isoContents = Join-Path $existingWorkDir.FullName "iso_contents"
    if (-not (Test-Path $isoContents)) { return }

    $sync["Win11ISOWorkDir"]     = $existingWorkDir.FullName
    $sync["Win11ISOContentsDir"] = $isoContents

    $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"

    $modified = $existingWorkDir.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
    Write-WinUtilISOLog "Existing working directory found: $($existingWorkDir.FullName)"
    Write-WinUtilISOLog "Last modified: $modified - Skipping Steps 1-3 and resuming at Step 4."
    Write-WinUtilISOLog "Click 'Clean & Reset' if you want to start over with a new ISO."

    [System.Windows.MessageBox]::Show(
        "A previous WinUtil ISO working directory was found:`n`n$($existingWorkDir.FullName)`n`n(Last modified: $modified)`n`nStep 4 (output options) has been restored so you can save the already-modified image.`n`nClick 'Clean & Reset' in Step 4 if you want to start over.",
        "Existing Work Found", "OK", "Info")
}

function Invoke-WinUtilISOCleanAndReset {
    $workDir = $sync["Win11ISOWorkDir"]

    if ($workDir -and (Test-Path $workDir)) {
        $confirm = [System.Windows.MessageBox]::Show(
            "This will delete the temporary working directory:`n`n$workDir`n`nAnd reset the interface back to the start.`n`nContinue?",
            "Clean & Reset", "YesNo", "Warning")
        if ($confirm -ne "Yes") { return }
    }

    $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",    $sync)
    $runspace.SessionStateProxy.SetVariable("workDir", $workDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        try {
            if ($workDir) {
                $mountDir = Join-Path $workDir "wim_mount"
                try {
                    $mountedImages = Get-WindowsImage -Mounted |
                                     Where-Object { $_.Path -like "$workDir*" }
                    if ($mountedImages) {
                        foreach ($img in $mountedImages) {
                            Log "Dismounting WIM at: $($img.Path) (discarding changes)..."
                            SetProgress "Dismounting WIM image..." 3
                            Dismount-WindowsImage -Path $img.Path -Discard
                            Log "WIM dismounted successfully."
                        }
                    } elseif (Test-Path $mountDir) {
                        Log "No mounted WIM reported by Get-WindowsImage. Running DISM /Cleanup-Wim as a precaution..."
                        SetProgress "Running DISM cleanup..." 3
                        & dism /English /Cleanup-Wim | ForEach-Object { Log $_ }
                    }
                } catch {
                    Log "Warning: could not dismount WIM cleanly. Attempting DISM /Cleanup-Wim fallback: $_"
                    try { & dism /English /Cleanup-Wim | ForEach-Object { Log $_ } }
                    catch { Log "Warning: DISM /Cleanup-Wim also failed: $_" }
                }
            }

            if ($workDir -and (Test-Path $workDir)) {
                Log "Scanning files to delete in: $workDir"
                SetProgress "Scanning files..." 5

                $allFiles = @(Get-ChildItem -Path $workDir -File -Recurse -Force)
                $allDirs  = @(Get-ChildItem -Path $workDir -Directory -Recurse -Force |
                    Sort-Object { $_.FullName.Length } -Descending)
                $total   = $allFiles.Count
                $deleted = 0

                Log "Found $total files to delete."

                foreach ($f in $allFiles) {
                    try { Remove-Item -Path $f.FullName -Force } catch { Log "WARNING: could not delete $($f.FullName): $_" }
                    $deleted++
                    if ($deleted % 100 -eq 0 -or $deleted -eq $total) {
                        $pct = [math]::Round(($deleted / [Math]::Max($total, 1)) * 85) + 5
                        SetProgress "Deleting files in $($f.Directory.Name)... ($deleted / $total)" $pct
                    }
                }

                foreach ($d in $allDirs) {
                    try { Remove-Item -Path $d.FullName -Force } catch { Log "WARNING: could not delete $($d.FullName): $_" }
                }

                try { Remove-Item -Path $workDir -Recurse -Force } catch { Log "WARNING: could not delete temp directory ${workDir}: $_" }

                if (Test-Path $workDir) {
                    Log "WARNING: some items could not be deleted in $workDir"
                } else {
                    Log "Temp directory deleted successfully."
                }
            } else {
                Log "No temp directory found - resetting UI."
            }

            SetProgress "Resetting UI..." 95
            Log "Resetting interface..."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["Win11ISOWorkDir"]     = $null
                $sync["Win11ISOContentsDir"] = $null
                $sync["Win11ISOImagePath"]   = $null
                $sync["Win11ISODriveLetter"] = $null
                $sync["Win11ISOWimPath"]     = $null
                $sync["Win11ISOImageInfo"]   = $null
                $sync["Win11ISOUSBDisks"]    = $null

                $sync["WPFWin11ISOPath"].Text                   = "No ISO selected..."
                $sync["WPFWin11ISOFileInfo"].Visibility          = "Collapsed"
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Collapsed"
                $sync["WPFWin11ISOOptionUSB"].Visibility         = "Collapsed"
                $sync["WPFWin11ISOOutputSection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility      = "Collapsed"
                $sync["WPFWin11ISOSelectSection"].Visibility     = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled       = $true
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled   = $true

                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0

                $sync["WPFWin11ISOStatusLog"].Text   = "Ready. Please select a Windows 11 ISO to begin."
            })
        } catch {
            Log "ERROR during Clean & Reset: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $true
            })
        } finally {
            $sync["Win11ISOProcessRunning"] = $false
        }
    })

    $script.BeginInvoke()
}

function Get-WinUtilOSCDImgPath {
    # Windows ADK installation
    $oscdimg = Get-ChildItem "C:\Program Files (x86)\Windows Kits" -Recurse -Filter "oscdimg.exe" -ErrorAction SilentlyContinue |
               Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscdimg) {
        # Per-user winget installation
        $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                   Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $oscdimg) {
        # Installation available through the current process PATH
        $oscdimg = Get-Command oscdimg.exe -CommandType Application -ErrorAction SilentlyContinue |
                   Select-Object -First 1 -ExpandProperty Source
    }

    if (-not $oscdimg) {
        # WinGet links that may not yet be available through the current process PATH
        $oscdimg = @(
            "$env:LOCALAPPDATA\Microsoft\WinGet\Links\oscdimg.exe"
            "$env:ProgramFiles\WinGet\Links\oscdimg.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }

    return $oscdimg
}

function Invoke-WinUtilISOExport {
    $contentsDir = $sync["Win11ISOContentsDir"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show(
            "No modified ISO content found.  Please complete Steps 1-3 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Title            = "Save Modified Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso"
    $dlg.FileName         = "Win11_Modified_$(Get-Date -Format 'yyyyMMdd').iso"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $outputISO = $dlg.FileName

    $oscdimg = Get-WinUtilOSCDImgPath

    if (-not $oscdimg) {
        Write-WinUtilISOLog "oscdimg.exe not found. Attempting to install via winget..."
        try {
            # First ensure winget is installed and operational
            Install-WinUtilWinget

            $winget = Get-Command winget
            $result = & $winget install -e --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
            Write-WinUtilISOLog "winget output: $result"
            $oscdimg = Get-WinUtilOSCDImgPath
        } catch {
            Write-WinUtilISOLog "winget not available or install failed: $_"
        }

        if (-not $oscdimg) {
            Write-WinUtilISOLog "oscdimg.exe still not found after install attempt."
            [System.Windows.MessageBox]::Show(
                "oscdimg.exe could not be found or installed automatically.`n`nPlease install it manually:`n  winget install -e --id Microsoft.OSCDIMG`n`nOr install the Windows ADK from:`nhttps://learn.microsoft.com/windows-hardware/get-started/adk-install",
                "oscdimg Not Found", "OK", "Warning")
            return
        }
        Write-WinUtilISOLog "oscdimg.exe installed successfully."
    }

    $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)
    $runspace.SessionStateProxy.SetVariable("outputISO",   $outputISO)
    $runspace.SessionStateProxy.SetVariable("oscdimg",     $oscdimg)

    $win11ISOLogFuncDef = "function Write-WinUtilISOLog {`n" + ${function:Write-WinUtilISOLog}.ToString() + "`n}"
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        try {
            Write-WinUtilISOLog "Exporting to ISO: $outputISO"
            SetProgress "Building ISO..." 10

            $bootData    = "2#p0,e,b`"$contentsDir\boot\etfsboot.com`"#pEF,e,b`"$contentsDir\efi\microsoft\boot\efisys.bin`""
            $oscdimgArgs = @("-m", "-o", "-u2", "-udfver102", "-bootdata:$bootData", "-l`"CTOS_MODIFIED`"", "`"$contentsDir`"", "`"$outputISO`"")

            Write-WinUtilISOLog "Running oscdimg..."

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $oscdimg
            $psi.Arguments              = $oscdimgArgs -join " "
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start()

            # Stream stdout line-by-line as oscdimg runs
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line.Trim()) { Write-WinUtilISOLog $line }
            }

            $proc.WaitForExit()

            # Flush any stderr after process exits
            $stderr = $proc.StandardError.ReadToEnd()
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) { Write-WinUtilISOLog "[stderr]$line" }
            }

            if ($proc.ExitCode -eq 0) {
                SetProgress "ISO exported" 100
                Write-WinUtilISOLog "ISO exported successfully: $outputISO"
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show("ISO exported successfully!`n`n$outputISO", "Export Complete", "OK", "Info")
                })
            } else {
                Write-WinUtilISOLog "oscdimg exited with code $($proc.ExitCode)."
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show(
                        "oscdimg exited with code $($proc.ExitCode).`nCheck the status log for details.",
                        "Export Error", "OK", "Error")
                })
            }
        } catch {
            Write-WinUtilISOLog "ERROR during ISO export: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("ISO export failed:`n`n$_", "Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOScript {
    <#
    .SYNOPSIS
        Prepares copied Windows setup media without modifying its install image.

    .DESCRIPTION
        Stages WinUtil's AppX removal, registry tweaks, and scheduled-task cleanup
        in the answer file for first logon, writes sources\ei.cfg for the selected
        edition, and optionally adds current-system drivers to one install.wim index.

    .PARAMETER ISOContentsDir
        Root directory of the copied ISO contents.

    .PARAMETER AutoUnattendXml
        Full XML content for autounattend.xml.

    .PARAMETER InstallEditionId
        Windows setup EditionID for sources\ei.cfg, for example Professional or Core.

    .PARAMETER InstallImagePath
        Copied install.wim to service when current-system driver injection is enabled.

    .PARAMETER InstallImageIndex
        Selected edition index in install.wim.

    .PARAMETER Log
        Optional ScriptBlock for progress/status logging. Receives a single [string] argument.
    #>
    param (
        [Parameter(Mandatory)][string]$ISOContentsDir,
        [string]$AutoUnattendXml = "",
        [bool]$InjectCurrentSystemDrivers = $false,
        [string]$InstallEditionId = "",
        [string]$InstallImagePath = "",
        [int]$InstallImageIndex = 1,
        [scriptblock]$Log = { param($m) Write-Output $m }
    )

    function Add-WinUtilISOStagedDrivers {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [Parameter(Mandatory)][string]$InstallImagePath,
            [Parameter(Mandatory)][int]$InstallImageIndex,
            [scriptblock]$Logger
        )

        function Copy-WinUtilISODriverFolder {
            param (
                [Parameter(Mandatory)][string]$Source,
                [Parameter(Mandatory)][string]$Destination
            )

            $folderName = Split-Path $Source -Leaf
            $targetPath = Join-Path $Destination $folderName
            $suffix = 1
            while (Test-Path -LiteralPath $targetPath) {
                $targetPath = Join-Path $Destination "${folderName}_$suffix"
                $suffix++
            }

            Copy-Item -LiteralPath $Source -Destination $targetPath -Recurse -Force -ErrorAction Stop
            return $targetPath
        }

        function Test-WinUtilISOStorageDriver {
            param ([Parameter(Mandatory)][System.IO.FileInfo]$InfFile)

            if ($InfFile.BaseName -match '(?i)(iaahci|iastor|vmd|irst|rst)') {
                return $true
            }

            try {
                return (Get-Content -LiteralPath $InfFile.FullName -Raw -ErrorAction Stop) -match '(?im)^\s*Class\s*=\s*(SCSIAdapter|HDC)\s*(?:;.*)?$'
            } catch {
                & $Logger "Warning: could not classify storage driver '$($InfFile.FullName)': $_"
                return $false
            }
        }

        function Invoke-WinUtilISODism {
            param (
                [Parameter(Mandatory)][string[]]$Arguments,
                [Parameter(Mandatory)][string]$Operation
            )

            $output = @(& dism.exe @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                foreach ($line in @($output | Select-Object -Last 20)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                        & $Logger "  dism[$Operation]: $line"
                    }
                }
                throw "DISM $Operation failed with exit code $exitCode."
            }
            if ($Operation -ne 'metadata') {
                & $Logger "DISM $Operation completed."
            }
            return $output
        }

        function Get-WinUtilISOWimMetadata {
            param ([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][int]$Index)

            $metadata = @{}
            $output = Invoke-WinUtilISODism -Arguments @('/English', '/Get-WimInfo', "/WimFile:$ImagePath", "/Index:$Index") -Operation 'metadata'
            foreach ($line in $output) {
                if ([string]$line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') {
                    $metadata[$Matches[1].Trim()] = $Matches[2].Trim()
                }
            }
            return $metadata
        }

        function Assert-WinUtilISOWimMetadata {
            param (
                [Parameter(Mandatory)][hashtable]$Before,
                [hashtable]$After
            )

            foreach ($key in 'Languages', 'Installation', 'Edition', 'ProductSuite', 'ProductType') {
                $beforeValue = [string]$Before[$key]
                if ($beforeValue -eq '<undefined>' -or ($key -in 'Installation', 'Edition', 'ProductType' -and [string]::IsNullOrWhiteSpace($beforeValue))) {
                    throw "install.wim metadata is already invalid: $key is undefined. Driver injection was not attempted."
                }
                if ($After) {
                    $afterValue = [string]$After[$key]
                    if ($afterValue -eq '<undefined>' -or ($beforeValue -and $afterValue -ne $beforeValue)) {
                        throw "install.wim metadata validation failed after driver injection: $key changed from '$beforeValue' to '$afterValue'."
                    }
                }
            }
        }

        function Test-WinUtilISOMountedImage {
            param ([Parameter(Mandatory)][string]$Path)

            return @(& dism.exe /English /Get-MountedImageInfo 2>$null) -match [regex]::Escape($Path)
        }

        if ([IO.Path]::GetExtension($InstallImagePath) -ne '.wim') {
            throw 'Current-system driver injection requires install.wim; install.esd cannot be serviced in place.'
        }
        if (-not (Test-Path -LiteralPath $InstallImagePath)) {
            throw "install.wim was not found: $InstallImagePath"
        }
        if ($InstallImageIndex -lt 1) {
            throw 'Current-system driver injection requires a valid install.wim image index.'
        }

        $driverExportRoot = Join-Path $env:TEMP "WinUtil_DriverExport_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(([guid]::NewGuid()).ToString('N').Substring(0, 8))"
        $mountDir = Join-Path (Split-Path -Path $ContentRoot -Parent) 'wim_mount'
        New-Item -Path $driverExportRoot -ItemType Directory -Force | Out-Null
        $imageMounted = $false

        try {
            & $Logger "Exporting current system drivers before modifying install.wim..."
            $dismLog = Join-Path $env:TEMP "WinUtil_DismDriverExport_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            $dismProcess = Start-Process -FilePath "dism.exe" -ArgumentList "/online /export-driver /destination:`"$driverExportRoot`" /LogPath:`"$dismLog`"" -Wait -NoNewWindow -PassThru
            if ($dismProcess.ExitCode -ne 0) {
                throw "dism.exe driver export failed with exit code $($dismProcess.ExitCode)."
            }

            $driverInfs = @(Get-ChildItem -Path $driverExportRoot -Filter '*.inf' -Recurse -File)
            if ($driverInfs.Count -eq 0) {
                throw 'DISM exported no driver INF files.'
            }
            $driverFolders = @($driverInfs | Group-Object { $_.Directory.FullName })
            $winpeDriverDir = Join-Path $ContentRoot '$WinpeDriver$'
            $storageCount = 0
            $copyFailures = 0

            foreach ($driverFolderGroup in $driverFolders) {
                $driverFolder = [string]$driverFolderGroup.Name
                $storageInfs = @($driverFolderGroup.Group | Where-Object { Test-WinUtilISOStorageDriver -InfFile $_ })
                if ($storageInfs.Count -eq 0) {
                    continue
                }

                try {
                    New-Item -Path $winpeDriverDir -ItemType Directory -Force | Out-Null
                    $winpeTarget = Copy-WinUtilISODriverFolder -Source $driverFolder -Destination $winpeDriverDir
                    $storageCount++
                    & $Logger "Staged boot-storage package '$driverFolder' for WinPE as '$winpeTarget'."
                } catch {
                    $copyFailures++
                    & $Logger "Warning: failed to stage boot-storage package '$driverFolder': $_"
                }
            }

            if ($copyFailures -gt 0) {
                throw "Failed to stage $copyFailures boot-storage driver package folders."
            }

            & $Logger "Exported $($driverInfs.Count) driver INF files across $($driverFolders.Count) package folders; staged $storageCount boot-storage packages for WinPE."
            $metadataBefore = Get-WinUtilISOWimMetadata -ImagePath $InstallImagePath -Index $InstallImageIndex
            Assert-WinUtilISOWimMetadata -Before $metadataBefore

            Set-ItemProperty -LiteralPath $InstallImagePath -Name IsReadOnly -Value $false
            New-Item -Path $mountDir -ItemType Directory -Force | Out-Null
            & $Logger "Mounting install.wim index $InstallImageIndex once for driver injection..."
            Invoke-WinUtilISODism -Arguments @('/English', '/Mount-Image', "/ImageFile:$InstallImagePath", "/Index:$InstallImageIndex", "/MountDir:$mountDir") -Operation 'mount' | Out-Null
            $imageMounted = $true

            & $Logger "Adding all exported drivers to the selected Windows image in one DISM operation..."
            Invoke-WinUtilISODism -Arguments @('/English', "/Image:$mountDir", '/Add-Driver', "/Driver:$driverExportRoot", '/Recurse') -Operation 'add-driver' | Out-Null

            & $Logger 'Committing the driver-only install.wim change...'
            Invoke-WinUtilISODism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Commit') -Operation 'commit' | Out-Null
            $imageMounted = $false

            $metadataAfter = Get-WinUtilISOWimMetadata -ImagePath $InstallImagePath -Index $InstallImageIndex
            Assert-WinUtilISOWimMetadata -Before $metadataBefore -After $metadataAfter
            & $Logger 'Driver injection complete; install.wim metadata validation passed.'
        } finally {
            if ($imageMounted -or (Test-WinUtilISOMountedImage -Path $mountDir)) {
                try {
                    Invoke-WinUtilISODism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Discard') -Operation 'discard' | Out-Null
                } catch {
                    & $Logger "Warning: could not discard the failed install.wim mount: $_"
                }
            }
            Remove-Item -Path $mountDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $driverExportRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Write-WinUtilISOEditionConfig {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [string]$EditionId,
            [scriptblock]$Logger
        )

        $sourcesDir = Join-Path $ContentRoot "sources"
        New-Item -Path $sourcesDir -ItemType Directory -Force | Out-Null

        $pidPath = Join-Path $sourcesDir "PID.txt"
        if (Test-Path $pidPath) {
            Remove-Item -Path $pidPath -Force
            & $Logger "Removed sources\PID.txt so setup will not force a stale or mismatched product key."
        }

        if ([string]::IsNullOrWhiteSpace($EditionId)) {
            & $Logger "Warning: selected edition ID is unknown - skipping sources\ei.cfg fallback."
            return
        }

        $eiCfgPath = Join-Path $sourcesDir "ei.cfg"
        $eiCfg = @"
[EditionID]
$EditionId
[Channel]
Retail
[VL]
0
"@.Trim()

        Set-Content -Path $eiCfgPath -Value $eiCfg -Encoding ASCII -Force
        & $Logger "Written sources\ei.cfg for EditionID '$EditionId'."
    }

    function Add-WinUtilISOSetupCustomizations {
        param (
            [Parameter(Mandatory)][string]$XmlContent,
            [Parameter(Mandatory)][int]$InstallImageIndex,
            [scriptblock]$Logger
        )

        $appxPackages = @(
            'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingSearch',
            'Microsoft.BingWeather', 'Microsoft.GetHelp', 'Microsoft.MicrosoftOfficeHub',
            'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftStickyNotes',
            'Microsoft.OutlookForWindows', 'Microsoft.Paint', 'Microsoft.PowerAutomateDesktop',
            'Microsoft.StartExperiencesApp', 'Microsoft.Todos', 'Microsoft.Windows.DevHome',
            'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsSoundRecorder',
            'Microsoft.ZuneMusic', 'MicrosoftCorporationII.QuickAssist', 'MSTeams'
        )

        $appxList = ($appxPackages | ForEach-Object { "    '$_'" }) -join "`r`n"
        $postInstallScript = @"
`$ErrorActionPreference = 'Continue'
`$logPath = 'C:\Windows\Setup\Scripts\WinUtil-PostInstall.log'
Start-Transcript -Path `$logPath -Append -ErrorAction SilentlyContinue

try {
    Write-Host 'WinUtil: Removing provisioned AppX packages...'
    `$packages = @(
$appxList
    )
    foreach (`$package in `$packages) {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { `$_.DisplayName -like "*`$package*" } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName `$_.PackageName -ErrorAction SilentlyContinue | Out-Null }
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { `$_.Name -like "*`$package*" } |
            ForEach-Object { Remove-AppxPackage -AllUsers -Package `$_.PackageFullName -ErrorAction SilentlyContinue | Out-Null }
    }

    function Set-WinUtilRegistryValue([string]`$Path, [string]`$Name, [string]`$Type, [string]`$Value) {
        reg.exe add `$Path /v `$Name /t `$Type /d `$Value /f 2>&1 | Out-Null
    }

    function Set-WinUtilContentDeliveryManagerValues([string]`$HiveRoot) {
        `$contentDeliveryManager = "`$HiveRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        Set-WinUtilRegistryValue `$contentDeliveryManager 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'ContentDeliveryAllowed' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'FeatureManagementEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SoftLandingEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContentEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
        reg.exe delete "`$contentDeliveryManager\Subscriptions" /f 2>&1 | Out-Null
        reg.exe delete "`$contentDeliveryManager\SuggestedApps" /f 2>&1 | Out-Null
    }

    Write-Host 'WinUtil: Applying registry tweaks...'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' /f 2>&1 | Out-Null
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate' /f 2>&1 | Out-Null
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DisableWindowsUpdateAccess' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer' 'REG_SZ' 'http://localhost:8080'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUStatusServer' 'REG_SZ' 'http://localhost:8080'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' 'workCompleted' 'REG_DWORD' '1'
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' /f 2>&1 | Out-Null
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\BITS' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\wuauserv' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\UsoSvc' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc' 'Start' 'REG_DWORD' '4'

    `$defaultHive = 'HKU\WinUtilDefault'
    reg.exe load `$defaultHive 'C:\Users\Default\NTUSER.DAT' 2>&1 | Out-Null
    if (`$LASTEXITCODE -eq 0) {
        Set-WinUtilRegistryValue "`$defaultHive\Control Panel\UnsupportedHardwareNotificationCache" 'SV1' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Control Panel\UnsupportedHardwareNotificationCache" 'SV2' 'REG_DWORD' '0'
        Set-WinUtilContentDeliveryManagerValues `$defaultHive
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Windows\CurrentVersion\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" 'HasAccepted' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Input\TIPC" 'Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\InputPersonalization" 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\InputPersonalization" 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\InputPersonalization\TrainedDataStore" 'HarvestContacts' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Personalization\Settings" 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
        reg.exe unload `$defaultHive 2>&1 | Out-Null
    }

    Set-WinUtilContentDeliveryManagerValues 'HKCU'
    Set-WinUtilRegistryValue 'HKCU\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'

    Write-Host 'WinUtil: Removing scheduled task definitions...'
    `$taskPaths = @(
        'C:\Windows\System32\Tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Customer Experience Improvement Program',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Chkdsk\Proxy',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        'C:\Windows\System32\Tasks\Microsoft\Windows\InstallService',
        'C:\Windows\System32\Tasks\Microsoft\Windows\UpdateOrchestrator',
        'C:\Windows\System32\Tasks\Microsoft\Windows\UpdateAssistant',
        'C:\Windows\System32\Tasks\Microsoft\Windows\WaaSMedic',
        'C:\Windows\System32\Tasks\Microsoft\Windows\WindowsUpdate',
        'C:\Windows\System32\Tasks\Microsoft\WindowsUpdate'
    )
    foreach (`$taskPath in `$taskPaths) { Remove-Item -LiteralPath `$taskPath -Recurse -Force -ErrorAction SilentlyContinue }

    Start-Process -FilePath 'C:\Windows\System32\OneDriveSetup.exe' -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue
    Write-Host 'WinUtil: Post-install customization complete.'
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
"@

        $xmlDoc = [xml]::new()
        $xmlDoc.PreserveWhitespace = $true
        $xmlDoc.LoadXml($XmlContent)
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $nsMgr.AddNamespace('sg', 'https://schneegans.de/windows/unattend-generator/')

        $setupComponent = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-Setup"]', $nsMgr)
        $extensions = $xmlDoc.SelectSingleNode('//sg:Extensions', $nsMgr)
        $firstLogonFile = $xmlDoc.SelectSingleNode('//sg:File[@path="C:\Windows\Setup\Scripts\FirstLogon.ps1"]', $nsMgr)
        if (-not $setupComponent -or -not $extensions -or -not $firstLogonFile) {
            throw 'autounattend.xml is missing a required Windows Setup, Extensions, or FirstLogon.ps1 node.'
        }

        $imageInstall = $setupComponent.SelectSingleNode('u:ImageInstall', $nsMgr)
        if (-not $imageInstall) {
            $imageInstall = $xmlDoc.CreateElement('ImageInstall', $setupComponent.NamespaceURI)
            [void]$setupComponent.AppendChild($imageInstall)
        }
        $osImage = $imageInstall.SelectSingleNode('u:OSImage', $nsMgr)
        if (-not $osImage) {
            $osImage = $xmlDoc.CreateElement('OSImage', $setupComponent.NamespaceURI)
            [void]$imageInstall.AppendChild($osImage)
        }
        $installFrom = $osImage.SelectSingleNode('u:InstallFrom', $nsMgr)
        if (-not $installFrom) {
            $installFrom = $xmlDoc.CreateElement('InstallFrom', $setupComponent.NamespaceURI)
            [void]$osImage.AppendChild($installFrom)
        }
        foreach ($existingMetadata in @($installFrom.SelectNodes('u:MetaData', $nsMgr))) {
            [void]$installFrom.RemoveChild($existingMetadata)
        }
        $metadata = $xmlDoc.CreateElement('MetaData', $setupComponent.NamespaceURI)
        $action = $xmlDoc.CreateAttribute('wcm', 'action', 'http://schemas.microsoft.com/WMIConfig/2002/State')
        $action.Value = 'add'
        [void]$metadata.Attributes.Append($action)
        $key = $xmlDoc.CreateElement('Key', $setupComponent.NamespaceURI)
        $key.InnerText = '/IMAGE/INDEX'
        [void]$metadata.AppendChild($key)
        $value = $xmlDoc.CreateElement('Value', $setupComponent.NamespaceURI)
        $value.InnerText = [string]$InstallImageIndex
        [void]$metadata.AppendChild($value)
        [void]$installFrom.AppendChild($metadata)

        $postInstallFile = $xmlDoc.CreateElement('File', $extensions.NamespaceURI)
        $postInstallFile.SetAttribute('path', 'C:\Windows\Setup\Scripts\WinUtil-PostInstall.ps1')
        $postInstallFile.InnerText = $postInstallScript
        [void]$extensions.AppendChild($postInstallFile)

        $firstLogonFile.InnerText = "& 'C:\Windows\Setup\Scripts\WinUtil-PostInstall.ps1';`r`n`r`n$($firstLogonFile.InnerText.Trim())"

        $null = & $Logger 'Added WinUtil post-install AppX, registry, and scheduled-task customizations to autounattend.xml.'
        return $xmlDoc.OuterXml
    }

    function Add-WinUtilISOSetupScriptFallback {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [Parameter(Mandatory)][string]$XmlContent,
            [scriptblock]$Logger
        )

        $xmlDoc = [xml]::new()
        $xmlDoc.PreserveWhitespace = $true
        $xmlDoc.LoadXml($XmlContent)
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $nsMgr.AddNamespace('sg', 'https://schneegans.de/windows/unattend-generator/')

        $setupScriptsRoot = Join-Path $ContentRoot 'sources\$OEM$\$$\Setup\Scripts'
        $stagedCount = 0
        foreach ($file in $xmlDoc.SelectNodes('//sg:File', $nsMgr)) {
            $path = $file.GetAttribute('path')
            if (-not $path.StartsWith('C:\Windows\Setup\Scripts\', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $relativePath = $path.Substring('C:\Windows\Setup\Scripts\'.Length)
            $targetPath = Join-Path $setupScriptsRoot $relativePath
            New-Item -Path (Split-Path $targetPath -Parent) -ItemType Directory -Force | Out-Null

            $encoding = switch ([System.IO.Path]::GetExtension($targetPath)) {
                { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; break }
                { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new($false, $true); break }
                default { [System.Text.Encoding]::Default }
            }
            $bytes = $encoding.GetPreamble() + $encoding.GetBytes($file.InnerText.Trim())
            [System.IO.File]::WriteAllBytes($targetPath, $bytes)
            $stagedCount++
        }

        $useConfigurationSet = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-Setup"]/u:UseConfigurationSet', $nsMgr)
        if ($useConfigurationSet) {
            $useConfigurationSet.InnerText = 'true'
            [System.IO.File]::WriteAllText((Join-Path $ContentRoot 'autounattend.xml'), $xmlDoc.OuterXml, [System.Text.UTF8Encoding]::new($false))
        }
        & $Logger "Staged $stagedCount WinUtil setup script fallback files at '$setupScriptsRoot'."
    }

    if (-not (Test-Path $ISOContentsDir)) {
        throw "ISO contents directory does not exist: $ISOContentsDir"
    }

    if ([string]::IsNullOrWhiteSpace($AutoUnattendXml)) {
        throw "autounattend.xml content is required to prepare setup media."
    }

    $preparedAutoUnattendXml = Add-WinUtilISOSetupCustomizations -XmlContent $AutoUnattendXml -InstallImageIndex $InstallImageIndex -Logger $Log
    $unattendPath = Join-Path $ISOContentsDir "autounattend.xml"
    [System.IO.File]::WriteAllText($unattendPath, $preparedAutoUnattendXml, [System.Text.UTF8Encoding]::new($false))
    & $Log "Written autounattend.xml with WinUtil setup customizations to ISO root ($unattendPath)."
    Add-WinUtilISOSetupScriptFallback -ContentRoot $ISOContentsDir -XmlContent $preparedAutoUnattendXml -Logger $Log

    Write-WinUtilISOEditionConfig -ContentRoot $ISOContentsDir -EditionId $InstallEditionId -Logger $Log

    if ($InjectCurrentSystemDrivers) {
        Add-WinUtilISOStagedDrivers -ContentRoot $ISOContentsDir -Logger $Log -InstallImagePath $InstallImagePath -InstallImageIndex $InstallImageIndex
    }
}

function Invoke-WinUtilISORefreshUSBDrives {
    $combo    = $sync["WPFWin11ISOUSBDriveComboBox"]
    $removable = @(Get-Disk | Where-Object { $_.BusType -eq "USB" } | Sort-Object Number)

    $combo.Items.Clear()

    if ($removable.Count -eq 0) {
        $combo.Items.Add("No USB drives detected.")
        $combo.SelectedIndex = 0
        $sync["Win11ISOUSBDisks"] = @()
        Write-WinUtilISOLog "No USB drives detected."
        return
    }

    foreach ($disk in $removable) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $combo.Items.Add("Disk $($disk.Number): $($disk.FriendlyName)  [$sizeGB GB] - $($disk.PartitionStyle)")
    }
    $combo.SelectedIndex = 0
    Write-WinUtilISOLog "Found $($removable.Count) USB drive(s)."
    $sync["Win11ISOUSBDisks"] = $removable
}

function Invoke-WinUtilISOWriteUSB {
    $contentsDir = $sync["Win11ISOContentsDir"]
    $usbDisks    = $sync["Win11ISOUSBDisks"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show("No modified ISO content found. Please complete Steps 1-3 first.", "Not Ready", "OK", "Warning")
        return
    }

    $installWim = Join-Path $contentsDir "sources\install.wim"
    $installEsd = Join-Path $contentsDir "sources\install.esd"
    if (Test-Path $installEsd) {
        $installEsdFile = Get-Item $installEsd
        $esdSizeBytes = $installEsdFile.Length
        $esdSizeMB = [math]::Ceiling($esdSizeBytes / 1MB)
        if ($esdSizeBytes -ge 4GB) {
            [System.Windows.MessageBox]::Show(
                "This ISO uses an install.esd file that is $esdSizeMB MB. WinUtil's FAT32 USB format cannot store files larger than 4 GB.`n`nExport an ISO instead or use media with install.wim.",
                "USB Creation Not Supported", "OK", "Warning")
            return
        }
    }

    $combo = $sync["WPFWin11ISOUSBDriveComboBox"]
    $selectedIndex = $combo.SelectedIndex
    $selectedItemText = [string]$combo.SelectedItem
    $usbDisks = @($usbDisks)

    $targetDisk = $null
    if ($selectedIndex -ge 0 -and $selectedIndex -lt $usbDisks.Count) {
        $targetDisk = $usbDisks[$selectedIndex]
    } elseif ($selectedItemText -match 'Disk\s+(\d+):') {
        $selectedDiskNum = [int]$matches[1]
        $targetDisk = $usbDisks | Where-Object { $_.Number -eq $selectedDiskNum } | Select-Object -First 1
    }

    if (-not $targetDisk) {
        [System.Windows.MessageBox]::Show("Please select a USB drive from the dropdown.", "No Drive Selected", "OK", "Warning")
        return
    }

    $diskNum    = $targetDisk.Number
    $sizeGB     = [math]::Round($targetDisk.Size / 1GB, 1)

    $confirm = [System.Windows.MessageBox]::Show(
        "ALL data on Disk $diskNum ($($targetDisk.FriendlyName), $sizeGB GB) will be PERMANENTLY ERASED.`n`nAre you sure you want to continue?",
        "Confirm USB Erase", "YesNo", "Warning")

    if ($confirm -ne "Yes") {
        Write-WinUtilISOLog "USB write cancelled by user."
        return
    }

    $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true
    Write-WinUtilISOLog "Starting USB write to Disk $diskNum..."

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("diskNum",     $diskNum)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        function Get-FreeDriveLetter {
            $used = (Get-PSDrive -PSProvider FileSystem).Name
            foreach ($c in [char[]](68..90)) {
                if ($used -notcontains [string]$c) { return $c }
            }
            return $null
        }

        try {
            SetProgress "Formatting USB drive..." 10

            # Phase 1: Clean disk via diskpart (retry once if the drive is not yet ready)
            $dpFile1 = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
            "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1 -Encoding ASCII
            Log "Running diskpart clean on Disk $diskNum..."
            $dpCleanOut = diskpart /s $dpFile1
            $dpCleanOut | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile1 -Force

            if (($dpCleanOut -join ' ') -match 'device is not ready') {
                Log "Disk $diskNum was not ready; waiting 5 seconds and retrying clean..."
                Start-Sleep -Seconds 5
                Update-Disk -Number $diskNum
                $dpFile1b = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
                "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1b -Encoding ASCII
                diskpart /s $dpFile1b | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
                Remove-Item $dpFile1b -Force
            }

            # Phase 2: Initialize as GPT
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum
            $diskObj = Get-Disk -Number $diskNum
            if ($diskObj.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum initialized as GPT."
            } else {
                Set-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum converted to GPT (was $($diskObj.PartitionStyle))."
            }

            # Phase 3: Create FAT32 partition via diskpart, then format with Format-Volume
            # (diskpart's 'format' command can fail with "no volume selected" on fresh/never-formatted drives)
            $volLabel = "W11-" + (Get-Date).ToString('yyMMdd')
            $dpFile2  = Join-Path $env:TEMP "winutil_diskpart2_$(Get-Random).txt"
            $maxFat32PartitionMB = 32768
            $diskSizeMB = [int][Math]::Floor((Get-Disk -Number $diskNum).Size / 1MB)
            $createPartitionCommand = "create partition primary"
            if ($diskSizeMB -gt $maxFat32PartitionMB) {
                $createPartitionCommand = "create partition primary size=$maxFat32PartitionMB"
                Log "Disk $diskNum is $diskSizeMB MB; creating FAT32 partition capped at $maxFat32PartitionMB MB (32 GB)."
            }

            @(
                "select disk $diskNum"
                $createPartitionCommand
                "exit"
            ) | Set-Content -Path $dpFile2 -Encoding ASCII
            Log "Creating partitions on Disk $diskNum..."
            diskpart /s $dpFile2 | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile2 -Force

            SetProgress "Formatting USB partition..." 25
            Start-Sleep -Seconds 3
            Update-Disk -Number $diskNum

            $partitions = Get-Partition -DiskNumber $diskNum
            Log "Partitions on Disk $diskNum after creation: $($partitions.Count)"
            foreach ($p in $partitions) {
                Log "  Partition $($p.PartitionNumber)  Type=$($p.Type)  Letter=$($p.DriveLetter)  Size=$([math]::Round($p.Size/1MB))MB"
            }

            $winpePart = $partitions | Where-Object { $_.Type -eq "Basic" } | Select-Object -Last 1
            if (-not $winpePart) {
                throw "Could not find the Basic partition on Disk $diskNum after creation."
            }

            # Format using Format-Volume (reliable on fresh drives; diskpart format fails
            # with 'no volume selected' when the partition has never been formatted before)
            Log "Formatting Partition $($winpePart.PartitionNumber) as FAT32 (label: $volLabel)..."
            Get-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber |
                Format-Volume -FileSystem FAT32 -NewFileSystemLabel $volLabel -Force -Confirm:$false
            Log "Partition $($winpePart.PartitionNumber) formatted as FAT32."

            SetProgress "Assigning drive letters..." 30
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum

            try { Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -AccessPath "$($winpePart.DriveLetter):" } catch { Log "Warning: could not remove existing partition access path: $_" }
            $usbLetter = Get-FreeDriveLetter
            if (-not $usbLetter) { throw "No free drive letters (D-Z) available to assign to the USB data partition." }
            Set-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -NewDriveLetter $usbLetter
            Log "Assigned drive letter $usbLetter to WINPE partition (Partition $($winpePart.PartitionNumber))."
            Start-Sleep -Seconds 2

            $usbDrive = "${usbLetter}:"
            $retries = 0
            while (-not (Test-Path $usbDrive) -and $retries -lt 6) {
                $retries++
                Log "Waiting for $usbDrive to become accessible (attempt $retries/6)..."
                Start-Sleep -Seconds 2
            }
            if (-not (Test-Path $usbDrive)) { throw "Drive $usbDrive is not accessible after letter assignment." }
            Log "USB data partition: $usbDrive"

            $contentSizeBytes = (Get-ChildItem -LiteralPath $contentsDir -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum
            if (-not $contentSizeBytes) { $contentSizeBytes = 0 }
            $usbVolume = Get-Volume -DriveLetter $usbLetter
            $partitionCapacityBytes = [int64]$usbVolume.Size
            $partitionFreeBytes = [int64]$usbVolume.SizeRemaining

            $contentSizeGB = [math]::Round($contentSizeBytes / 1GB, 2)
            $partitionCapacityGB = [math]::Round($partitionCapacityBytes / 1GB, 2)
            $partitionFreeGB = [math]::Round($partitionFreeBytes / 1GB, 2)

            Log "Source content size: $contentSizeGB GB. USB partition capacity: $partitionCapacityGB GB, free: $partitionFreeGB GB."

            if ($contentSizeBytes -gt $partitionCapacityBytes) {
                throw "ISO content ($contentSizeGB GB) is larger than the USB partition capacity ($partitionCapacityGB GB). Use a larger USB drive or reduce image size."
            }

            if ($contentSizeBytes -gt $partitionFreeBytes) {
                throw "Insufficient free space on USB partition. Required: $contentSizeGB GB, available: $partitionFreeGB GB."
            }

            SetProgress "Copying Windows 11 files to USB..." 45

            # Copy files; split install.wim if > 4 GB (FAT32 limit)
            $installWim = Join-Path $contentsDir "sources\install.wim"
            if (Test-Path $installWim) {
                $wimSizeMB = [math]::Round((Get-Item $installWim).Length / 1MB)
                if ($wimSizeMB -gt 3800) {
                    Log "install.wim is $wimSizeMB MB - splitting for FAT32 compatibility... This will take several minutes."
                    Set-ItemProperty -LiteralPath $installWim -Name IsReadOnly -Value $false
                    $splitDest = Join-Path $usbDrive "sources\install.swm"
                    New-Item -ItemType Directory -Path (Split-Path $splitDest) -Force
                    Split-WindowsImage -ImagePath $installWim -SplitImagePath $splitDest -FileSize 3800 -CheckIntegrity
                    Log "install.wim split complete."
                    Log "Copying remaining files to USB..."
                    & robocopy $contentsDir $usbDrive /E /XF install.wim /NFL /NDL /NJH /NJS
                } else {
                    & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
                }
            } else {
                & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
            }

            SetProgress "Finalising USB drive..." 90
            Log "Files copied to USB."
            SetProgress "USB write complete" 100
            Log "USB drive is ready for use."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "USB drive created successfully!`n`nYou can now boot from this drive to install Windows 11.",
                    "USB Ready", "OK", "Info")
            })
        } catch {
            Log "ERROR during USB write: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("USB write failed:`n`n$_", "USB Write Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $Name"
        Write-WinUtilLog -Component "Script" -Message "Running script for $Name"
        Invoke-Command $scriptblock -ErrorAction Stop
        Write-WinUtilLog -Component "Script" -Message "Completed script for $Name"
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Command not found while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Runtime exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Security exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Access denied while running script for $Name`: $($PSItem.Exception.Message)"
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Unhandled exception while running script for $Name`: $($psitem.Exception.Message)"
    }

}

Function Invoke-WinUtilSponsors {
    $sponsors = ([regex]::Matches(([regex]::Match((Invoke-RestMethod https://github.com/sponsors/ChrisTitusTech),'(?s)(?<=Current sponsors).*?(?=Past sponsors)')).Value,'(?<=alt="@)[^"]+')).Value | Where-Object {$_ -ne "ChrisTitusTech"}
    return $sponsors
}

function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Install the OpenSSH Server feature if not already installed
    if ((Get-WindowsCapability -Name OpenSSH.Server -Online).State -ne "Installed") {
        Write-Host "Enabling OpenSSH Server... This will take a long time."
        Add-WindowsCapability -Name OpenSSH.Server -Online
    }

    Write-Host "Starting the services"

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service -Name ssh-agent

    #Adding Firewall rule for port 22
    Write-Host "Setting up firewall rules"
    if (-not ((Get-NetFirewallRule -Name 'sshd').Enabled)) {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "Firewall rule for OpenSSH Server created and enabled."
    }

    # An SSH logon for a member of the administrators group gets a full token
    # with no UAC prompt, so sshd reads administrator keys from a machine-wide
    # file that only Administrators and SYSTEM may write. WinUtil always runs
    # elevated, so the account being set up here is always an administrator.
    $sshProgramDataPath = Join-Path $env:ProgramData "ssh"
    $sshdConfigPath = Join-Path $sshProgramDataPath "sshd_config"
    $authorizedKeysPath = Join-Path $sshProgramDataPath "administrators_authorized_keys"
    $profileKeysPath = Join-Path $env:USERPROFILE ".ssh\authorized_keys"

    if (-not (Test-Path -Path $sshProgramDataPath)) {
        New-Item -Path $sshProgramDataPath -ItemType Directory -Force | Out-Null
    }

    # Earlier WinUtil versions commented out the administrators block in
    # sshd_config. Detect that state before restoring it, so administrator keys
    # already in use are carried over instead of silently stopping working.
    $configContent = if (Test-Path -Path $sshdConfigPath) { [string](Get-Content -Path $sshdConfigPath -Raw) } else { "" }
    $restoredContent = $configContent -replace '(?m)^# (Match Group administrators)$', '$1'
    $restoredContent = $restoredContent -replace '(?m)^# (\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)$', '$1'
    $configWasOverridden = $restoredContent -ne $configContent

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "Creating administrators_authorized_keys file..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force | Out-Null
        Write-Host "administrators_authorized_keys file created at $authorizedKeysPath."
    }

    if ($configWasOverridden -and (Test-Path -Path $profileKeysPath)) {
        $currentKeys = @(Get-Content -Path $authorizedKeysPath)
        $keysToMove = @(Get-Content -Path $profileKeysPath | Where-Object {
            $_.Trim() -and -not $_.TrimStart().StartsWith("#") -and $currentKeys -notcontains $_
        })

        if ($keysToMove.Count -gt 0) {
            Add-Content -Path $authorizedKeysPath -Value $keysToMove
            Write-Host "Moved $($keysToMove.Count) key(s) from $profileKeysPath to $authorizedKeysPath."
        }
    }

    # sshd ignores the file unless inheritance is off and access is limited to
    # Administrators (S-1-5-32-544) and SYSTEM (S-1-5-18). SIDs keep this
    # working on localized installs, where the group names differ.
    $acl = Get-Acl -Path $authorizedKeysPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRule($rule)
    }
    foreach ($sid in @("S-1-5-32-544", "S-1-5-18")) {
        [void]$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]::new($sid), "FullControl", "Allow"))
    }
    Set-Acl -Path $authorizedKeysPath -AclObject $acl

    if ($configWasOverridden) {
        Set-Content -Path $sshdConfigPath -Value $restoredContent -Force
        Write-Host "Restored the administrator key file setting in sshd_config."
        Restart-Service -Name sshd -Force
    }

    Write-Host "OpenSSH server was successfully enabled."
    Write-Host "The config file can be located at $sshdConfigPath"
    Write-Host "Add your public keys to this file -> $authorizedKeysPath"
}

function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($themeProperty in $themeProperties) {
            # Apply properties that deal with colors
            if ($themeProperty.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($themeProperty.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($themeProperty.Name)" -Value $themeProperty.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($themeProperty.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($themeProperty.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($themeProperty.Name -like "*Thickness*") -or ($themeProperty.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($themeProperty.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-WinutilTheme -currentTheme "shared"

    switch ($sync.preferences.theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
    }

    # Reapply font scaling if it was previously set (theme change resets shared resources)
    if ($sync.ContainsKey("FontScaleFactor") -and $sync.FontScaleFactor -ne 1.0) {
        Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScaleFactor
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}

function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    $action = if ($undo) { "Undo" } else { "Apply" }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak: $CheckBox"

    if ($undo) {
        $Values = @{
            Registry = "OriginalValue"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if ($sync.configs.tweaks.$CheckBox.service) {
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            if ($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found."
                }
            }

            if ($changeservice) {
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if ($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | Where-Object { -not $psitem.Values } | ForEach-Object {
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if ($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if (!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Remove-WinUtilAPPX -Name $psitem
            }
            Remove-WinUtilProvisionedAPPX -PackageList $sync.configs.tweaks.$CheckBox.appx
        }
    }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak completed: $CheckBox"
}

function Invoke-WinUtilUninstallPSProfile {

    if (Test-Path ($Profile + ".bak")) {
        Move-Item -Path ($Profile + ".bak") -Destination $Profile
    } else {
        Remove-Item -Path $Profile
    }

    Write-Host "Successfully uninstalled CTT PowerShell Profile." -ForegroundColor Green
}

function New-WinUtilFossBadge {
    <#
        .SYNOPSIS
            Creates the FOSS marker: the open source keyhole on a green backdrop
        .DESCRIPTION
            Returns a fresh element on every call, because a WPF element can only have one parent.
            The artwork is authored in a 22x22 box and scaled by the Viewbox, so callers only pick a size.
        .PARAMETER Size
            Edge length of the badge in pixels
        .PARAMETER Round
            Use a full circle instead of the corner triangle, for the legend rather than an app entry
    #>
    param(
        [double]$Size = 24,
        [switch]$Round
    )

    $artwork = New-Object Windows.Controls.Grid
    $artwork.Width = 22
    $artwork.Height = 22

    $backdrop = New-Object Windows.Shapes.Path
    $backdrop.Fill = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))
    $keyhole = New-Object Windows.Shapes.Path
    $keyhole.Stroke = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(247, 247, 247))

    if ($Round) {
        $backdrop.Data = [Windows.Media.EllipseGeometry]::new([Windows.Point]::new(11, 11), 11, 11)
        # Keyhole centred in the circle, which has room for a larger ring than the triangle does
        $keyhole.Data = [Windows.Media.Geometry]::Parse("M 7.673,15.751 A 5.8,5.8 0 1 1 14.327,15.751")
        $keyhole.StrokeThickness = 3.4
    } else {
        # Triangle filling the top right corner, its outer corner rounded to match AppEntryBorderStyle
        $backdrop.Data = [Windows.Media.Geometry]::Parse("M 0,0 L 17,0 A 5,5 0 0 1 22,5 L 22,22 Z")
        # Keyhole centred on the triangle's incentre (15.56, 6.44) so it keeps the same
        # 1.8 clearance from all three edges
        $keyhole.Data = [Windows.Media.Geometry]::Parse("M 13.61,9.225 A 3.4,3.4 0 1 1 17.51,9.225")
        $keyhole.StrokeThickness = 2.4
    }

    $keyhole.StrokeStartLineCap = [Windows.Media.PenLineCap]::Round
    $keyhole.StrokeEndLineCap = [Windows.Media.PenLineCap]::Round
    [void]$artwork.Children.Add($backdrop)
    [void]$artwork.Children.Add($keyhole)

    $badge = New-Object Windows.Controls.Viewbox
    $badge.Width = $Size
    $badge.Height = $Size
    $badge.Child = $artwork
    $badge.ToolTip = "Free and Open Source Software"

    return $badge
}

function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX package pattern: $Name"

    # We explicitly loop through packages instead of using the pipeline because PowerShell 7 pipeline binding
    # for Remove-AppxPackage fails silently, and Get-AppxPackage -AllUsers returns duplicate objects for each user profile.
    $pkgs = Get-AppxPackage "*$Name*" -AllUsers | Sort-Object -Property PackageFullName -Unique
    if ($null -ne $pkgs) {
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "Failed to remove AppX package $($pkg.PackageFullName): $($_.Exception.Message)"
            }
        }
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX removal completed for package pattern: $Name"
}

function Remove-WinUtilProvisionedAPPX {
    <#

    .SYNOPSIS
        Removes all AppX provisioned packages that match the given names

    .PARAMETER PackageList
        An array of names of the APPX packages to remove

    .EXAMPLE
        Remove-WinUtilProvisionedAPPX -PackageList @("Microsoft.Microsoft3DViewer", "Microsoft.WindowsCalculator")

    #>
    param (
        [string[]]$PackageList
    )

    if ($null -eq $PackageList -or $PackageList.Count -eq 0) {
        return
    }

    Write-Host "`nRemoving provisioned packages..."
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX provisioned packages: $($PackageList -join ', ')"

    # DISM cmdlets like Get-AppxProvisionedPackage often fail with "Class not registered" or hang in PowerShell 7.
    # We shell out to Windows PowerShell 5.1 (powershell.exe) to reliably remove the provisioned packages.
    $ps5Command = {
        $pkgs = $args
        $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($Package in $pkgs) {
            $provs = $provisionedPackages |
                Where-Object DisplayName -Like "*$Package*"

            if ($null -ne $provs) {
                foreach ($prov in $provs) {
                    try {
                        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                    }
                    catch {
                        $failures.Add("Failed to remove provisioned AppX package $($prov.PackageName): $($_.Exception.Message)")
                    }
                }
            }
        }

        if ($failures.Count -gt 0) {
            throw ($failures -join [Environment]::NewLine)
        }
    }

    $removalOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $PackageList 2>&1
    if ($LASTEXITCODE -ne 0 -or $null -ne $removalOutput) {
        $failureDetails = ($removalOutput | Out-String).Trim()
        $errorMessage = "AppX provisioned package removal failed: $failureDetails"
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message $errorMessage
        throw $errorMessage
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX provisioned package removal completed."
}

function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set winutil checkboxs to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )
    $selectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedApps + $sync.selectedTweaks + $sync.selectedFeatures + $sync.selectedAppx), [StringComparer]::OrdinalIgnoreCase)

    foreach ($syncEntry in $sync.GetEnumerator()) {
        if ($syncEntry.Value -is [System.Windows.Controls.CheckBox] -and $syncEntry.Name -notlike "WPFToggle*" -and $syncEntry.Name -like $checkboxfilterpattern) {
            $checkboxName = $syncEntry.Key
            $sync.$checkboxName.IsChecked = $selectedSet.Contains($checkboxName)
        }
    }

    # Update Installs tab UI values
    $count = $sync.SelectedApps.Count
    $sync.WPFselectedAppsButton.Content = "Selected Apps: $count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import - toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedToggles), [StringComparer]::OrdinalIgnoreCase)
        foreach ($toggle in $sync.GetEnumerator()) {
            if ($toggle.Key -like "WPFToggle*" -and $toggle.Value -is [System.Windows.Controls.CheckBox] -and $importedToggles.Contains($toggle.Key)) {
                $sync[$toggle.Key].IsChecked = $true
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}

function Save-WinUtilFile {
    <#
    .SYNOPSIS
        Downloads a file and reports transfer progress.
    #>
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [scriptblock]$ProgressCallback
    )

    $response = $null
    $responseStream = $null
    $outputStream = $null

    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $responseStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Create($DestinationPath)
        $buffer = New-Object byte[] 81920
        $downloadedBytes = 0L
        $lastPercent = -1

        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead

            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [int](($downloadedBytes / $totalBytes) * 100))
                if ($percent -ne $lastPercent) {
                    & $ProgressCallback $percent
                    $lastPercent = $percent
                }
            }
        }

        if ($lastPercent -ne 100) {
            & $ProgressCallback 100
        }
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $responseStream) {
            $responseStream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Set-WinUtilAppCategoryFilter {
    <#
        .SYNOPSIS
            Applies the Install tab category filter and syncs the chip states to it

        .DESCRIPTION
            The selection lives in $sync.SelectedAppCategories. An empty selection means every
            category is shown, which is what the All chip represents. The category filter and the
            search box are independent: this only touches categories, and the current search text
            is reapplied on top.

        .PARAMETER Category
            The category to act on. An empty value clears the filter back to All.

        .PARAMETER Additive
            Toggles this category in or out of the current selection instead of replacing it.
            Bound to ctrl click.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Category = "",

        [Parameter(Mandatory = $false)]
        [switch]$Additive
    )

    if ($null -eq $sync.SelectedAppCategories) {
        $sync.SelectedAppCategories = [System.Collections.Generic.List[string]]::new()
    }
    $selected = $sync.SelectedAppCategories

    if ([string]::IsNullOrWhiteSpace($Category)) {
        $selected.Clear()
    } elseif ($Additive) {
        if ($selected.Contains($Category)) {
            [void]$selected.Remove($Category)
        } else {
            $selected.Add($Category)
        }
    } elseif ($selected.Count -eq 1 -and $selected.Contains($Category)) {
        # Clicking the only active category again clears the filter
        $selected.Clear()
    } else {
        $selected.Clear()
        $selected.Add($Category)
    }

    Update-WinUtilAppCategoryChip
    Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Categories $selected.ToArray()
}

function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)

    if($DNSProvider -eq "Default") {
        Write-WinUtilLog -Component "DNS" -Message "DNS provider is Default; no DNS changes applied."
        return $true
    }

    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces:"
        Write-Host $($Adapters | Out-String)
        Write-WinUtilLog -Component "DNS" -Message "Setting DNS provider to $DNSProvider for $(@($Adapters).Count) active adapter(s)."

        if($DNSProvider -ne "DHCP") {
            $dns = $sync.configs.dns.$DNSProvider
            if($null -eq $dns) {
                Write-Warning "DNS provider $DNSProvider was not found in configuration."
                Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not found in configuration."
                return $false
            }
        }

        $dohSupported = [bool](Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
        if ($DNSProvider -ne "DHCP" -and $dns.DohOnly -and -not $dohSupported) {
            Write-Warning "DNS provider $DNSProvider requires DNS over HTTPS, which is not supported on this system."
            Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider requires DNS over HTTPS, which is not supported on this system."
            return $false
        }

        $dnscacheBase = "HKLM:\System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters"

        Foreach ($Adapter in $Adapters) {
            $interfaceParams = "$dnscacheBase\$($Adapter.InterfaceGuid)"

            if($DNSProvider -eq "DHCP") {
                Write-WinUtilLog -Component "DNS" -Message "Resetting DNS to DHCP on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex))."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
                netsh interface ip set dnsservers name="$($Adapter.Name)" source=dhcp
                netsh interface ipv6 set dnsservers name="$($Adapter.Name)" source=dhcp

                $dohInterfaceSettings = "$interfaceParams\DohInterfaceSettings"
                if (Test-Path $dohInterfaceSettings) {
                    if ($dohSupported) {
                        $dohServerAddresses = @(
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh" -ErrorAction SilentlyContinue
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh6" -ErrorAction SilentlyContinue
                        ) | Select-Object -ExpandProperty PSChildName -Unique

                        foreach ($ip in $dohServerAddresses) {
                            if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {
                                Write-WinUtilLog -Component "DNS" -Message "Removing DoH registration for $ip."
                                Remove-DnsClientDohServerAddress -ServerAddress $ip -Confirm:$false -ErrorAction Stop
                            }
                        }
                    }

                    Remove-Item -Path $dohInterfaceSettings -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                $ipv4Addresses = @(@($dns.Primary, $dns.Secondary) | Where-Object { $_ })
                $ipv6Addresses = @(@($dns.Primary6, $dns.Secondary6) | Where-Object { $_ })

                if ($dohSupported -and $dns.DohTemplate) {
                    try {
                        $ips = @($dns.Primary, $dns.Secondary, $dns.Primary6, $dns.Secondary6) | Where-Object { $_ }
                        foreach ($ip in $ips) {
                            $dohTemplate = if ($dns.SecondaryDohTemplate -and @($dns.Secondary, $dns.Secondary6) -contains $ip) {
                                $dns.SecondaryDohTemplate
                            } else {
                                $dns.DohTemplate
                            }
                            $existing = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
                            if ($existing) {
                                Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                            } else {
                                Write-WinUtilLog -Component "DNS" -Message "Registering DoH template for $ip."
                                Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                            }

                            $leaf = if ($ip.Contains(':')) { 'Doh6' } else { 'Doh' }
                            $regPath = "$interfaceParams\DohInterfaceSettings\$leaf\$ip"

                            if (-not (Test-Path $regPath)) {
                                New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
                            }
                            New-ItemProperty -Path $regPath -Name "DohFlags" -Value 1 -PropertyType QWord -Force -ErrorAction Stop | Out-Null
                        }
                    } catch {
                        if ($dns.DohOnly) {
                            throw
                        }

                        Write-Warning "DNS over HTTPS setup for provider $DNSProvider failed; continuing with plain DNS."
                        Write-WinUtilLog -Level "WARN" -Component "DNS" -Message "DNS over HTTPS setup for provider $DNSProvider failed; continuing with plain DNS: $($psitem.Exception.Message)"
                    }
                }

                Write-WinUtilLog -Component "DNS" -Message "Setting IPv4 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary), $($dns.Secondary)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $ipv4Addresses -ErrorAction Stop
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv6 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary6), $($dns.Secondary6)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $ipv6Addresses -ErrorAction Stop
            }
        }
        if ($DNSProvider -ne "DHCP" -and $dohSupported -and $dns.DohTemplate) {
            Clear-DnsClientCache
        }
        Write-WinUtilLog -Component "DNS" -Message "DNS provider change completed: $DNSProvider"
        return $true
    } catch {
        Write-Warning "DNS provider $DNSProvider was not completed because an error occurred."
        Write-Warning $psitem.Exception.Message
        Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not completed: $($psitem.Exception.Message)"
        return $false
    }
}

function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found. Creating..."
            Write-WinUtilLog -Component "Registry" -Message "Creating registry path: $Path"
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Write-WinUtilLog -Component "Registry" -Message "Setting $Path\$Name ($Type) to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Write-WinUtilLog -Component "Registry" -Message "Removing $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception."
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Security exception while changing $Path\$Name to $Value`: $($psitem.Exception.Message)"
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Registry item not found while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
       Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unauthorized while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unhandled exception while changing $Path\$Name`: $($psitem.Exception.Message)"
    }
}

function Set-WinUtilRegistryComboState {
    <#
    .SYNOPSIS
        Applies and verifies a config-defined registry combo-box state.

    .PARAMETER Registry
        Registry settings containing a value mapping for each supported state.

    .PARAMETER State
        The state name to apply.
    #>
    param(
        [Parameter(Mandatory)]
        $Registry,

        [Parameter(Mandatory)]
        [string]$State
    )

    if ($Registry[0].Values.PSObject.Properties.Name -notcontains $State) {
        throw "Unknown registry state '$State'."
    }

    # Preserve exact prior values so a partial update can be rolled back.
    $previousValues = foreach ($setting in @($Registry)) {
        $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
        [pscustomobject]@{ Setting = $setting; Exists = $currentValue.Exists; Value = $currentValue.Value }
    }

    try {
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $previousValue = $previousValues | Where-Object Setting -EQ $setting
            if ($configuredValue -ne "<RemoveEntry>" -or $previousValue.Exists) {
                Set-WinUtilRegistry -Name $setting.Name -Path $setting.Path -Type $setting.Type -Value $configuredValue
            }
        }

        # Set-WinUtilRegistry reports write errors without throwing, so verify each result explicitly.
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
            $writeMatches = if ($configuredValue -eq "<RemoveEntry>") {
                -not $currentValue.Exists
            } else {
                $currentValue.Exists -and [string]$currentValue.Value -eq [string]$configuredValue
            }
            if (-not $writeMatches) {
                throw "The registry values did not match the requested state."
            }
        }
    } catch {
        $applyError = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($applyError)) {
            $applyError = "The registry values did not match the requested state."
        }
        $rollbackFailed = $false
        foreach ($previousValue in $previousValues) {
            try {
                $currentValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($previousValue.Exists -or $currentValue.Exists) {
                    $rollbackValue = if ($previousValue.Exists) { $previousValue.Value } else { "<RemoveEntry>" }
                    Set-WinUtilRegistry -Name $previousValue.Setting.Name -Path $previousValue.Setting.Path -Type $previousValue.Setting.Type -Value $rollbackValue
                }
                $restoredValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($restoredValue.Exists -ne $previousValue.Exists -or ($restoredValue.Exists -and [string]$restoredValue.Value -ne [string]$previousValue.Value)) {
                    $rollbackFailed = $true
                }
            } catch {
                $rollbackFailed = $true
            }
        }
        if ($rollbackFailed) {
            throw "Unable to apply registry state '$State': $applyError. The previous registry state could not be restored."
        }
        throw "Unable to apply registry state '$State': $applyError"
    }
}

Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"
        Write-WinUtilLog -Component "Service" -Message "Setting service $Name startup type to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        if (($service.PSObject.Properties.Name -contains "StartType") -and ([string]$service.StartType -eq [string]$StartupType) ) {
            Write-Host "Service $Name is already set to $StartupType"
            Write-WinUtilLog -Component "Service" -Message "Service $Name startup type is already $StartupType; no change needed."
            return
        }

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start= delayed-auto
            if ($LASTEXITCODE -ne 0) {
                throw "sc.exe config failed with exit code $LASTEXITCODE"
            }
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
        Write-WinUtilLog -Component "Service" -Message "Service $Name startup type set to $StartupType"
    } catch {
        if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
            Write-Warning "Service $Name was not found."
            Write-WinUtilLog -Level "WARN" -Component "Service" -Message "Service $Name was not found."
        } else {
            Write-Warning "Unable to set $Name due to unhandled exception."
            Write-Warning $_.Exception.Message
            Write-WinUtilLog -Level "ERROR" -Component "Service" -Message "Unable to set service $Name to $StartupType`: $($_.Exception.Message)"
        }
    }

}

function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                if (-not $sync["logorender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                if (-not $sync["checkmarkrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                if (-not $sync["warningrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}

function Set-WinUtilTweaksProgressIndicator {
    <#
    .SYNOPSIS
        Shows, updates, or hides the window-level progress indicator used by long-running
        workflows such as app management, Tweaks, AppX management, and Win11 Creator.
        It lives outside the TabControl, so it stays visible no matter which tab is active.
    .PARAMETER Visible
        Whether the indicator should be shown or hidden.
    .PARAMETER Label
        The text to display above the progress bar.
    .PARAMETER Percent
        The percentage of the progress bar that should be filled (0-100).
    #>
    param(
        [bool]$Visible,
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent
    )

    if ($null -eq $sync.form -or $null -eq $sync.form.Dispatcher) {
        return
    }

    $indicatorVisible = if ($Visible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $indicatorLabel = $Label
    $hasLabel = $PSBoundParameters.ContainsKey('Label')
    $hasPercent = $PSBoundParameters.ContainsKey('Percent')

    Invoke-WPFUIThread -ScriptBlock {
        $sync.WPFTweaksProgressBar.Visibility = $indicatorVisible
        if ($hasLabel) {
            $sync.WPFTweaksProgressLabel.Text = $indicatorLabel
        }
        if ($hasPercent) {
            $sync.WPFTweaksProgressValue.Value = $Percent
        }
    }
}

function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "WinUtil"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0
    $linkHoverBrush = $LinkHoverForegroundColor

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            Start-Process $eventSender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $linkHoverBrush
            $eventSender.FontSize = ($FontSize + ($FontSize / 4))
            $eventSender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $LinkForegroundColor
            $eventSender.FontSize = $FontSize
            $eventSender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}

function Show-WinUtilMessage {
    <#
    .SYNOPSIS
        Shows a WinUtil message box and returns the selected result.
    #>
    param (
        [string]$Message,
        [string]$Title = "Winutil",
        $Button = "OK",
        $Icon = "Information"
    )

    [System.Windows.MessageBox]::Show($Message, $Title, $Button, $Icon)
}

function Invoke-WinUtilInstallAppRenderBatch {
    param(
        [Parameter(Mandatory = $true)]
        $CategoryBatch
    )

    foreach ($appKey in $CategoryBatch.AppKeys) {
        $sync.$appKey = Initialize-InstallAppEntry -TargetElement $CategoryBatch.TargetElement -AppKey $appKey
    }

    # Entries render in batches, so a filter that is already active has to be applied to each new
    # batch. Categories count as an active filter just like search text does.
    if ($sync.currentTab -eq "Install" -and $sync.SearchBar) {
        $selectedCategories = if ($sync.SelectedAppCategories) { $sync.SelectedAppCategories.ToArray() } else { @() }

        if (-not [string]::IsNullOrWhiteSpace($sync.SearchBar.Text) -or $selectedCategories.Count -gt 0) {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Categories $selectedCategories
        }
    }
}

function Complete-WinUtilInstallAppRendering {
    $sync.InstallAppEntriesRendered = $true
}

function Invoke-WinUtilInstallAppRenderNextBatch {
    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    Complete-WinUtilInstallAppRendering
}

function Start-WinUtilInstallAppRendering {
    if ($null -eq $sync.InstallAppRenderQueue) {
        return
    }

    $sync.InstallAppEntriesRendered = $false

    if ($sync.Form -and $sync.Form.Dispatcher) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    while ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    Complete-WinUtilInstallAppRendering
}

function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if WinGet and/or Choco are installed

    .PARAMETER winget
        Check if WinGet is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    if ($winget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---        WinGet is installed          ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      WinGet is not installed        ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---      Chocolatey is installed        ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey is not installed      ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}

function Update-WinUtilAppCategoryChip {
    <#
        .SYNOPSIS
            Pushes the current category selection onto the Install tab filter chips

        .DESCRIPTION
            The chips are toggle buttons, so their checked state has to follow the selection
            rather than whatever the last click did to them. The All chip is checked when no
            category is selected.
    #>
    $selected = $sync.SelectedAppCategories
    if ($null -eq $selected) { return }

    foreach ($chip in $sync.AppCategoryChips) {
        $control = $sync[$chip.Name]
        if ($null -eq $control) { continue }
        $control.IsChecked = if ($chip.Category) { $selected.Contains($chip.Category) } else { $selected.Count -eq 0 }
    }
}

function Update-WinUtilSelections {
    param(
        [Parameter(Mandatory)]
        [string[]]$flatJson,

        [switch]$Replace,

        [switch]$SkipUnknown
    )

    $nextSelections = @{
        selectedApps     = [System.Collections.Generic.List[string]]::new()
        selectedTweaks   = [System.Collections.Generic.List[string]]::new()
        selectedToggles  = [System.Collections.Generic.List[string]]::new()
        selectedFeatures = [System.Collections.Generic.List[string]]::new()
        selectedAppx     = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($cbkey in $flatJson) {

        $listName = switch -Regex ($cbkey) {
            '^WPFInstall' { 'selectedApps' }
            '^WPFTweaks'  { 'selectedTweaks' }
            '^WPFToggle'  { 'selectedToggles' }
            '^WPFFeature' { 'selectedFeatures' }
            '^WPFAppx'    { 'selectedAppx' }
        }

        if (-not $listName) {
            if ($SkipUnknown) {
                $cbkey
                continue
            }
            throw "Unsupported selection key '$cbkey'."
        }

        $isKnownSelection = switch ($listName) {
            'selectedApps' {
                $sync.configs.applicationsHashtable.ContainsKey($cbkey)
            }
            'selectedTweaks' {
                $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey]
            }
            'selectedToggles' {
                $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey]
            }
            'selectedFeatures' {
                $null -ne $sync.configs.feature.PSObject.Properties[$cbkey]
            }
            'selectedAppx' {
                $sync.configs.appxHashtable.ContainsKey($cbkey)
            }
        }

        if (-not $isKnownSelection) {
            if ($SkipUnknown) {
                $cbkey
                continue
            }
            throw "Unknown selection key '$cbkey'."
        }

        $nextSelections[$listName].Add($cbkey)
    }

    $validSelectionCount = ($nextSelections.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    if ($SkipUnknown -and $validSelectionCount -eq 0) {
        return
    }

    if ($Replace) {
        foreach ($listName in $nextSelections.Keys) {
            $sync[$listName] = $nextSelections[$listName]
        }
        return
    }

    foreach ($listName in $nextSelections.Keys) {
        foreach ($cbkey in $nextSelections[$listName]) {
            $sync.$listName.Add($cbkey)
        }
    }
}

function Write-WinUtilLog {
    <#

    .SYNOPSIS
        Writes a timestamped WinUtil log entry to the active session log.

    .PARAMETER Message
        The message to write.

    .PARAMETER Level
        The severity level for the log entry.

    .PARAMETER Component
        The WinUtil component producing the log entry.

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",

        [string]$Component = "WinUtil"
    )

    try {
        $logPath = $null
        $transcriptPath = $null
        if ($null -ne $sync -and $sync.ContainsKey("logPath")) {
            $logPath = $sync.logPath
        }

        if ($null -ne $sync -and $sync.ContainsKey("transcriptPath")) {
            $transcriptPath = $sync.transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($transcriptPath)) {
            $logPath = $transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and $null -ne $sync -and $sync.ContainsKey("winutildir")) {
            $logDirectory = Join-Path $sync.winutildir "logs"
            $logPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            $sync.logPath = $logPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($env:LocalAppData)) {
            if ([string]::IsNullOrWhiteSpace($script:WinUtilLogPath)) {
                $logDirectory = Join-Path (Join-Path $env:LocalAppData "winutil") "logs"
                $script:WinUtilLogPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            }
            $logPath = $script:WinUtilLogPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath)) {
            return
        }

        $logDirectory = Split-Path -Path $logPath -Parent
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $line = "[$timestamp] [$Level] [$Component] $Message"

        if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and $logPath -eq $transcriptPath) {
            Write-Host $line
            return
        }

        try {
            Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch [System.IO.IOException] {
            Write-Host $line
        }
    } catch {
        Write-Warning "Unable to write WinUtil log entry: $($_.Exception.Message)"
    }
}

function Initialize-WPFUI {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appscategory"{
            Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1

            # Create and configure a popup for displaying selected apps
            $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
            $selectedAppsPopup.IsOpen = $false
            $selectedAppsPopup.PlacementTarget = $sync.WPFselectedAppsButton
            $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $selectedAppsPopup.AllowsTransparency = $true

            # Style the popup with a border and background
            $selectedAppsBorder = New-Object Windows.Controls.Border
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
            $selectedAppsBorder.Width = 200
            $selectedAppsBorder.Padding = 5
            $selectedAppsPopup.Child = $selectedAppsBorder
            $sync.selectedAppsPopup = $selectedAppsPopup

            # Add a stack panel inside the popup's border to organize its child elements
            $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
            $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

            # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
            $sync.WPFselectedAppsButton.Add_MouseLeave({
                if (-not $sync.selectedAppsPopup.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })
            $selectedAppsPopup.Add_MouseLeave({
                if (-not $sync.WPFselectedAppsButton.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })

            # Creates the popup that is displayed when the user right-clicks on an app entry
            # This popup contains buttons for installing, uninstalling, and viewing app information

            $appPopup = New-Object Windows.Controls.Primitives.Popup
            $appPopup.StaysOpen = $false
            $appPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $appPopup.AllowsTransparency = $true
            # Store the popup globally so the position can be set later
            $sync.appPopup = $appPopup

            $appPopupStackPanel = New-Object Windows.Controls.StackPanel
            $appPopupStackPanel.Orientation = "Horizontal"
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopup.IsOpen = $false
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 }
            )
            foreach ($button in $appButtons) {
                $newButton = New-Object Windows.Controls.Button
                $newButton.Style = $sync.Form.Resources.AppEntryButtonStyle
                $newButton.Content = $button.Icon
                $appPopupStackPanel.Children.Add($newButton) | Out-Null

                # Dynamically load the selected app object so the buttons can be reused and do not need to be created for each app
                switch ($button.Name) {
                    "Install" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Install or Upgrade $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFInstall -PackagesToInstall $appObject
                        })
                    }
                    "Uninstall" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Uninstall $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFUnInstall -PackagesToUninstall $appObject
                        })
                    }
                    "Info" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Open the application's website in your default browser`n$($appObject.link)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Start-Process $appObject.link
                        })
                    }
                }
            }
        }
        "appspanel" {
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $sync.configs.applicationsHashtable
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}


function Invoke-WinUtilAutoRun {
    <#

    .SYNOPSIS
        Runs Install, Tweaks, and Features with optional UI invocation.
    #>

    function BusyWait {
        Start-Sleep -Milliseconds 100
        while ($sync.ProcessRunning) {
            Start-Sleep -Milliseconds 100
        }
    }

    if ($sync.selectedTweaks.Count -gt 0) {
        Write-Host "Applying tweaks..."
        Invoke-WPFtweaksbutton
        BusyWait
    }

    if ($sync.selectedFeatures.Count -gt 0) {
        Write-Host "Applying features..."
        Invoke-WPFFeatureInstall
        BusyWait
    }

    if ($sync.selectedApps.Count -gt 0) {
        Write-Host "Installing applications..."
        Invoke-WPFInstall
        BusyWait
    }

    if ($sync.selectedAppx.Count -gt 0) {
        Write-Host "Removing AppX packages..."
        Invoke-WPFAppxRemoval
        BusyWait
    }

    Write-Host "Done."
}

function Invoke-WPFAppxInstall {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "An AppX process is currently running." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "No AppX Package selected" -Title "Error" -Button "OK" -Icon "Error"
        return
    }

    $selected = @($sync.selectedAppx)
    $apps = $sync.configs.appxHashtable

    $sync.ProcessRunning = $true
    Invoke-WPFRunspace -ParameterList @(("selected", $selected), ("apps", $apps)) -ScriptBlock {
        param($selected, $apps)

        $totalPackages = @($selected).Count
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        try {
            Write-WinUtilLog -Component "AppX" -Message "Starting AppX install for $totalPackages selected package(s)."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing AppX install (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
            }

            for ($index = 0; $index -lt $totalPackages; $index++) {
                $key = $selected[$index]
                $app = $apps[$key]
                $position = $index + 1
                $startPercent = [int](($index / $totalPackages) * 100)

                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $($app.Content) ($position/$totalPackages)" -Percent $startPercent
                }
                Write-Host "Installing $($app.Content)"
                Install-WinUtilAPPX -Name $app.PackageId -StoreId $app.StoreId

                $completedPercent = [int](($position / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $($app.Content) ($position/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            Write-Host "================================="
            Write-Host "--   AppX Install Finished   ---"
            Write-Host "================================="
            Write-WinUtilLog -Component "AppX" -Message "AppX install finished."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX install finished" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "AppX install failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX install failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        }
        finally {
            $sync.ProcessRunning = $false
        }
    }
}

function Invoke-WPFAppxRemoval {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "An AppX process is currently running." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "No AppX Package selected" -Title "Error" -Button "OK" -Icon "Error"
        return
    }

    $selected = @($sync.selectedAppx)
    $apps = $sync.configs.appxHashtable

    $sync.ProcessRunning = $true
    Invoke-WPFRunspace -ParameterList @(("selected", $selected), ("apps", $apps)) -ScriptBlock {
        param($selected, $apps)

        $totalPackages = @($selected).Count
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        $packageList = [System.Collections.Generic.List[string]]::new()

        try {
            Write-WinUtilLog -Component "AppX" -Message "Starting AppX removal for $totalPackages selected package(s)."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing AppX removal (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
            }

            for ($index = 0; $index -lt $totalPackages; $index++) {
                $key = $selected[$index]
                $app = $apps[$key]
                $position = $index + 1
                $startPercent = [int](($index / $totalPackages) * 90)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Removing $($app.Content) ($position/$totalPackages)" -Percent $startPercent
                }

                if ($key -eq "WPFAppxMicrosoft_XboxGamingOverlay") {
                    # Making sure Game Bar isn't running
                    Write-WinUtilLog -Component "AppX" -Message "Stopping GameBarFTServer before removing Xbox Gaming Overlay."
                    Stop-Process -Name GameBarFTServer -Force -Confirm:$false -ErrorAction SilentlyContinue

                    # This stops annoying ms-gamebar popup when launching games.
                    Write-WinUtilLog -Component "AppX" -Message "Disabling Game DVR capture before removing Xbox Gaming Overlay."
                    Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR -Name AppCaptureEnabled -Value 0
                }

                if ($key -eq "WPFAppxMicrosoft_WindowsNotepad") {
                    Write-WinUtilLog -Component "AppX" -Message "Stopping dllhost before removing Notepad."
                    Stop-Process -Name dllhost -Force -Confirm:$false -ErrorAction SilentlyContinue
                }

                Write-Host "Removing $($app.Content)"
                Write-WinUtilLog -Component "AppX" -Message "Removing $($app.Content) ($($app.PackageId))."
                Remove-WinUtilAPPX -Name $app.PackageId
                $packageList.Add($app.PackageId)

                if ($key -eq "WPFAppxMSTeams") {
                    # Uninstalls Microsoft Teams Meeting Add-in for Microsoft Office
                    Write-WinUtilLog -Component "AppX" -Message "Uninstalling Microsoft Teams meeting add-in package."
                    Get-Package -Name "Microsoft Teams*" -ErrorAction SilentlyContinue | Uninstall-Package -Force
                }

                $completedPercent = [int](($position / $totalPackages) * 90)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Removed $($app.Content) ($position/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            if ($packageList.Count -gt 0) {
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Removing provisioned AppX packages" -Percent 90
                }
                Remove-WinUtilProvisionedAPPX -PackageList $packageList.ToArray()
            }

            Write-Host "================================="
            Write-Host "--   AppX Removal Finished   ---"
            Write-Host "================================="
            Write-WinUtilLog -Component "AppX" -Message "AppX removal finished."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX removal finished" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "AppX removal failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX removal failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        }
        finally {
            $sync.ProcessRunning = $false
        }

    } | Out-Null
}

function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","Chris Titus Tech's Windows Utility","OK","Info")
    if (-not $sync.ProcessRunning -and -not $sync.Win11ISOProcessRunning) {
        Set-WinUtilTweaksProgressIndicator -Visible $false
    }

    # Check if button is defined in feature config with function or InvokeScript
    if ($sync.configs.feature.$Button) {
        $buttonConfig = $sync.configs.feature.$Button

        # If button has a function defined, call it
        if ($buttonConfig.function) {
            $functionName = $buttonConfig.function
            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName
                return
            }
        }

        # If button has InvokeScript defined, execute the scripts
        if ($buttonConfig.InvokeScript -and $buttonConfig.InvokeScript.Count -gt 0) {
            foreach ($script in $buttonConfig.InvokeScript) {
                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
                }
            }
            return
        }
    }

    # Fallback to hard-coded switch for buttons not in feature.json
    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFAdvanced" {Invoke-WPFPresets "Advanced" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -Enable}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFUpdatesdefault" {Invoke-WPFUpdatesdefault}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFAppxRemoval" {Invoke-WPFTab "WPFTab6BT"}
        "WPFBackToTweaks" {Invoke-WPFTab "WPFTab2BT"}
        "WPFInstallSelectedAppx" {Invoke-WPFAppxInstall}
        "WPFRemoveSelectedAppx" {Invoke-WPFAppxRemoval}
        "WPFDefaultAppxSelection" {Invoke-WPFPresets "AppxDefault" -checkboxfilterpattern "WPFAppx*"}
        "WPFSelectAllAppx" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $true}
        }
        "WPFClearAppxSelection" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $false}
        }
        "WPFGetInstalledAppx" {
            $installedAppxPackages = Get-WinUtilInstalledAPPX
            foreach ($appx in $sync.configs.appxHashtable.GetEnumerator()) {
                if ($appx.Value.PackageId -in $installedAppxPackages) {
                    $sync.$($appx.Key).IsChecked = $true
                }
            }
        }
        "WPFCloseButton" {$sync.Form.Close(); Write-Host "Bye bye!"}
        "WPFMinimizeButton" {[Windows.SystemCommands]::MinimizeWindow($sync.Form)}
        "WPFMaximizeButton" {
            if ($sync.Form.WindowState -eq [Windows.WindowState]::Normal) {
                [Windows.SystemCommands]::MaximizeWindow($sync.Form)
            } else {
                [Windows.SystemCommands]::RestoreWindow($sync.Form)
            }
        }
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
    }
}

function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFFeatureInstall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ScriptBlock {
        $Features = $sync.selectedFeatures
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }

        $x = 0

        $Features | ForEach-Object {
            Invoke-WinUtilFeatureInstall $_
            $X++
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($x/$Features.Count) }
        }

        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }

        Write-Host "==================================="
        Write-Host "---   Features are Installed    ---"
        Write-Host "---  A Reboot may be required   ---"
        Write-Host "==================================="
    } | Out-Null
}

function Invoke-WPFFixesNetwork {
    netsh winsock reset
    netsh int ip reset
    Write-Host "Network Configuration has been Reset. Please restart your computer."
}

function Invoke-WPFFixesNTPPool {
    <#
    .SYNOPSIS
        Configures Windows to use pool.ntp.org for NTP synchronization

    .DESCRIPTION
        Replaces the default Windows NTP server (time.windows.com) with
        pool.ntp.org for improved time synchronization accuracy and reliability.
    #>

    Start-Service w32time
    w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL

    Restart-Service w32time
    w32tm /resync

    Write-Host "================================="
    Write-Host "-- NTP Configuration Complete ---"
    Write-Host "================================="
}

function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using the Invoke-WPFSystemRepair function
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
    Write-Host "Starting Windows Update Repair..."
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        Invoke-WPFSystemRepair
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate" -Name "AccountDomainSid" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate" -Name "PingID" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate" -Name "SusClientId" -ErrorAction SilentlyContinue
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Clearing ANY Windows Update Policy settings..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Reset Windows Update "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- Reset All Windows Update Settings to Stock -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}

function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes WinGet by running `choco install winget`
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall WinGet
    #>
    # Install Choco if not already present
    try {
        Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
        Write-Host "==> Starting WinGet Repair"
        Install-WinUtilWinget
    } catch {
        Write-Error "Failed to install WinGet: $_"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
    } finally {
        Write-Host "==> Finished WinGet Repair"
        Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    }

}

function Invoke-WPFGetInstalled {
    <#
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "[Invoke-WPFGetInstalled] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $managerPreference = $sync.preferences.packagemanager
    $operation = [Hashtable]::Synchronized(@{
        Checkboxes = @()
        Error = $null
    })
    $completeAction = [Action[hashtable, string]]{
        param(
            [hashtable]$completedOperation,
            [string]$completedCheckbox
        )
        try {
            if ($completedOperation.Error) {
                Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Get installed state failed: $($completedOperation.Error)"
                Write-Warning "Unable to get installed state: $($completedOperation.Error)"
                return
            }

            if ($completedCheckbox -eq "winget") {
                foreach ($checkboxName in $completedOperation.Checkboxes) {
                    if (-not $sync.selectedApps.Contains($checkboxName)) {
                        $sync.selectedApps.Add($checkboxName)
                    }
                }
                Reset-WPFCheckBoxes -checkboxfilterpattern "WPFInstall*"
            } else {
                foreach ($checkboxName in $completedOperation.Checkboxes) {
                    $sync.$checkboxName.ischecked = $True
                }
            }
        } finally {
            $sync.ProcessRunning = $false
            Set-WinUtilTaskbaritem -state "None"
        }
    }

    $sync.ProcessRunning = $true
    Set-WinUtilTaskbaritem -state "Indeterminate"
    try {
        Invoke-WPFRunspace -ParameterList @(
            ("managerPreference", $managerPreference),
            ("checkbox", $checkbox),
            ("operation", $operation),
            ("completeAction", $completeAction)
        ) -ScriptBlock {
            param (
                [string]$checkbox,
                [string]$managerPreference,
                [hashtable]$operation,
                [Action[hashtable, string]]$completeAction
            )
            try {
                if ($checkbox -eq "winget") {
                    switch ($managerPreference) {
                        "Choco" { $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox "choco"); break }
                        "Winget" { $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox $checkbox); break }
                    }
                } elseif ($checkbox -eq "tweaks") {
                    $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox $checkbox)
                }
            } catch {
                $operation.Error = $_.Exception.Message
            } finally {
                $sync.Form.Dispatcher.BeginInvoke($completeAction, [object[]]@($operation, $checkbox)) | Out-Null
            }
        }
    } catch {
        $operation.Error = $_.Exception.Message
        $completeAction.Invoke($operation, $checkbox)
    }
}

function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null
    )

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON Files (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $allConfs = ($sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures + $sync.selectedAppx) | ForEach-Object { [string]$_ }
                    if (-not $allConfs) {
                        [System.Windows.MessageBox]::Show(
                            "No settings are selected to export. Please select at least one app, tweak, toggle, feature, or AppX package before exporting.",
                            "Nothing to Export", "OK", "Warning")
                        return
                    }
                    $jsonFile = $allConfs | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://christitus.com/win) } -Config '$Config'""" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    $isLegacyConfig = $jsonFile -is [System.Management.Automation.PSCustomObject] -and
                        $null -ne $jsonFile.PSObject.Properties["Install"] -and
                        $null -ne $jsonFile.PSObject.Properties["WPFInstall"]
                    if ($isLegacyConfig) {
                        Write-WinUtilLog -Component "Impex" -Message "Detected legacy WinUtil config structure; flattening import object."
                        # Legacy exports stored checkbox keys in WPFInstall and duplicated package
                        # source metadata in Install. Current package IDs come from the app catalog,
                        # so only the selection-key properties are restored.
                        $flattenedJson = @(
                            foreach ($property in $jsonFile.PSObject.Properties) {
                                if ($property.Name -notmatch '^WPF(?:Install|Tweaks|Toggle|Feature|Appx)') {
                                    continue
                                }

                                foreach ($selection in @($property.Value)) {
                                    if ($selection -is [string] -and -not [string]::IsNullOrWhiteSpace($selection)) {
                                        $selection
                                    }
                                }
                            }
                        )
                    } else {
                        # New style config: flat array of strings
                        $flattenedJson = $jsonFile
                    }

                    if (-not $flattenedJson) {
                        [System.Windows.MessageBox]::Show(
                            "The selected file contains no settings to import. No changes have been made.",
                            "Empty Configuration", "OK", "Warning")
                        return
                    }

                    # Modern configs stay strict. Legacy configs can reference entries that no
                    # longer exist, so restore supported selections and report the retired keys.
                    if ($isLegacyConfig) {
                        $skippedSelections = @(Update-WinUtilSelections -flatJson $flattenedJson -Replace -SkipUnknown)

                        if ($skippedSelections.Count -gt 0) {
                            $skippedSummary = $skippedSelections -join ", "
                            Write-WinUtilLog -Component "Impex" -Level "WARN" -Message "Skipped unsupported legacy selections: $skippedSummary"
                        }

                        if ($skippedSelections.Count -eq @($flattenedJson).Count) {
                            if ($sync.Form) {
                                Show-WinUtilMessage -Message "This legacy configuration contains no settings supported by this version of WinUtil. No changes have been made." -Title "Unsupported Legacy Configuration" -Icon "Warning" | Out-Null
                            }
                            return
                        }

                        if ($skippedSelections.Count -gt 0) {
                            $skippedDisplay = @($skippedSelections | Select-Object -First 10) -join ", "
                            if ($skippedSelections.Count -gt 10) {
                                $skippedDisplay += "`n...and $($skippedSelections.Count - 10) more. See the WinUtil log for details."
                            }
                            if ($sync.Form) {
                                Show-WinUtilMessage -Message "Supported settings were imported. The following retired settings were skipped:`n`n$skippedDisplay" -Title "Legacy Configuration Partially Imported" -Icon "Warning" | Out-Null
                            }
                        }
                    } else {
                        # Build and validate every imported selection before replacing the current
                        # state. This keeps a malformed config from leaving partial selections behind.
                        Update-WinUtilSelections -flatJson $flattenedJson -Replace
                    }

                    if ($sync.Form) {
                        Reset-WPFCheckBoxes -doToggles $true
                    }
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}

function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [PSObject[]]$PackagesToInstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )


    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFInstall] An Install process is currently running."
        Show-WinUtilMessage -Message $msg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to install or upgrade."
        Show-WinUtilMessage -Message $WarningMsg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Install" -Message "Install requested for $(@($PackagesToInstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToInstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Install" -Message "Install selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $totalPackages = @($packagesWinget).Count + @($packagesChoco).Count
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        Write-WinUtilLog -Component "Install" -Message "Install package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count)"

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app install (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Install-WinUtilWinget
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    Install-WinUtilProgramWinget -Action Install -Programs @($program)
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $program ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing Chocolatey packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            Write-WinUtilLog -Component "Install" -Message "Install workflow completed."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install finished" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Install workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        } finally {
            if ($hasUI) {
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $true
                    }
                }
            }
            $sync.ProcessRunning = $False
        }
    } | Out-Null
}

function Invoke-WPFInstallUpgrade {
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco # Ensure Chocolatey is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'choco upgrade all -y'
    } else {
        Install-WinUtilWinget # Ensure WinGet is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList '-NoExit winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements'
    }
}

function Invoke-WPFOOSU {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "Another process is currently running." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $downloadPath = Join-Path $sync.winutildir "ooshutup10.exe"
    $sync.ProcessRunning = $true

    Invoke-WPFRunspace -ParameterList @(,("downloadPath", $downloadPath)) -ScriptBlock {
        param($downloadPath)

        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        try {
            Write-WinUtilLog -Component "OOSU" -Message "Downloading O&O ShutUp10++."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Downloading O&O ShutUp10++ (0%)" -Percent 0
            }

            Save-WinUtilFile -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -DestinationPath $downloadPath -ProgressCallback {
                param($percent)

                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Downloading O&O ShutUp10++ ($percent%)" -Percent $percent
                }
            }

            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Launching O&O ShutUp10++" -Percent 100
            }
            Start-Process -FilePath $downloadPath

            Write-WinUtilLog -Component "OOSU" -Message "O&O ShutUp10++ launched."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "O&O ShutUp10++ launched" -Percent 100
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "OOSU" -Message "O&O ShutUp10++ download failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "O&O ShutUp10++ download failed" -Percent 100
            }
            Write-Error "Couldn't download O&O ShutUp10. Please make sure you have an active Internet connection."
        }
        finally {
            $sync.ProcessRunning = $false
        }
    }
}

function Invoke-WPFPanelAutologin {
    Invoke-WebRequest -Uri https://live.sysinternals.com/Autologon.exe -OutFile "$winutildir\autologin.exe"
    Start-Process -FilePath "$winutildir\autologin.exe" -ArgumentList /accepteula
}

function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}

function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern so applying a preset replaces the current
    # state rather than merging with it
    switch ($checkboxfilterpattern) {
        "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
        "WPFInstall*" { $sync.selectedApps = [System.Collections.Generic.List[string]]::new() }
        "WPFAppx*" { $sync.selectedAppx = [System.Collections.Generic.List[string]]::new() }
        "WPFFeature*" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle*" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}

function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    [OutputType([System.IAsyncResult])]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    if (-not ("WinUtilRunspaceCleanup" -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation;

public sealed class WinUtilRunspaceCleanupState
{
    public PowerShell PowerShell { get; set; }
    public IAsyncResult Handle { get; set; }
}

public static class WinUtilRunspaceCleanup
{
    public static readonly System.Threading.WaitOrTimerCallback Callback = Cleanup;

    public static void Cleanup(object state, bool timedOut)
    {
        var cleanupState = state as WinUtilRunspaceCleanupState;
        if (cleanupState == null || cleanupState.PowerShell == null || cleanupState.Handle == null)
        {
            return;
        }

        try
        {
            cleanupState.PowerShell.EndInvoke(cleanupState.Handle);
        }
        catch
        {
        }
        finally
        {
            cleanupState.PowerShell.Dispose();
        }
    }
}
"@
    }

    Initialize-WinUtilRunspacePool | Out-Null

    # Create a PowerShell instance
    $powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    [void]$powershell.AddScript($ScriptBlock)
    [void]$powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        [void]$powershell.AddParameter($parameter[0], $parameter[1])
    }

    $powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $handle = $powershell.BeginInvoke()

    $cleanupState = [WinUtilRunspaceCleanupState]::new()
    $cleanupState.PowerShell = $powershell
    $cleanupState.Handle = $handle
    [System.Threading.ThreadPool]::RegisterWaitForSingleObject($handle.AsyncWaitHandle, [WinUtilRunspaceCleanup]::Callback, $cleanupState, -1, $true) | Out-Null

    # Return the handle
    return $handle
}

function Invoke-WPFSelectedCheckboxesUpdate ($type, $checkboxName) {
    $listName = switch -Regex ($checkboxName) {
        '^WPFInstall' { 'selectedApps' }
        '^WPFTweaks'  { 'selectedTweaks' }
        '^WPFToggle'  { 'selectedToggles' }
        '^WPFFeature' { 'selectedFeatures' }
        '^WPFAppx'    { 'selectedAppx' }
    }

    $selectionChanged = $false
    if ($type -eq "Add") {
        if (-not $sync.$listName.Contains($checkboxName)) {
            $sync.$listName.Add($checkboxName)
            $selectionChanged = $true
        }
    } else {
        $selectionChanged = $sync.$listName.Remove($checkboxName)
    }

    if ($listName -eq "selectedApps" -and $selectionChanged) {
        $sync.WPFselectedAppsButton.Content = "Selected Apps: $($sync.selectedApps.Count)"
        $sync.selectedAppsstackPanel.Children.Clear()
        $sync.selectedApps | Sort-Object | ForEach-Object {
            Add-SelectedAppsMenuItem -name $sync.configs.applicationsHashtable.$_.Content -key $_
        }
    }
}

function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -ScriptBlock {

        Invoke-WinUtilSSHServer

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}

function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM
        Checks for disk failure using Chkdsk

    .DESCRIPTION
        1. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
        2. SFC - scans protected system files for corruption and fixes them
        3. DISM - Repair a corrupted Windows operating system image
    #>

    Start-Process cmd.exe -ArgumentList "/c chkdsk /scan /perf" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c sfc /scannow" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c dism /online /cleanup-image /restorehealth" -NoNewWindow -Wait

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
}

function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    $sync.$tabNav.Items[$tabNumber].IsSelected = $true
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header
    Initialize-WinUtilTabContent -TabName $sync.currentTab

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset the search text, but keep the categories the chips are still showing as selected
        $selectedCategories = if ($sync.SelectedAppCategories) { $sync.SelectedAppCategories.ToArray() } else { @() }
        Find-AppsByNameOrDescription -SearchString "" -Categories $selectedCategories
    } elseif ($sync.currentTab -eq "Tweaks") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "AppX") {
        # Reset AppX tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    }

    # Show search bar in Install, Tweaks, and AppX tabs
    if ($tabNumber -eq 0 -or $tabNumber -eq 1 -or $tabNumber -eq 5) {
        $sync.SearchBar.Visibility = "Visible"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Visible"
        }
    } else {
        $sync.SearchBar.Visibility = "Collapsed"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Collapsed"
        }
        # Hide the clear button if it's visible
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
}

function Invoke-WPFToggleAllCategories {
    <#
        .SYNOPSIS
            Expands or collapses all categories in the Install tab

        .PARAMETER Action
            The action to perform: "Expand" or "Collapse"

        .DESCRIPTION
            This function iterates through all category containers in the Install tab
            and expands or collapses their WrapPanels while updating the toggle button labels
    #>

    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Expand", "Collapse")]
        [string]$Action
    )

    try {
        if ($null -eq $sync.ItemsControl) {
            Write-Warning "ItemsControl not initialized"
            return
        }

        $targetVisibility = if ($Action -eq "Expand") { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $targetPrefix = if ($Action -eq "Expand") { "-" } else { "+" }
        $sourcePrefix = if ($Action -eq "Expand") { "+" } else { "-" }

        # Iterate through all items in the ItemsControl
        $sync.ItemsControl.Items | ForEach-Object {
            $categoryContainer = $_

            # Check if this is a category container (StackPanel with children)
            if ($categoryContainer -is [System.Windows.Controls.StackPanel] -and $categoryContainer.Children.Count -ge 2) {
                # Get the WrapPanel (second child)
                $wrapPanel = $categoryContainer.Children[1]
                $wrapPanel.Visibility = $targetVisibility

                # Update the label to show the correct state
                $categoryLabel = $categoryContainer.Children[0]
                if ($categoryLabel.Content -like "$sourcePrefix*") {
                    $escapedSourcePrefix = [regex]::Escape($sourcePrefix)
                    $categoryLabel.Content = $categoryLabel.Content -replace "^$escapedSourcePrefix ", "$targetPrefix "
                }
            }
        }
    }
    catch {
        Write-Error "Error toggling categories: $_"
    }
}

function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "[Invoke-WPFtweaksbutton] Install process is currently running."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = $sync.selectedTweaks
  $dnsProvider = $sync["WPFchangedns"].text
  if (-not ($dnsProvider)) {
    $dnsProvider = "Default"
  }
  $restorePointTweak = "WPFTweaksRestorePoint"
  $restorePointSelected = $Tweaks -contains $restorePointTweak
  $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
  $totalSteps = [Math]::Max($Tweaks.Count, 1)
  $completedSteps = 0
  Write-WinUtilLog -Component "Tweaks" -Message "Tweaks requested: $(@($Tweaks).Count) selected tweak(s), DNS provider: $dnsProvider"

  if ($tweaks.count -eq 0 -and $dnsProvider -eq "Default") {
    $msg = "Please check the tweaks you wish to perform."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  if ($restorePointSelected) {
    $sync.ProcessRunning = $true

    if ($Tweaks.Count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Creating restore point" -Percent 0
    Write-WinUtilLog -Component "Tweaks" -Message "Creating restore point before applying selected tweaks."
    Invoke-WinUtilTweaks $restorePointTweak
    $completedSteps = 1

    if ($tweaksToRun.Count -eq 0 -and $dnsProvider -eq "Default") {
      Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Tweaks finished" -Percent 100
      $sync.ProcessRunning = $false
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
      Write-Host "================================="
      Write-Host "--     Tweaks are Finished    ---"
      Write-Host "================================="
      Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed after restore point."
      return
    }
  }

  # The leading "," in the ParameterList is necessary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  Invoke-WPFRunspace -ParameterList @(("tweaks", $tweaksToRun), ("dnsProvider", $dnsProvider), ("completedSteps", $completedSteps), ("totalSteps", $totalSteps)) -ScriptBlock {
    param($tweaks, $dnsProvider, $completedSteps, $totalSteps)

    $sync.ProcessRunning = $true

    if ($completedSteps -eq 0) {
      if ($Tweaks.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
      } else {
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
      }
    }

    if ($dnsProvider -ne "Default") {
      $dnsResult = @(Set-WinUtilDNS -DNSProvider $dnsProvider)
      if ($dnsResult[-1] -ne $true) {
        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "DNS change failed" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        Write-WinUtilLog -Level "ERROR" -Component "Tweaks" -Message "Tweaks workflow stopped because the DNS change failed."
        return
      }
    }

    for ($i = 0; $i -lt $tweaks.Count; $i++) {
      Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Applying $($tweaks[$i]) ($($completedSteps + 1)/$totalSteps)" -Percent ($completedSteps / $totalSteps * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $completedSteps++
      $progress = $completedSteps / $totalSteps
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value $progress }
    }
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Tweaks finished" -Percent 100
    $sync.ProcessRunning = $false
    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
    Write-Host "================================="
    Write-Host "--     Tweaks are Finished    ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed."
  } | Out-Null
}

function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object System.Windows.GridLength([double]1, [System.Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            ComboDescriptions = $entryInfo.ComboDescriptions
            Registry    = $entryInfo.registry
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create a StackPanel for application content controls
        $stackPanelContainer = New-Object Windows.Controls.StackPanel
        $stackPanelContainer.HorizontalAlignment = 'Stretch'
        $stackPanelContainer.VerticalAlignment = 'Stretch'

        # Check if the target grid (or any ancestor) is already inside a ScrollViewer
        $hasOuterScrollViewer = $false
        $currentElement = $targetGrid
        while ($null -ne $currentElement) {
            if ($currentElement -is [System.Windows.Controls.ScrollViewer] -or $currentElement.GetType().Name -eq "ScrollViewer") {
                $hasOuterScrollViewer = $true
                break
            }
            $currentElement = $currentElement.Parent
        }

        if ($hasOuterScrollViewer) {
            # Add StackPanel directly to DockPanel without nesting a ScrollViewer
            [Windows.Controls.DockPanel]::SetDock($stackPanelContainer, [Windows.Controls.Dock]::Bottom)
            $dockPanelContainer.Children.Add($stackPanelContainer) | Out-Null
        }
        else {
            # Create a ScrollViewer for targets that do not already have an outer ScrollViewer
            $scrollViewer = New-Object Windows.Controls.ScrollViewer
            $scrollViewer.VerticalScrollBarVisibility = "Auto"
            $scrollViewer.HorizontalScrollBarVisibility = "Disabled"
            $scrollViewer.HorizontalAlignment = 'Stretch'
            $scrollViewer.VerticalAlignment = 'Stretch'
            $scrollViewer.Content = $stackPanelContainer

            [Windows.Controls.DockPanel]::SetDock($scrollViewer, [Windows.Controls.Dock]::Bottom)
            $dockPanelContainer.Children.Add($scrollViewer) | Out-Null
        }
        $panelcount++

        # Now proceed with adding category labels and entries to $stackPanelContainer
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            $label = New-Object Windows.Controls.Label
            $categoryCleanName = $category -replace ".*__", ""
            $label.Content = $categoryCleanName
            $label.Focusable = $true
            $label.IsTabStop = $true
            [System.Windows.Automation.AutomationProperties]::SetName($label, $categoryCleanName)
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $stackPanelContainer.Children.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes, notes last) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    'Note' { 3 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $stackPanelContainer.Children.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                            # Skip applying tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtilTweaks $Sender.name
                            }
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                            # Skip undoing tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtiltweaks $Sender.name -undo $true
                            }
                        })
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = Get-WinUtilEntryToolTip -Description $entryInfo.Description -Key $entryInfo.Name
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $stackPanelContainer.Children.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $toggleButton.Name) {
                            $toggleButton.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($toggleButton.Name) | Out-Null
                        }
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.ToolTip = $entryInfo.Description
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        $comboBox.Tag = [pscustomobject]@{
                            Registry = $entryInfo.Registry
                            State = $null
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        $comboItems = if ($entryInfo.ComboItems -is [string]) {
                            if ($entryInfo.ComboItems.Contains("|")) {
                                $entryInfo.ComboItems -split "\|"
                            } else {
                                $entryInfo.ComboItems -split " "
                            }
                        } else {
                            @($entryInfo.ComboItems)
                        }

                        foreach ($comboitem in $comboItems) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            if ($entryInfo.ComboDescriptions) {
                                $comboDescription = $entryInfo.ComboDescriptions.PSObject.Properties[$comboitem].Value
                                if ($comboDescription) {
                                    $comboBoxItem.ToolTip = $comboDescription
                                }
                            }
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $stackPanelContainer.Children.Add($horizontalStackPanel) | Out-Null

                        if ($entryInfo.Registry -and @($entryInfo.Registry)[0].Values) {
                            try {
                                $comboBox.Tag.State = Get-WinUtilRegistryComboState -Registry $entryInfo.Registry
                                $comboBox.SelectedIndex = @($comboBox.Items.Content).IndexOf([string]$comboBox.Tag.State)
                            } catch {
                                $unknownStateItem = New-Object Windows.Controls.ComboBoxItem
                                $unknownStateItem.Content = "Custom / Unknown - select a state"
                                $unknownStateItem.IsEnabled = $false
                                $unknownStateItem.ToolTip = "$($_.Exception.Message) Select one of the supported states to replace these values."
                                $comboBox.Items.Add($unknownStateItem) | Out-Null
                                $comboBox.SelectedItem = $unknownStateItem
                                $comboBox.ToolTip = $unknownStateItem.ToolTip
                            }
                        } else {
                            $comboBox.SelectedIndex = 0
                        }

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.SelectedItem.Content
                        }

                        $sync[$entryInfo.Name] = $comboBox

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                                $registry = $this.Tag.Registry
                                if ($registry -and $selectedItem.IsEnabled -and $selectedItem.Content -ne $this.Tag.State) {
                                    try {
                                        Set-WinUtilRegistryComboState -Registry $registry -State $selectedItem.Content
                                        $this.Tag.State = $selectedItem.Content
                                        $this.ToolTip = $null
                                        $unknownStateItem = @($this.Items) | Where-Object Content -EQ "Custom / Unknown - select a state" | Select-Object -First 1
                                        if ($unknownStateItem) {
                                            $this.Items.Remove($unknownStateItem)
                                        }
                                    } catch {
                                        $applyError = $_.Exception.Message
                                        if ([string]::IsNullOrWhiteSpace($applyError)) {
                                            $applyError = "Unable to apply registry state '$($selectedItem.Content)'."
                                        }
                                        $previousState = if ($this.Tag.State) { $this.Tag.State } else { "Custom / Unknown - select a state" }
                                        $this.SelectedItem = @($this.Items) | Where-Object Content -EQ $previousState | Select-Object -First 1
                                        [System.Windows.MessageBox]::Show(
                                            $applyError,
                                            "WinUtil",
                                            [System.Windows.MessageBoxButton]::OK,
                                            [System.Windows.MessageBoxImage]::Warning
                                        ) | Out-Null
                                    }
                                }
                            }
                        })

                        if ($entryInfo.Registry -and @($entryInfo.Registry)[0].Values -and $entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $comboBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true
                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $comboBox

                            $textBlock.Add_MouseUp({
                                [System.Object]$Sender = $args[0]
                                Start-Process $Sender.ToolTip -ErrorAction Stop
                            })

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null
                            $sync[$textBlock.Name] = $textBlock
                        }
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $stackPanelContainer.Children.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $button.Name) {
                            $button.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($button.Name) | Out-Null
                        }
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)
                            $radioButtonGroups[$entryInfo.GroupName] = $groupStackPanel

                            # Add the group container to the ItemsControl
                            $stackPanelContainer.Children.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    "Note" {
                        $textBlock = New-Object Windows.Controls.TextBlock
                        $textBlock.TextWrapping = "Wrap"
                        $textBlock.Margin = "5,5,5,5"
                        $textBlock.UseLayoutRounding = $true

                        $bulletBadge = [Windows.Documents.InlineUIContainer]::new((New-WinUtilFossBadge -Size 18 -Round))
                        $bulletBadge.BaselineAlignment = [Windows.BaselineAlignment]::Center

                        $textRun = New-Object Windows.Documents.Run
                        $textRun.Text = " $($entryInfo.Content)"
                        $textRun.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $textRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))

                        $textBlock.Inlines.Add($bulletBadge)
                        $textBlock.Inlines.Add($textRun)

                        $stackPanelContainer.Children.Add($textBlock) | Out-Null
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = Get-WinUtilEntryToolTip -Description $entryInfo.Description -Key $entryInfo.Name
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $checkBox

                            $textBlock.Add_MouseUp({
                                [System.Object]$Sender = $args[0]
                                Start-Process $Sender.ToolTip -ErrorAction Stop
                            })

                            $updateLinkMargin = {
                                [System.Object]$Sender = $args[0]
                                $linkedCheckBox = $Sender.Tag
                                $MarginTopBase = if ($linkedCheckBox) { $linkedCheckBox.Margin.Top } else { 0 }
                                $Sender.Margin = New-Object Windows.Thickness(
                                    [math]::Round($Sender.FontSize * 0.5),
                                    ($MarginTopBase - [math]::Round($Sender.FontSize / 2)),
                                    0, 0
                                )
                            }
                            $textBlock.Add_Loaded($updateLinkMargin)
                            $fontSizeDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty(
                                [Windows.Controls.Control]::FontSizeProperty,
                                [Windows.Controls.TextBlock]
                            )
                            $fontSizeDescriptor.AddValueChanged($textBlock, $updateLinkMargin)

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $stackPanelContainer.Children.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                        })
                    }
                }
            }
        }
    }
}

function Invoke-WPFUIThread ($ScriptBlock) {
    if ($null -eq $sync.form -or $null -eq $sync.form.Dispatcher) {
        return
    }

    $sync.form.Dispatcher.Invoke([action]$ScriptBlock)
}

function Invoke-WPFUltimatePerformance ([switch]$Enable) {
    if ($Enable) {
        powercfg /setactive (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Select-String -Pattern '[A-Fa-f0-9-]{36}').Matches.Value
        [System.Windows.MessageBox]::Show("Ultimate Power Plan plan installed and activated.","Success","OK","Information")
    } else {
        powercfg /restoredefaultschemes
        [System.Windows.MessageBox]::Show("Power Plan was reset to defaults.","Success","OK","Information")
    }
}

function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFundoall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "Please check the tweaks you wish to undo."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -ScriptBlock {
        param($tweaks)

        $sync.ProcessRunning = $true
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks requested: $(@($tweaks).Count) selected tweak(s)."
        if ($tweaks.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Undoing $($tweaks[$i]) ($($i + 1)/$($tweaks.Count))" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) }
        }

        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Undo Tweaks Finished" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        Write-Host "=================================="
        Write-Host "---  Undo Tweaks are Finished  ---"
        Write-Host "=================================="
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks workflow completed."

    }
}

function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFUnInstall] Install process is currently running"
        Show-WinUtilMessage -Message $msg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to uninstall"
        Show-WinUtilMessage -Message $WarningMsg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $ButtonType = "YesNo"
    $MessageboxTitle = "Are you sure?"
    $Messageboxbody = ("This will uninstall the following applications: `n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = "Information"

    $confirm = Show-WinUtilMessage -Message $Messageboxbody -Title $MessageboxTitle -Button $ButtonType -Icon $MessageIcon

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall requested for $(@($PackagesToUninstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToUninstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $totalPackages = @($packagesWinget).Count + @($packagesChoco).Count
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        Write-WinUtilLog -Component "Uninstall" -Message "Uninstall package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count)"

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app uninstall (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            if ($packagesWinget -contains "Microsoft.Edge") {
                New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force
            }

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    Install-WinUtilProgramWinget -Action Uninstall -Programs @($program)
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled $program ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling Chocolatey packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            Write-WinUtilLog -Component "Uninstall" -Message "Uninstall workflow completed."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall finished" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Uninstall" -Message "Uninstall workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        } finally {
            if ($hasUI) {
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $true
                    }
                }
            }
            $sync.ProcessRunning = $False
        }

    }
}

function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    #>
    Write-WinUtilLog -Component "Updates" -Message "Resetting Windows Update settings to default."

    Write-Host "Removing Windows Update settings managed by WinUtil..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Removing Windows Update registry values managed by WinUtil."

    $registryValues = @(
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            Names = @("NoAutoUpdate", "AUOptions", "NoAutoRebootWithLoggedOnUsers", "AUPowerManagement")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            Names = @("ExcludeWUDriversInQualityUpdate", "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
            Names = @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata"
            Names = @("PreventDeviceMetadataFromNetwork")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
            Names = @("DontPromptForWindowsUpdate", "DontSearchWindowsUpdate", "DriverUpdateWizardWuSearchEnabled")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
            Names = @("DODownloadMode")
        }
    )

    foreach ($registryEntry in $registryValues) {
        foreach ($valueName in $registryEntry.Names) {
            Remove-ItemProperty -Path $registryEntry.Path -Name $valueName -ErrorAction SilentlyContinue
        }
    }

    $explorerPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $settingsPageVisibility = (Get-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue).SettingsPageVisibility
    if ($settingsPageVisibility -eq "hide:windowsupdate") {
        Write-Host "Removing WinUtil's legacy Windows Update page restriction..."
        Write-WinUtilLog -Component "Updates" -Message "Removing the legacy Windows Update settings page restriction."
        Remove-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue
    }

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Restoring Windows Update service startup types."

    Write-Host "Restored BITS to Manual."
    Write-WinUtilLog -Component "Updates" -Message "Restoring BITS service to Manual."
    Set-Service -Name BITS -StartupType Manual

    Write-Host "Restored wuauserv to Manual."
    Write-WinUtilLog -Component "Updates" -Message "Restoring wuauserv service to Manual."
    Set-Service -Name wuauserv -StartupType Manual

    Write-Host "Restored UsoSvc to Automatic."
    Write-WinUtilLog -Component "Updates" -Message "Starting UsoSvc service and restoring startup type to Automatic."
    Set-Service -Name UsoSvc -StartupType Automatic
    Start-Service -Name UsoSvc

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Enabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "---  Windows Update Settings Reset to Default   ---" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update default workflow completed. Restart required."
}

function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    #>
    $confirmation = Show-WinUtilMessage `
        -Message "Disabling Windows Update stops update services, disables scheduled tasks, and clears downloaded update files. Security updates will not be installed until defaults are restored. Continue?" `
        -Title "Disable Windows Update?" `
        -Button "YesNo" `
        -Icon "Warning"

    if ($confirmation -ne "Yes") {
        Write-WinUtilLog -Component "Updates" -Message "Windows Update disable workflow cancelled."
        return
    }

    Write-WinUtilLog -Component "Updates" -Message "Disabling Windows Update settings."

    Write-Host "Configuring registry settings..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Configuring Windows Update registry policy values for disable mode."
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    foreach ($serviceName in @("BITS", "wuauserv", "UsoSvc")) {
        Write-Host "Stopping and disabling $serviceName service."
        Write-WinUtilLog -Component "Updates" -Message "Stopping and disabling $serviceName service."
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $serviceName -StartupType Disabled
    }

    Remove-Item -Path "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Cleared SoftwareDistribution folder."
    Write-WinUtilLog -Component "Updates" -Message "Cleared SoftwareDistribution folder."

    Write-Host "Disabling update related scheduled tasks..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Disabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "=================================" -ForegroundColor Green
    Write-Host "--- Windows Update Is Disabled ---" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update disable workflow completed. Restart required."
}

function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Defers feature updates for 365 days
        3. Defers quality updates for 4 days
        4. Prevents automatic restarts while a user is signed in

    #>

    Write-Host "Disabling driver offering through Windows Update..."
    Write-WinUtilLog -Component "Updates" -Message "Applying recommended Windows Update settings."
    Write-WinUtilLog -Component "Updates" -Message "Disabling driver offering through Windows Update."

    $windowsUpdatePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $automaticUpdatePolicyPath = Join-Path $windowsUpdatePolicyPath "AU"

    Write-Host "Restoring Windows Update availability..."
    Write-WinUtilLog -Component "Updates" -Message "Restoring Windows Update services and scheduled tasks before applying recommended settings."

    Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -ErrorAction SilentlyContinue

    Set-Service -Name BITS -StartupType Manual
    Set-Service -Name wuauserv -StartupType Manual
    Set-Service -Name UsoSvc -StartupType Automatic
    Start-Service -Name UsoSvc

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    New-Item -Path $windowsUpdatePolicyPath -Force
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Deferring feature updates by 365 days and quality updates by 4 days..."
    Write-WinUtilLog -Component "Updates" -Message "Deferring feature updates by 365 days and quality updates by 4 days."

    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    $legacySettingsPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    foreach ($legacyValue in @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")) {
        Remove-ItemProperty -Path $legacySettingsPath -Name $legacyValue -ErrorAction SilentlyContinue
    }

    Write-Host "Preventing automatic restarts while users are signed in..."
    Write-WinUtilLog -Component "Updates" -Message "Configuring scheduled automatic updates without restarting while users are signed in."

    New-Item -Path $automaticUpdatePolicyPath -Force
    # NoAutoRebootWithLoggedOnUsers only applies when automatic updates use option 4.
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUOptions" -Type DWord -Value 4
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "================================="
    Write-Host "-- Updates Set to Recommended ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Updates" -Message "Recommended Windows Update settings workflow completed."
}

$sync.configs.applications = @'
{
  "WPFInstall1password": {
    "category": "Utilities",
    "choco": "1password",
    "content": "1Password",
    "description": "1Password is a password manager that allows you to store and manage your passwords securely.",
    "link": "https://1password.com/",
    "winget": "AgileBits.1Password",
    "foss": false
  },
  "WPFInstall7zip": {
    "category": "Utilities",
    "choco": "7zip",
    "content": "7-Zip",
    "description": "7-Zip is a free and open-source file archiver utility. It supports several compression formats and provides a high compression ratio, making it a popular choice for file compression.",
    "link": "https://www.7-zip.org/",
    "winget": "7zip.7zip",
    "foss": true
  },
  "WPFInstalladobe": {
    "category": "Document",
    "choco": "adobereader",
    "content": "Adobe Acrobat Reader",
    "description": "Adobe Acrobat Reader is a free PDF viewer with essential features for viewing, printing, and annotating PDF documents.",
    "link": "https://www.adobe.com/acrobat/pdf-reader.html",
    "winget": "Adobe.Acrobat.Reader.64-bit",
    "foss": false
  },
  "WPFInstalladvancedip": {
    "category": "Pro Tools",
    "choco": "advanced-ip-scanner",
    "content": "Advanced IP Scanner",
    "description": "Advanced IP Scanner is a fast and easy-to-use network scanner. It is designed to analyze LAN networks and provides information about connected devices.",
    "link": "https://www.advanced-ip-scanner.com/",
    "winget": "Famatech.AdvancedIPScanner",
    "foss": false
  },
  "WPFInstallaimp": {
    "category": "Multimedia Tools",
    "choco": "aimp",
    "content": "AIMP (Music Player)",
    "description": "AIMP is a feature-rich music player with support for various audio formats, playlists, and customizable user interface.",
    "link": "https://www.aimp.ru/",
    "winget": "AIMP.AIMP",
    "foss": false
  },
  "WPFInstallangryipscanner": {
    "category": "Pro Tools",
    "choco": "angryip",
    "content": "Angry IP Scanner",
    "description": "Angry IP Scanner is an open-source and cross-platform network scanner. It is used to scan IP addresses and ports, providing information about network connectivity.",
    "link": "https://angryip.org/",
    "winget": "angryziber.AngryIPScanner",
    "foss": true
  },
  "WPFInstallanydesk": {
    "category": "Utilities",
    "choco": "anydesk",
    "content": "AnyDesk",
    "description": "AnyDesk is a remote desktop software that enables users to access and control computers remotely. It is known for its fast connection and low latency.",
    "link": "https://anydesk.com/",
    "winget": "AnyDesk.AnyDesk",
    "foss": false
  },
  "WPFInstallaudacity": {
    "category": "Multimedia Tools",
    "choco": "audacity",
    "content": "Audacity",
    "description": "Audacity is a free and open-source audio editing software known for its powerful recording and editing capabilities.",
    "link": "https://www.audacityteam.org/",
    "winget": "Audacity.Audacity",
    "foss": true
  },
  "WPFInstallautoruns": {
    "category": "Microsoft Tools",
    "choco": "autoruns",
    "content": "Autoruns",
    "description": "This utility shows you what programs are configured to run during system bootup or login.",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
    "winget": "Microsoft.Sysinternals.Autoruns",
    "foss": false
  },
  "WPFInstallrdcman": {
    "category": "Microsoft Tools",
    "choco": "rdcman",
    "content": "RDCMan",
    "description": "RDCMan manages multiple remote desktop connections. It is useful for managing server labs where you need regular access to each machine such as automated checkin systems and data centers.",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
    "winget": "Microsoft.Sysinternals.RDCMan",
    "foss": false
  },
  "WPFInstallautohotkey": {
    "category": "Utilities",
    "choco": "autohotkey",
    "content": "AutoHotkey",
    "description": "AutoHotkey is a scripting language for Windows that allows users to create custom automation scripts and macros. It is often used for automating repetitive tasks and customizing keyboard shortcuts.",
    "link": "https://www.autohotkey.com/",
    "winget": "AutoHotkey.AutoHotkey",
    "foss": true
  },
  "WPFInstallbattlenet": {
    "category": "Games",
    "choco": "na",
    "winget": "Blizzard.BattleNet",
    "content": "Battle.net",
    "description": "Battle.net is a launcher for games created and developed by Activision Blizzard",
    "link": "https://battle.net",
    "foss": false
  },
  "WPFInstallbitwarden": {
    "category": "Utilities",
    "choco": "bitwarden",
    "content": "Bitwarden",
    "description": "Bitwarden is an open-source password management solution. It allows users to store and manage their passwords in a secure and encrypted vault, accessible across multiple devices.",
    "link": "https://bitwarden.com/",
    "winget": "Bitwarden.Bitwarden",
    "foss": true
  },
  "WPFInstallblender": {
    "category": "Multimedia Tools",
    "choco": "blender",
    "content": "Blender (3D Graphics)",
    "description": "Blender is a powerful open-source 3D creation suite, offering modeling, sculpting, animation, and rendering tools.",
    "link": "https://www.blender.org/",
    "winget": "BlenderFoundation.Blender",
    "foss": true
  },
  "WPFInstallbrave": {
    "category": "Browsers",
    "choco": "brave",
    "content": "Brave",
    "description": "Brave is a privacy-focused web browser that blocks ads and trackers, offering a faster and safer browsing experience.",
    "link": "https://www.brave.com",
    "winget": "Brave.Brave",
    "foss": true
  },
  "WPFInstallbruno": {
    "category": "Development",
    "choco": "bruno",
    "content": "Bruno",
    "description": "Bruno is a local-first API client that stores collections as plain text files for version control and collaboration.",
    "link": "https://www.usebruno.com/",
    "winget": "Bruno.Bruno",
    "foss": true
  },
  "WPFInstallbulkcrapuninstaller": {
    "category": "Utilities",
    "choco": "bulk-crap-uninstaller",
    "content": "Bulk Crap Uninstaller",
    "description": "Bulk Crap Uninstaller is a free and open-source uninstaller utility for Windows. It helps users remove unwanted programs and clean up their system by uninstalling multiple applications at once.",
    "link": "https://www.bcuninstaller.com/",
    "winget": "Klocman.BulkCrapUninstaller",
    "foss": true
  },
  "WPFInstallblurautoclicker": {
    "category": "Utilities",
    "choco": "na",
    "content": "BlurAutoClicker",
    "description": "An Auto-clicker with a few advanced features and generally better performance than popular alternatives.",
    "link": "https://blur009.vercel.app/projects/blur-autoclicker/",
    "winget": "Blur009.BlurAutoClicker",
    "foss": true
  },
  "WPFInstallcalibre": {
    "category": "Multimedia Tools",
    "choco": "calibre",
    "content": "Calibre",
    "description": "Calibre is a powerful and easy-to-use e-book manager, viewer, and converter.",
    "link": "https://calibre-ebook.com/",
    "winget": "calibre.calibre",
    "foss": true
  },
  "WPFInstallcemu": {
    "category": "Games",
    "choco": "cemu",
    "content": "Cemu",
    "description": "Cemu is a highly experimental software to emulate Wii U applications on PC.",
    "link": "https://cemu.info/",
    "winget": "Cemu.Cemu",
    "foss": true
  },
  "WPFInstallchatgpt": {
    "category": "Development",
    "choco": "na",
    "content": "ChatGPT Desktop",
    "description": "The official ChatGPT desktop app for Windows, distributed through the Microsoft Store.",
    "link": "https://openai.com/chatgpt/download/",
    "winget": "msstore:9NT1R1C2HH7J",
    "foss": false
  },
  "WPFInstallchatterino": {
    "category": "Communications",
    "choco": "chatterino",
    "content": "Chatterino",
    "description": "Chatterino is a chat client for Twitch chat that offers a clean and customizable interface for a better streaming experience.",
    "link": "https://www.chatterino.com/",
    "winget": "ChatterinoTeam.Chatterino",
    "foss": true
  },
  "WPFInstallchrome": {
    "category": "Browsers",
    "choco": "googlechrome",
    "content": "Chrome",
    "description": "Google Chrome is a widely used web browser known for its speed, simplicity, and seamless integration with Google services.",
    "link": "https://www.google.com/chrome/",
    "winget": "Google.Chrome",
    "foss": false
  },
  "WPFInstallchromium": {
    "category": "Browsers",
    "choco": "chromium",
    "content": "Chromium",
    "description": "Chromium is the open-source project that serves as the foundation for various web browsers, including Chrome.",
    "link": "https://www.chromium.org/",
    "winget": "Hibbiki.Chromium",
    "foss": true
  },
  "WPFInstallcinebenchr23": {
    "category": "Pro Tools",
    "choco": "na",
    "content": "Cinebench R23",
    "description": "Cinebench R23 is a benchmark tool for comparing CPU rendering performance across systems.",
    "link": "https://www.maxon.net/en/cinebench",
    "winget": "Maxon.CinebenchR23",
    "foss": false
  },
  "WPFInstallclaude": {
    "category": "Development",
    "choco": "claude",
    "content": "Claude Desktop",
    "description": "Anthropic's Claude desktop application for focused AI-assisted work and chat.",
    "link": "https://claude.ai/download",
    "winget": "Anthropic.Claude",
    "foss": false
  },
  "WPFInstallclaude-code": {
    "category": "Development",
    "choco": "claude-code",
    "content": "Claude Code",
    "description": "Anthropic's agentic coding tool for terminal and IDE development workflows.",
    "link": "https://code.claude.com/",
    "winget": "Anthropic.ClaudeCode",
    "foss": false
  },
  "WPFInstallcmake": {
    "category": "Development",
    "choco": "cmake",
    "content": "CMake",
    "description": "CMake is an open-source, cross-platform family of tools designed to build, test and package software.",
    "link": "https://cmake.org/",
    "winget": "Kitware.CMake",
    "foss": true
  },
  "WPFInstallcodex": {
    "category": "Development",
    "choco": "codex",
    "content": "Codex",
    "description": "Codex CLI is an OpenAI coding agent that runs locally in your terminal.",
    "link": "https://developers.openai.com/codex/cli",
    "winget": "OpenAI.Codex",
    "foss": true
  },
  "WPFInstallcpuz": {
    "category": "Pro Tools",
    "choco": "cpu-z",
    "content": "CPU-Z",
    "description": "CPU-Z is a system monitoring and diagnostic tool for Windows. It provides detailed information about the computer's hardware components, including the CPU, memory, and motherboard.",
    "link": "https://www.cpuid.com/softwares/cpu-z.html",
    "winget": "CPUID.CPU-Z",
    "foss": false
  },
  "WPFInstallcrystaldiskinfo": {
    "category": "Utilities",
    "choco": "crystaldiskinfo",
    "content": "Crystal Disk Info",
    "description": "Crystal Disk Info is a disk health monitoring tool that provides information about the status and performance of hard drives. It helps users anticipate potential issues and monitor drive health.",
    "link": "https://crystalmark.info/en/software/crystaldiskinfo/",
    "winget": "CrystalDewWorld.CrystalDiskInfo",
    "foss": true
  },
  "WPFInstallcrystaldiskmark": {
    "category": "Utilities",
    "choco": "crystaldiskmark",
    "content": "Crystal Disk Mark",
    "description": "Crystal Disk Mark is a disk benchmarking tool that measures the read and write speeds of storage devices. It helps users assess the performance of their hard drives and SSDs.",
    "link": "https://crystalmark.info/en/software/crystaldiskmark/",
    "winget": "CrystalDewWorld.CrystalDiskMark",
    "foss": true
  },
  "WPFInstallcursor": {
    "category": "Development",
    "choco": "cursoride",
    "content": "Cursor",
    "description": "AI-powered code editor (VS Code-based) with agentic coding features and integrated AI assistance for development workflows.",
    "link": "https://cursor.com/",
    "winget": "Anysphere.Cursor",
    "foss": false
  },
  "WPFInstallddu": {
    "category": "Pro Tools",
    "choco": "ddu",
    "content": "Display Driver Uninstaller",
    "description": "Display Driver Uninstaller (DDU) is a tool for completely uninstalling graphics drivers from NVIDIA, AMD, and Intel. It is useful for troubleshooting graphics driver-related issues.",
    "link": "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
    "winget": "Wagnardsoft.DisplayDriverUninstaller",
    "foss": true
  },
  "WPFInstalldiscord": {
    "category": "Communications",
    "choco": "discord",
    "content": "Discord",
    "description": "Discord is a popular communication platform with voice, video, and text chat, designed for gamers but used by a wide range of communities.",
    "link": "https://discord.com/",
    "winget": "Discord.Discord",
    "foss": false
  },
  "WPFInstalldismtools": {
    "category": "Microsoft Tools",
    "choco": "dismtools",
    "content": "DISMTools",
    "description": "DISMTools is a fast, customizable GUI for the DISM utility, supporting Windows images from Windows 7 onward. It handles installations on any drive, offers project support, and lets users tweak settings like color modes, language, and DISM versions; powered by both native DISM and a managed DISM API.",
    "link": "https://github.com/CodingWonders/DISMTools",
    "winget": "CodingWondersSoftware.DISMTools.Stable",
    "foss": true
  },
  "WPFInstallntlite": {
    "category": "Microsoft Tools",
    "choco": "ntlite-free",
    "content": "NTLite",
    "description": "Integrate updates, drivers, automate Windows and application setup, speedup Windows deployment process and have it all set for the next time.",
    "link": "https://ntlite.com",
    "winget": "Nlitesoft.NTLite",
    "foss": false
  },
  "WPFInstalldorion": {
    "category": "Communications",
    "choco": "dorion",
    "content": "Dorion",
    "description": "Tiny alternative Discord client with a smaller footprint, snappier startup, themes, plugins and more!",
    "link": "https://spikehd.dev/projects/dorion/",
    "winget": "SpikeHD.Dorion",
    "foss": true
  },
  "WPFInstalldockerdesktop": {
    "category": "Development",
    "choco": "docker-desktop",
    "content": "Docker Desktop",
    "description": "Docker Desktop provides a local environment for building, running, and testing containerized applications on Windows.",
    "link": "https://www.docker.com/products/docker-desktop/",
    "winget": "Docker.DockerDesktop",
    "foss": false
  },
  "WPFInstalldotnet6": {
    "category": "Microsoft Tools",
    "choco": "dotnet-6.0-runtime",
    "content": ".NET Desktop Runtime 6",
    "description": ".NET Desktop Runtime 6 is a runtime environment required for running applications developed with .NET 6.",
    "link": "https://dotnet.microsoft.com/download/dotnet/6.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.6",
    "foss": true
  },
  "WPFInstalldotnet8": {
    "category": "Microsoft Tools",
    "choco": "dotnet-8.0-runtime",
    "content": ".NET Desktop Runtime 8",
    "description": ".NET Desktop Runtime 8 is a runtime environment required for running applications developed with .NET 8.",
    "link": "https://dotnet.microsoft.com/download/dotnet/8.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.8",
    "foss": true
  },
  "WPFInstalldotnet9": {
    "category": "Microsoft Tools",
    "choco": "dotnet-9.0-runtime",
    "content": ".NET Desktop Runtime 9",
    "description": ".NET Desktop Runtime 9 is a runtime environment required for running applications developed with .NET 9.",
    "link": "https://dotnet.microsoft.com/download/dotnet/9.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.9",
    "foss": true
  },
  "WPFInstalldotnet10": {
    "category": "Microsoft Tools",
    "choco": "dotnet-10.0-runtime",
    "content": ".NET Desktop Runtime 10",
    "description": ".NET Desktop Runtime 10 is a runtime environment required for running applications developed with .NET 10.",
    "link": "https://dotnet.microsoft.com/download/dotnet/10.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.10",
    "foss": true
  },
  "WPFInstalldropbox": {
    "category": "Utilities",
    "choco": "dropbox",
    "content": "Dropbox",
    "description": "Dropbox is a cloud storage client for syncing files, sharing content, and keeping documents available across devices.",
    "link": "https://www.dropbox.com/desktop",
    "winget": "Dropbox.Dropbox",
    "foss": false
  },
  "WPFInstalleaapp": {
    "category": "Games",
    "choco": "ea-app",
    "content": "EA App",
    "description": "EA App is a platform for accessing and playing Electronic Arts games.",
    "link": "https://www.ea.com/ea-app",
    "winget": "ElectronicArts.EADesktop",
    "foss": false
  },
  "WPFInstalleartrumpet": {
    "category": "Multimedia Tools",
    "choco": "eartrumpet",
    "content": "EarTrumpet (Audio)",
    "description": "EarTrumpet is an audio control app for Windows, providing a simple and intuitive interface for managing sound settings.",
    "link": "https://eartrumpet.app/",
    "winget": "File-New-Project.EarTrumpet",
    "foss": true
  },
  "WPFInstalledge": {
    "category": "Browsers",
    "choco": "microsoft-edge",
    "content": "Edge",
    "description": "Microsoft Edge is a modern web browser built on Chromium, offering performance, security, and integration with Microsoft services.",
    "link": "https://www.microsoft.com/edge",
    "winget": "Microsoft.Edge",
    "foss": false
  },
  "WPFInstalles-de": {
    "category": "Games",
    "choco": "",
    "content": "EmulationStation Desktop Edition",
    "_comment": "This and emulationstation are two completely different things. ES-DE is your frontend for everything and has its own set of emulators. Emulationstation is a graphical frontend for RetroArch.",
    "description": "EmulationStation Desktop Edition is a frontend for browsing and launching games from your multi-platform game collection.",
    "link": "https://es-de.org/",
    "winget": "ES-DE.EmulationStation-DE",
    "foss": true
  },
  "WPFInstallenteauth": {
    "category": "Utilities",
    "choco": "ente-auth",
    "content": "Ente Auth",
    "description": "Ente Auth is a free, cross-platform, end-to-end encrypted authenticator app.",
    "link": "https://ente.io/auth/",
    "winget": "ente-io.auth-desktop",
    "foss": true
  },
  "WPFInstallepicgames": {
    "category": "Games",
    "choco": "epicgameslauncher",
    "content": "Epic Games Launcher",
    "description": "Epic Games Launcher is the client for accessing and playing games from the Epic Games Store.",
    "link": "https://www.epicgames.com/store/en-US/",
    "winget": "EpicGames.EpicGamesLauncher",
    "foss": false
  },
  "WPFInstallfiles": {
    "category": "Utilities",
    "choco": "files",
    "content": "Files",
    "description": "Alternative file explorer.",
    "link": "https://files.community",
    "winget": "FilesCommunity.Files",
    "foss": true
  },
  "WPFInstallfirefox": {
    "category": "Browsers",
    "choco": "firefox",
    "content": "Firefox",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions.",
    "link": "https://www.mozilla.org/en-US/firefox/new/",
    "winget": "Mozilla.Firefox",
    "foss": true
  },
  "WPFInstallfirefoxesr": {
    "category": "Browsers",
    "choco": "FirefoxESR",
    "content": "Firefox ESR",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions. Firefox ESR (Extended Support Release) receives major updates every 42 weeks with minor updates such as crash fixes, security fixes and policy updates as needed, but at least every four weeks.",
    "link": "https://www.mozilla.org/en-US/firefox/enterprise/",
    "winget": "Mozilla.Firefox.ESR",
    "foss": true
  },
  "WPFInstallfloorp": {
    "category": "Browsers",
    "choco": "floorp",
    "content": "Floorp",
    "description": "Floorp is an open-source web browser project that aims to provide a simple and fast browsing experience.",
    "link": "https://floorp.app/",
    "winget": "Ablaze.Floorp",
    "foss": true
  },
  "WPFInstallflux": {
    "category": "Utilities",
    "choco": "flux",
    "content": "F.lux",
    "description": "f.lux adjusts the color temperature of your screen to reduce eye strain during nighttime use.",
    "link": "https://justgetflux.com/",
    "winget": "flux.flux",
    "foss": false
  },
  "WPFInstallfoobar": {
    "category": "Multimedia Tools",
    "choco": "foobar2000",
    "content": "foobar2000 (Music Player)",
    "description": "foobar2000 is a highly customizable and extensible music player for Windows, known for its modular design and advanced features.",
    "link": "https://www.foobar2000.org/",
    "winget": "PeterPawlowski.foobar2000",
    "foss": false
  },
  "WPFInstallfnm": {
    "category": "Development",
    "choco": "fnm",
    "content": "Fast Node Manager",
    "description": "Fast Node Manager (fnm) is a fast, cross-platform tool for installing and switching between Node.js versions.",
    "link": "https://github.com/Schniz/fnm",
    "winget": "Schniz.fnm",
    "foss": true
  },
  "WPFInstallfoxpdfreader": {
    "category": "Document",
    "choco": "foxitreader",
    "content": "Foxit PDF Reader",
    "description": "Foxit PDF Reader is a free PDF viewer with a familiar ribbon-style interface.",
    "link": "https://www.foxit.com/pdf-reader/",
    "winget": "Foxit.FoxitReader",
    "foss": false
  },
  "WPFInstallgeforcenow": {
    "category": "Games",
    "choco": "nvidia-geforce-now",
    "content": "GeForce NOW",
    "description": "GeForce NOW is a cloud gaming service that allows you to play high-quality PC games on your device.",
    "link": "https://www.nvidia.com/en-us/geforce-now/",
    "winget": "Nvidia.GeForceNow",
    "foss": false
  },
  "WPFInstallgimp": {
    "category": "Multimedia Tools",
    "choco": "gimp",
    "content": "GIMP (Image Editor)",
    "description": "GIMP is a versatile open-source raster graphics editor used for tasks such as photo retouching, image editing, and image composition.",
    "link": "https://www.gimp.org/",
    "winget": "GIMP.GIMP.3",
    "foss": true
  },
  "WPFInstallgit": {
    "category": "Development",
    "choco": "git",
    "content": "Git",
    "description": "Git is a distributed version control system widely used for tracking changes in source code during software development.",
    "link": "https://git-scm.com/",
    "winget": "Git.Git",
    "foss": true
  },
  "WPFInstallgitextensions": {
    "category": "Development",
    "choco": "gitextensions",
    "content": "Git Extensions",
    "description": "Git Extensions is a graphical Git client for Windows with repository, history, and commit management tools.",
    "link": "https://gitextensions.github.io/",
    "winget": "GitExtensionsTeam.GitExtensions",
    "foss": true
  },
  "WPFInstallgithubcli": {
    "category": "Development",
    "choco": "gh",
    "content": "GitHub CLI",
    "description": "GitHub CLI brings pull requests, issues, releases, and other GitHub workflows to the terminal.",
    "link": "https://cli.github.com/",
    "winget": "GitHub.cli",
    "foss": true
  },
  "WPFInstallgithubdesktop": {
    "category": "Development",
    "choco": "git;github-desktop",
    "content": "GitHub Desktop",
    "description": "GitHub Desktop is a visual Git client that simplifies collaboration on GitHub repositories with an easy-to-use interface.",
    "link": "https://desktop.github.com/",
    "winget": "GitHub.GitHubDesktop",
    "foss": true
  },
  "WPFInstallgog": {
    "category": "Games",
    "choco": "goggalaxy",
    "content": "GOG Galaxy",
    "description": "GOG Galaxy is a gaming client that offers DRM-free games, additional content, and more.",
    "link": "https://www.gog.com/galaxy",
    "winget": "GOG.Galaxy",
    "foss": false
  },
  "WPFInstallgolang": {
    "category": "Development",
    "choco": "golang",
    "content": "Go",
    "description": "Go (or Golang) is a statically typed, compiled programming language designed for simplicity, reliability, and efficiency.",
    "link": "https://go.dev/",
    "winget": "GoLang.Go",
    "foss": true
  },
  "WPFInstallgoogledrive": {
    "category": "Utilities",
    "choco": "googledrive",
    "content": "Google Drive",
    "description": "File syncing across devices all tied to your Google account.",
    "link": "https://www.google.com/drive/",
    "winget": "Google.GoogleDrive",
    "foss": false
  },
  "WPFInstallgpuz": {
    "category": "Pro Tools",
    "choco": "gpu-z",
    "content": "GPU-Z",
    "description": "GPU-Z provides detailed information about your graphics card and GPU.",
    "link": "https://www.techpowerup.com/gpuz/",
    "winget": "TechPowerUp.GPU-Z",
    "foss": false
  },
  "WPFInstallgsudo": {
    "category": "Pro Tools",
    "choco": "gsudo",
    "content": "gsudo",
    "description": "gsudo is a sudo equivalent for Windows. It allows you to run commands with elevated administrative privileges directly within the current console window.",
    "link": "https://github.com/gerardog/gsudo",
    "winget": "gerardog.gsudo",
    "foss": true
  },
  "WPFInstallhelium": {
    "category": "Browsers",
    "choco": "helium",
    "content": "Helium",
    "description": "Private, fast, and honest web browser.",
    "link": "https://helium.computer",
    "winget": "ImputNet.Helium",
    "foss": true
  },
  "WPFInstallhugo": {
    "category": "Utilities",
    "choco": "hugo-extended",
    "content": "Hugo",
    "description": "The world's fastest framework for building websites.",
    "link": "https://gohugo.io",
    "winget": "Hugo.Hugo.Extended",
    "foss": true
  },
  "WPFInstallhandbrake": {
    "category": "Multimedia Tools",
    "choco": "handbrake",
    "content": "HandBrake",
    "description": "HandBrake is an open-source video transcoder, allowing you to convert video from nearly any format to a selection of widely supported codecs.",
    "link": "https://handbrake.fr/",
    "winget": "HandBrake.HandBrake",
    "foss": true
  },
  "WPFInstallheroiclauncher": {
    "category": "Games",
    "choco": "heroic-games-launcher",
    "content": "Heroic Games Launcher",
    "description": "Heroic Games Launcher is an open-source alternative game launcher for Epic Games Store.",
    "link": "https://heroicgameslauncher.com/",
    "winget": "HeroicGamesLauncher.HeroicGamesLauncher",
    "foss": true
  },
  "WPFInstallhwinfo": {
    "category": "Pro Tools",
    "choco": "hwinfo",
    "content": "HWiNFO",
    "description": "HWiNFO provides comprehensive hardware information and diagnostics for Windows.",
    "link": "https://www.hwinfo.com/",
    "winget": "REALiX.HWiNFO",
    "foss": false
  },
  "WPFInstallhwmonitor": {
    "category": "Pro Tools",
    "choco": "hwmonitor",
    "content": "HWMonitor",
    "description": "HWMonitor is a hardware monitoring program that reads PC systems main health sensors.",
    "link": "https://www.cpuid.com/softwares/hwmonitor.html",
    "winget": "CPUID.HWMonitor",
    "foss": false
  },
  "WPFInstallimageglass": {
    "category": "Multimedia Tools",
    "choco": "imageglass",
    "content": "ImageGlass (Image Viewer)",
    "description": "ImageGlass is a versatile image viewer with support for various image formats and a focus on simplicity and speed.",
    "link": "https://imageglass.org/",
    "winget": "DuongDieuPhap.ImageGlass",
    "foss": true
  },
  "WPFInstallinternetdownloadmanager": {
    "category": "Utilities",
    "choco": "internet-download-manager",
    "content": "Internet Download Manager",
    "description": "Internet Download Manager is a download manager for accelerating, resuming, and scheduling file downloads.",
    "link": "https://www.internetdownloadmanager.com/",
    "winget": "Tonec.InternetDownloadManager",
    "foss": false
  },
  "WPFInstallirfanview": {
    "category": "Multimedia Tools",
    "choco": "irfanview",
    "content": "IrfanView",
    "description": "IrfanView is a lightweight, fast, and free image viewer and editor. Supports multiple formats, batch processing, and powerful plugins.",
    "link": "https://irfanview.com/",
    "winget": "IrfanSkiljan.IrfanView",
    "foss": false
  },
  "WPFInstallitch": {
    "category": "Games",
    "choco": "itch",
    "content": "Itch.io",
    "description": "Itch.io is a digital distribution platform for indie games and creative projects.",
    "link": "https://itch.io/",
    "winget": "ItchIo.Itch",
    "foss": true
  },
  "WPFInstallitunes": {
    "category": "Multimedia Tools",
    "choco": "itunes",
    "content": "iTunes",
    "description": "iTunes is a media player, media library, and online radio broadcaster application developed by Apple Inc.",
    "link": "https://www.apple.com/itunes/",
    "winget": "Apple.iTunes",
    "foss": false
  },
  "WPFInstalljava8": {
    "category": "Development",
    "choco": "corretto8jdk",
    "content": "Amazon Corretto 8 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.8.JDK",
    "foss": true
  },
  "WPFInstalljava21": {
    "category": "Development",
    "choco": "corretto21jdk",
    "content": "Amazon Corretto 21 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.21.JDK",
    "foss": true
  },
  "WPFInstalljava25": {
    "category": "Development",
    "choco": "corretto25jdk",
    "content": "Amazon Corretto 25 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.25.JDK",
    "foss": true
  },
  "WPFInstalljellyfinmediaplayer": {
    "category": "Selfhosted Tools",
    "choco": "jellyfin-media-player",
    "content": "Jellyfin Media Player",
    "description": "Jellyfin Media Player is a client application for the Jellyfin media server, providing access to your media library.",
    "link": "https://jellyfin.org/",
    "winget": "Jellyfin.JellyfinMediaPlayer",
    "foss": true
  },
  "WPFInstalljellyfinserver": {
    "category": "Selfhosted Tools",
    "choco": "jellyfin",
    "content": "Jellyfin Server",
    "description": "Jellyfin Server is an open-source media server software, allowing you to organize and stream your media library.",
    "link": "https://jellyfin.org/",
    "winget": "Jellyfin.Server",
    "foss": true
  },
  "WPFInstalljetbrains": {
    "category": "Development",
    "choco": "jetbrainstoolbox",
    "content": "Jetbrains Toolbox",
    "description": "Jetbrains Toolbox is a platform for easy installation and management of JetBrains developer tools.",
    "link": "https://www.jetbrains.com/toolbox/",
    "winget": "JetBrains.Toolbox",
    "foss": false
  },
  "WPFInstalljpegview": {
    "category": "Utilities",
    "choco": "jpegview",
    "content": "JPEG View",
    "description": "JPEGView is a lean, fast and highly configurable viewer/editor for JPEG, BMP, PNG, WEBP, TGA, GIF, JXL, HEIC, HEIF, AVIF, and TIFF images with a minimal GUI.",
    "link": "https://github.com/sylikc/jpegview",
    "winget": "sylikc.JPEGView",
    "foss": true
  },
  "WPFInstalljoplin": {
    "category": "Document",
    "choco": "joplin",
    "content": "Joplin",
    "description": "Joplin is an open-source note-taking and to-do application with synchronization capabilities.",
    "link": "https://joplinapp.org/",
    "winget": "Joplin.Joplin",
    "foss": true
  },
  "WPFInstallkeepassxc": {
    "category": "Utilities",
    "choco": "keepassxc",
    "content": "KeePassXC",
    "description": "KeePassXC is a modern, secure, and open-source password manager that stores and manages your most sensitive information. You can run KeePassXC on Windows, macOS, and Linux systems. KeePassXC is for people with extremely high demands of secure personal data management. It saves many different types of information, such as usernames, passwords, URLs, attachments, and notes in an offline, encrypted file that can be stored in any location, including private and public cloud solutions. For easy identification and management, user-defined titles and icons can be specified for entries. In addition, entries are sorted into customizable groups. An integrated search function allows you to use advanced patterns to easily find any entry in your database. A customizable, fast, and easy-to-use password generator utility allows you to create passwords with any combination of characters or easy to remember passphrases.",
    "link": "https://keepassxc.org/",
    "winget": "KeePassXCTeam.KeePassXC",
    "foss": true
  },
  "WPFInstallklite": {
    "category": "Multimedia Tools",
    "choco": "k-litecodecpack-standard",
    "content": "K-Lite Codec Standard",
    "description": "K-Lite Codec Pack Standard is a collection of audio and video codecs and related tools, providing essential components for media playback.",
    "link": "https://www.codecguide.com/",
    "winget": "CodecGuide.K-LiteCodecPack.Standard",
    "foss": false
  },
  "WPFInstallkodi": {
    "category": "Selfhosted Tools",
    "choco": "kodi",
    "content": "Kodi Media Center",
    "description": "Kodi is an open-source media center application that allows you to play and view most videos, music, podcasts, and other digital media files.",
    "link": "https://kodi.tv/",
    "winget": "XBMCFoundation.Kodi",
    "foss": true
  },
  "WPFInstalllazygit": {
    "category": "Development",
    "choco": "lazygit",
    "content": "Lazygit",
    "description": "Simple terminal UI for git commands.",
    "link": "https://github.com/jesseduffield/lazygit/",
    "winget": "JesseDuffield.lazygit",
    "foss": true
  },
  "WPFInstalllibreoffice": {
    "category": "Document",
    "choco": "libreoffice-fresh",
    "content": "LibreOffice",
    "description": "LibreOffice is a powerful and free office suite, compatible with other major office suites.",
    "link": "https://www.libreoffice.org/",
    "winget": "TheDocumentFoundation.LibreOffice",
    "foss": true
  },
  "WPFInstalllibrewolf": {
    "category": "Browsers",
    "choco": "librewolf",
    "content": "LibreWolf",
    "description": "LibreWolf is a privacy-focused web browser based on Firefox, with additional privacy and security enhancements.",
    "link": "https://librewolf.net/",
    "winget": "LibreWolf.LibreWolf",
    "foss": true
  },
  "WPFInstalllocalsend": {
    "category": "Selfhosted Tools",
    "choco": "localsend.install",
    "content": "LocalSend",
    "description": "An open-source cross-platform alternative to AirDrop.",
    "link": "https://localsend.org/",
    "winget": "LocalSend.LocalSend",
    "foss": true
  },
  "WPFInstallmpc-qt": {
    "category": "Multimedia Tools",
    "choco": "mediainfo",
    "content": "mpc-qt",
    "description": "Media Player Classic Qute Theater",
    "link": "https://mpc-qt.github.io",
    "winget": "mpc-qt.mpc-qt",
    "foss": true
  },
  "WPFInstallmpv": {
    "category": "Multimedia Tools",
    "content": "mpv",
    "description": "mpv is a free, open source, and cross-platform media player supporting a wide variety of media formats, codecs, and subtitle types.",
    "link": "https://mpv.io/",
    "winget": "shinchiro.mpv",
    "foss": true
  },
  "WPFInstallmatrix": {
    "category": "Communications",
    "choco": "element-desktop",
    "content": "Element",
    "description": "Element is a client for Matrix; an open network for secure, decentralized communication.",
    "link": "https://element.io/",
    "winget": "Element.Element",
    "foss": true
  },
  "WPFInstallminitoolpartitionwizard": {
    "category": "Utilities",
    "choco": "minitoolpartitionwizard",
    "content": "MiniTool Partition Wizard",
    "description": "Comprehensive free partition manager that performs advanced operations Windows natively cannot, such as merging partitions, converting file systems, and organizing disk capacity.",
    "link": "https://www.partitionwizard.com/",
    "winget": "MiniTool.PartitionWizard.Free",
    "foss": false
  },
  "WPFInstallmodrinth": {
    "category": "Games",
    "choco": "modrinth-app",
    "content": "Modrinth App",
    "description": "Modrinth App is a desktop application for managing Minecraft mods and modpacks.",
    "link": "https://modrinth.com/app",
    "winget": "Modrinth.ModrinthApp",
    "foss": true
  },
  "WPFInstallmoonlight": {
    "category": "Selfhosted Tools",
    "choco": "moonlight-qt",
    "content": "Moonlight/GameStream Client",
    "description": "Moonlight/GameStream Client allows you to stream PC games to other devices over your local network.",
    "link": "https://moonlight-stream.org/",
    "winget": "MoonlightGameStreamingProject.Moonlight",
    "foss": true
  },
  "WPFInstallmpchc": {
    "category": "Multimedia Tools",
    "choco": "mpc-hc-clsid2",
    "content": "Media Player Classic - Home Cinema",
    "description": "Media Player Classic - Home Cinema (MPC-HC) is a free and open-source video and audio player for Windows. MPC-HC is based on the original Guliverkli project and contains many additional features and bug fixes.",
    "link": "https://mpc-hc.org/",
    "winget": "clsid2.mpc-hc",
    "foss": true
  },
  "WPFInstallmsedgeredirect": {
    "category": "Utilities",
    "choco": "msedgeredirect",
    "content": "MSEdgeRedirect",
    "description": "A Tool to Redirect News, Search, Widgets, Weather, and More to your default browser.",
    "link": "https://github.com/rcmaehl/MSEdgeRedirect",
    "winget": "rcmaehl.MSEdgeRedirect",
    "foss": true
  },
  "WPFInstallmsiafterburner": {
    "category": "Utilities",
    "choco": "msiafterburner",
    "content": "MSI Afterburner",
    "description": "MSI Afterburner is a graphics card overclocking utility with advanced features.",
    "link": "https://www.msi.com/Landing/afterburner",
    "winget": "Guru3D.Afterburner",
    "foss": false
  },
  "WPFInstallmullvadvpn": {
    "category": "Pro Tools",
    "choco": "mullvad-app",
    "content": "Mullvad VPN",
    "description": "This is the VPN client software for the Mullvad VPN service.",
    "link": "https://mullvad.net/",
    "winget": "MullvadVPN.MullvadVPN",
    "foss": true
  },
  "WPFInstallmullvadbrowser": {
    "category": "Browsers",
    "choco": "na",
    "content": "Mullvad Browser",
    "description": "Mullvad Browser is a privacy-focused web browser, developed in partnership with the Tor Project.",
    "link": "https://mullvad.net/browser",
    "winget": "MullvadVPN.MullvadBrowser",
    "foss": true
  },
  "WPFInstallnomacs": {
    "category": "Multimedia Tools",
    "choco": "nomacs",
    "content": "nomacs",
    "description": "nomacs is a free, open-source image viewer, which supports multiple platforms. You can use it for viewing all common image formats, including RAW and .psd images.",
    "link": "https://nomacs.org/",
    "winget": "nomacs.nomacs",
    "foss": true
  },
  "WPFInstallnanazip": {
    "category": "Utilities",
    "choco": "nanazip",
    "content": "NanaZip",
    "description": "NanaZip is a fast and efficient file compression and decompression tool.",
    "link": "https://nanazip.org",
    "winget": "M2Team.NanaZip",
    "foss": true
  },
  "WPFInstallnetbird": {
    "category": "Selfhosted Tools",
    "choco": "netbird",
    "content": "NetBird",
    "description": "NetBird is an open-source alternative comparable to TailScale that can be connected to a self-hosted server.",
    "link": "https://netbird.io/",
    "winget": "Netbird.Netbird",
    "foss": true
  },
  "WPFInstalltailscale": {
    "category": "Utilities",
    "choco": "tailscale",
    "content": "Tailscale",
    "description": "The Tailscale client allows you to connect all your devices using WireGuardÂ®, without the hassle. Tailscale makes it as easy as installing an app and signing in.",
    "link": "https://tailscale.com/",
    "winget": "Tailscale.Tailscale",
    "foss": false
  },
  "WPFInstallnaps2": {
    "category": "Document",
    "choco": "naps2",
    "content": "NAPS2 (Scanner)",
    "description": "NAPS2 is a document scanning application that simplifies the process of creating electronic documents.",
    "link": "https://www.naps2.com/",
    "winget": "Cyanfish.NAPS2",
    "foss": true
  },
  "WPFInstallneovim": {
    "category": "Development",
    "choco": "neovim",
    "content": "Neovim",
    "description": "Neovim is a highly extensible text editor and an improvement over the original Vim editor.",
    "link": "https://neovim.io/",
    "winget": "Neovim.Neovim",
    "foss": true
  },
  "WPFInstallnextclouddesktop": {
    "category": "Selfhosted Tools",
    "choco": "nextcloud-client",
    "content": "Nextcloud Desktop",
    "description": "Nextcloud Desktop is the official desktop client for the Nextcloud file synchronization and sharing platform.",
    "link": "https://nextcloud.com/install/#install-clients",
    "winget": "Nextcloud.NextcloudDesktop",
    "foss": true
  },
  "WPFInstallnmap": {
    "category": "Pro Tools",
    "choco": "nmap",
    "content": "Nmap",
    "description": "Nmap (Network Mapper) is an open-source tool for network exploration and security auditing. It discovers devices on a network and provides information about their ports and services.",
    "link": "https://nmap.org/",
    "winget": "Insecure.Nmap",
    "foss": true
  },
  "WPFInstallnodejs": {
    "category": "Development",
    "choco": "nodejs",
    "content": "NodeJS",
    "description": "NodeJS is a JavaScript runtime built on Chrome's V8 JavaScript engine for building server-side and networking applications.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS",
    "foss": true
  },
  "WPFInstallnodejslts": {
    "category": "Development",
    "choco": "nodejs-lts",
    "content": "NodeJS LTS",
    "description": "NodeJS LTS provides Long-Term Support releases for stable and reliable server-side JavaScript development.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS.LTS",
    "foss": true
  },
  "WPFInstallpnpm": {
    "category": "Development",
    "content": "pnpm",
    "description": "pnpm is a fast and disk space efficient package manager for JavaScript and Node.js applications.",
    "link": "https://pnpm.io/",
    "winget": "pnpm.pnpm",
    "foss": true
  },
  "WPFInstallnotepadplus": {
    "category": "Multimedia Tools",
    "choco": "notepadplusplus",
    "content": "Notepad++",
    "description": "Notepad++ is a free, open-source code editor and Notepad replacement with support for multiple languages.",
    "link": "https://notepad-plus-plus.org/",
    "winget": "Notepad++.Notepad++",
    "foss": true
  },
  "WPFInstallnuget": {
    "category": "Microsoft Tools",
    "choco": "nuget.commandline",
    "content": "NuGet",
    "description": "NuGet is a package manager for the .NET framework, enabling developers to manage and share libraries in their .NET applications.",
    "link": "https://www.nuget.org/",
    "winget": "Microsoft.NuGet",
    "foss": true
  },
  "WPFInstallnvclean": {
    "category": "Utilities",
    "choco": "na",
    "content": "NVCleanstall",
    "description": "NVCleanstall is a tool designed to customize NVIDIA driver installations, allowing advanced users to control more aspects of the installation process.",
    "link": "https://www.techpowerup.com/nvcleanstall/",
    "winget": "TechPowerUp.NVCleanstall",
    "foss": false
  },
  "WPFInstallobs": {
    "category": "Multimedia Tools",
    "choco": "obs-studio",
    "content": "OBS Studio",
    "description": "OBS Studio is a free and open-source software for video recording and live streaming. It supports real-time video/audio capturing and mixing, making it popular among content creators.",
    "link": "https://obsproject.com/",
    "winget": "OBSProject.OBSStudio",
    "foss": true
  },
  "WPFInstallobsidian": {
    "category": "Document",
    "choco": "obsidian",
    "content": "Obsidian",
    "description": "Obsidian is a powerful note-taking and knowledge management application.",
    "link": "https://obsidian.md/",
    "winget": "Obsidian.Obsidian",
    "foss": false
  },
  "WPFInstallokular": {
    "category": "Document",
    "choco": "okular",
    "content": "Okular",
    "description": "Okular is a versatile document viewer with advanced features.",
    "link": "https://okular.kde.org/",
    "winget": "KDE.Okular",
    "foss": true
  },
  "WPFInstallonedrive": {
    "category": "Microsoft Tools",
    "choco": "onedrive",
    "content": "OneDrive",
    "description": "OneDrive is a cloud storage service provided by Microsoft, allowing users to store and share files securely across devices.",
    "link": "https://onedrive.live.com/",
    "winget": "Microsoft.OneDrive",
    "foss": false
  },
  "WPFInstallonlyoffice": {
    "category": "Document",
    "choco": "onlyoffice",
    "content": "ONLYOFFICE Desktop",
    "description": "ONLYOFFICE Desktop is a comprehensive office suite for document editing and collaboration.",
    "link": "https://www.onlyoffice.com/desktop.aspx",
    "winget": "ONLYOFFICE.DesktopEditors",
    "foss": true
  },
  "WPFInstallOPAutoClicker": {
    "category": "Utilities",
    "choco": "autoclicker",
    "content": "OPAutoClicker",
    "description": "A full-fledged autoclicker with two modes of autoclicking, at your dynamic cursor location or at a prespecified location.",
    "link": "https://www.opautoclicker.com",
    "winget": "OPAutoClicker.OPAutoClicker",
    "foss": false
  },
  "WPFInstallopenrgb": {
    "category": "Utilities",
    "choco": "openrgb",
    "content": "OpenRGB",
    "description": "OpenRGB is an open-source RGB lighting control software designed to manage and control RGB lighting for various components and peripherals.",
    "link": "https://openrgb.org/",
    "winget": "OpenRGB.OpenRGB",
    "foss": true
  },
  "WPFInstallOpenVPN": {
    "category": "Pro Tools",
    "choco": "openvpn-connect",
    "content": "OpenVPN Connect",
    "description": "OpenVPN Connect is a VPN client that allows you to connect securely to a VPN server. It provides a secure and encrypted connection for protecting your online privacy.",
    "link": "https://openvpn.net/",
    "winget": "OpenVPNTechnologies.OpenVPNConnect",
    "foss": false
  },
  "WPFInstallOVirtualBox": {
    "category": "Utilities",
    "choco": "virtualbox",
    "content": "Oracle VirtualBox",
    "description": "Oracle VirtualBox is a powerful and free open-source virtualization tool for x86 and AMD64/Intel64 architectures.",
    "link": "https://www.virtualbox.org/",
    "winget": "Oracle.VirtualBox",
    "foss": true
  },
  "WPFInstallpolicyplus": {
    "category": "Utilities",
    "choco": "na",
    "content": "Policy Plus",
    "description": "Local Group Policy Editor plus more, for all Windows editions.",
    "link": "https://github.com/Fleex255/PolicyPlus",
    "winget": "Fleex255.PolicyPlus",
    "foss": true
  },
  "WPFInstallprocessexplorer": {
    "category": "Microsoft Tools",
    "choco": "procexp",
    "content": "Process Explorer",
    "description": "Process Explorer is a task manager and system monitor.",
    "link": "https://learn.microsoft.com/sysinternals/downloads/process-explorer",
    "winget": "Microsoft.Sysinternals.ProcessExplorer",
    "foss": false
  },
  "WPFInstallPaintdotnet": {
    "category": "Multimedia Tools",
    "choco": "paint.net",
    "content": "Paint.NET",
    "description": "Paint.NET is a free image and photo editing software for Windows. It features an intuitive user interface and supports a wide range of powerful editing tools.",
    "link": "https://www.getpaint.net/",
    "winget": "dotPDN.PaintDotNet",
    "foss": false
  },
  "WPFInstallparsec": {
    "category": "Utilities",
    "choco": "parsec",
    "content": "Parsec",
    "description": "Parsec is a low-latency, high-quality remote desktop sharing application for collaborating and gaming across devices.",
    "link": "https://parsec.app/",
    "winget": "Parsec.Parsec",
    "foss": false
  },
  "WPFInstallpeazip": {
    "category": "Utilities",
    "choco": "peazip",
    "content": "PeaZip",
    "description": "PeaZip is a free, open-source file archiver utility that supports multiple archive formats and provides encryption features.",
    "link": "https://peazip.github.io/",
    "winget": "Giorgiotani.Peazip",
    "foss": true
  },
  "WPFInstallpdf-xchange": {
    "category": "Document",
    "choco": "pdfxchangeeditor",
    "content": "PDF-XChange Editor",
    "description": "A comprehensive Windows-based software suite and editor for creating, viewing, editing, annotating, and signing PDF files.",
    "link": "https://www.pdf-xchange.com/",
    "winget": "TrackerSoftware.PDF-XChangeEditor",
    "foss": false
  },
  "WPFInstallpdf24creator": {
    "category": "Document",
    "choco": "pdf24",
    "content": "PDF24 Creator",
    "description": "Free and easy-to-use online/desktop PDF tools that make you more productive",
    "link": "https://tools.pdf24.org/en/creator",
    "winget": "geeksoftwareGmbH.PDF24Creator",
    "foss": false
  },
  "WPFInstallpdfgear": {
    "category": "Document",
    "choco": "pdfgear",
    "content": "PDFgear",
    "description": "PDFgear is a piece of full-featured PDF management software for Windows, macOS, and mobile, and it's completely free to use.",
    "link": "https://www.pdfgear.com/",
    "winget": "PDFgear.PDFgear",
    "foss": false
  },
  "WPFInstallpdfsam": {
    "category": "Document",
    "choco": "pdfsam",
    "content": "PDFsam Basic",
    "description": "PDFsam Basic is a free and open-source tool for splitting, merging, and rotating PDF files.",
    "link": "https://pdfsam.org/",
    "winget": "PDFsam.PDFsam",
    "foss": true
  },
  "WPFInstallplaynite": {
    "category": "Games",
    "choco": "playnite",
    "content": "Playnite",
    "description": "Playnite is an open-source video game library manager with one simple goal: To provide a unified interface for all of your games.",
    "link": "https://playnite.link/",
    "winget": "Playnite.Playnite",
    "foss": true
  },
  "WPFInstallplex": {
    "category": "Selfhosted Tools",
    "choco": "plexmediaserver",
    "content": "Plex Media Server",
    "description": "Plex Media Server is a media server software that allows you to organize and stream your media library. It supports various media formats and offers a wide range of features.",
    "link": "https://www.plex.tv/your-media/",
    "winget": "Plex.PlexMediaServer",
    "foss": false
  },
  "WPFInstallplexdesktop": {
    "category": "Selfhosted Tools",
    "choco": "plex",
    "content": "Plex Desktop",
    "description": "Plex Desktop for Windows is the front end for Plex Media Server.",
    "link": "https://www.plex.tv",
    "winget": "Plex.Plex",
    "foss": false
  },
  "WPFInstallposh": {
    "category": "Development",
    "choco": "oh-my-posh",
    "content": "Oh My Posh (Prompt)",
    "description": "Oh My Posh is a cross-platform prompt theme engine for any shell.",
    "link": "https://ohmyposh.dev/",
    "winget": "JanDeDobbeleer.OhMyPosh",
    "foss": true
  },
  "WPFInstallpostman": {
    "category": "Development",
    "choco": "postman",
    "content": "Postman",
    "description": "Postman is an API platform and desktop client for designing, testing, documenting, and collaborating on APIs.",
    "link": "https://www.postman.com/downloads/",
    "winget": "Postman.Postman",
    "foss": false
  },
  "WPFInstallpowershell": {
    "category": "Microsoft Tools",
    "choco": "powershell-core",
    "content": "PowerShell",
    "description": "PowerShell is a task automation framework and scripting language designed for system administrators, offering powerful command-line capabilities.",
    "link": "https://github.com/PowerShell/PowerShell",
    "winget": "Microsoft.PowerShell",
    "foss": true
  },
  "WPFInstallpowertoys": {
    "category": "Microsoft Tools",
    "choco": "powertoys",
    "content": "PowerToys",
    "description": "PowerToys is a set of utilities for power users to enhance productivity, featuring tools like FancyZones, PowerRename, and more.",
    "link": "https://github.com/microsoft/PowerToys",
    "winget": "Microsoft.PowerToys",
    "foss": true
  },
  "WPFInstallprismlauncher": {
    "category": "Games",
    "choco": "prismlauncher",
    "content": "Prism Launcher",
    "description": "Prism Launcher is an open-source Minecraft launcher with the ability to manage multiple instances, accounts, and mods.",
    "link": "https://prismlauncher.org/",
    "winget": "PrismLauncher.PrismLauncher",
    "foss": true
  },
  "WPFInstallprocesslasso": {
    "category": "Utilities",
    "choco": "plasso",
    "content": "Process Lasso",
    "description": "Process Lasso is a system optimization and automation tool that improves system responsiveness and stability by adjusting process priorities and CPU affinities.",
    "link": "https://bitsum.com/",
    "winget": "BitSum.ProcessLasso",
    "foss": false
  },
  "WPFInstallprotonauth": {
    "category": "Utilities",
    "choco": "protonauth",
    "content": "Proton Authenticator",
    "description": "2FA app from Proton to securely sync and backup 2FA codes.",
    "link": "https://proton.me/authenticator",
    "winget": "Proton.ProtonAuthenticator",
    "foss": true
  },
  "WPFInstallprotonmail": {
    "category": "Communications",
    "choco": "protonmail",
    "content": "Proton Mail",
    "description": "Proton Mail is an end-to-end encrypted email service by Proton, protecting your privacy with zero-access encryption.",
    "link": "https://proton.me/mail",
    "winget": "Proton.ProtonMail",
    "foss": true
  },
  "WPFInstallprotondrive": {
    "category": "Utilities",
    "choco": "protondrive",
    "content": "Proton Drive",
    "description": "Proton Drive is an end-to-end encrypted Swiss vault for your files that protects your data.",
    "link": "https://proton.me/drive",
    "winget": "Proton.ProtonDrive",
    "foss": true
  },
  "WPFInstallprotonpass": {
    "category": "Utilities",
    "choco": "protonpass",
    "content": "Proton Pass",
    "description": "Proton Pass is a cloud-based password manager with end-to-end encryption and unique email aliases.",
    "link": "https://proton.me/pass",
    "winget": "Proton.ProtonPass",
    "foss": true
  },
  "WPFInstallprotonvpn": {
    "category": "Pro Tools",
    "choco": "protonvpn",
    "content": "Proton VPN",
    "description": "Proton VPN is a no-logs VPN service that protects your privacy online with features like Secure Core and Tor over VPN.",
    "link": "https://protonvpn.com/",
    "winget": "Proton.ProtonVPN",
    "foss": true
  },
  "WPFInstallprocessmonitor": {
    "category": "Microsoft Tools",
    "choco": "procexp",
    "content": "Process Monitor",
    "description": "SysInternals Process Monitor is an advanced monitoring tool that shows real-time file system, registry, and process/thread activity.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
    "winget": "Microsoft.Sysinternals.ProcessMonitor",
    "foss": false
  },
  "WPFInstallputty": {
    "category": "Pro Tools",
    "choco": "putty",
    "content": "PuTTY",
    "description": "PuTTY is a free and open-source terminal emulator, serial console, and network file transfer application. It supports various network protocols such as SSH, Telnet, and SCP.",
    "link": "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
    "winget": "PuTTY.PuTTY",
    "foss": true
  },
  "WPFInstallpython3": {
    "category": "Development",
    "choco": "python",
    "content": "Python3",
    "description": "Python is a versatile programming language used for web development, data analysis, artificial intelligence, and more.",
    "link": "https://www.python.org/",
    "winget": "Python.Python.3.14",
    "foss": true
  },
  "WPFInstallqbittorrent": {
    "category": "Utilities",
    "choco": "qbittorrent",
    "content": "qBittorrent",
    "description": "qBittorrent is a free and open-source BitTorrent client that aims to provide a feature-rich and lightweight alternative to other torrent clients.",
    "link": "https://www.qbittorrent.org/",
    "winget": "qBittorrent.qBittorrent",
    "foss": true
  },
  "WPFInstallqownnotes": {
    "category": "Document",
    "choco": "qownnotes",
    "content": "QOwnNotes",
    "description": "QOwnNotes is a free open-source note taking app with Nextcloud/ownCloud integration.",
    "link": "https://www.qownnotes.org/",
    "winget": "pbek.QOwnNotes",
    "foss": true
  },
  "WPFInstallqtox": {
    "category": "Communications",
    "choco": "qtox",
    "content": "QTox",
    "description": "QTox is a free and open-source messaging app that prioritizes user privacy and security in its design.",
    "link": "https://qtox.github.io/",
    "winget": "Tox.qTox",
    "foss": true
  },
  "WPFInstallrevo": {
    "category": "Utilities",
    "choco": "revo-uninstaller",
    "content": "Revo Uninstaller",
    "description": "Revo Uninstaller is an advanced uninstaller tool that helps you remove unwanted software and clean up your system.",
    "link": "https://www.revouninstaller.com/",
    "winget": "RevoUninstaller.RevoUninstaller",
    "foss": false
  },
  "WPFInstallWiseProgramUninstaller": {
    "category": "Utilities",
    "choco": "na",
    "content": "Wise Program Uninstaller (WiseCleaner)",
    "description": "Wise Program Uninstaller is the perfect solution for uninstalling Windows programs, allowing you to uninstall applications quickly and completely using its simple and user-friendly interface.",
    "link": "https://www.wisecleaner.com/wise-program-uninstaller.html",
    "winget": "WiseCleaner.WiseProgramUninstaller",
    "foss": false
  },
  "WPFInstallrufus": {
    "category": "Utilities",
    "choco": "rufus",
    "content": "Rufus Imager",
    "description": "Rufus is a utility that helps format and create bootable USB drives, such as USB keys or pen drives.",
    "link": "https://rufus.ie/",
    "winget": "Rufus.Rufus",
    "foss": true
  },
  "WPFInstallrustlang": {
    "category": "Development",
    "choco": "rust",
    "content": "Rust",
    "description": "Rust is a programming language designed for safety and performance, particularly focused on systems programming.",
    "link": "https://www.rust-lang.org/",
    "winget": "Rustlang.Rust.MSVC",
    "foss": true
  },
  "WPFInstallsdio": {
    "category": "Utilities",
    "choco": "sdio",
    "content": "Snappy Driver Installer Origin",
    "description": "Snappy Driver Installer Origin is a free and open-source driver updater with a vast driver database for Windows.",
    "link": "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
    "winget": "GlennDelahoy.SnappyDriverInstallerOrigin",
    "foss": true
  },
  "WPFInstallsharex": {
    "category": "Multimedia Tools",
    "choco": "sharex",
    "content": "ShareX (Screenshots)",
    "description": "ShareX is a free and open-source screen capture and file sharing tool. It supports various capture methods and offers advanced features for editing and sharing screenshots.",
    "link": "https://getsharex.com/",
    "winget": "ShareX.ShareX",
    "foss": true
  },
  "WPFInstallnilesoftShell": {
    "category": "Utilities",
    "choco": "nilesoft-shell",
    "content": "Nilesoft Shell",
    "description": "Shell is an expanded context menu tool that adds extra functionality and customization options to the Windows context menu.",
    "link": "https://nilesoft.org/",
    "winget": "Nilesoft.Shell",
    "foss": false
  },
  "WPFInstallsysteminformer": {
    "category": "Development",
    "choco": "systeminformer",
    "content": "System Informer",
    "description": "A free, powerful, multi-purpose tool that helps you monitor system resources, debug software and detect malware.",
    "link": "https://systeminformer.com/",
    "winget": "WinsiderSS.SystemInformer",
    "foss": true
  },
  "WPFInstallsignal": {
    "category": "Communications",
    "choco": "signal",
    "content": "Signal",
    "description": "Signal is a privacy-focused messaging app that offers end-to-end encryption for secure and private communication.",
    "link": "https://signal.org/",
    "winget": "OpenWhisperSystems.Signal",
    "foss": true
  },
  "WPFInstallsignalrgb": {
    "category": "Utilities",
    "choco": "na",
    "content": "SignalRGB",
    "description": "SignalRGB lets you control and sync your favorite RGB devices with one free application.",
    "link": "https://www.signalrgb.com/",
    "winget": "WhirlwindFX.SignalRgb",
    "foss": false
  },
  "WPFInstallsimplenote": {
    "category": "Document",
    "choco": "simplenote",
    "content": "Simplenote",
    "description": "Simplenote is an easy way to keep notes, lists, ideas and more.",
    "link": "https://simplenote.com/",
    "winget": "Automattic.Simplenote",
    "foss": true
  },
  "WPFInstallsimplewall": {
    "category": "Pro Tools",
    "choco": "simplewall",
    "content": "Simplewall",
    "description": "Simplewall is a free and open-source firewall application for Windows. It allows users to control and manage the inbound and outbound network traffic of applications.",
    "link": "https://github.com/henrypp/simplewall",
    "winget": "Henry++.simplewall",
    "foss": true
  },
  "WPFInstallslack": {
    "category": "Communications",
    "choco": "slack",
    "content": "Slack",
    "description": "Slack is a collaboration hub that connects teams and facilitates communication through channels, messaging, and file sharing.",
    "link": "https://slack.com/",
    "winget": "SlackTechnologies.Slack",
    "foss": false
  },
  "WPFInstallstartallback": {
    "category": "Utilities",
    "choco": "StartAllBack",
    "content": "StartAllBack",
    "description": "StartAllBack restores and improves Windows taskbar, Start menu, File Explorer, and shell UI behavior.",
    "link": "https://www.startallback.com/",
    "winget": "StartIsBack.StartAllBack",
    "foss": false
  },
  "WPFInstallstarship": {
    "category": "Development",
    "choco": "starship",
    "content": "Starship (Shell Prompt)",
    "description": "Starship is a fast, customizable, cross-platform prompt for PowerShell and other shells.",
    "link": "https://starship.rs/",
    "winget": "Starship.Starship",
    "foss": true
  },
  "WPFInstallsteam": {
    "category": "Games",
    "choco": "steam-client",
    "content": "Steam",
    "description": "Steam is a digital distribution platform for purchasing and playing video games, offering multiplayer gaming, video streaming, and more.",
    "link": "https://store.steampowered.com/about/",
    "winget": "Valve.Steam",
    "foss": false
  },
  "WPFInstallroblox": {
    "category": "Games",
    "choco": "na",
    "content": "Roblox",
    "description": "Roblox is a platform and game creation system that allows users to create and play games developed by the community.",
    "link": "https://www.roblox.com/",
    "winget": "Roblox.Roblox",
    "foss": false
  },
  "WPFInstallsublimetext": {
    "category": "Development",
    "choco": "sublimetext4",
    "content": "Sublime Text",
    "description": "Sublime Text is a sophisticated text editor for code, markup, and prose.",
    "link": "https://www.sublimetext.com/",
    "winget": "SublimeHQ.SublimeText.4",
    "foss": false
  },
  "WPFInstallsumatra": {
    "category": "Document",
    "choco": "sumatrapdf",
    "content": "Sumatra PDF",
    "description": "Sumatra PDF is a lightweight and fast PDF viewer with minimalistic design.",
    "link": "https://www.sumatrapdfreader.org/free-pdf-reader.html",
    "winget": "SumatraPDF.SumatraPDF",
    "foss": true
  },
  "WPFInstallsunshine": {
    "category": "Selfhosted Tools",
    "choco": "sunshine",
    "content": "Sunshine/GameStream Server",
    "description": "Sunshine is a GameStream server that allows you to remotely play PC games on Android devices, offering low-latency streaming.",
    "link": "https://app.lizardbyte.dev/Sunshine/",
    "winget": "LizardByte.Sunshine",
    "foss": true
  },
  "WPFInstalltcpview": {
    "category": "Microsoft Tools",
    "choco": "tcpview",
    "content": "TCPView",
    "description": "SysInternals TCPView is a network monitoring tool that displays a detailed list of all TCP and UDP endpoints on your system.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
    "winget": "Microsoft.Sysinternals.TCPView",
    "foss": false
  },
  "WPFInstallteams": {
    "category": "Communications",
    "choco": "microsoft-teams",
    "content": "Teams",
    "description": "Microsoft Teams is a collaboration platform that integrates with Office 365 and offers chat, video conferencing, file sharing, and more.",
    "link": "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
    "winget": "Microsoft.Teams",
    "foss": false
  },
  "WPFInstallteamviewer": {
    "category": "Utilities",
    "choco": "teamviewer9",
    "content": "TeamViewer",
    "description": "TeamViewer is a popular remote access and support software that allows you to connect to and control remote devices.",
    "link": "https://www.teamviewer.com/",
    "winget": "TeamViewer.TeamViewer",
    "foss": false
  },
  "WPFInstallteamspeak3": {
    "category": "Communications",
    "choco": "teamspeak",
    "content": "TeamSpeak 3",
    "description": "TEAMSPEAK. YOUR TEAM. YOUR RULES. Use crystal clear sound to communicate with your teammates cross-platform with military-grade security, lag-free performance & unparalleled reliability and uptime.",
    "link": "https://www.teamspeak.com/",
    "winget": "TeamSpeakSystems.TeamSpeakClient",
    "foss": false
  },
  "WPFInstallteamspeak6": {
    "category": "Communications",
    "choco": "na",
    "content": "TeamSpeak 6",
    "description": "TEAMSPEAK. YOUR TEAM. YOUR RULES. Use crystal clear sound to communicate with your teammates cross-platform with military-grade security, lag-free performance & unparalleled reliability and uptime.",
    "link": "https://www.teamspeak.com/",
    "winget": "TeamSpeakSystems.TeamSpeakClient.Beta.6",
    "foss": false
  },
  "WPFInstalltelegram": {
    "category": "Communications",
    "choco": "telegram",
    "content": "Telegram",
    "description": "Telegram is a cloud-based instant messaging app known for its security features, speed, and simplicity.",
    "link": "https://telegram.org/",
    "winget": "Telegram.TelegramDesktop",
    "foss": true
  },
  "WPFInstallterminal": {
    "category": "Microsoft Tools",
    "choco": "microsoft-windows-terminal",
    "content": "Windows Terminal",
    "description": "Windows Terminal is a modern, fast, and efficient terminal application for command-line users, supporting multiple tabs, panes, and more.",
    "link": "https://aka.ms/terminal",
    "winget": "Microsoft.WindowsTerminal",
    "foss": true
  },
  "WPFInstallthunderbird": {
    "category": "Communications",
    "choco": "thunderbird",
    "content": "Thunderbird",
    "description": "Mozilla Thunderbird is a free and open-source email client, news client, and chat client with advanced features.",
    "link": "https://www.thunderbird.net/",
    "winget": "Mozilla.Thunderbird",
    "foss": true
  },
  "WPFInstallbetterbird": {
    "category": "Communications",
    "choco": "betterbird",
    "content": "Betterbird",
    "description": "Betterbird is a fork of Mozilla Thunderbird with additional features and bugfixes.",
    "link": "https://www.betterbird.eu/",
    "winget": "Betterbird.Betterbird",
    "foss": true
  },
  "WPFInstalltor": {
    "category": "Browsers",
    "choco": "tor-browser",
    "content": "Tor Browser",
    "description": "Tor Browser is designed for anonymous web browsing, utilizing the Tor network to protect user privacy and security.",
    "link": "https://www.torproject.org/",
    "winget": "TorProject.TorBrowser",
    "foss": true
  },
  "WPFInstalltotalcommander": {
    "category": "Utilities",
    "choco": "TotalCommander",
    "content": "Total Commander",
    "description": "Total Commander is a file manager for Windows that provides a powerful and intuitive interface for file management.",
    "link": "https://www.ghisler.com/",
    "winget": "Ghisler.TotalCommander",
    "foss": false
  },
  "WPFInstalltreesize": {
    "category": "Utilities",
    "choco": "treesizefree",
    "content": "TreeSize Free",
    "description": "TreeSize Free is a disk space manager that helps you analyze and visualize the space usage on your drives.",
    "link": "https://www.jam-software.com/treesize_free/",
    "winget": "JAMSoftware.TreeSize.Free",
    "foss": false
  },
  "WPFInstallttaskbar": {
    "category": "Utilities",
    "choco": "translucenttb",
    "content": "TranslucentTB",
    "description": "TranslucentTB is a tool that allows you to customize the transparency of the Windows Taskbar.",
    "link": "https://translucenttb.github.io",
    "winget": "CharlesMilette.TranslucentTB",
    "foss": true
  },
  "WPFInstallubisoft": {
    "category": "Games",
    "choco": "ubisoft-connect",
    "content": "Ubisoft Connect",
    "description": "Ubisoft Connect is Ubisoft's digital distribution and online gaming service, providing access to Ubisoft's games and services.",
    "link": "https://ubisoftconnect.com/",
    "winget": "Ubisoft.Connect",
    "foss": false
  },
  "WPFInstallungoogled": {
    "category": "Browsers",
    "choco": "ungoogled-chromium",
    "content": "Ungoogled Chromium",
    "description": "Ungoogled Chromium is a version of Chromium without Google's integration for enhanced privacy and control.",
    "link": "https://github.com/Eloston/ungoogled-chromium",
    "winget": "eloston.ungoogled-chromium",
    "foss": true
  },
  "WPFInstallunity": {
    "category": "Development",
    "choco": "unityhub",
    "content": "Unity Game Engine",
    "description": "Unity is a powerful game development platform for creating 2D, 3D, augmented reality, and virtual reality games.",
    "link": "https://unity.com/",
    "winget": "Unity.UnityHub",
    "foss": false
  },
  "WPFInstallvagrant": {
    "category": "Development",
    "choco": "vagrant",
    "content": "Vagrant",
    "description": "Vagrant builds and manages reproducible virtual machine development environments from declarative configuration.",
    "link": "https://developer.hashicorp.com/vagrant",
    "winget": "Hashicorp.Vagrant",
    "foss": false
  },
  "WPFInstalleverything": {
    "category": "Utilities",
    "choco": "everything",
    "content": "Everything",
    "description": "Everything is a search engine that locates files and folders by filename instantly for Windows. Unlike Windows search Everything initially displays every file and folder on your computer (hence the name Everything). You type in a search filter to limit what files and folders are displayed.",
    "link": "https://www.voidtools.com/",
    "winget": "voidtools.Everything",
    "foss": false
  },
  "WPFInstallvc2015_32": {
    "category": "Microsoft Tools",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 32-bit",
    "description": "Visual C++ 2015-2022 32-bit redistributable package installs runtime components of Visual C++ libraries required to run 32-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x86",
    "foss": false
  },
  "WPFInstallvc2015_64": {
    "category": "Microsoft Tools",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 64-bit",
    "description": "Visual C++ 2015-2022 64-bit redistributable package installs runtime components of Visual C++ libraries required to run 64-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x64",
    "foss": false
  },
  "WPFInstallventoy": {
    "category": "Pro Tools",
    "choco": "ventoy",
    "content": "Ventoy",
    "description": "Ventoy is an open-source tool for creating bootable USB drives. It supports multiple ISO files on a single USB drive, making it a versatile solution for installing operating systems.",
    "link": "https://www.ventoy.net/",
    "winget": "Ventoy.Ventoy",
    "foss": true
  },
  "WPFInstallvesktop": {
    "category": "Communications",
    "choco": "na",
    "content": "Vesktop",
    "description": "A cross platform electron-based desktop app aiming to give you a snappier Discord experience with Vencord pre-installed.",
    "link": "https://vesktop.dev",
    "winget": "Vencord.Vesktop",
    "foss": true
  },
  "WPFInstallviber": {
    "category": "Communications",
    "choco": "viber",
    "content": "Viber",
    "description": "Viber is a free messaging and calling app with features like group chats, video calls, and more.",
    "link": "https://www.viber.com/",
    "winget": "Rakuten.Viber",
    "foss": false
  },
  "WPFInstallvisualstudio2022": {
    "category": "Development",
    "choco": "visualstudio2022community",
    "content": "Visual Studio 2022",
    "description": "Visual Studio 2022 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.2022.Community",
    "foss": false
  },
  "WPFInstallvisualstudio2026": {
    "category": "Development",
    "choco": "visualstudio2026community",
    "content": "Visual Studio 2026",
    "description": "Visual Studio 2026 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.Community",
    "foss": false
  },
  "WPFInstallvivaldi": {
    "category": "Browsers",
    "choco": "vivaldi",
    "content": "Vivaldi",
    "description": "Vivaldi is a highly customizable web browser with a focus on user personalization and productivity features.",
    "link": "https://vivaldi.com/",
    "winget": "Vivaldi.Vivaldi",
    "foss": false
  },
  "WPFInstallvlc": {
    "category": "Multimedia Tools",
    "choco": "vlc",
    "content": "VLC (Video Player)",
    "description": "VLC Media Player is a free and open-source multimedia player that supports a wide range of audio and video formats. It is known for its versatility and cross-platform compatibility.",
    "link": "https://www.videolan.org/vlc/",
    "winget": "VideoLAN.VLC",
    "foss": true
  },
  "WPFInstallvrdesktopstreamer": {
    "category": "Games",
    "choco": "na",
    "content": "Virtual Desktop Streamer",
    "description": "Virtual Desktop Streamer is a tool that allows you to stream your desktop screen to VR devices.",
    "link": "https://www.vrdesktop.net/",
    "winget": "VirtualDesktop.Streamer",
    "foss": false
  },
  "WPFInstallvscode": {
    "category": "Development",
    "choco": "vscode",
    "content": "VS Code",
    "description": "Visual Studio Code is a free, open-source code editor with support for multiple programming languages.",
    "link": "https://code.visualstudio.com/",
    "winget": "Microsoft.VisualStudioCode",
    "foss": true
  },
  "WPFInstallvscodium": {
    "category": "Development",
    "choco": "vscodium",
    "content": "VS Codium",
    "description": "VSCodium is a community-driven, freely-licensed binary distribution of Microsoft's VS Code.",
    "link": "https://vscodium.com/",
    "winget": "VSCodium.VSCodium",
    "foss": true
  },
  "WPFInstallwaterfox": {
    "category": "Browsers",
    "choco": "waterfox",
    "content": "Waterfox",
    "description": "Waterfox is a fast, privacy-focused web browser based on Firefox, designed to preserve user choice and privacy.",
    "link": "https://www.waterfox.net/",
    "winget": "Waterfox.Waterfox",
    "foss": true
  },
  "WPFInstallwhatsapp": {
    "category": "Communications",
    "choco": "na",
    "content": "WhatsApp Desktop",
    "description": "WhatsApp Desktop is the official Windows desktop messaging app from Meta, distributed through the Microsoft Store.",
    "link": "https://www.whatsapp.com/download",
    "winget": "msstore:9NKSQGP7F2NH",
    "foss": false
  },
  "WPFInstallwingetui": {
    "category": "Utilities",
    "choco": "wingetui",
    "content": "UniGetUI",
    "description": "UniGetUI is a GUI for WinGet, Chocolatey, and other Windows CLI package managers.",
    "link": "https://devolutions.net/unigetui/",
    "winget": "Devolutions.UniGetUI",
    "foss": true
  },
  "WPFInstallwinrar": {
    "category": "Utilities",
    "choco": "winrar",
    "content": "WinRAR",
    "description": "WinRAR is a powerful archive manager that allows you to create, manage, and extract compressed files.",
    "link": "https://www.win-rar.com/",
    "winget": "RARLab.WinRAR",
    "foss": false
  },
  "WPFInstallwinscp": {
    "category": "Pro Tools",
    "choco": "winscp",
    "content": "WinSCP",
    "description": "WinSCP is a popular open-source SFTP, FTP, and SCP client for Windows. It allows secure file transfers between a local and a remote computer.",
    "link": "https://winscp.net/",
    "winget": "WinSCP.WinSCP",
    "foss": true
  },
  "WPFInstallwireguard": {
    "category": "Pro Tools",
    "choco": "wireguard",
    "content": "WireGuard",
    "description": "WireGuard is a fast and modern VPN (Virtual Private Network) protocol. It aims to be simpler and more efficient than other VPN protocols, providing secure and reliable connections.",
    "link": "https://www.wireguard.com/",
    "winget": "WireGuard.WireGuard",
    "foss": true
  },
  "WPFInstallwireshark": {
    "category": "Pro Tools",
    "choco": "wireshark",
    "content": "Wireshark",
    "description": "Wireshark is a widely-used open-source network protocol analyzer. It allows users to capture and analyze network traffic in real-time, providing detailed insights into network activities.",
    "link": "https://www.wireshark.org/",
    "winget": "WiresharkFoundation.Wireshark",
    "foss": true
  },
  "WPFInstallwiztree": {
    "category": "Utilities",
    "choco": "wiztree",
    "content": "WizTree",
    "description": "WizTree is a fast disk space analyzer that helps you quickly find the files and folders consuming the most space on your hard drive.",
    "link": "https://wiztreefree.com/",
    "winget": "AntibodySoftware.WizTree",
    "foss": false
  },
  "WPFInstallxeheditor": {
    "category": "Utilities",
    "choco": "HxD",
    "content": "HxD Hex Editor",
    "description": "HxD is a free hex editor that allows you to edit, view, search, and analyze binary files.",
    "link": "https://mh-nexus.de/en/hxd/",
    "winget": "MHNexus.HxD",
    "foss": false
  },
  "WPFInstallxournal": {
    "category": "Document",
    "choco": "xournalplusplus",
    "content": "Xournal++",
    "description": "Xournal++ is an open-source handwriting notetaking software with PDF annotation capabilities.",
    "link": "https://xournalpp.github.io/",
    "winget": "Xournal++.Xournal++",
    "foss": true
  },
  "WPFInstallyarn": {
    "category": "Development",
    "choco": "yarn",
    "content": "Yarn",
    "description": "Yarn is a fast, reliable, and secure dependency management tool for JavaScript projects.",
    "link": "https://yarnpkg.com/",
    "winget": "Yarn.Yarn",
    "foss": true
  },
  "WPFInstallzoom": {
    "category": "Communications",
    "choco": "zoom",
    "content": "Zoom",
    "description": "Zoom is a popular video conferencing and web conferencing service for online meetings, webinars, and collaborative projects.",
    "link": "https://zoom.us/",
    "winget": "Zoom.Zoom",
    "foss": false
  },
  "WPFInstalluv": {
    "category": "Development",
    "choco": "uv",
    "content": "uv",
    "description": "uv is a fast Python package and project manager written in Rust.",
    "link": "https://docs.astral.sh/uv/getting-started/installation/",
    "winget": "astral-sh.uv",
    "foss": true
  },
  "WPFInstalltightvnc": {
    "category": "Utilities",
    "choco": "TightVNC",
    "content": "TightVNC",
    "description": "TightVNC is a free and open-source remote desktop software that lets you access and control a computer over the network. With its intuitive interface, you can interact with the remote screen as if you were sitting in front of it. You can open files, launch applications, and perform other actions on the remote desktop almost as if you were physically there.",
    "link": "https://www.tightvnc.com/",
    "winget": "GlavSoft.TightVNC",
    "foss": true
  },
  "WPFInstallglazewm": {
    "category": "Utilities",
    "choco": "glazewm",
    "content": "GlazeWM",
    "description": "GlazeWM is a tiling window manager for Windows inspired by i3 and Polybar.",
    "link": "https://github.com/glzr-io/glazewm",
    "winget": "glzr-io.glazewm",
    "foss": true
  },
  "WPFInstallOverwolf": {
    "category": "Games",
    "choco": "overwolf",
    "content": "Overwolf",
    "description": "Popular platform for game overlays and companion apps (mod managers, trackers, etc.), widely used by gamers.",
    "link": "https://www.overwolf.com/app/overwolf-curseforge",
    "winget": "Overwolf.CurseForge",
    "foss": false
  },
  "WPFInstallOFGB": {
    "category": "Utilities",
    "choco": "ofgb",
    "content": "OFGB (Oh Frick Go Back)",
    "description": "GUI Tool to remove ads from various places around Windows 11",
    "link": "https://github.com/xM4ddy/OFGB",
    "winget": "xM4ddy.OFGB",
    "foss": true
  },
  "WPFInstallZenBrowser": {
    "category": "Browsers",
    "choco": "zen-browser",
    "content": "Zen Browser",
    "description": "The modern, privacy-focused, performance-driven browser built on Firefox.",
    "link": "https://zen-browser.app/",
    "winget": "Zen-Team.Zen-Browser",
    "foss": true
  },
  "WPFInstallZed": {
    "category": "Development",
    "choco": "zed",
    "content": "Zed",
    "description": "Zed is a modern, high-performance code editor designed from the ground up for speed and collaboration.",
    "link": "https://zed.dev/",
    "winget": "ZedIndustries.Zed",
    "foss": true
  },
  "WPFInstallzotero": {
    "category": "Document",
    "choco": "zotero",
    "content": "Zotero",
    "description": "Zotero is a free, easy-to-use tool to help you collect, organize, cite, and share your research materials.",
    "link": "https://www.zotero.org/",
    "winget": "DigitalScholar.Zotero",
    "foss": true
  },
  "WPFInstalldeskflow": {
    "category": "Utilities",
    "choco": "deskflow",
    "content": "Deskflow",
    "description": "Deskflow is a free and open-source software KVM that lets you share a single keyboard and mouse across multiple computers.",
    "link": "https://github.com/deskflow/deskflow",
    "winget": "Deskflow.Deskflow",
    "foss": true
  },
  "WPFInstallRuby": {
    "category": "Development",
    "choco": "ruby",
    "winget": "RubyInstallerTeam.Ruby.4.0",
    "description": "A Ruby language execution environment with a MSYS2 installation.",
    "content": "Ruby",
    "link": "https://rubyinstaller.org/",
    "foss": true
  },
  "WPFInstallLua": {
    "category": "Development",
    "choco": "lua",
    "winget": "rjpcomputing.luaforwindows",
    "description": "A 'batteries included environment' for the Lua scripting language on Windows.",
    "content": "Lua",
    "link": "https://github.com/rjpcomputing/luaforwindows",
    "foss": true
  },
  "WPFInstallCloudflareWARP": {
    "category": "Utilities",
    "choco": "warp",
    "winget": "Cloudflare.Warp",
    "description": "WARP is a freemium VPN service provided by Cloudflare. Includes usage of Cloudflare's DNS",
    "content": "Cloudflare WARP",
    "link": "https://one.one.one.one",
    "foss": false
  }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
  "WPFInstall": {
    "Content": "Install/Upgrade Applications",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "1",
    "Description": "Install or upgrade the selected applications"
  },
  "WPFUninstall": {
    "Content": "Uninstall Applications",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "2",
    "Description": "Uninstall the selected applications"
  },
  "WPFInstallUpgrade": {
    "Content": "Upgrade all Applications",
    "Category": "____Actions",
    "Type": "Button",
    "Order": "3",
    "Description": "Upgrade all applications to the latest version"
  },
  "WingetRadioButton": {
    "Content": "WinGet",
    "Category": "__Package Manager",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": true,
    "Order": "1",
    "Description": "Use WinGet for package management"
  },
  "ChocoRadioButton": {
    "Content": "Chocolatey",
    "Category": "__Package Manager",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": false,
    "Order": "2",
    "Description": "Use Chocolatey for package management"
  },
  "WPFCollapseAllCategories": {
    "Content": "Collapse All Categories",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "1",
    "Description": "Collapse all application categories"
  },
  "WPFExpandAllCategories": {
    "Content": "Expand All Categories",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "2",
    "Description": "Expand all application categories"
  },
  "WPFClearInstallSelection": {
    "Content": "Clear Selection",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "3",
    "Description": "Clear the selection of applications"
  },
  "WPFGetInstalled": {
    "Content": "Show Installed Apps",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "4",
    "Description": "Show installed applications"
  },
  "WPFselectedAppsButton": {
    "Content": "Selected Apps: 0",
    "Category": "__Selection",
    "Type": "Button",
    "Order": "5",
    "Description": "Show the selected applications"
  },
  "WPFInstallFOSSInfo": {
    "Content": "Free and Open Source Software",
    "Category": "__Selection",
    "Type": "Note",
    "Order": "0",
    "Description": "Information about the #FOSS label on application entries"
  }
}
'@ | ConvertFrom-Json
$sync.configs.appx = @'
{
  "WPFAppxMicrosoft_WindowsFeedbackHub": {
    "Category": "Microsoft Apps",
    "Content": "Feedback Hub",
    "Description": "Allows users to submit bug reports, feature suggestions, and diagnostic data directly to Microsoft.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsFeedbackHub",
    "StoreId": "9NBLGGH4R32N"
  },
  "WPFAppxMicrosoft_GetHelp": {
    "Category": "Microsoft Apps",
    "Content": "Get Help",
    "Description": "Provides access to automated troubleshooting guides, support documentation, and direct Microsoft customer assistance.",
    "Panel": "0",
    "PackageId": "Microsoft.GetHelp",
    "StoreId": "9PKDZBMV1H3T"
  },
  "WPFAppxMicrosoft_OutlookForWindows": {
    "Category": "Microsoft Apps",
    "Content": "Outlook for Windows",
    "Description": "Provides modern email management, calendar scheduling, and contact organization features.",
    "Panel": "0",
    "PackageId": "Microsoft.OutlookForWindows",
    "StoreId": "9NRX63209R7B"
  },
  "WPFAppxMSTeams": {
    "Category": "Microsoft Apps",
    "Content": "Microsoft Teams",
    "Description": "Facilitates instant messaging, video conferencing, file sharing, and workspace collaboration.",
    "Panel": "0",
    "PackageId": "MSTeams",
    "StoreId": "XP8BT8DW290MPQ"
  },
  "WPFAppxClipchamp_Clipchamp": {
    "Category": "Utilities & Productivity",
    "Content": "Clipchamp",
    "Description": "Provides a user-friendly video editor with built-in templates, effects, and timeline editing tools.",
    "Panel": "0",
    "PackageId": "Clipchamp.Clipchamp",
    "StoreId": "9P1J8S7CCWWT"
  },
  "WPFAppxMicrosoft_MicrosoftOfficeHub": {
    "Category": "Microsoft Apps",
    "Content": "Microsoft 365",
    "Description": "Serves as a centralized launcher and dashboard for accessing cloud-based Microsoft 365 apps and recent documents.",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftOfficeHub",
    "StoreId": "9WZDNCRD29V9"
  },
  "WPFAppxMicrosoft_ZuneMusic": {
    "Category": "Utilities & Productivity",
    "Content": "Media Player",
    "Description": "Plays local audio and video files with modern playlist management and casting capabilities.",
    "Panel": "0",
    "PackageId": "Microsoft.ZuneMusic",
    "StoreId": "9WZDNCRFJ3PT"
  },
  "WPFAppxMicrosoft_BingSearch": {
    "Category": "Bing & Web Services",
    "Content": "Bing Search",
    "Description": "Integrates Microsoft Bing search capabilities and web services directly into the operating system.",
    "Panel": "1",
    "PackageId": "Microsoft.BingSearch",
    "StoreId": "9NZBF4GT040C"
  },
  "WPFAppxMicrosoftCorporationII_QuickAssist": {
    "Category": "Utilities & Productivity",
    "Content": "Quick Assist",
    "Description": "Enables secure remote technical support and screen sharing over an internet connection.",
    "Panel": "0",
    "PackageId": "MicrosoftCorporationII.QuickAssist",
    "StoreId": "9P7BP5VNWKX5"
  },
  "WPFAppxMicrosoft_WindowsDevHome": {
    "Category": "Developer Tools",
    "Content": "Dev Home",
    "Description": "Provides a specialized dashboard for software developer environment setups, repository syncing, and hardware widgets.",
    "Panel": "1",
    "PackageId": "Microsoft.Windows.DevHome",
    "StoreId": "9N8MHTPHNGVV"
  },
  "WPFAppxMicrosoft_WindowsCrossDevice": {
    "Category": "Microsoft Ecosystem",
    "Content": "Mobile Devices",
    "Description": "Manages system-level background connectivity with paired mobile devices. Removing this may disable cross-device features such as phone screen mirroring, file transfer, and mobile hotspot handoff integrated into Windows Settings.",
    "Panel": "0",
    "PackageId": "MicrosoftWindows.CrossDevice",
    "StoreId": "9NTXGKQ8P7N0"
  },
  "WPFAppxMicrosoft_Todos": {
    "Category": "Utilities & Productivity",
    "Content": "To Do",
    "Description": "Creates, tracks, and synchronizes personal tasks, smart lists, and daily reminders.",
    "Panel": "0",
    "PackageId": "Microsoft.Todos",
    "StoreId": "9NBLGGH5R558"
  },
  "WPFAppxMicrosoft_PowerAutomateDesktop": {
    "Category": "Developer Tools",
    "Content": "Power Automate",
    "Description": "Automates repetitive workflows and desktop tasks using low-code visual scripting.",
    "Panel": "1",
    "PackageId": "Microsoft.PowerAutomateDesktop",
    "StoreId": "9NFTCH6J7FHV"
  },
  "WPFAppxMicrosoft_YourPhone": {
    "Category": "Microsoft Ecosystem",
    "Content": "Phone Link",
    "Description": "Synchronizes text messages, phone notifications, photos, and calls from a mobile device to the desktop.",
    "Panel": "0",
    "PackageId": "Microsoft.YourPhone",
    "StoreId": "9NMPJ99VJBWV"
  },
  "WPFAppxMicrosoft_MicrosoftStickyNotes": {
    "Category": "Utilities & Productivity",
    "Content": "Sticky Notes",
    "Description": "Creates quick, floating text notes on the desktop that automatically sync across devices.",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftStickyNotes",
    "StoreId": "9NBLGGH4QGHW"
  },
  "WPFAppxMicrosoft_WindowsSoundRecorder": {
    "Category": "Utilities & Productivity",
    "Content": "Sound Recorder",
    "Description": "Records and trims live audio inputs with simple microphone adjustment controls.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsSoundRecorder",
    "StoreId": "9WZDNCRFHWKN"
  },
  "WPFAppxMicrosoft_WindowsAlarms": {
    "Category": "Utilities & Productivity",
    "Content": "Clock",
    "Description": "Features world clocks, alarms, countdown timers, stopwatches, and dedicated focus session tracking.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsAlarms",
    "StoreId": "9WZDNCRFJ3PR"
  },
  "WPFAppxMicrosoft_Paint": {
    "Category": "Utilities & Productivity",
    "Content": "Paint",
    "Description": "Provides built-in digital sketching, basic image editing, and pixel-level graphic manipulation tools.",
    "Panel": "0",
    "PackageId": "Microsoft.Paint",
    "StoreId": "9PCFS5B6T72H"
  },
  "WPFAppxMicrosoft_WindowsNotepad": {
    "Category": "Utilities & Productivity",
    "Content": "Notepad",
    "Description": "Provides a lightweight text editor with multi-tab support for plain text files and code snippets.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsNotepad",
    "StoreId": "9MSMLRH6LZF3"
  },
  "WPFAppxMicrosoft_ScreenSketch": {
    "Category": "Utilities & Productivity",
    "Content": "Snipping Tool",
    "Description": "Captures screenshots or screen recordings with built-in markup, image cropping, and optical character recognition (OCR).",
    "Panel": "0",
    "PackageId": "Microsoft.ScreenSketch",
    "StoreId": "9MZ95KL8MR0L"
  },
  "WPFAppxMicrosoft_Copilot": {
    "Category": "Bing & Web Services",
    "Content": "Copilot",
    "Description": "Launches the Microsoft AI companion for contextual answers, creative writing assistance, and intelligent web search.",
    "Panel": "1",
    "PackageId": "Microsoft.Copilot",
    "StoreId": "9NHT9RB2F4HD"
  },
  "WPFAppxMicrosoft_WindowsCalculator": {
    "Category": "Utilities & Productivity",
    "Content": "Calculator",
    "Description": "Performs standard arithmetic, scientific operations, programming calculations, and unit conversions.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCalculator",
    "StoreId": "9WZDNCRFHVN5"
  },
  "WPFAppxMicrosoft_WindowsCamera": {
    "Category": "Utilities & Productivity",
    "Content": "Camera",
    "Description": "Captures photographs and records video files via connected webcams or imaging hardware.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCamera",
    "StoreId": "9WZDNCRFJBBG"
  },
  "WPFAppxMicrosoft_WindowsPhotos": {
    "Category": "Utilities & Productivity",
    "Content": "Photos",
    "Description": "Organizes, views, and crops local images with basic color adjustment and album creation tools.",
    "Panel": "0",
    "PackageId": "Microsoft.Windows.Photos",
    "StoreId": "9WZDNCRFJBH4"
  },
  "WPFAppxMicrosoft_BingNews": {
    "Category": "Bing & Web Services",
    "Content": "News",
    "Description": "Aggregates breaking news headlines, personalized article feeds, and world current events.",
    "Panel": "1",
    "PackageId": "Microsoft.BingNews",
    "StoreId": "9WZDNCRFHVFW"
  },
  "WPFAppxMicrosoft_BingWeather": {
    "Category": "Bing & Web Services",
    "Content": "Weather",
    "Description": "Displays local real-time weather tracking, radar maps, and historical meteorological forecasts.",
    "Panel": "1",
    "PackageId": "Microsoft.BingWeather",
    "StoreId": "9WZDNCRFJ3Q2"
  },
  "WPFAppxMicrosoft_GamingApp": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox App",
    "Description": "Serves as the primary gaming library manager, social community interface, and PC Game Pass dashboard.",
    "Panel": "1",
    "PackageId": "Microsoft.GamingApp",
    "StoreId": "9MV0B5HZVK9Z"
  },
  "WPFAppxMicrosoft_XboxGamingOverlay": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox Game Bar",
    "Description": "Provides customizable in-game status widgets, audio balancing sliders, system monitoring tools, and gameplay recording.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxGamingOverlay",
    "StoreId": "9NZKPSTSNW4P"
  },
  "WPFAppxMicrosoft_XboxIdentityProvider": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox Identity Provider",
    "Description": "Manages Xbox network user authentication and background account validation for connected titles. Warning: removing this may break Microsoft account sign-in for non-Xbox games and apps that rely on this authentication pipeline.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxIdentityProvider",
    "StoreId": "9WZDNCRD1HKW"
  },
  "WPFAppxMicrosoft_XboxSpeechToTextOverlay": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox Speech To Text Overlay",
    "Description": "Provides system-level live accessibility captions and voice-to-text translation for gaming chat networks.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxSpeechToTextOverlay"
  },
  "WPFAppxMicrosoft_Xbox_TCUI": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox TCUI",
    "Description": "Provides core account connection UI modules for single sign-on flows within game titles. Warning: removing this may break Microsoft account authentication in games and apps that do not otherwise require the Xbox app.",
    "Panel": "1",
    "PackageId": "Microsoft.Xbox.TCUI"
  },
  "WPFAppxMicrosoft_StartExperiencesApp": {
    "Category": "Bing & Web Services",
    "Content": "Start Experiences App",
    "Description": "Powers the Windows Widgets board, delivering a personalized feed of news, weather, sports, and finance content.",
    "Panel": "1",
    "PackageId": "Microsoft.StartExperiencesApp",
    "StoreId": "9PC1H9VN18CM"
  },
  "WPFAppxMicrosoft_MicrosoftSolitaireCollection": {
    "Category": "Xbox & Gaming",
    "Content": "Solitaire Collection",
    "Description": "Bundles built-in card game modes including Klondike, Spider, FreeCell, Pyramid, and TriPeaks alongside daily challenges.",
    "Panel": "1",
    "PackageId": "Microsoft.MicrosoftSolitaireCollection"
  }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
  "Google": {
    "Primary": "8.8.8.8",
    "Secondary": "8.8.4.4",
    "Primary6": "2001:4860:4860::8888",
    "Secondary6": "2001:4860:4860::8844",
    "DohTemplate": "https://dns.google/dns-query"
  },
  "Cloudflare": {
    "Primary": "1.1.1.1",
    "Secondary": "1.0.0.1",
    "Primary6": "2606:4700:4700::1111",
    "Secondary6": "2606:4700:4700::1001",
    "DohTemplate": "https://cloudflare-dns.com/dns-query"
  },
  "Cloudflare_Malware": {
    "Primary": "1.1.1.2",
    "Secondary": "1.0.0.2",
    "Primary6": "2606:4700:4700::1112",
    "Secondary6": "2606:4700:4700::1002",
    "DohTemplate": "https://security.cloudflare-dns.com/dns-query"
  },
  "Cloudflare_Malware_Adult": {
    "Primary": "1.1.1.3",
    "Secondary": "1.0.0.3",
    "Primary6": "2606:4700:4700::1113",
    "Secondary6": "2606:4700:4700::1003",
    "DohTemplate": "https://family.cloudflare-dns.com/dns-query"
  },
  "Open_DNS": {
    "Primary": "208.67.222.222",
    "Secondary": "208.67.220.220",
    "Primary6": "2620:119:35::35",
    "Secondary6": "2620:119:53::53",
    "DohTemplate": "https://doh.opendns.com/dns-query"
  },
  "Quad9": {
    "Primary": "9.9.9.9",
    "Secondary": "149.112.112.112",
    "Primary6": "2620:fe::fe",
    "Secondary6": "2620:fe::9",
    "DohTemplate": "https://dns.quad9.net/dns-query"
  },
  "AdGuard_Ads_Trackers": {
    "Primary": "94.140.14.14",
    "Secondary": "94.140.15.15",
    "Primary6": "2a10:50c0::ad1:ff",
    "Secondary6": "2a10:50c0::ad2:ff",
    "DohTemplate": "https://dns.adguard-dns.com/dns-query"
  },
  "AdGuard_Ads_Trackers_Malware_Adult": {
    "Primary": "94.140.14.15",
    "Secondary": "94.140.15.16",
    "Primary6": "2a10:50c0::bad1:ff",
    "Secondary6": "2a10:50c0::bad2:ff",
    "DohTemplate": "https://family.adguard-dns.com/dns-query"
  },
  "Mullvad": {
    "Primary": "194.242.2.2",
    "Secondary": "194.242.2.3",
    "Primary6": "2a07:e340::2",
    "Secondary6": "2a07:e340::3",
    "DohOnly": true,
    "DohTemplate": "https://dns.mullvad.net/dns-query",
    "SecondaryDohTemplate": "https://adblock.dns.mullvad.net/dns-query"
  },
  "Mullvad_Ads_Trackers": {
    "Primary": "194.242.2.3",
    "Secondary": "194.242.2.2",
    "Primary6": "2a07:e340::3",
    "Secondary6": "2a07:e340::2",
    "DohOnly": true,
    "DohTemplate": "https://adblock.dns.mullvad.net/dns-query",
    "SecondaryDohTemplate": "https://dns.mullvad.net/dns-query"
  },
  "Mullvad_Ads_Trackers_Malware": {
    "Primary": "194.242.2.4",
    "Secondary": "194.242.2.3",
    "Primary6": "2a07:e340::4",
    "Secondary6": "2a07:e340::3",
    "DohOnly": true,
    "DohTemplate": "https://base.dns.mullvad.net/dns-query",
    "SecondaryDohTemplate": "https://adblock.dns.mullvad.net/dns-query"
  },
  "Mullvad_Ads_Trackers_Malware_Social": {
    "Primary": "194.242.2.5",
    "Secondary": "194.242.2.4",
    "Primary6": "2a07:e340::5",
    "Secondary6": "2a07:e340::4",
    "DohOnly": true,
    "DohTemplate": "https://extended.dns.mullvad.net/dns-query",
    "SecondaryDohTemplate": "https://base.dns.mullvad.net/dns-query"
  },
  "Mullvad_Ads_Trackers_Malware_Adult_Gambling": {
    "Primary": "194.242.2.6",
    "Secondary": "194.242.2.5",
    "Primary6": "2a07:e340::6",
    "Secondary6": "2a07:e340::5",
    "DohOnly": true,
    "DohTemplate": "https://family.dns.mullvad.net/dns-query",
    "SecondaryDohTemplate": "https://extended.dns.mullvad.net/dns-query"
  },
  "Mullvad_Ads_Trackers_Malware_Adult_Gambling_Social": {
    "Primary": "194.242.2.9",
    "Secondary": "194.242.2.6",
    "Primary6": "2a07:e340::9",
    "Secondary6": "2a07:e340::6",
    "DohOnly": true,
    "DohTemplate": "https://all.dns.mullvad.net/dns-query",
    "SecondaryDohTemplate": "https://family.dns.mullvad.net/dns-query"
  }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
  "WPFFeaturesdotnet": {
    "Content": ".NET Framework (Versions 2, 3, 4) - Enable",
    "Description": ".NET and .NET Framework is a developer platform made up of tools, programming languages, and libraries for building many different types of applications.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "NetFx4-AdvSrvs",
      "NetFx3"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/code-reference/features/features/dotnet"
  },
  "WPFFixesNTPPool": {
    "Content": "NTP Server - Enable",
    "Description": "Replaces the default Windows NTP server (time.windows.com) with pool.ntp.org for improved time synchronization accuracy and reliability.",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNTPPool",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/ntppool"
  },
  "WPFFeatureshyperv": {
    "Content": "Hyper-V - Enable",
    "Description": "Hyper-V is a hardware virtualization product developed by Microsoft that allows users to create and manage virtual machines.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "Microsoft-Hyper-V-All"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/hyperv"
  },
  "WPFFeatureslegacymedia": {
    "Content": "Legacy Media Components (WMP, DirectPlay) - Enable",
    "Description": "Enables legacy programs from previous versions of Windows.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "WindowsMediaPlayer",
      "MediaPlayback",
      "DirectPlay",
      "LegacyComponents"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/code-reference/features/features/legacymedia"
  },
  "WPFFeaturewsl": {
    "Content": "Windows Subsystem for Linux (WSL) - Enable",
    "Description": "Windows Subsystem for Linux is an optional feature of Windows that allows Linux programs to run natively on Windows without the need for a separate virtual machine or dual booting.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "VirtualMachinePlatform",
      "Microsoft-Windows-Subsystem-Linux"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/code-reference/features/features/wsl"
  },
  "WPFFeaturenfs": {
    "Content": "Network File System (NFS) - Enable",
    "Description": "Network File System (NFS) is a mechanism for storing files on a network.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "ServicesForNFS-ClientOnly",
      "ClientForNFS-Infrastructure",
      "NFS-Administration"
    ],
    "InvokeScript": [
      "nfsadmin client stop",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousUID' -Type DWord -Value 0",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousGID' -Type DWord -Value 0",
      "nfsadmin client start",
      "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/nfs"
  },
  "WPFFeatureRegBackup": {
    "Content": "Registry Backup (Daily Task 12:30am) - Enable",
    "Description": "Enables daily registry backup, previously disabled by Microsoft in Windows 10 1803.",
    "category": "Features",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'EnablePeriodicBackup' -Type DWord -Value 1 -Force\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'BackupCount' -Type DWord -Value 2 -Force\r\n      $action = New-ScheduledTaskAction -Execute 'schtasks' -Argument '/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"'\r\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\r\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName 'AutoRegBackup' -Description 'Create System Registry Backups' -User 'System'\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/regbackup"
  },
  "WPFFeatureEnableLegacyRecovery": {
    "Content": "Legacy F8 Boot Recovery - Enable",
    "Description": "Enables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
    "category": "Features",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy legacy"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/enablelegacyrecovery"
  },
  "WPFFeatureDisableLegacyRecovery": {
    "Content": "Legacy F8 Boot Recovery - Disable",
    "Description": "Disables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
    "category": "Features",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy standard"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/disablelegacyrecovery"
  },
  "WPFFeaturesSandbox": {
    "Content": "Windows Sandbox - Enable",
    "Description": "Windows Sandbox is a lightweight virtual machine that provides a temporary desktop environment to safely run applications and programs in isolation.",
    "category": "Features",
    "panel": "1",
    "feature": [
      "Containers-DisposableClientVM"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/sandbox"
  },
  "WPFFeatureInstall": {
    "Content": "Install Features",
    "category": "Features",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFeatureInstall",
    "link": "https://winutil.christitus.com/code-reference/features/features/install"
  },
  "WPFPanelAutologin": {
    "Content": "AutoLogon - Run",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFPanelAutologin",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/autologin"
  },
  "WPFFixesUpdate": {
    "Content": "Windows Update - Reset",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesUpdate",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/update"
  },
  "WPFFixesNetwork": {
    "Content": "Network - Reset",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNetwork",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/network"
  },
  "WPFPanelDISM": {
    "Content": "System Corruption Scan - Run",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSystemRepair",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/dism"
  },
  "WPFFixesWinget": {
    "Content": "WinGet - Reinstall",
    "category": "Fixes",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesWinget",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/winget"
  },
  "WPFPanelComputer": {
    "Content": "Computer Management",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "compmgmt.msc"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/computer"
  },
  "WPFPanelControl": {
    "Content": "Control Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "control"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/control"
  },
  "WPFPanelMouse": {
    "Content": "Mouse Properties",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "main.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/mouse"
  },
  "WPFPanelNetwork": {
    "Content": "Network Connections",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "ncpa.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/network"
  },
  "WPFPanelPower": {
    "Content": "Power Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "powercfg.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/power"
  },
  "WPFPanelPrinter": {
    "Content": "Printer Panel",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "Start-Process 'shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}'"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/printer"
  },
  "WPFPanelPrograms": {
    "Content": "Programs and Features",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "appwiz.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/programs"
  },
  "WPFPanelRegion": {
    "Content": "Region",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "intl.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/region"
  },
  "WPFPanelSecurity": {
    "Content": "Security and Maintenance",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "wscui.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/security"
  },
  "WPFPanelSound": {
    "Content": "Sound Settings",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "mmsys.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/sound"
  },
  "WPFPanelSystem": {
    "Content": "System Properties",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "sysdm.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/system"
  },
  "WPFPanelTimedate": {
    "Content": "Time and Date",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "timedate.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/timedate"
  },
  "WPFPanelFirewall": {
    "Content": "Windows Defender Firewall",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "firewall.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/firewall"
  },
  "WPFPanelRestore": {
    "Content": "Windows Restore",
    "category": "Legacy Windows Panels",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "rstrui.exe"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/restore"
  },
  "WPFWinUtilInstallPSProfile": {
    "Content": "CTT PowerShell Profile - Install",
    "category": "Powershell Profile Powershell 7+ Only",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilInstallPSProfile",
    "link": "https://winutil.christitus.com/code-reference/features/powershell-profile-powershell-7--only/installpsprofile"
  },
  "WPFWinUtilUninstallPSProfile": {
    "Content": "CTT PowerShell Profile - Remove",
    "category": "Powershell Profile Powershell 7+ Only",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilUninstallPSProfile",
    "link": "https://winutil.christitus.com/code-reference/features/powershell-profile-powershell-7--only/uninstallpsprofile"
  },
  "WPFWinUtilSSHServer": {
    "Content": "OpenSSH Server - Enable",
    "category": "Remote Access",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSSHServer",
    "link": "https://winutil.christitus.com/code-reference/features/remote-access/sshserver"
  }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
  "Standard": [
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDiskCleanup",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksRestorePoint"
  ],
  "Minimal": [
    "WPFTweaksConsumerFeatures",
    "WPFTweaksWPBT",
    "WPFTweaksServices",
    "WPFTweaksTelemetry"
  ],
  "Advanced": [
    "WPFTweaksRestorePoint",
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksDisableStoreSearch",
    "WPFTweaksRevertStartMenu",
    "WPFTweaksWidget",
    "WPFTweaksRemoveOneDrive",
    "WPFTweaksWindowsAI",
    "WPFTweaksRightClickMenu"
  ],
  "AppxDefault": [
    "WPFAppxMicrosoft_WindowsFeedbackHub",
    "WPFAppxMicrosoft_GetHelp",
    "WPFAppxMicrosoft_MicrosoftOfficeHub",
    "WPFAppxMicrosoft_WindowsCalculator",
    "WPFAppxClipchamp_Clipchamp",
    "WPFAppxMicrosoft_WindowsAlarms",
    "WPFAppxMicrosoftCorporationII_QuickAssist",
    "WPFAppxMicrosoft_WindowsSoundRecorder",
    "WPFAppxMicrosoft_MicrosoftStickyNotes",
    "WPFAppxMicrosoft_Todos",
    "WPFAppxMicrosoft_MicrosoftSolitaireCollection",
    "WPFAppxMicrosoft_PowerAutomateDesktop",
    "WPFAppxMicrosoft_WindowsDevHome",
    "WPFAppxMicrosoft_BingWeather",
    "WPFAppxMicrosoft_StartExperiencesApp",
    "WPFAppxMicrosoft_BingNews",
    "WPFAppxMicrosoft_Copilot",
    "WPFAppxMicrosoft_BingSearch"
  ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
  "shared": {
    "AppEntryWidth": "220",
    "AppEntryFontSize": "13.2",
    "AppEntryIconSize": "28",
    "AppEntryMargin": "3",
    "AppEntryBorderThickness": "1",
    "CustomDialogFontSize": "12",
    "CustomDialogFontSizeHeader": "14",
    "CustomDialogLogoSize": "25",
    "CustomDialogWidth": "400",
    "CustomDialogHeight": "200",
    "FontSize": "12",
    "FontFamily": "Arial",
    "HeaderFontSize": "16",
    "HeaderFontFamily": "Consolas, Monaco",
    "CheckBoxBulletDecoratorSize": "14",
    "CheckBoxMargin": "15,0,0,2",
    "TabContentMargin": "5",
    "TabButtonFontSize": "14",
    "TabButtonWidth": "110",
    "TabButtonHeight": "26",
    "TabRowHeightInPixels": "50",
    "ToolTipWidth": "300",
    "IconFontSize": "14",
    "IconButtonSize": "35",
    "SettingsIconFontSize": "18",
    "CloseIconFontSize": "12",
    "GroupBorderBackgroundColor": "#0B1F33",
    "ButtonFontSize": "12",
    "ButtonFontFamily": "Arial",
    "ButtonWidth": "200",
    "ButtonHeight": "25",
    "ConfigTabButtonFontSize": "14",
    "ConfigUpdateButtonFontSize": "14",
    "SearchBarWidth": "200",
    "SearchBarHeight": "26",
    "SearchBarTextBoxFontSize": "12",
    "SearchBarClearButtonFontSize": "14",
    "CheckboxMouseOverColor": "#999999",
    "ButtonBorderThickness": "1",
    "ButtonMargin": "1",
    "ButtonCornerRadius": "2"
  },
  "Light": {
    "AppInstallUnselectedColor": "#F0F9FF",
    "AppInstallHighlightedColor": "#BAE6FD",
    "AppInstallSelectedColor": "#7DD3FC",
    "ComboBoxForegroundColor": "#0C4A6E",
    "ComboBoxBackgroundColor": "#F0F9FF",
    "LabelboxForegroundColor": "#075985",
    "MainForegroundColor": "#0C4A6E",
    "MainBackgroundColor": "#F0F9FF",
    "LabelBackgroundColor": "#F0F9FF",
    "LinkForegroundColor": "#0284C7",
    "LinkHoverForegroundColor": "#075985",
    "ScrollBarBackgroundColor": "#7DD3FC",
    "ScrollBarHoverColor": "#38BDF8",
    "ScrollBarDraggingColor": "#0284C7",
    "ProgressBarForegroundColor": "#0284C7",
    "ProgressBarBackgroundColor": "Transparent",
    "ButtonInstallBackgroundColor": "#E0F2FE",
    "ButtonTweaksBackgroundColor": "#E0F2FE",
    "ButtonConfigBackgroundColor": "#E0F2FE",
    "ButtonUpdatesBackgroundColor": "#E0F2FE",
    "ButtonWin11ISOBackgroundColor": "#E0F2FE",
    "ButtonAppxBackgroundColor": "#E0F2FE",
    "ButtonInstallForegroundColor": "#075985",
    "ButtonTweaksForegroundColor": "#075985",
    "ButtonConfigForegroundColor": "#075985",
    "ButtonUpdatesForegroundColor": "#075985",
    "ButtonWin11ISOForegroundColor": "#075985",
    "ButtonAppxForegroundColor": "#075985",
    "ButtonBackgroundColor": "#E0F2FE",
    "ButtonBackgroundPressedColor": "#0284C7",
    "ButtonBackgroundMouseoverColor": "#BAE6FD",
    "ButtonBackgroundSelectedColor": "#7DD3FC",
    "ButtonForegroundColor": "#075985",
    "ToggleButtonOnColor": "#38BDF8",
    "ToggleButtonOffColor": "#36566B",
    "ToolTipBackgroundColor": "#F0F9FF",
    "BorderColor": "#0EA5E9",
    "BorderOpacity": "0.2"
  },
  "Dark": {
    "AppInstallUnselectedColor": "#0B1624",
    "AppInstallHighlightedColor": "#12314A",
    "AppInstallSelectedColor": "#0EA5E9",
    "ComboBoxForegroundColor": "#F7F7F7",
    "ComboBoxBackgroundColor": "#0B1F33",
    "LabelboxForegroundColor": "#7DD3FC",
    "MainForegroundColor": "#F7F7F7",
    "MainBackgroundColor": "#07111F",
    "LabelBackgroundColor": "#07111F",
    "LinkForegroundColor": "#38BDF8",
    "LinkHoverForegroundColor": "#BAE6FD",
    "ScrollBarBackgroundColor": "#0B4F71",
    "ScrollBarHoverColor": "#0284C7",
    "ScrollBarDraggingColor": "#38BDF8",
    "ProgressBarForegroundColor": "#38BDF8",
    "ProgressBarBackgroundColor": "Transparent",
    "ButtonInstallBackgroundColor": "#0B1F33",
    "ButtonTweaksBackgroundColor": "#0B1F33",
    "ButtonConfigBackgroundColor": "#0B1F33",
    "ButtonUpdatesBackgroundColor": "#0B1F33",
    "ButtonWin11ISOBackgroundColor": "#0B1F33",
    "ButtonAppxBackgroundColor": "#0B1F33",
    "ButtonInstallForegroundColor": "#BAE6FD",
    "ButtonTweaksForegroundColor": "#BAE6FD",
    "ButtonConfigForegroundColor": "#BAE6FD",
    "ButtonUpdatesForegroundColor": "#BAE6FD",
    "ButtonWin11ISOForegroundColor": "#BAE6FD",
    "ButtonAppxForegroundColor": "#BAE6FD",
    "ButtonBackgroundColor": "#0B1F33",
    "ButtonBackgroundPressedColor": "#0369A1",
    "ButtonBackgroundMouseoverColor": "#0C4A6E",
    "ButtonBackgroundSelectedColor": "#0284C7",
    "ButtonForegroundColor": "#E0F2FE",
    "ToggleButtonOnColor": "#38BDF8",
    "ToggleButtonOffColor": "#36566B",
    "ToolTipBackgroundColor": "#0B1F33",
    "BorderColor": "#164E63",
    "BorderOpacity": "0.2"
  }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
  "WPFTweaksActivity": {
    "Content": "Activity History - Disable",
    "Description": "Erases recent docs, clipboard, and run history.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "EnableActivityFeed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "UploadUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/activity"
  },
  "WPFTweaksHiber": {
    "Content": "Hibernation - Disable",
    "Description": "Hibernation is really meant for laptops as it saves what's in memory before turning the PC off. It really should never be used.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
        "Name": "HibernateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
        "Name": "ShowHibernateOption",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "powercfg.exe /hibernate off"
    ],
    "UndoScript": [
      "powercfg.exe /hibernate on"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/hiber"
  },
  "WPFTweaksWidget": {
    "Content": "Widgets - Remove",
    "Description": "Removes the annoying widgets in the bottom left of the Taskbar.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Sometimes if you dont stop the Widgets process the removal may fail\r\n\r\n      Get-Process *Widget* | Stop-Process\r\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      Write-Host \"Removed widgets\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/widget"
  },
  "WPFTweaksRevertStartMenu": {
    "Content": "Start Menu Previous Layout - Enable",
    "Description": "Bring back the old Start Menu layout from before the gradual rollout of the new one in 25H2. On newer versions of Windows !!THIS TWEAK WILL NOT WORK!!",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\ControlSet001\\Control\\FeatureManagement\\Overrides\\8\\3036241548",
        "Name": "EnabledState",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/revertstartmenu"
  },
  "WPFTweaksDisableStoreSearch": {
    "Content": "Microsoft Store Recommended Search Results - Disable",
    "Description": "Will not display recommended Microsoft Store apps when searching for apps in the Start menu.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny Everyone:F"
    ],
    "UndoScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant Everyone:F"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disablestoresearch"
  },
  "WPFTweaksLocation": {
    "Content": "Location Tracking - Disable",
    "Description": "Disables Location Tracking.",
    "category": "Essential Tweaks",
    "panel": "1",
    "service": [
      {
        "Name": "lfsvc",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      }
    ],
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
        "Name": "Value",
        "Value": "Deny",
        "Type": "String",
        "OriginalValue": "Allow"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
        "Name": "SensorPermissionState",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\Maps",
        "Name": "AutoUpdateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/location"
  },
  "WPFTweaksServices": {
    "Content": "Services - Set to Manual",
    "Description": "Sets some services to Manual startup and adjusts the SvcHostSplitThresholdInKB registry value to better match system memory, which can significantly reduce the number of svchost.exe processes.",
    "category": "Essential Tweaks",
    "panel": "1",
    "service": [
      {
        "Name": "CscService",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      },
      {
        "Name": "DiagTrack",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "MapsBroker",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "StorSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SharedAccess",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      }
    ],
    "InvokeScript": [
      "\r\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\r\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/services"
  },
  "WPFTweaksBraveDebloat": {
    "Content": "Brave Browser - Debloat",
    "Description": "Disables various annoyances like Brave Rewards, Leo AI, Crypto Wallet and VPN.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveRewardsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveWalletDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveVPNDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveAIChatEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveStatsPingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveNewsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveTalkDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "TorDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveP3AEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "UrlKeyedAnonymizedDataCollectionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "SafeBrowsingExtendedReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "MetricsReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/bravedebloat"
  },
  "WPFTweaksDisableWarningForUnsignedRdp": {
    "Content": "RDP Unsigned File Warnings - Disable",
    "Description": "Disables warnings shown when launching unsigned RDP files introduced with the latest Windows 10 and 11 updates.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
        "Name": "RedirectionWarningDialogVersion",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
        "Name": "RdpLaunchConsentAccepted",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablewarningforunsignedrdp"
  },
  "WPFTweaksEdgeDebloat": {
    "Content": "Microsoft Edge - Debloat",
    "Description": "Disables various telemetry options, popups, and other annoyances in Edge.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
        "Name": "CreateDesktopShortcutDefault",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "PersonalizationReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
        "Name": "1",
        "Value": "ofefcgjbeghpigppfmkologfjadafddi",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowRecommendationsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "HideFirstRunExperience",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "UserFeedbackAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ConfigureDoNotTrack",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "AlternateErrorPagesEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeCollectionsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeShoppingAssistantEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "MicrosoftEdgeInsiderPromotionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowMicrosoftRewards",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WebWidgetAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DiagnosticData",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeAssetDeliveryServiceEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WalletDonationEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DefaultBrowserSettingsCampaignEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/edgedebloat"
  },
  "WPFTweaksConsumerFeatures": {
    "Content": "ConsumerFeatures - Disable",
    "Description": "Stops promoted app installs and reduces app suggestions from Microsoft Store content.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
        "Name": "DisableWindowsConsumerFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/consumerfeatures"
  },
  "WPFTweaksTelemetry": {
    "Content": "Telemetry - Disable",
    "Description": "Disables Microsoft Telemetry.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
        "Name": "TailoredExperiencesWithDiagnosticDataEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
        "Name": "HasAccepted",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Input\\TIPC",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitInkCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitTextCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
        "Name": "HarvestContacts",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
        "Name": "AcceptedPrivacyPolicy",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
        "Name": "AllowTelemetry",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Start_TrackProgs",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
        "Name": "NumberOfSIUFInPeriod",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      # Disable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 2\r\n\r\n      # Disable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Disabled\r\n\r\n      # Disable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Disabled\r\n\r\n      # Disable PowerShell 7 telemetry\r\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')\r\n\r\n      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Enable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 1\r\n\r\n      # Enable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Automatic\r\n\r\n      # Enable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Automatic\r\n\r\n      # Enable PowerShell 7 telemetry\r\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '', 'Machine')\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/telemetry"
  },
  "WPFTweaksDeliveryOptimization": {
    "Content": "Delivery Optimization - Disable",
    "Description": "Stops Windows from using your bandwidth to upload updates to other PCs on the internet or local network.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization",
        "Name": "DODownloadMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/deliveryoptimization"
  },
  "WPFTweaksRemoveEdge": {
    "Content": "Microsoft Edge - Remove",
    "Description": "Uninstalls Microsoft Edge by creating dummy MicrosoftEdge.exe file in the legacy Edge folder. This tricks Windows into unlocking the official Edge uninstaller allowing for a system-level removal.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $Path = Resolve-Path -Path \"$Env:ProgramFiles (x86)\\Microsoft\\Edge\\Application\\*\\Installer\\setup.exe\" | Select-Object -Last 1\r\n\r\n      if (Test-Path $Path) {\r\n          New-Item -Path \"$Env:SystemRoot\\SystemApps\\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\\MicrosoftEdge.exe\" -Force\r\n          Start-Process -FilePath $Path -ArgumentList \"--uninstall --system-level --force-uninstall --delete-profile\" -Wait\r\n          Write-Host \"Microsoft Edge was removed\"\r\n      } else {\r\n          Write-Host \"Microsoft Edge is not installed\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Installing Microsoft Edge...\"\r\n      winget install Microsoft.Edge --source winget\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removeedge"
  },
  "WPFTweaksDisableBitLocker": {
    "Content": "BitLocker - Disable",
    "Description": "Disables BitLocker.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "Disable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "UndoScript": [
      "Enable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disablebitlocker"
  },
  "WPFTweaksUTC": {
    "Content": "Date & Time - Set Time to UTC",
    "Description": "Essential for computers that are dual booting. Fixes the time sync with Linux systems.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
        "Name": "RealTimeIsUniversal",
        "Value": "1",
        "Type": "QWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/utc"
  },
  "WPFTweaksRemoveOneDrive": {
    "Content": "Microsoft OneDrive - Remove",
    "Description": "Denies permission to remove OneDrive user files, then uses its own uninstaller to remove it and restores the original permission afterward.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Deny permission to remove OneDrive folder\r\n      icacls $Env:OneDrive /deny \"Administrators:(D,DC)\"\r\n\r\n      Write-Host \"Uninstalling OneDrive...\"\r\n      Start-Process -FilePath (Join-Path $Env:SystemRoot \"System32\\OneDriveSetup.exe\") -ArgumentList '/uninstall' -Wait\r\n\r\n      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\r\n      Write-Host \"Removing leftover OneDrive Files...\"\r\n\r\n      Stop-Process -Name FileCoAuth,Explorer\r\n\r\n      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force\r\n      Remove-Item \"$Env:ProgramData\\Microsoft OneDrive\" -Recurse -Force\r\n\r\n      # Grant back permission to access OneDrive folder\r\n      icacls $Env:OneDrive /grant \"Administrators:(D,DC)\"\r\n\r\n      if (-not (Get-ChildItem -Path $Env:OneDrive)) {\r\n          Remove-Item -Path $Env:OneDrive -Recurse\r\n          [Environment]::SetEnvironmentVariable('OneDrive', $null, 'User')\r\n      }\r\n\r\n      # Disable OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Disabled\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Installing OneDrive\"\r\n      winget install Microsoft.Onedrive --source winget\r\n\r\n      # Enabled OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Automatic\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removeonedrive"
  },
  "WPFTweaksRemoveHomeAndGallery": {
    "Content": "File Explorer Home and Gallery - Disable",
    "Description": "Removes the Home and Gallery from Explorer and sets This PC as default.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "LaunchTo",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removehomeandgallery"
  },
  "WPFTweaksDisplay": {
    "Content": "Visual Effects - Set to Best Performance",
    "Description": "Sets the system preferences to performance. You can do this manually with sysdm.cpl as well.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "DragFullWindows",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "MenuShowDelay",
        "Value": "200",
        "Type": "String",
        "OriginalValue": "400"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
        "Name": "MinAnimate",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "KeyboardDelay",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewAlphaSelect",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewShadow",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAnimations",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
        "Name": "VisualFXSetting",
        "Value": "3",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\DWM",
        "Name": "EnableAeroPeek",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarMn",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
    ],
    "UndoScript": [
      "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/display"
  },
  "WPFTweaksReservedStorage": {
    "Content": "Disable Reserved Storage",
    "Description": "Disables Windows Reserved Storage (7-10 GB held for updates/temp files). Recommended only on small drives. Re-enable before major Windows feature updates to avoid installation failures.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "DISM /Online /Set-ReservedStorageState /State:Disabled"
    ],
    "UndoScript": [
      "DISM /Online /Set-ReservedStorageState /State:Enabled"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/reservedstorage"
  },
  "WPFTweaksRestorePoint": {
    "Content": "Restore Point - Create",
    "Description": "Creates a restore point at runtime in case a revert is needed from WinUtil modifications.",
    "category": "Essential Tweaks",
    "panel": "1",
    "Checked": "False",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
        "Name": "SystemRestorePointCreationFrequency",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1440"
      }
    ],
    "InvokeScript": [
      "\r\n      if (-not (Get-ComputerRestorePoint)) {\r\n          Enable-ComputerRestore -Drive $Env:SystemDrive\r\n      }\r\n\r\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\r\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/restorepoint"
  },
  "WPFTweaksEndTaskOnTaskbar": {
    "Content": "End Task With Right Click - Enable",
    "Description": "Enables option to end task when right clicking a program in the taskbar.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
        "Name": "TaskbarEndTask",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/endtaskontaskbar"
  },
  "WPFTweaksStorage": {
    "Content": "Storage Sense - Disable",
    "Description": "Storage Sense deletes temp files automatically.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
        "Name": "01",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/storage"
  },
  "WPFTweaksWindowsAI": {
    "Content": "Windows AI - Disable And Remove",
    "Description": "Removes and disables all AI features/packages",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "hide:aicomponents",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\WindowsNotepad",
        "Name": "DisableAIFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\r\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\r\n\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\r\n\r\n      Get-AppxPackage -AllUsers \"*Copilot*\" | Remove-AppxPackage -AllUsers\r\n      winget uninstall -e --name \"Copilot\" --silent --force --accept-source-agreements 2>$null\r\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\r\n\r\n      if ($Appx) {\r\n          Remove-AppxPackage $Appx\r\n      }\r\n\r\n      Set-Service -Name WSAIFabricSvc -StartupType Disabled\r\n      Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart\r\n\r\n      Write-Host \"Windows AI Disabled\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/windowsai"
  },
  "WPFTweaksWPBT": {
    "Content": "Windows Platform Binary Table (WPBT) - Disable",
    "Description": "If enabled, WPBT allows your computer vendor to execute programs at boot time, such as anti-theft software, software drivers, as well as force install software without user consent. Poses potential security risk.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
        "Name": "DisableWpbtExecution",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/wpbt"
  },
  "WPFTweaksPreventDeviceMetadataFromNetwork": {
    "Content": "Prevent Device Companion Apps",
    "Description": "Prevents additional software from being installed when plugging in devices (e.g. Ads when plugging in a monitor). Poses potential security risk.",
    "category": "Essential Tweaks",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Device Metadata",
        "Name": "PreventDeviceMetadataFromNetwork",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/preventdevicemetadatafromnetwork"
  },
  "WPFTweaksRazerBlock": {
    "Content": "Razer Software Auto-Install - Disable",
    "Description": "Blocks ALL Razer Software installations. The hardware works fine without any software.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
        "Name": "SearchOrderConfig",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
        "Name": "DisableCoInstallers",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "\r\n      $RazerPath = \"$Env:SystemRoot\\Installer\\Razer\"\r\n\r\n      if (Test-Path $RazerPath) {\r\n        Remove-Item $RazerPath\\* -Recurse -Force\r\n      } else {\r\n        New-Item -Path $RazerPath -ItemType Directory\r\n      }\r\n\r\n      icacls $RazerPath /deny \"Everyone:(W)\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      icacls \"$Env:SystemRoot\\Installer\\Razer\" /remove:d Everyone\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/razerblock"
  },
  "WPFTweaksDisableNotifications": {
    "Content": "System Tray Notifications & Calendar - Disable",
    "Description": "Disables all Notifications INCLUDING Calendar.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "DisableNotificationCenter",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
        "Name": "ToastEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablenotifications"
  },
  "WPFTweaksBlockAdobeNet": {
    "Content": "Adobe URL Block List - Enable",
    "Description": "Reduces user interruptions by selectively blocking connections to Adobe's activation and telemetry servers. Credit: Ruddernation-Designs",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $hostsUrl = Invoke-RestMethod -Uri https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\r\n      Add-Content -Path \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" -Value $hostsUrl\r\n\r\n      ipconfig /flushdns\r\n      Write-Host 'Added Adobe url block list from host file'\r\n      "
    ],
    "UndoScript": [
      "\r\n      Set-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" (\r\n          (Get-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\") -join \"`n\" -replace '(?s)#New Ver.*', ''\r\n      )\r\n\r\n      ipconfig /flushdns\r\n      Write-Host 'Removed Adobe url block list from host file'\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/blockadobenet"
  },
  "WPFTweaksRightClickMenu": {
    "Content": "Right-Click Menu Previous Layout - Enable",
    "Description": "Restores the classic context menu when right-clicking in File Explorer, replacing the simplified Windows 11 version.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "InvokeScript": [
      "\r\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name InprocServer32 -Value \"\" -Force\r\n      Stop-Process -Name explorer\r\n      "
    ],
    "UndoScript": [
      "Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/rightclickmenu"
  },
  "WPFTweaksDiskCleanup": {
    "Content": "Disk Cleanup - Run",
    "Description": "Runs Disk Cleanup on Drive C: and removes old Windows Updates.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      cleanmgr.exe /d C: /VERYLOWDISK\r\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/diskcleanup"
  },
  "WPFTweaksDeleteTempFiles": {
    "Content": "Temporary Files - Remove",
    "Description": "Erases TEMP Folders.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force\r\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/deletetempfiles"
  },
  "WPFTweaksIPv46": {
    "Content": "IPv6 - Set IPv4 as Preferred",
    "Description": "Setting the IPv4 preference can have latency and security benefits on private networks where IPv6 is not configured.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "32",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/ipv46"
  },
  "WPFTweaksTeredo": {
    "Content": "Teredo - Disable",
    "Description": "Teredo network tunneling is an IPv6 feature that can cause additional latency, but may cause problems with some games.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "netsh interface teredo set state disabled"
    ],
    "UndoScript": [
      "netsh interface teredo set state default"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/teredo"
  },
  "WPFTweaksDisableIPv6": {
    "Content": "IPv6 - Disable",
    "Description": "Disables IPv6.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "255",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "UndoScript": [
      "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disableipv6"
  },
  "WPFTweaksDisableBGapps": {
    "Content": "Background Apps - Disable",
    "Description": "Disables all Microsoft Store apps from running in the background, which has to be done individually since Windows 11.",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
        "Name": "GlobalUserDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablebgapps"
  },
  "WPFTweaksDisableExplorerAutoDiscovery": {
    "Content": "File Explorer Automatic Folder Discovery - Disable",
    "Description": "Windows Explorer automatically tries to guess the type of the folder based on its contents, slowing down the browsing experience. WARNING! Will disable File Explorer grouping.",
    "category": "Essential Tweaks",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      # Every folder\r\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\r\n\r\n      if (!(Test-Path $allFolders)) {\r\n        New-Item -Path $allFolders -Force\r\n        Write-Host \"Created $allFolders\"\r\n      }\r\n\r\n      # Generic view\r\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\r\n      Write-Host \"Set FolderType to NotSpecified\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disableexplorerautodiscovery"
  },
  "WPFToggleDetailedBSoD": {
    "Content": "BSoD Verbose Mode",
    "Description": "Gives more information when you blue screen.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisplayParameters",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisableEmoticon",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/detailedbsod"
  },
  "WPFToggleBatteryPercentage": {
    "Content": "System Tray Battery Percentage",
    "Description": "Shows numeric battery percentage next to the battery icon in the system tray.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "IsBatteryPercentageEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/batterypercentage"
  },
  "WPFToggleDarkMode": {
    "Content": "Dark Theme for Windows",
    "Description": "Dark Mode for the system and applications.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "AppsUseLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "SystemUsesLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/darkmode"
  },
  "WPFToggleShowExt": {
    "Content": "File Explorer File Extensions",
    "Description": "Shows .file extensions in Explorer (.exe, .png, etc.)",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "HideFileExt",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/showext"
  },
  "WPFToggleHiddenFiles": {
    "Content": "File Explorer Hidden Files",
    "Description": "Reveals hidden files in Explorer.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Hidden",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/hiddenfiles"
  },
  "WPFToggleVerboseLogon": {
    "Content": "Logon Verbose Mode",
    "Description": "Show detailed messages during startup/shutdown.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
        "Name": "VerboseStatus",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/verboselogon"
  },
  "WPFToggleNewOutlook": {
    "Content": "Microsoft Outlook New Version",
    "Description": "This will ensures the classic Outlook application is used.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "UseNewOutlook",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "HideNewOutlookToggle",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "DoNewOutlookAutoMigration",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "NewOutlookMigrationUserSetting",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/newoutlook"
  },
  "WPFToggleScrollbars": {
    "Content": "Scrollbars Always Visible",
    "Description": "If enabled, scrollbars will always be visible. If disabled, Windows will automatically hide scrollbars when not in use.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility",
        "Name": "DynamicScrollbars",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/scrollbars"
  },
  "WPFMultiplaneOverlay": {
    "Content": "Multiplane Overlay",
    "Description": "Multiplane Overlay composes multiple image layers, which can sometimes cause issues with graphics cards. Changes to this preference are applied immediately.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Combobox",
    "ComboItems": "Enabled|Disabled (Compatibility)|Fully Disabled",
    "ComboDescriptions": {
      "Enabled": "Uses Windows' default overlay behavior.",
      "Disabled (Compatibility)": "Disables MPO using OverlayTestMode=5, the less aggressive compatibility method.",
      "Fully Disabled": "Disables MPO using OverlayTestMode=5 and DisableOverlays=1, the more aggressive method."
    },
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
        "Name": "OverlayTestMode",
        "Type": "DWord",
        "DefaultValue": "0",
        "Values": {
          "Enabled": "<RemoveEntry>",
          "Disabled (Compatibility)": "5",
          "Fully Disabled": "5"
        }
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
        "Name": "DisableOverlays",
        "Type": "DWord",
        "DefaultValue": "0",
        "Values": {
          "Enabled": "<RemoveEntry>",
          "Disabled (Compatibility)": "<RemoveEntry>",
          "Fully Disabled": "1"
        }
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/multiplaneoverlay"
  },
  "WPFToggleMouseAcceleration": {
    "Content": "Mouse Acceleration",
    "Description": "Makes it so Cursor movement is affected by the speed of your physical mouse movements.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseSpeed",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold1",
        "Value": "6",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold2",
        "Value": "10",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/mouseacceleration"
  },
  "WPFToggleNumLock": {
    "Content": "Num Lock on Startup",
    "Description": "Toggle the Num Lock key state when your computer starts.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKU:\\.Default\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/numlock"
  },
  "WPFToggleWindowSnapping": {
    "Content": "Window Snapping",
    "Description": "Toggles the window snapping feature when dragging windows.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "WindowArrangementActive",
        "Value": "1",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/windowsnapping"
  },
  "WPFToggleStandbyFix": {
    "Content": "S0 Sleep Network Connectivity",
    "Description": "Toggles network connectivity during S0 Sleep which is low power idle in modern laptops.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
        "Name": "ACSettingIndex",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/standbyfix"
  },
  "WPFToggleS3Sleep": {
    "Content": "S3 Sleep",
    "Description": "Toggles between Modern Standby and S3 Sleep, which cuts off power to the CPU while continuing to refresh the memory.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
        "Name": "PlatformAoAcOverride",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/s3sleep"
  },
  "WPFToggleHideSettingsHome": {
    "Content": "Settings Home Page",
    "Description": "Toggles the Home Page in the Windows Settings app.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "show:home",
        "Type": "String",
        "OriginalValue": "hide:home",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/hidesettingshome"
  },
  "WPFToggleBingSearch": {
    "Content": "Start Menu Bing Search",
    "Description": "Toggles Bing web search results in Windows Search.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "BingSearchEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/bingsearch"
  },
  "WPFToggleLoginBlur": {
    "Content": "Logon Screen Acrylic Blur",
    "Description": "Toggles the acrylic blur effect on login screen background.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "DisableAcrylicBackgroundOnLogon",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/loginblur"
  },
  "WPFTweaksDisableLockscreen": {
    "Content": "Lock Screen - Disable",
    "Description": "Skips the lock screen entirely and goes directly to the sign-in screen on boot and wake.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization",
        "Name": "NoLockScreen",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/disablelockscreen"
  },
  "WPFToggleStartMenuRecommendations": {
    "Content": "Start Menu Recommendations",
    "Description": "Toggles the recommendations section in the Start Menu. WARNING: This will also disable Windows Spotlight on your Lock Screen as a side effect.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
        "Name": "IsEducationEnvironment",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/startmenurecommendations"
  },
  "WPFToggleStickyKeys": {
    "Content": "Sticky Keys",
    "Description": "Toggles the Sticky Keys, which activate when clicking shift rapidly.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
        "Name": "Flags",
        "Value": "506",
        "Type": "DWord",
        "OriginalValue": "58",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/stickykeys"
  },
  "WPFToggleTaskbarAlignment": {
    "Content": "Taskbar Centered Icons",
    "Description": "Toggles the Taskbar alignment either to the left or center.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAl",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskbaralignment"
  },
  "WPFToggleTaskbarSearch": {
    "Content": "Taskbar Search Icon",
    "Description": "Toggles the Search Button on the Taskbar.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskbarsearch"
  },
  "WPFToggleTaskView": {
    "Content": "Taskbar Task View Icon",
    "Description": "Toggles the Task View Button in the Taskbar.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskview"
  },
  "WPFToggleGameMode": {
    "Content": "Game Mode",
    "Description": "Toggles Windows prioritizes gaming performance by allocating system resources to games.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AllowAutoGameMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AutoGameModeEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/gamemode"
  },
  "WPFToggleLongPaths": {
    "Content": "Enable Long Paths",
    "Description": "Toggles support for file paths longer than 260 characters in Explorer.",
    "category": "Customize Preferences",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem",
        "Name": "LongPathsEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/longpaths"
  },
  "WPFOOSUbutton": {
    "Content": "O&O ShutUp10++ - Run",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Type": "Button",
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/oosubutton"
  },
  "WPFchangedns": {
    "Content": "DNS - Set to:",
    "category": "z__Advanced Tweaks - CAUTION",
    "panel": "1",
    "Type": "Combobox",
    "ComboItems": "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult Mullvad Mullvad_Ads_Trackers Mullvad_Ads_Trackers_Malware Mullvad_Ads_Trackers_Malware_Social Mullvad_Ads_Trackers_Malware_Adult_Gambling Mullvad_Ads_Trackers_Malware_Adult_Gambling_Social",
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/changedns"
  },
  "WPFAddUltPerf": {
    "Content": "Ultimate Performance Profile - Enable",
    "category": "Performance Plans - NOT FOR LAPTOPS",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/code-reference/tweaks/performance-plans---not-for-laptops/addultperf"
  },
  "WPFRemoveUltPerf": {
    "Content": "Ultimate Performance Profile - Disable",
    "category": "Performance Plans - NOT FOR LAPTOPS",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/code-reference/tweaks/performance-plans---not-for-laptops/removeultperf"
  }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:WinUtility"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True"
        WindowStyle="SingleBorderWindow"
        Width="Auto"
        Height="Auto"
        MinWidth="800"
        MinHeight="600"
        Title="LucaXShop">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="10" UseAeroCaptionButtons="False"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource ToolTipBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
        <Setter Property="MaxWidth" Value="{DynamicResource ToolTipWidth}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="2"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <!-- This ContentTemplate ensures that the content of the ToolTip wraps text properly for better readability -->
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <ContentPresenter Content="{TemplateBinding Content}">
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock">
                                <Setter Property="TextWrapping" Value="Wrap"/>
                            </Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </DataTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <Setter Property="Padding" Value="5,2,5,2"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto"  Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="AppEntryBorderStyle" TargetType="Border">
        <Setter Property="BorderBrush" Value="Gray"/>
        <Setter Property="BorderThickness" Value="{DynamicResource AppEntryBorderThickness}"/>
        <Setter Property="CornerRadius" Value="5"/>
        <Setter Property="Padding" Value="6,4"/>
        <Setter Property="Width" Value="{DynamicResource AppEntryWidth}"/>
        <Setter Property="VerticalAlignment" Value="Top"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Background" Value="{DynamicResource AppInstallUnselectedColor}"/>
    </Style>
    <Style x:Key="AppEntryCheckboxStyle" TargetType="CheckBox">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="HorizontalAlignment" Value="Left"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <ContentPresenter Content="{TemplateBinding Content}"
                                      VerticalAlignment="Center"
                                      HorizontalAlignment="Left"/>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="AppEntryNameStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntryFontSize}"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Background" Value="Transparent"/>
    </Style>
    <Style x:Key="AppEntryButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Height" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
        <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
        <Setter Property="HorizontalAlignment" Value="Center"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <TextBlock  Text="{Binding}"
                                FontFamily="Segoe MDL2 Assets"
                                FontSize="{DynamicResource IconFontSize}"
                                Background="Transparent"/>
                </DataTemplate>
            </Setter.Value>
        </Setter>
        <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Cursor" Value="Hand"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>


    </Style>
    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid Name="GridRoot" Width="7" Background="{TemplateBinding Background}" >
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style x:Key="ComboBoxToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Background="{TemplateBinding Background}" BorderThickness="0">
                            <ContentPresenter/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="MinWidth"   Value="{DynamicResource ButtonWidth}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border Name="OuterBorder"
                                    BorderBrush="{DynamicResource BorderColor}"
                                    BorderThickness="1"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}"
                                    Background="{TemplateBinding Background}">
                                <ToggleButton Name="ToggleButton"
                                              Style="{StaticResource ComboBoxToggleButtonStyle}"
                                              Background="Transparent"
                                              BorderThickness="0"
                                              IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                              ClickMode="Press">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0"
                                                   Text="{TemplateBinding SelectionBoxItem}"
                                                   Foreground="{TemplateBinding Foreground}"
                                                   Background="Transparent"
                                                   HorizontalAlignment="Left" VerticalAlignment="Center"
                                                   Margin="6,3,2,3"/>
                                        <Path Grid.Column="1"
                                              Data="M 0,0 L 8,0 L 4,5 Z"
                                              Fill="{TemplateBinding Foreground}"
                                              Width="8" Height="5"
                                              VerticalAlignment="Center"
                                              HorizontalAlignment="Center"
                                              Stretch="Uniform"
                                              Margin="4,0,6,0"/>
                                    </Grid>
                                </ToggleButton>
                            </Border>
                            <Popup Name="Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   Focusable="False"
                                   AllowsTransparency="True"
                                   PopupAnimation="Slide">
                                <Border Name="DropDownBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1"
                                        CornerRadius="4">
                                    <ScrollViewer>
                                        <ItemsPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,2"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}"/>
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}"/>
            <Setter Property="Padding" Value="6,3"/>
            <Setter Property="ContentTemplate">
                <Setter.Value>
                    <DataTemplate>
                        <TextBlock Text="{Binding}" Background="Transparent"
                                   Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ComboBoxItem}}"/>
                    </DataTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
        </Style>
        <Style x:Key="TabToggleButton" TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Content" Value=""/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border Name="ButtonGlow"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonForegroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <Border Name="BackgroundBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonBackgroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                        <ContentPresenter
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"
                                            Margin="10,2,10,2"/>
                                    </Border>
                                </Grid>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="5" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-100" BlurRadius="15"/>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Panel.ZIndex" Value="2000"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter Property="BorderBrush" Value="Pink"/>
                                <Setter Property="BorderThickness" Value="2"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="2" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-111" BlurRadius="10"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="False">
                                <Setter Property="BorderBrush" Value="Transparent"/>
                                <Setter Property="BorderThickness" Value="{DynamicResource ButtonBorderThickness}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <!-- Toggle Dot Background -->
                                    <Ellipse Width="8" Height="16"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0" />

                                    <!-- Toggle Dot with hover grow effect -->
                                    <Ellipse Name="ToggleDot"
                                            Width="8" Height="8"
                                            Fill="{DynamicResource ButtonForegroundColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0"
                                            RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform>
                                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>

                                    <!-- Content Presenter -->
                                    <ContentPresenter HorizontalAlignment="Center"
                                                    VerticalAlignment="Center"
                                                    Margin="10,2,10,2"/>
                                </Grid>
                            </Border>
                        </Grid>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom"/>
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3"/>
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Content" Value="X"/>
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="Red"/>
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderThickness" Value="10"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="{TemplateBinding Background}" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border Name="Border"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                Background="{DynamicResource ButtonBackgroundColor}"
                                                BorderThickness="1"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Margin="1"
                                                SnapsToDevicePixels="True"/>
                                        <Viewbox Name="CheckMarkContainer"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                HorizontalAlignment="Center"
                                                VerticalAlignment="Center"
                                                Visibility="Collapsed">
                                            <Path Name="CheckMark"
                                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                                  StrokeThickness="1.5"
                                                  Data="M 0 5 L 5 10 L 12 0"
                                                  Stretch="Uniform"/>
                                        </Viewbox>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0"
                                                  HorizontalAlignment="Left"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"/>
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMarkContainer" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <!--Setter TargetName="Border" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/-->
                                <Setter Property="Foreground" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Viewbox Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                <Grid Width="14" Height="14">
                                    <Ellipse Name="OuterCircle"
                                            Stroke="{DynamicResource ToggleButtonOffColor}"
                                            Fill="{DynamicResource ButtonBackgroundColor}"
                                            StrokeThickness="1"
                                            Width="14"
                                            Height="14"
                                            SnapsToDevicePixels="True"/>
                                    <Ellipse Name="InnerCircle"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            Width="8"
                                            Height="8"
                                            Visibility="Collapsed"
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"/>
                                </Grid>
                            </Viewbox>
                            <ContentPresenter Margin="4,0,0,0"
                                            VerticalAlignment="Center"
                                            RecognizesAccessKey="True"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel>
                            <Grid>
                                <Border Width="45"
                                        Height="20"
                                        Background="#555555"
                                        CornerRadius="10"
                                        Margin="5,0"
                                />
                                <Border Name="WPFToggleSwitchButton"
                                        Width="25"
                                        Height="25"
                                        Background="Black"
                                        CornerRadius="12.5"
                                        HorizontalAlignment="Left"
                                />
                                <ContentPresenter Name="WPFToggleSwitchContent"
                                                  Margin="10,0,0,0"
                                                  Content="{TemplateBinding Content}"
                                                  VerticalAlignment="Center"
                                />
                            </Grid>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="false">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchLeft" />
                                    <BeginStoryboard Name="WPFToggleSwitchRight">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="0,0,0,0"
                                                    To="28,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#fff9f4f4"
                                />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="true">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchRight" />
                                    <BeginStoryboard Name="WPFToggleSwitchLeft">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="28,0,0,0"
                                                    To="0,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#ff060600"
                                />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" Name="Border" CornerRadius="8"
                                BorderThickness="1"
                                Width="34" Height="17">
                            <Ellipse Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform"
                                    Margin="2,2,2,1"
                                    HorizontalAlignment="Left" Width="10.8"
                                    RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}"/>
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="labelfortweaks" TargetType="{x:Type Label}">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="White" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="Cut"/>
                                                    <MenuItem Command="Copy" Header="Copy"/>
                                                    <MenuItem Command="Paste" Header="Paste"/>
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollVisibilityRectangle" TargetType="Rectangle">
            <Setter Property="Visibility" Value="Collapsed"/>
            <Style.Triggers>
                <MultiDataTrigger>
                    <MultiDataTrigger.Conditions>
                        <Condition Binding="{Binding Path=ComputedHorizontalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                        <Condition Binding="{Binding Path=ComputedVerticalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                    </MultiDataTrigger.Conditions>
                    <Setter Property="Visibility" Value="Visible"/>
                </MultiDataTrigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="RoundedProgressBarStyle" TargetType="ProgressBar">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border CornerRadius="4" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1">
                            <Grid ClipToBounds="True">
                                <Border Name="PART_Track" CornerRadius="4" Background="Transparent"/>
                                <Border Name="PART_Indicator" CornerRadius="4" Background="{DynamicResource ProgressBarForegroundColor}" HorizontalAlignment="Left"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Filter Chip Style â€” used by the Install tab category filter buttons -->
        <Style x:Key="FilterChipStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Margin" Value="2"/>
            <Setter Property="Padding" Value="12,0,12,0"/>
            <Setter Property="Width" Value="Auto"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="ChipBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{DynamicResource ButtonBorderThickness}"
                                CornerRadius="{DynamicResource ButtonCornerRadius}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Category filter chips. A toggle rather than a button, so the active filter is visible
             on the chip itself instead of only in the results below. -->
        <Style x:Key="FilterChipToggleStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="2"/>
            <Setter Property="Padding" Value="12,4,12,4"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Name="ChipBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{DynamicResource BorderColor}"
                                BorderThickness="1"
                                CornerRadius="{DynamicResource ButtonCornerRadius}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                              TextBlock.Foreground="{TemplateBinding Foreground}"
                                              TextBlock.FontSize="{TemplateBinding FontSize}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <!-- Only colours change on check. Anything affecting text width, bold for
                                 instance, would resize the chip and shift every chip after it. -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter TargetName="ChipBorder" Property="BorderBrush" Value="{DynamicResource LabelboxForegroundColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <!-- Offline banner -->
        <Border Name="WPFOfflineBanner" Grid.Row="0" Background="#8B0000" Visibility="Collapsed" Padding="6,4">
            <TextBlock Text="&#x26A0; Offline Mode - No Internet Connection" Foreground="White" FontWeight="Bold"
                HorizontalAlignment="Center" FontSize="13" Background="Transparent"/>
        </Border>
        <Grid Grid.Row="1" Background="{DynamicResource MainBackgroundColor}">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/> <!-- Navigation buttons -->
                <ColumnDefinition Width="*"/> <!-- Search bar and buttons -->
            </Grid.ColumnDefinitions>

            <!-- Navigation Buttons Panel -->
            <StackPanel Name="NavDockPanel" Orientation="Horizontal" Grid.Column="0" VerticalAlignment="Center" Margin="5,5,10,5">
                <StackPanel Name="NavLogoPanel" Orientation="Horizontal" HorizontalAlignment="Left" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Margin="10,0,20,0">
                </StackPanel>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonInstallBackgroundColor}" Foreground="white" FontWeight="Bold" Name="WPFTab1BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonInstallForegroundColor}" >
                            <Underline>I</Underline>nstall
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonTweaksBackgroundColor}" Foreground="{DynamicResource ButtonTweaksForegroundColor}" FontWeight="Bold" Name="WPFTab2BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonTweaksForegroundColor}">
                            <Underline>T</Underline>weaks
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonConfigBackgroundColor}" Foreground="{DynamicResource ButtonConfigForegroundColor}" FontWeight="Bold" Name="WPFTab3BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonConfigForegroundColor}">
                            <Underline>C</Underline>onfig
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonUpdatesBackgroundColor}" Foreground="{DynamicResource ButtonUpdatesForegroundColor}" FontWeight="Bold" Name="WPFTab4BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonUpdatesForegroundColor}">
                            <Underline>U</Underline>pdates
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="Auto" MinWidth="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonWin11ISOBackgroundColor}" Foreground="{DynamicResource ButtonWin11ISOForegroundColor}" FontWeight="Bold" Name="WPFTab5BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonWin11ISOForegroundColor}">
                            <Underline>W</Underline>in11 Creator
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
            </StackPanel>

            <!-- Search Bar and Action Buttons -->
            <Grid Name="GridBesideNavDockPanel" Grid.Column="1" Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Height="Auto">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*"/> <!-- Search bar area - priority space -->
                    <ColumnDefinition Width="Auto"/><!-- Buttons area -->
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Margin="5,0,10,0" MinWidth="120" Height="{DynamicResource SearchBarHeight}" VerticalAlignment="Center" HorizontalAlignment="Stretch">
                    <Grid>
                        <TextBox
                            Height="{DynamicResource SearchBarHeight}"
                            FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                            VerticalAlignment="Center" HorizontalAlignment="Stretch"
                            BorderThickness="1"
                            Name="SearchBar"
                            Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}"
                            Padding="3,3,30,0"
                            ToolTip="Press Ctrl-F and type app name to filter application list below. Press Esc to reset the filter"
                            AutomationProperties.Name="Search">
                        </TextBox>
                        <TextBlock
                            Name="SearchBarIcon"
                            VerticalAlignment="Center" HorizontalAlignment="Right"
                            FontFamily="Segoe MDL2 Assets"
                            Foreground="{DynamicResource ButtonBackgroundSelectedColor}"
                            FontSize="{DynamicResource IconFontSize}"
                            Margin="0,0,8,0" Width="Auto" Height="Auto">&#xE721;
                        </TextBlock>
                    </Grid>
                </Border>
                <Button Grid.Column="0"
                    VerticalAlignment="Center" HorizontalAlignment="Right"
                    Name="SearchBarClearButton"
                    Style="{StaticResource SearchBarClearButtonStyle}"
                    AutomationProperties.Name="Clear Search"
                    Margin="0,0,20,0" Visibility="Collapsed">
                </Button>

                <!-- Buttons Container -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="5,5,5,5">
                    <Button Name="ThemeButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="N/A"
                    ToolTip="Change the LucaXShop UI Theme"
                    AutomationProperties.Name="Theme"
                />
                    <Popup Name="ThemePopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Auto" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Follow the Windows Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Dark" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Dark Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Light" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Use Light Theme"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="FontScalingButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE8D3;"
                    ToolTip="Adjust Font Scaling for Accessibility"
                    AutomationProperties.Name="Font Scaling"
                />
                    <Popup Name="FontScalingPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=FontScalingButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" MinWidth="200">
                            <TextBlock Text="Font Scaling"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,5,10,5"
                                       FontWeight="Bold"/>
                            <Separator Margin="5,0,5,5"/>
                            <StackPanel Orientation="Horizontal" Margin="10,5,10,10">
                                <TextBlock Text="Small"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="0,0,10,0"/>
                                <Slider Name="FontScalingSlider"
                                        Minimum="0.75" Maximum="2.0"
                                        Value="1.0"
                                        TickFrequency="0.25"
                                        TickPlacement="BottomRight"
                                        IsSnapToTickEnabled="True"
                                        Width="120"
                                        VerticalAlignment="Center"
                                        AutomationProperties.Name="Font Scaling"/>
                                <TextBlock Text="Large"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="10,0,0,0"/>
                            </StackPanel>
                            <TextBlock Name="FontScalingValue"
                                       Text="100%"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,0,10,5"/>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="10,0,10,10">
                                <Button Name="FontScalingResetButton"
                                        Content="Reset"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                                <Button Name="FontScalingApplyButton"
                                        Content="Apply"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="SettingsButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    ToolTip="Settings"
                    AutomationProperties.Name="Settings"
                    Content="&#xE713;"/>
                    <Popup Name="SettingsPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Import" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Import Configuration from exported file."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Export" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Export Selected Elements and copy execution command to clipboard."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="About" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="เว็บไซต์" Name="DocumentationMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Discord" Name="SponsorMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="LucaXShopDiscordButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Foreground="{DynamicResource LabelboxForegroundColor}"
                        FontSize="{DynamicResource ButtonFontSize}"
                        FontWeight="Bold"
                        Padding="8,0"
                        MinWidth="82"
                        Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="2,0,2,0"
                        Content="Discord"
                        ToolTip="เปิด Discord ของ LucaXShop"
                        AutomationProperties.Name="LucaXShop Discord"/>
                    <Button Name="LucaXShopWebsiteButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Foreground="{DynamicResource LabelboxForegroundColor}"
                        FontSize="{DynamicResource ButtonFontSize}"
                        FontWeight="Bold"
                        Padding="8,0"
                        MinWidth="72"
                        Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="2,0,5,0"
                        Content="เว็บไซต์"
                        ToolTip="เปิดเว็บไซต์ LucaXShop"
                        AutomationProperties.Name="LucaXShop Website"/>
                    <Button
                        Content="&#xE921;"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderThickness="0"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="0"
                        FontFamily="Segoe MDL2 Assets"
                        Foreground="{DynamicResource MainForegroundColor}"
                        FontSize="{DynamicResource CloseIconFontSize}"
                        ToolTip="Minimize"
                        AutomationProperties.Name="Minimize"
                        Name="WPFMinimizeButton" />
                    <Button
                        BorderThickness="0"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="0,0,0,0"
                        FontFamily="Segoe MDL2 Assets"
                        Foreground="{DynamicResource MainForegroundColor}"
                        FontSize="{DynamicResource CloseIconFontSize}"
                        Name="WPFMaximizeButton">
                        <Button.Style>
                            <Style TargetType="Button" BasedOn="{StaticResource HoverButtonStyle}">
                                <Setter Property="Content" Value="&#xE922;"/>
                                <Setter Property="ToolTip" Value="Maximize"/>
                                <Setter Property="AutomationProperties.Name" Value="Maximize"/>
                                <Style.Triggers>
                                    <DataTrigger Binding="{Binding WindowState, RelativeSource={RelativeSource AncestorType={x:Type Window}}}" Value="Maximized">
                                        <Setter Property="Content" Value="&#xE923;"/>
                                        <Setter Property="ToolTip" Value="Restore"/>
                                        <Setter Property="AutomationProperties.Name" Value="Restore"/>
                                    </DataTrigger>
                                </Style.Triggers>
                            </Style>
                        </Button.Style>
                    </Button>

                    <Button
                        Content="&#xE8BB;"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderThickness="0"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="0"
                        FontFamily="Segoe MDL2 Assets"
                        Foreground="{DynamicResource MainForegroundColor}"
                        FontSize="{DynamicResource CloseIconFontSize}"
                        ToolTip="Close"
                        AutomationProperties.Name="Close"
                        Name="WPFCloseButton" />
                </StackPanel>
            </Grid>
        </Grid>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="2" Grid.Column="0" Padding="-1">
            <TabItem Header="Install" Visibility="Collapsed" Name="WPFTab1">
                <Grid Background="Transparent" >
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Category filters. Click one to filter, ctrl click to combine several. -->
                    <WrapPanel Grid.Row="0" Orientation="Horizontal" Margin="5,5,5,5" Name="WPFSearchChips">
                        <TextBlock Text="&#xE71C;"
                                   FontFamily="Segoe MDL2 Assets"
                                   FontSize="{DynamicResource IconFontSize}"
                                   Foreground="{DynamicResource LabelboxForegroundColor}"
                                   Background="Transparent"
                                   VerticalAlignment="Center"
                                   Margin="10,0,10,0"
                                   ToolTip="Filter by category. Ctrl click to select more than one."/>
                        <ToggleButton Name="WPFSearchChipAll"             Content="All"               Style="{StaticResource FilterChipToggleStyle}" IsChecked="True"/>
                        <ToggleButton Name="WPFSearchChipBrowsers"        Content="Browsers"          Style="{StaticResource FilterChipToggleStyle}"/>
                        <ToggleButton Name="WPFSearchChipCommunications"  Content="Communications"    Style="{StaticResource FilterChipToggleStyle}"/>
                        <ToggleButton Name="WPFSearchChipDevelopment"     Content="Development"       Style="{StaticResource FilterChipToggleStyle}"/>
                        <ToggleButton Name="WPFSearchChipDocument"        Content="Document"          Style="{StaticResource FilterChipToggleStyle}"/>
                        <ToggleButton Name="WPFSearchChipGames"           Content="Games"             Style="{StaticResource FilterChipToggleStyle}"/>
                        <ToggleButton Name="WPFSearchChipMicrosoftTools"  Content="Microsoft Tools"   Style="{StaticResource FilterChipToggleStyle}"/>
                        <ToggleButton Name="WPFSearchChipMultimediaTools" Content="Multimedia Tools"  Style="{StaticResource FilterChipToggleStyle}"/>
                        <ToggleButton Name="WPFSearchChipProTools"        Content="Pro Tools"         Style="{StaticResource FilterChipToggleStyle}"/>
                        <ToggleButton Name="WPFSearchChipSelfhostedTools" Content="Selfhosted Tools"  Style="{StaticResource FilterChipToggleStyle}"/>
                        <ToggleButton Name="WPFSearchChipUtilities"       Content="Utilities"         Style="{StaticResource FilterChipToggleStyle}"/>
                    </WrapPanel>

                    <Grid Grid.Row="1" Margin="{DynamicResource TabContentMargin}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>

                        <Grid Name="appscategory" Grid.Column="0" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>

                        <Grid Name="appspanel" Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="Tweaks" Visibility="Collapsed" Name="WPFTab2">
                <Grid>
                    <!-- Main content area with a ScrollViewer -->
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="5">
                                <Label Content="Recommended Selections:" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFstandard" Content=" Standard " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFminimal" Content=" Minimal " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFAdvanced" Content=" Advanced " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearTweaksSelection" Content=" Clear " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledTweaks" Content=" Get Installed Tweaks " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFAppxRemoval" Content=" AppX Removal " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </WrapPanel>
                            </StackPanel>

                            <Grid Name="tweakspanel" Grid.Row="1">
                                <!-- Your tweakspanel content goes here -->
                            </Grid>

                            <Border Grid.ColumnSpan="2" Grid.Row="2" Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10">
                                        Note: Hover over items to get a better description. Please be careful as many of these tweaks will heavily modify your system.
                                        <LineBreak/>Recommended selections are for normal users and if you are unsure do NOT check anything else!
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Grid.Column="0">
                            <Button Name="WPFTweaksbutton" Content="Run Tweaks" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFUndoall" Content="Undo Selected Tweaks" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="Config" Visibility="Collapsed" Name="WPFTab3">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                    <Grid Name="featurespanel" Grid.Row="1" Background="Transparent">
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Updates" Visibility="Collapsed" Name="WPFTab4">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="{DynamicResource TabContentMargin}">
                    <Grid Background="Transparent" MaxWidth="1250" HorizontalAlignment="Center">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <StackPanel Grid.Row="0" Margin="10,10,10,14">
                            <TextBlock Text="Windows Update Profiles"
                                       FontSize="24"
                                       FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Choose how Windows receives updates. Each profile replaces the Windows Update settings managed by WinUtil."
                                       Margin="0,6,0,0"
                                       FontSize="13"
                                       TextWrapping="Wrap"
                                       Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>

                        <UniformGrid Grid.Row="1" Columns="3">
                            <Border Style="{StaticResource BorderStyle}"
                                    BorderBrush="{DynamicResource ProgressBarForegroundColor}"
                                    BorderThickness="2"
                                    Padding="16"
                                    MinHeight="300">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0" Margin="0,0,0,14">
                                        <TextBlock Text="Recommended"
                                                   FontSize="20"
                                                   FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="Balanced security and stability"
                                                   Margin="0,4,0,0"
                                                   FontSize="13"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                    </StackPanel>
                                    <StackPanel Grid.Row="1">
                                        <TextBlock Text="- Defers feature updates for 365 days" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- Defers quality updates for 4 days" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- Excludes drivers from quality updates" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- Prevents automatic restarts while a user is signed in" TextWrapping="Wrap" Margin="0,0,0,12" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="Available on Windows Pro, Enterprise, and Education editions."
                                                   FontSize="11"
                                                   FontStyle="Italic"
                                                   TextWrapping="Wrap"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                    </StackPanel>
                                    <Button Name="WPFUpdatessecurity"
                                            Grid.Row="2"
                                            Content="Apply Recommended"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Margin="0,16,0,0"
                                            Padding="10"/>
                                </Grid>
                            </Border>

                            <Border Style="{StaticResource BorderStyle}" Padding="16" MinHeight="300">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0" Margin="0,0,0,14">
                                        <TextBlock Text="Windows Default"
                                                   FontSize="20"
                                                   FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="Return control to Windows"
                                                   Margin="0,4,0,0"
                                                   FontSize="13"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                    </StackPanel>
                                    <StackPanel Grid.Row="1">
                                        <TextBlock Text="- Removes Windows Update policies applied by WinUtil" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- Restores update service startup settings" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- Re-enables update scheduled tasks" TextWrapping="Wrap" Margin="0,0,0,12" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="Use this to undo the Recommended or Disable profile."
                                                   FontSize="11"
                                                   FontStyle="Italic"
                                                   TextWrapping="Wrap"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                    </StackPanel>
                                    <Button Name="WPFUpdatesdefault"
                                            Grid.Row="2"
                                            Content="Restore Defaults"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Margin="0,16,0,0"
                                            Padding="10"/>
                                </Grid>
                            </Border>

                            <Border Style="{StaticResource BorderStyle}" Padding="16" MinHeight="300">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0" Margin="0,0,0,14">
                                        <TextBlock Text="Disable Updates"
                                                   FontSize="20"
                                                   FontWeight="Bold"
                                                   Foreground="Red"/>
                                        <TextBlock Text="Advanced use only"
                                                   Margin="0,4,0,0"
                                                   FontSize="13"
                                                   FontWeight="SemiBold"
                                                   Foreground="Red"/>
                                    </StackPanel>
                                    <StackPanel Grid.Row="1">
                                        <TextBlock Text="- Disables automatic update policy" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- Stops update services and scheduled tasks" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- Clears downloaded update files" TextWrapping="Wrap" Margin="0,0,0,12" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="Security updates will not be installed while this profile is active."
                                                   FontSize="11"
                                                   FontStyle="Italic"
                                                   TextWrapping="Wrap"
                                                   Foreground="Red"/>
                                    </StackPanel>
                                    <Button Name="WPFUpdatesdisable"
                                            Grid.Row="2"
                                            Content="Disable Updates"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Foreground="Red"
                                            Margin="0,16,0,0"
                                            Padding="10"/>
                                </Grid>
                            </Border>
                        </UniformGrid>

                        <Border Grid.Row="2" Style="{StaticResource BorderStyle}" Margin="8,14,8,8" Padding="12">
                            <TextBlock Text="Changes apply system-wide. Restart Windows after switching profiles. Use Restore Defaults to undo WinUtil update policies."
                                       TextWrapping="Wrap"
                                       HorizontalAlignment="Center"
                                       Foreground="{DynamicResource MainForegroundColor}"/>
                        </Border>
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Win11ISO" Visibility="Collapsed" Name="WPFTab5">
                <Grid Name="Win11ISOPanel" Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>  <!-- Steps 1-4 -->
                        <RowDefinition Height="*"/>     <!-- Log / Status -->
                    </Grid.RowDefinitions>

                    <!-- Steps 1-4 -->
                    <StackPanel Grid.Row="0">

                            <!-- â”€â”€â”€ STEP 1 : Select Windows 11 ISO â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ -->
                            <Grid Name="WPFWin11ISOSelectSection" Margin="5" HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Left: File Selector -->
                                <StackPanel Grid.Column="0" Margin="5,5,15,5">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        Step 1 - Select Windows 11 ISO
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,6">
                                        Browse to your locally saved Windows 11 ISO file. Only official ISOs
                                        downloaded from Microsoft are supported.
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" FontStyle="Italic">
                                        <Run FontWeight="Bold">NOTE:</Run> This is only meant for Fresh and New Windows installs.
                                    </TextBlock>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBox Grid.Column="0"
                                                 Name="WPFWin11ISOPath"
                                                 IsReadOnly="True"
                                                 VerticalAlignment="Center"
                                                 Padding="6,4"
                                                 Margin="0,0,6,0"
                                                 Text="No ISO selected..."
                                                 Foreground="{DynamicResource MainForegroundColor}"
                                                 Background="{DynamicResource MainBackgroundColor}"/>
                                        <Button Grid.Column="1"
                                                Name="WPFWin11ISOBrowseButton"
                                                Content="Browse"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </Grid>
                                    <TextBlock Name="WPFWin11ISOFileInfo"
                                               FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               Margin="0,8,0,0"
                                               TextWrapping="Wrap"
                                               Visibility="Collapsed"/>
                                </StackPanel>

                                <!-- Right: Download guidance -->
                                <Border Grid.Column="1"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Margin="5" Padding="15">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="OrangeRed" Margin="0,0,0,10">
                                            !!WARNING!! You must use an official Microsoft ISO
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">
                                            Download the Windows 11 ISO directly from Microsoft.com.
                                            Third-party, pre-modified, or unofficial images are not supported
                                            and may produce broken results.
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,6">
                                            On the Microsoft download page, choose:
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="12,0,0,12">
                                            - Edition  : Windows 11
                                            <LineBreak/>- Language : your preferred language
                                            <LineBreak/>- Architecture : 64-bit (x64)
                                        </TextBlock>
                                        <Button Name="WPFWin11ISODownloadLink"
                                                Content="Open Microsoft Download Page"
                                                HorizontalAlignment="Left"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- â”€â”€â”€ STEP 2 : Mount & Verify ISO â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ -->
                            <Grid Name="WPFWin11ISOMountSection"
                                  Margin="5"
                                  Visibility="Collapsed"
                                  HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" Margin="0,0,20,0" VerticalAlignment="Top">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        Step 2 - Mount &amp; Verify ISO
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" MaxWidth="320">
                                        Mount the ISO and confirm it contains a valid Windows 11
                                        install.wim before any modifications are made.
                                    </TextBlock>
                                    <Button Name="WPFWin11ISOMountButton"
                                            Content="Mount &amp; Verify ISO"
                                            HorizontalAlignment="Left"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <CheckBox Name="WPFWin11ISOInjectDrivers"
                                              Content="Inject current system drivers"
                                              FontSize="{DynamicResource FontSize}"
                                              Foreground="{DynamicResource MainForegroundColor}"
                                              IsChecked="False"
                                              Margin="0,8,0,0"
                                              ToolTip="Stages boot-storage drivers for Setup and adds all exported drivers to the selected install.wim edition in one DISM pass."/>
                                </StackPanel>

                                <!-- Verification results panel -->
                                <Border Grid.Column="1"
                                        Name="WPFWin11ISOVerifyResultPanel"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Padding="12" Margin="0,0,0,0"
                                        Visibility="Collapsed">
                                    <StackPanel>
                                        <TextBlock Name="WPFWin11ISOMountDriveLetter"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock Name="WPFWin11ISOArchLabel"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,6,0,4">
                                            Select Edition:
                                        </TextBlock>
                                        <ComboBox Name="WPFWin11ISOEditionComboBox"
                                                  FontSize="{DynamicResource FontSize}"
                                                  Foreground="{DynamicResource MainForegroundColor}"
                                                  Background="{DynamicResource MainBackgroundColor}"
                                                  HorizontalAlignment="Left"
                                                  Margin="0,0,0,0"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- â”€â”€â”€ STEP 3 : Modify install.wim â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ -->
                            <StackPanel Name="WPFWin11ISOModifySection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                    Step 3 - Modify install.wim
                                </TextBlock>
                                <TextBlock FontSize="{DynamicResource FontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           TextWrapping="Wrap" Margin="0,0,0,12">
                                    The ISO contents will be extracted to a temporary working directory,
                                    install.wim will be modified (components removed, tweaks applied),
                                    and the result will be repackaged. This process may take several minutes
                                    depending on your hardware.
                                </TextBlock>
                                <Button Name="WPFWin11ISOModifyButton"
                                        Content="Run Windows ISO Modification and Creator"
                                        HorizontalAlignment="Left"
                                        Width="Auto" Padding="12,0"
                                        Height="{DynamicResource ButtonHeight}"/>
                            </StackPanel>

                            <!-- â”€â”€â”€ STEP 4 : Output Options â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€ -->
                            <StackPanel Name="WPFWin11ISOOutputSection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <!-- Header row: title + Clean & Reset button -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               VerticalAlignment="Center">
                                        Step 4 - Output: What would you like to do with the modified image?
                                    </TextBlock>
                                    <Button Grid.Column="1"
                                            Name="WPFWin11ISOCleanResetButton"
                                            Content="Clean &amp; Reset"
                                            Foreground="OrangeRed"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"
                                            ToolTip="Delete the temporary working directory and reset the interface back to Step 1"
                                            Margin="12,0,0,0"/>
                                </Grid>

                                <!-- â”€â”€ Choice prompt buttons â”€â”€ -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="16"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Button Grid.Column="0"
                                            Name="WPFWin11ISOChooseISOButton"
                                            Content="Save as an ISO File"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <Button Grid.Column="2"
                                            Name="WPFWin11ISOChooseUSBButton"
                                            Content="Write Directly to a USB Drive (ERASES DRIVE)"
                                            Foreground="OrangeRed"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                </Grid>

                                <!-- â”€â”€ USB write sub-panel (revealed on USB choice) â”€â”€ -->
                                <Border Name="WPFWin11ISOOptionUSB"
                                        Style="{StaticResource BorderStyle}"
                                        Visibility="Collapsed"
                                        Margin="0,8,0,0">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">
                                            <Run FontWeight="Bold" Foreground="OrangeRed">!! All data on the selected USB drive will be permanently erased !!</Run>
                                            <LineBreak/>
                                            Select a removable USB drive below, then click Erase &amp; Write.
                                        </TextBlock>
                                        <!-- USB drive selector row -->
                                        <Grid Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <ComboBox Grid.Column="0"
                                                      Name="WPFWin11ISOUSBDriveComboBox"
                                                      Foreground="{DynamicResource MainForegroundColor}"
                                                      Background="{DynamicResource MainBackgroundColor}"
                                                      VerticalAlignment="Center"
                                                      Margin="0,0,6,0"/>
                                            <Button Grid.Column="1"
                                                    Name="WPFWin11ISORefreshUSBButton"
                                                    Content="Refresh"
                                                    Width="Auto" Padding="8,0"
                                                    Height="{DynamicResource ButtonHeight}"/>
                                        </Grid>
                                        <Button Name="WPFWin11ISOWriteUSBButton"
                                                Content="Erase &amp; Write to USB"
                                                Foreground="OrangeRed"
                                                HorizontalAlignment="Stretch"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"
                                                Margin="0,0,0,10"/>
                                    </StackPanel>
                                </Border>
                            </StackPanel>

                    </StackPanel>

                    <!-- Status Log (fills remaining height) -->
                    <Grid Grid.Row="1" Margin="5">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0"
                                   FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                   Foreground="{DynamicResource MainForegroundColor}"
                                   Margin="0,0,0,4">
                            Status Log
                        </TextBlock>
                        <TextBox Grid.Row="1"
                                 Name="WPFWin11ISOStatusLog"
                                 IsReadOnly="True"
                                 TextWrapping="Wrap"
                                 VerticalScrollBarVisibility="Visible"
                                 VerticalAlignment="Stretch"
                                 Padding="6"
                                 Background="{DynamicResource MainBackgroundColor}"
                                 Foreground="{DynamicResource MainForegroundColor}"
                                 BorderBrush="{DynamicResource BorderColor}"
                                 BorderThickness="1"
                                 Text="Ready. Please select a Windows 11 ISO to begin."/>
                    </Grid>

                </Grid>
            </TabItem>
            <TabItem Header="AppX" Visibility="Collapsed" Name="WPFTab6">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Margin="5">
                                <Label Content="Selections:" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFDefaultAppxSelection" Content=" Default " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledAppx" Content=" Get Installed " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFSelectAllAppx" Content=" Select All " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearAppxSelection" Content=" Clear Selection " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </StackPanel>
                            </StackPanel>

                            <Grid Name="appxpanel" Grid.Row="1">
                            </Grid>

                            <Border Grid.Row="2" Style="{StaticResource BorderStyle}" Margin="5,15,5,5">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}">
                                        Note: Select the Windows AppX packages you wish to install or remove.
                                        <LineBreak/>Install Selected registers a local manifest when available, then falls back to the Microsoft Store.
                                        <LineBreak/>Remove Selected removes packages for the current user and all new user profiles.
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>

                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
                            <Button Name="WPFBackToTweaks" Content="Back to Tweaks" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFInstallSelectedAppx" Content="Install Selected" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFRemoveSelectedAppx" Content="Remove Selected" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
        </TabControl>

        <!-- Window-level progress indicator - visible regardless of active tab -->
        <Border Name="WPFTweaksProgressBar" Grid.Row="3" Background="{DynamicResource MainBackgroundColor}" Visibility="Collapsed" Padding="10,6">
            <StackPanel Orientation="Vertical">
                <TextBlock Name="WPFTweaksProgressLabel" Text="" Foreground="{DynamicResource MainForegroundColor}" FontSize="13" Background="Transparent" Margin="0,0,0,4"/>
                <ProgressBar Name="WPFTweaksProgressValue" Height="6" Minimum="0" Maximum="100" Value="0" Style="{StaticResource RoundedProgressBarStyle}"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>

'@
$WinUtilAutounattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <!--https://schneegans.de/windows/unattend-generator/?LanguageMode=Interactive&ProcessorArchitecture=amd64&BypassRequirementsCheck=true&ComputerNameMode=Random&CompactOsMode=Default&TimeZoneMode=Implicit&PartitionMode=Interactive&DiskAssertionMode=Skip&WindowsEditionMode=Interactive&InstallFromMode=Automatic&PEMode=Default&UserAccountMode=InteractiveLocal&PasswordExpirationMode=Unlimited&LockoutMode=Default&HideFiles=Hidden&ClassicContextMenu=true&LaunchToThisPC=true&ShowEndTask=true&TaskbarSearch=Hide&TaskbarIconsMode=Empty&DisableWidgets=true&LeftTaskbar=true&HideTaskViewButton=true&StartTilesMode=Default&StartPinsMode=Empty&EnableLongPaths=true&HideEdgeFre=true&DisableEdgeStartupBoost=true&DeleteWindowsOld=true&EffectsMode=Default&DeleteEdgeDesktopIcon=true&DesktopIconsMode=Default&StartFoldersMode=Default&WifiMode=Skip&ExpressSettings=DisableAll&LockKeysMode=Configure&CapsLockInitial=Off&CapsLockBehavior=Toggle&NumLockInitial=On&NumLockBehavior=Toggle&ScrollLockInitial=Off&ScrollLockBehavior=Toggle&StickyKeysMode=Disabled&ColorMode=Custom&SystemColorTheme=Dark&AppsColorTheme=Dark&AccentColor=%230078d4&WallpaperMode=Default&LockScreenMode=Default&WdacMode=Skip&AppLockerMode=Skip-->
    <settings pass="offlineServicing"></settings>
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
            <UseConfigurationSet>false</UseConfigurationSet>
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="generalize"></settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\Specialize.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\DefaultUser.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>6</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>7</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>8</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ShippedWithReserves /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="auditSystem"></settings>
    <settings pass="auditUser"></settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\FirstLogon.ps1"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
        <ExtractScript>
param(
    [xml]$Document
);

foreach( $file in $Document.unattend.Extensions.File ) {
    $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) );
    mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) {
        { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); }
        default { [System.Text.Encoding]::Default; }
    };
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( $path, $bytes );
}
        </ExtractScript>
        <File path="C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml">
&lt;LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1"&gt;
    &lt;CustomTaskbarLayoutCollection PinListPlacement="Replace"&gt;
        &lt;defaultlayout:TaskbarLayout&gt;
            &lt;taskbar:TaskbarPinList&gt;
                &lt;taskbar:DesktopApp DesktopApplicationLinkPath="#leaveempty" /&gt;
            &lt;/taskbar:TaskbarPinList&gt;
        &lt;/defaultlayout:TaskbarLayout&gt;
    &lt;/CustomTaskbarLayoutCollection&gt;
&lt;/LayoutModificationTemplate&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.vbs">
HKU = &amp;H80000003
Set reg = GetObject("winmgmts://./root/default:StdRegProv")
Set fso = CreateObject("Scripting.FileSystemObject")

If reg.EnumKey(HKU, "", sids) = 0 Then
    If Not IsNull(sids) Then
        For Each sid In sids
            key = sid + "\Software\Policies\Microsoft\Windows\Explorer"
            name = "LockedStartLayout"
            If reg.GetDWORDValue(HKU, key, name, existing) = 0 Then
                reg.SetDWORDValue HKU, key, name, 0
            End If
        Next
    End If
End If
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.xml">
&lt;Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"&gt;
    &lt;Triggers&gt;
        &lt;EventTrigger&gt;
            &lt;Enabled&gt;true&lt;/Enabled&gt;
            &lt;Subscription&gt;&amp;lt;QueryList&amp;gt;&amp;lt;Query Id="0" Path="Application"&amp;gt;&amp;lt;Select Path="Application"&amp;gt;*[System[Provider[@Name='UnattendGenerator'] and EventID=1]]&amp;lt;/Select&amp;gt;&amp;lt;/Query&amp;gt;&amp;lt;/QueryList&amp;gt;&lt;/Subscription&gt;
        &lt;/EventTrigger&gt;
    &lt;/Triggers&gt;
    &lt;Principals&gt;
        &lt;Principal id="Author"&gt;
            &lt;UserId&gt;S-1-5-18&lt;/UserId&gt;
            &lt;RunLevel&gt;LeastPrivilege&lt;/RunLevel&gt;
        &lt;/Principal&gt;
    &lt;/Principals&gt;
    &lt;Settings&gt;
        &lt;MultipleInstancesPolicy&gt;IgnoreNew&lt;/MultipleInstancesPolicy&gt;
        &lt;DisallowStartIfOnBatteries&gt;false&lt;/DisallowStartIfOnBatteries&gt;
        &lt;StopIfGoingOnBatteries&gt;false&lt;/StopIfGoingOnBatteries&gt;
        &lt;AllowHardTerminate&gt;true&lt;/AllowHardTerminate&gt;
        &lt;StartWhenAvailable&gt;false&lt;/StartWhenAvailable&gt;
        &lt;RunOnlyIfNetworkAvailable&gt;false&lt;/RunOnlyIfNetworkAvailable&gt;
        &lt;IdleSettings&gt;
            &lt;StopOnIdleEnd&gt;true&lt;/StopOnIdleEnd&gt;
            &lt;RestartOnIdle&gt;false&lt;/RestartOnIdle&gt;
        &lt;/IdleSettings&gt;
        &lt;AllowStartOnDemand&gt;true&lt;/AllowStartOnDemand&gt;
        &lt;Enabled&gt;true&lt;/Enabled&gt;
        &lt;Hidden&gt;false&lt;/Hidden&gt;
        &lt;RunOnlyIfIdle&gt;false&lt;/RunOnlyIfIdle&gt;
        &lt;WakeToRun&gt;false&lt;/WakeToRun&gt;
        &lt;ExecutionTimeLimit&gt;PT72H&lt;/ExecutionTimeLimit&gt;
        &lt;Priority&gt;7&lt;/Priority&gt;
    &lt;/Settings&gt;
    &lt;Actions Context="Author"&gt;
        &lt;Exec&gt;
            &lt;Command&gt;C:\Windows\System32\wscript.exe&lt;/Command&gt;
            &lt;Arguments&gt;C:\Windows\Setup\Scripts\UnlockStartLayout.vbs&lt;/Arguments&gt;
        &lt;/Exec&gt;
    &lt;/Actions&gt;
&lt;/Task&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\SetStartPins.ps1">
$json = '{"pinnedList":[]}';
if( [System.Environment]::OSVersion.Version.Build -lt 20000 ) {
    return;
}
$key = 'Registry::HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start';
New-Item -Path $key -ItemType 'Directory' -ErrorAction 'SilentlyContinue';
Set-ItemProperty -LiteralPath $key -Name 'ConfigureStartPins' -Value $json -Type 'String';
        </File>
        <File path="C:\Windows\Setup\Scripts\SetColorTheme.ps1">
$lightThemeSystem = 0;
$lightThemeApps = 0;
$accentColorOnStart = 0;
$enableTransparency = 0;
$htmlAccentColor = '#0078D4';
&amp; {
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
        Force = $true;
        Type = 'DWord';
    };
    Set-ItemProperty @params -Name 'SystemUsesLightTheme' -Value $lightThemeSystem;
    Set-ItemProperty @params -Name 'AppsUseLightTheme' -Value $lightThemeApps;
    Set-ItemProperty @params -Name 'ColorPrevalence' -Value $accentColorOnStart;
    Set-ItemProperty @params -Name 'EnableTransparency' -Value $enableTransparency;
};
&amp; {
    Add-Type -AssemblyName 'System.Drawing';
    $accentColor = [System.Drawing.ColorTranslator]::FromHtml( $htmlAccentColor );

    function ConvertTo-DWord {
        param(
            [System.Drawing.Color]
            $Color
        );

        [byte[]]$bytes = @(
            $Color.R;
            $Color.G;
            $Color.B;
            $Color.A;
        );
        return [System.BitConverter]::ToUInt32( $bytes, 0);
    }

    $startColor = [System.Drawing.Color]::FromArgb( 0xD2, $accentColor );
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent';
        Name = 'AccentPalette';
    };
    $palette = Get-ItemPropertyValue @params;
    $index = 20;
    $palette[ $index++ ] = $accentColor.R;
    $palette[ $index++ ] = $accentColor.G;
    $palette[ $index++ ] = $accentColor.B;
    $palette[ $index++ ] = $accentColor.A;
    Set-ItemProperty @params -Value $palette -Type 'Binary' -Force;
};
        </File>
        <File path="C:\Windows\Setup\Scripts\Specialize.ps1">
$scripts = @(
    {
        reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f;
    };
    {
        net.exe accounts /maxpwage:UNLIMITED;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f;
        [System.Diagnostics.EventLog]::CreateEventSource( 'UnattendGenerator', 'Application' );
    };
    {
        Register-ScheduledTask -TaskName 'UnlockStartLayout' -Xml $( Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UnlockStartLayout.xml' -Raw );
    };
    {
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
    };
    {
        Remove-Item -LiteralPath 'C:\Users\Public\Desktop\Microsoft Edge.lnk' -ErrorAction 'SilentlyContinue' -Verbose;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge" /v HideFirstRunExperience /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v BackgroundModeEnabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v StartupBoostEnabled /t REG_DWORD /d 0 /f;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetStartPins.ps1';
    };
    {
        reg.exe add "HKU\.DEFAULT\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\Specialize.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
$scripts = @(
    {
        [System.Diagnostics.EventLog]::WriteEntry( 'UnattendGenerator', "User '$env:USERNAME' has requested to unlock the Start menu layout.", [System.Diagnostics.EventLogEntryType]::Information, 1 );
    };
    {
        Remove-Item -Path "${env:USERPROFILE}\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
        Remove-Item -Path "$env:HOMEDRIVE\Users\Default\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
    };
    {
        $taskbarPath = "$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar";
        if( Test-Path $taskbarPath ) {
            Get-ChildItem -Path $taskbarPath -File | Remove-Item -Force;
        }
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesRemovedChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'Favorites' -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /f;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type 'DWord' -Value 1;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetColorTheme.ps1';
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /v Enabled /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v AllAppsViewMode /t REG_DWORD /d 2 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_IrisRecommendations /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_AccountNotifications /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowAllPinsList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowFrequentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowRecentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_TrackDocs /t REG_DWORD /d 0 /f;
    };
    {
        Restart-Computer -Force;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "$env:TEMP\UserOnce.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
$scripts = @(
    {
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "StartLayoutFile" /t REG_SZ /d "C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml" /f;
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "LockedStartLayout" /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 0 /f;
    };
    {
        foreach( $root in 'Registry::HKU\.DEFAULT', 'Registry::HKU\DefaultUser' ) {
          Set-ItemProperty -LiteralPath "$root\Control Panel\Keyboard" -Name 'InitialKeyboardIndicators' -Type 'String' -Value 2 -Force;
        }
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v TaskbarEndTask /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle \""Normal\"" -ExecutionPolicy \""Unrestricted\"" -NoProfile -File \""C:\Windows\Setup\Scripts\UserOnce.ps1\""" /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\DefaultUser.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
$scripts = @(
    {
        Remove-Item -LiteralPath @(
          'C:\Windows\Panther\unattend.xml';
          'C:\Windows\Panther\unattend-original.xml';
          'C:\Windows\Setup\Scripts\Wifi.xml';
          'C:\Windows.old';
        ) -Recurse -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /f;
        reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f;
        $services = @{ BITS = 'Manual'; wuauserv = 'Manual'; UsoSvc = 'Automatic'; WaaSMedicSvc = 'Manual' };
        foreach ($name in $services.Keys) {
            Set-Service -Name $name -StartupType $services[$name] -ErrorAction SilentlyContinue;
        }
    };
    {
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /v IsEducationEnvironment /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
    };
    {
        $recallFeature = Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' -and $_.FeatureName -like 'Recall' };
        if( $recallFeature ) {
            Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -ErrorAction SilentlyContinue;
        }
    };
    {
        $viveDir = Join-Path $env:TEMP 'ViVeTool';
        $viveZip = Join-Path $env:TEMP 'ViVeTool.zip';
        Invoke-WebRequest 'https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip' -OutFile $viveZip;
        Expand-Archive -Path $viveZip -DestinationPath $viveDir -Force;
        Remove-Item -Path $viveZip -Force;
        Start-Process -FilePath (Join-Path $viveDir 'ViVeTool.exe') -ArgumentList '/disable /id:47205210' -Wait -NoNewWindow;
        Remove-Item -Path $viveDir -Recurse -Force;
    };
    {
        Start-Process C:\Windows\System32\OneDriveSetup.exe -ArgumentList /uninstall
    };
    {
        if( (Get-BitLockerVolume -MountPoint $Env:SystemDrive).ProtectionStatus -eq 'On' ) {
            Disable-BitLocker -MountPoint $Env:SystemDrive;
        }
    };
    {
        if( (bcdedit | Select-String 'path').Count -eq 2 ) {
            bcdedit /set `{bootmgr`} timeout 0;
        }
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\FirstLogon.log";
        </File>
    </Extensions>
</unattend>

'@
Write-Host @"
██╗     ██╗   ██╗ ██████╗ █████╗ ███████╗██╗  ██╗ ██████╗ ██████╗ 
██║     ██║   ██║██╔════╝██╔══██╗██╔════╝██║  ██║██╔═══██╗██╔══██╗
██║     ██║   ██║██║     ███████║███████╗███████║██║   ██║██████╔╝
██║     ██║   ██║██║     ██╔══██║╚════██║██╔══██║██║   ██║██╔═══╝ 
███████╗╚██████╔╝╚██████╗██║  ██║███████║██║  ██║╚██████╔╝██║     
╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝     
                                                                  
██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗                 
██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║                 
██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║                 
██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║                 
██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗            
╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝  
"@

# Load the configuration files

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

$sync.configs.appxHashtable = @{}
$sync.configs.appx.PSObject.Properties | ForEach-Object {
    $sync.configs.appxHashtable[$_.Name] = $_.Value
}
$sync.preferences.theme = "Dark"
$sync.preferences.packagemanager = "Winget"

if ($Preset) {
    Initialize-WinUtilRunspacePool | Out-Null

    # Selects the tweaks from $Preset varible
    Update-WinUtilSelections -flatJson $sync.configs.preset.$Preset

    # Run tweaks that were selected by Update-WinUtilSelections
    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

if ($Config) {
    Initialize-WinUtilRunspacePool | Out-Null

    Invoke-WPFImpex -type "import" -Config $Config

    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
    Write-Host "Quitting LucaXShop..." -ForegroundColor Red
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        $null = $hwnd, $wParam, $lParam
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -theme $sync.preferences.theme


# Build only the default tab before first paint; other tabs initialize on first activation.
$sync.InitializedTabs = @{}
Initialize-WinUtilTabContent -TabName "Install"

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

$sync.ChocoRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Choco"
})
$sync.WingetRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Winget"
})

switch ($sync.preferences.packagemanager) {
    "Choco" {$sync.ChocoRadioButton.IsChecked = $true; break}
    "Winget" {$sync.WingetRadioButton.IsChecked = $true; break}
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

    }
}

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set the titlebar
$sync["Form"].title = "LucaXShop"
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"

    # Focus the search bar after clearing the text
    $sync.SearchBar.Focus()
    $sync.SearchBar.SelectAll()
})

# add some shortcuts for people that don't like clicking
function Invoke-WinUtilFontScaleStep([double]$Step) { $sync.FontScalingSlider.Value = [math]::Max(0.75, [math]::Min(2.0, $sync.FontScalingSlider.Value + $Step)); Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScalingSlider.Value }

$commonKeyEvents = {
    # Prevent shortcuts from executing if a process is already running
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    # Handle key presses of single keys
    switch ($_.Key) {
        "Escape" { $sync.SearchBar.Text = "" }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
            "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
            "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
            "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
            "W" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Win11ISO tab
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        $keyEventArgs = $_
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
        }
    }
    $ctrlShiftModifiers = [Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl" -or $_.KeyboardDevice.Modifiers -eq $ctrlShiftModifiers) {
        $keyEventArgs = $_
        switch ($_.Key) {
            { $_ -in "OemPlus", "Add" } { Invoke-WinUtilFontScaleStep 0.05; $keyEventArgs.Handled = $true }
            { $_ -in "OemMinus", "Subtract" } { Invoke-WinUtilFontScaleStep -0.05; $keyEventArgs.Handled = $true }
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)
$sync["Form"].Add_PreviewMouseWheel({
    if ([Windows.Input.Keyboard]::Modifiers -eq "Ctrl") { Invoke-WinUtilFontScaleStep $(if ($_.Delta -gt 0) { 0.05 } else { -0.05 }); $_.Handled = $true }
})

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource.Name -eq "NavDockPanel" -or
        $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                [Windows.SystemCommands]::MaximizeWindow($sync.Form)
            }
            else{
                [Windows.SystemCommands]::RestoreWindow($sync.Form)
            }
    }
})

$sync["Form"].Add_Deactivated({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
})

$sync["Form"].Add_ContentRendered({
    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height
        $sync.Form.MinWidth = [Math]::Min([double]$sync.Form.MinWidth, [double]$screenWidth)

        # Compare with the primary monitor size
        if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
            $sync.Form.Left = 0
            $sync.Form.Top = 0
            $sync.Form.Width = $screenWidth
            $sync.Form.Height = $screenHeight
        }
    }

    if ($PARAM_OFFLINE) {
        # Show offline banner
        $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "Internet connection required for installing applications."

        # Disable install-related buttons
        $sync.WPFInstall.IsEnabled = $false
        $sync.WPFUninstall.IsEnabled = $false
        $sync.WPFInstallUpgrade.IsEnabled = $false
        $sync.WPFGetInstalled.IsEnabled = $false

        # Show offline indicator
        Write-Host "Offline mode detected - Install tab disabled." -ForegroundColor Yellow

        # Optionally switch to a different tab if install tab was going to be default
        Invoke-WPFTab "WPFTab2BT"  # Switch to Tweaks tab instead
    }
    else {
        # Online - ensure install tab is enabled
        $sync.WPFTab1BT.IsEnabled = $true
        $sync.WPFTab1BT.Opacity = 1.0
        $sync.WPFTab1BT.ToolTip = $null
        Invoke-WPFTab "WPFTab1BT"  # Default to install tab
    }

    $sync["Form"].Focus()
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilRunspacePool | Out-Null }) | Out-Null
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true }) | Out-Null
})

# The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
# This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

$searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$searchBarTimer.IsEnabled = $false

$searchBarTimer.add_Tick({
    $searchBarTimer.Stop()
    switch ($sync.currentTab) {
        "Install" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Categories $sync.SelectedAppCategories.ToArray()
        }
        "Tweaks" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "AppX" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})
$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
        $sync.SearchBarIcon.Visibility = "Collapsed"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
        $sync.SearchBarIcon.Visibility = "Visible"
    }

    if ($searchBarTimer.IsEnabled) {
        $searchBarTimer.Stop()
    }
    $searchBarTimer.Start()
})

# Category filter chips. The chip carries its category in Tag, so one handler covers all of them.
$sync.AppCategoryChips = @(
    @{ Name = "WPFSearchChipAll";             Category = "" }
    @{ Name = "WPFSearchChipBrowsers";        Category = "Browsers" }
    @{ Name = "WPFSearchChipCommunications";  Category = "Communications" }
    @{ Name = "WPFSearchChipDevelopment";     Category = "Development" }
    @{ Name = "WPFSearchChipDocument";        Category = "Document" }
    @{ Name = "WPFSearchChipGames";           Category = "Games" }
    @{ Name = "WPFSearchChipMicrosoftTools";  Category = "Microsoft Tools" }
    @{ Name = "WPFSearchChipMultimediaTools"; Category = "Multimedia Tools" }
    @{ Name = "WPFSearchChipProTools";        Category = "Pro Tools" }
    @{ Name = "WPFSearchChipSelfhostedTools"; Category = "Selfhosted Tools" }
    @{ Name = "WPFSearchChipUtilities";       Category = "Utilities" }
)
$sync.SelectedAppCategories = [System.Collections.Generic.List[string]]::new()

foreach ($appCategoryChip in $sync.AppCategoryChips) {
    $sync[$appCategoryChip.Name].Tag = $appCategoryChip.Category
}

$sync["WPFSearchChipAll"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipBrowsers"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipCommunications"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipDevelopment"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipDocument"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipGames"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipMicrosoftTools"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipMultimediaTools"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipProTools"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipSelfhostedTools"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })
$sync["WPFSearchChipUtilities"].Add_Click({ Invoke-WinUtilAppCategoryChip -Chip $this })

$sync["Form"].Add_Loaded({
    param($e)
    $null = $e
    $sync.Form.MinWidth = "1150"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")

# LucaXShop logo is embedded so the script remains standalone.
$LucaXShopLogoBase64 = "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"
$LucaXShopLogoBytes = [Convert]::FromBase64String($LucaXShopLogoBase64)
$LucaXShopLogoStream = New-Object System.IO.MemoryStream(,$LucaXShopLogoBytes)
$LucaXShopLogoImage = New-Object System.Windows.Media.Imaging.BitmapImage
$LucaXShopLogoImage.BeginInit()
$LucaXShopLogoImage.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$LucaXShopLogoImage.StreamSource = $LucaXShopLogoStream
$LucaXShopLogoImage.EndInit()
$LucaXShopLogoImage.Freeze()

$sync["Form"].Icon = $LucaXShopLogoImage

$LucaXShopLogoControl = New-Object System.Windows.Controls.Image
$LucaXShopLogoControl.Source = $LucaXShopLogoImage
$LucaXShopLogoControl.Width = 32
$LucaXShopLogoControl.Height = 32
$LucaXShopLogoControl.Margin = "0,0,8,0"
$LucaXShopLogoControl.Stretch = [System.Windows.Media.Stretch]::Uniform
$NavLogoPanel.Children.Add($LucaXShopLogoControl) | Out-Null

$LucaXShopBrandText = New-Object System.Windows.Controls.TextBlock
$LucaXShopBrandText.Text = "LucaXShop"
$LucaXShopBrandText.FontSize = 16
$LucaXShopBrandText.FontWeight = "Bold"
$LucaXShopBrandText.VerticalAlignment = "Center"
$LucaXShopBrandText.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(56,189,248))
$NavLogoPanel.Children.Add($LucaXShopBrandText) | Out-Null

$LucaXShopLogoStream.Dispose()
Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $false

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
})
$sync["AutoThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
})
$sync["DarkThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
})
$sync["LightThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
})

$sync["SettingsButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
})
$sync["ImportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
})
$sync["ExportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
})
$sync["AboutMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    $authorInfo = @"
<b>LucaXShop</b>

Website : <a href="$LucaXShopWebsiteUrl">$LucaXShopWebsiteUrl</a>
Discord : <a href="$LucaXShopDiscordUrl">$LucaXShopDiscordUrl</a>
Version : $($sync.version)
"@
    Show-CustomDialog -Title "About" -Message $authorInfo
})
$sync["DocumentationMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Start-Process $LucaXShopWebsiteUrl
})
$sync["SponsorMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Start-Process $LucaXShopDiscordUrl
})

$sync["LucaXShopDiscordButton"].Add_Click({
    Start-Process $LucaXShopDiscordUrl
})

$sync["LucaXShopWebsiteButton"].Add_Click({
    Start-Process $LucaXShopWebsiteUrl
})

# Font Scaling Event Handlers
$sync["FontScalingButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
})

$sync["FontScalingSlider"].Add_ValueChanged({
    param($slider)
    $percentage = [math]::Round($slider.Value * 100)
    $sync.FontScalingValue.Text = "$percentage%"
})

$sync["FontScalingResetButton"].Add_Click({
    $sync.FontScalingSlider.Value = 1.0
    $sync.FontScalingValue.Text = "100%"
})

$sync["FontScalingApplyButton"].Add_Click({
    $scaleFactor = $sync.FontScalingSlider.Value
    Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
    Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
})

# â”€â”€ Win11ISO Tab button handlers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

$sync["WPFWin11ISOBrowseButton"].Add_Click({
    Invoke-WinUtilISOBrowse
})

$sync["WPFWin11ISODownloadLink"].Add_Click({
    Start-Process "https://www.microsoft.com/software-download/windows11"
})

$sync["WPFWin11ISOMountButton"].Add_Click({
    Invoke-WinUtilISOMountAndVerify
})

$sync["WPFWin11ISOModifyButton"].Add_Click({
    Invoke-WinUtilISOModify
})

$sync["WPFWin11ISOChooseISOButton"].Add_Click({
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Collapsed"
    Invoke-WinUtilISOExport
})

$sync["WPFWin11ISOChooseUSBButton"].Add_Click({
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Visible"
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISORefreshUSBButton"].Add_Click({
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISOWriteUSBButton"].Add_Click({
    Invoke-WinUtilISOWriteUSB
})

$sync["WPFWin11ISOCleanResetButton"].Add_Click({
    Invoke-WinUtilISOCleanAndReset
})

function Remove-WinUtilTempScript {
    <#
    .SYNOPSIS
        Removes the temporary script downloaded by windev.ps1.

    .DESCRIPTION
        Deletes the current script only when it is a winutil-*.ps1 file in
        the system temporary directory. This preserves normal file-backed
        and in-memory WinUtil launches.
    #>

    $scriptPath = $PSCommandPath
    $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')

    if (
        $scriptPath -and
        [IO.Path]::GetDirectoryName($scriptPath) -eq $tempPath -and
        [IO.Path]::GetFileName($scriptPath) -like 'winutil-*.ps1'
    ) {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

$sync["Form"].ShowDialog() | out-null
Remove-WinUtilTempScript
Stop-Transcript

