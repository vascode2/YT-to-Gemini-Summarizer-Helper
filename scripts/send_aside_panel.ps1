param(
    [Parameter(Mandatory = $true)]
    [int]$WindowHandle,
    [Parameter(Mandatory = $true)]
    [string]$PayloadPath,
    [Parameter(Mandatory = $true)]
    [string]$StatusPath,
    # The bare YouTube URL being summarized; used to decide whether the auto-attached
    # "current page" chip refers to the same video (keep) or something else (remove).
    [string]$Url = '',
    # Move keyboard focus back to the page (tab content) after sending, so page hotkeys
    # (e.g. Netflix extension Ctrl+C / playback keys) keep working instead of typing into the panel.
    [switch]$FocusPage
)

# Sends a prompt to the Aside browser's AI side panel (Windows UI Automation).
# The panel composer is a tiptap/ProseMirror contenteditable: it exposes TextPattern
# but no ValuePattern, so the text is pasted (the caller already put the payload on
# the clipboard) and submitted with Enter. Aside must be the foreground window.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
$scope = [System.Windows.Automation.TreeScope]::Descendants
$AE = [System.Windows.Automation.AutomationElement]
$timeoutMs = 8000

# Key injection via keybd_event: it only queues the events and returns. SendKeys.SendWait
# blocks until the target app has processed them and hung this helper for 40+ s while
# Aside's UI thread was busy.
Add-Type -Namespace Native -Name Keys -MemberDefinition '[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);'
function Send-Ctrl([byte]$Key) {
    [Native.Keys]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [Native.Keys]::keybd_event($Key, 0, 0, [UIntPtr]::Zero)
    [Native.Keys]::keybd_event($Key, 0, 2, [UIntPtr]::Zero)
    [Native.Keys]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
}
function Send-Enter {
    [Native.Keys]::keybd_event(0x0D, 0, 0, [UIntPtr]::Zero)
    [Native.Keys]::keybd_event(0x0D, 0, 2, [UIntPtr]::Zero)
}
# Step trace next to the status file, read by copy.ahk when a run fails or times out.
function Trace([string]$Step) {
    try { Add-Content -Path ($StatusPath + '.trace') -Value ('{0} {1}' -f [Environment]::TickCount64, $Step) } catch {}
}

function Find-PanelDocument($Root) {
    # The side panel is the Document that contains the "Close side panel" button.
    $docs = $Root.FindAll($scope, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document))
    foreach ($doc in $docs) {
        $close = $doc.FindFirst($scope, [System.Windows.Automation.PropertyCondition]::new($AE::NameProperty, 'Close side panel'))
        if ($close) { return $doc }
    }
    return $null
}

function Find-Composer($Panel) {
    $groups = $Panel.FindAll($scope, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Group))
    foreach ($g in $groups) {
        if (([string]$g.Current.ClassName).Contains('composer-editor')) { return $g }
    }
    return $null
}

function Read-Composer($Composer) {
    return ([string]$Composer.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1)).Trim()
}

function Test-ComposerEmpty([string]$text) {
    return [string]::IsNullOrEmpty($text) -or $text -eq 'Reply, @ for context'
}

function Get-VideoId([string]$u) {
    if ($u -match '(?:[?&]v=|/shorts/|youtu\.be/|/live/|/embed/)([A-Za-z0-9_-]{11})') { return $Matches[1] }
    return ''
}

try {
    $root = $AE::FromHandle([IntPtr]$WindowHandle)
    if (-not $root) { throw 'Aside window handle is invalid.' }

    $payload = [IO.File]::ReadAllText($PayloadPath, [Text.Encoding]::UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($payload)) { throw 'Aside payload is empty.' }

    Trace 'start'
    $panel = Find-PanelDocument $root
    if (-not $panel) {
        # Panel closed: Aside's "Toggle Sidebar" shortcut is Ctrl+S.
        Trace 'panel closed -> Ctrl+S'
        Send-Ctrl 0x53
        $deadline = [Environment]::TickCount64 + 4000
        do {
            Start-Sleep -Milliseconds 150
            $panel = Find-PanelDocument $root
        } while (-not $panel -and [Environment]::TickCount64 -lt $deadline)
        if (-not $panel) { throw 'Aside side panel did not open (Ctrl+S).' }
    }
    Trace 'panel ready'

    $composer = $null
    $deadline = [Environment]::TickCount64 + 4000
    do {
        $composer = Find-Composer $panel
        if (-not $composer) { Start-Sleep -Milliseconds 150 }
    } while (-not $composer -and [Environment]::TickCount64 -lt $deadline)
    if (-not $composer) { throw 'Aside side panel composer was not found.' }
    Trace 'composer found'

    # Drop the auto-attached current-page chip unless it is the very video we are sending.
    $wantId = Get-VideoId $Url
    $tabUrl = ''
    if ($wantId) {
        # Only needed to compare against the YouTube video being sent; a non-YouTube caller passes no -Url.
        $addr = $root.FindFirst($scope, [System.Windows.Automation.PropertyCondition]::new($AE::AutomationIdProperty, 'view_1012'))
        if ($addr) { $tabUrl = [string]$addr.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
    }
    $tabId = Get-VideoId $tabUrl
    if (-not $wantId -or $wantId -ne $tabId) {
        $buttons = $panel.FindAll($scope, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))
        foreach ($b in $buttons) {
            if (([string]$b.Current.Name).StartsWith('Remove ')) {
                $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Start-Sleep -Milliseconds 200
                break
            }
        }
        $composer = Find-Composer $panel
        if (-not $composer) { throw 'Aside side panel composer disappeared after removing the page chip.' }
    }

    $composer.SetFocus()
    Start-Sleep -Milliseconds 200
    Trace 'composer focused'
    Send-Ctrl 0x41
    Start-Sleep -Milliseconds 60
    Send-Ctrl 0x56
    Trace 'pasted'

    # First line only: the composer text may normalise newlines, so never probe across one.
    $firstLine = ($payload -split "\r?\n")[0].Trim()
    $probe = if ($wantId) { $wantId } else { $firstLine.Substring(0, [Math]::Min(20, $firstLine.Length)) }
    $deadline = [Environment]::TickCount64 + $timeoutMs
    do {
        Start-Sleep -Milliseconds 100
        # A multi-paragraph paste makes ProseMirror rebuild its nodes, which leaves the old
        # element stale (UIA calls on it block). Always look the composer up again.
        $pn = Find-PanelDocument $root
        $fresh = if ($pn) { Find-Composer $pn } else { $null }
        $text = if ($fresh) { Read-Composer $fresh } else { '' }
    } while (-not $text.Contains($probe) -and [Environment]::TickCount64 -lt $deadline)
    if (-not $text.Contains($probe)) { throw 'Aside composer did not receive the pasted prompt.' }
    Trace 'paste verified'

    Start-Sleep -Milliseconds 250
    Send-Enter
    Trace 'enter sent'

    $deadline = [Environment]::TickCount64 + $timeoutMs
    do {
        Start-Sleep -Milliseconds 100
        # The editor node is re-rendered on submit; look it up again instead of reusing a stale element.
        $pn = Find-PanelDocument $root
        $fresh = if ($pn) { Find-Composer $pn } else { $null }
        $text = if ($fresh) { Read-Composer $fresh } else { '' }
    } while (-not (Test-ComposerEmpty $text) -and [Environment]::TickCount64 -lt $deadline)
    if (-not (Test-ComposerEmpty $text)) { throw 'Aside did not clear the composer after Enter; prompt remains in the panel.' }

    if ($FocusPage) {
        # The page is the Document that does NOT hold the side-panel close button.
        $page = $null; $pageArea = 0
        foreach ($doc in $root.FindAll($scope, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document))) {
            if ($doc.FindFirst($scope, [System.Windows.Automation.PropertyCondition]::new($AE::NameProperty, 'Close side panel'))) { continue }
            $r = $doc.Current.BoundingRectangle
            if (($r.Width * $r.Height) -gt $pageArea) { $page = $doc; $pageArea = $r.Width * $r.Height }
        }
        if ($page) { $page.SetFocus() }
    }

    [IO.File]::WriteAllText($StatusPath, 'sent', [Text.Encoding]::ASCII)
    exit 0
}
catch {
    [IO.File]::WriteAllText($StatusPath, ('error: ' + $_.Exception.Message), [Text.UTF8Encoding]::new($false))
    exit 1
}
