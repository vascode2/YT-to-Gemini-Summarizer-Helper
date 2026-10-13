param(
    [Parameter(Mandatory = $true)]
    [int]$WindowHandle,
    [Parameter(Mandatory = $true)]
    [string]$PayloadPath,
    [Parameter(Mandatory = $true)]
    [string]$StatusPath,
    # The bare YouTube URL being summarized; used to decide whether the auto-attached
    # "current page" chip refers to the same video (keep) or something else (remove).
    [string]$Url = ''
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
        if ($g.Current.ClassName.Contains('composer-editor')) { return $g }
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

    $panel = Find-PanelDocument $root
    if (-not $panel) {
        # Panel closed: Aside's "Toggle Sidebar" shortcut is Ctrl+S.
        [System.Windows.Forms.SendKeys]::SendWait('^s')
        $deadline = [Environment]::TickCount64 + 4000
        do {
            Start-Sleep -Milliseconds 150
            $panel = Find-PanelDocument $root
        } while (-not $panel -and [Environment]::TickCount64 -lt $deadline)
        if (-not $panel) { throw 'Aside side panel did not open (Ctrl+S).' }
    }

    $composer = $null
    $deadline = [Environment]::TickCount64 + 4000
    do {
        $composer = Find-Composer $panel
        if (-not $composer) { Start-Sleep -Milliseconds 150 }
    } while (-not $composer -and [Environment]::TickCount64 -lt $deadline)
    if (-not $composer) { throw 'Aside side panel composer was not found.' }

    # Drop the auto-attached current-page chip unless it is the very video we are sending.
    $wantId = Get-VideoId $Url
    $tabUrl = ''
    $addr = $root.FindFirst($scope, [System.Windows.Automation.PropertyCondition]::new($AE::AutomationIdProperty, 'view_1012'))
    if ($addr) { $tabUrl = [string]$addr.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
    $tabId = Get-VideoId $tabUrl
    if (-not $wantId -or $wantId -ne $tabId) {
        $buttons = $panel.FindAll($scope, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))
        foreach ($b in $buttons) {
            if ($b.Current.Name.StartsWith('Remove ')) {
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
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 60
    [System.Windows.Forms.SendKeys]::SendWait('^v')

    $probe = if ($wantId) { $wantId } else { $payload.Substring(0, [Math]::Min(20, $payload.Length)) }
    $deadline = [Environment]::TickCount64 + $timeoutMs
    do {
        Start-Sleep -Milliseconds 100
        $text = Read-Composer $composer
    } while (-not $text.Contains($probe) -and [Environment]::TickCount64 -lt $deadline)
    if (-not $text.Contains($probe)) { throw 'Aside composer did not receive the pasted prompt.' }

    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')

    $deadline = [Environment]::TickCount64 + $timeoutMs
    do {
        Start-Sleep -Milliseconds 100
        # The editor node is re-rendered on submit; look it up again instead of reusing a stale element.
        $fresh = Find-Composer $panel
        $text = if ($fresh) { Read-Composer $fresh } else { '' }
    } while (-not (Test-ComposerEmpty $text) -and [Environment]::TickCount64 -lt $deadline)
    if (-not (Test-ComposerEmpty $text)) { throw 'Aside did not clear the composer after Enter; prompt remains in the panel.' }

    [IO.File]::WriteAllText($StatusPath, 'sent', [Text.Encoding]::ASCII)
    exit 0
}
catch {
    [IO.File]::WriteAllText($StatusPath, ('error: ' + $_.Exception.Message), [Text.UTF8Encoding]::new($false))
    exit 1
}
