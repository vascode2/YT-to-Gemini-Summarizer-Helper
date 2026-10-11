param(
    [Parameter(Mandatory = $true)]
    [int]$WindowHandle,
    [Parameter(Mandatory = $true)]
    [string]$PayloadPath,
    [Parameter(Mandatory = $true)]
    [string]$StatusPath,
    [switch]$StartNewChat,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$scope = [System.Windows.Automation.TreeScope]::Descendants
$timeoutMs = 8000

function Find-Element($Root, [System.Windows.Automation.ControlType]$Type, [scriptblock]$Match) {
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type)
    foreach ($candidate in $Root.FindAll($scope, $condition)) {
        if (& $Match $candidate) { return $candidate }
    }
    return $null
}

function Find-Composer($Root) {
    return Find-Element $Root ([System.Windows.Automation.ControlType]::Edit) {
        param($element)
        $element.Current.ClassName.Contains('ql-editor') -or $element.Current.Name -eq 'Ask Gemini' -or $element.Current.Name -eq 'Enter a prompt for Gemini'
    }
}

function Read-Composer($Root) {
    $element = Find-Composer $Root
    if (-not $element) { throw 'Gemini desktop composer was not found.' }
    return @{ Element = $element; Value = [string]$element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
}

function Test-ComposerEmpty([string]$value) {
    $normalized = $value.Trim()
    return [string]::IsNullOrEmpty($normalized) -or $normalized -eq 'Ask Gemini'
}

try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$WindowHandle)
    if (-not $root -or $root.Current.Name -ne 'Gemini') { throw 'Gemini desktop window handle is invalid.' }
    $composerState = Read-Composer $root
    $composer = $composerState.Element

    if ($StartNewChat) {
        $newChat = Find-Element $root ([System.Windows.Automation.ControlType]::Hyperlink) { param($element) $element.Current.Name -eq 'New chat' }
        if (-not $newChat) { throw 'Gemini desktop New chat control was not found.' }
        $newChat.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Milliseconds 400
        $composerState = Read-Composer $root
        $composer = $composerState.Element
    }

    $payload = [IO.File]::ReadAllText($PayloadPath, [Text.Encoding]::UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($payload)) { throw 'Gemini desktop payload is empty.' }

    $composer.SetFocus()
    $composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($payload)
    $deadline = [Environment]::TickCount64 + $timeoutMs
    do {
        Start-Sleep -Milliseconds 100
        $composerState = Read-Composer $root
    } while ($composerState.Value.Trim() -ne $payload -and [Environment]::TickCount64 -lt $deadline)
    if ($composerState.Value.Trim() -ne $payload) { throw 'Gemini desktop composer did not receive the complete prompt.' }

    $sendButton = Find-Element $root ([System.Windows.Automation.ControlType]::Button) { param($element) $element.Current.Name -eq 'Send message' }
    if (-not $sendButton) { throw 'Gemini desktop Send message button was not found; prompt remains in the composer.' }
    if (-not $sendButton.Current.IsEnabled) { throw 'Gemini desktop Send message button is disabled; prompt remains in the composer.' }

    if ($PrepareOnly) {
        $composer.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('')
        [IO.File]::WriteAllText($StatusPath, 'prepared', [Text.Encoding]::ASCII)
        exit 0
    }

    $sendButton.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $deadline = [Environment]::TickCount64 + $timeoutMs
    do {
        Start-Sleep -Milliseconds 100
        $composerState = Read-Composer $root
    } while (-not (Test-ComposerEmpty $composerState.Value) -and [Environment]::TickCount64 -lt $deadline)
    if (-not (Test-ComposerEmpty $composerState.Value)) { throw 'Gemini desktop did not clear the composer after Send.' }

    [IO.File]::WriteAllText($StatusPath, 'sent', [Text.Encoding]::ASCII)
    exit 0
}
catch {
    [IO.File]::WriteAllText($StatusPath, ('error: ' + $_.Exception.Message), [Text.UTF8Encoding]::new($false))
    exit 1
}
