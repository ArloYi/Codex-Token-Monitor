param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
if ($SelfTest) {
    Add-Type -Path (Join-Path $PSScriptRoot 'CodexData.cs') -ReferencedAssemblies System,System.Web.Extensions,System.Core
    [CodexMonitor.Data]::SelfTest()
    Write-Output 'Windows protocol self-test passed'
    exit 0
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'CodexData.cs')) + [Environment]::NewLine + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Hud.cs'))
Add-Type -TypeDefinition $source -ReferencedAssemblies System,System.Windows.Forms,System.Drawing,System.Web.Extensions,System.Core
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run((New-Object CodexMonitor.Hud))
