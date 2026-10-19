param([string]$SourcePath = (Join-Path $PSScriptRoot '..\Windows\CodexData.cs'))
$ErrorActionPreference = 'Stop'

# Run in an isolated Windows test worker: a running desktop Codex intentionally
# takes priority over PATH in production and would mask these fixtures.
if (Get-Process -Name Codex -ErrorAction SilentlyContinue) {
    throw 'Test setup requires a worker without a running Codex desktop app.'
}
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path $SourcePath -ReferencedAssemblies System,System.Web.Extensions,System.Core
$resolve = [CodexMonitor.Data].GetMethod('Executable', [Reflection.BindingFlags]'NonPublic,Static')
if (-not $resolve) { throw 'Executable discovery entrypoint missing.' }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-discovery-' + [Guid]::NewGuid())
$names = @('PATH', 'CODEX_BINARY', 'PROCESSOR_ARCHITECTURE', 'PROCESSOR_ARCHITEW6432')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$script:cases = 0

function New-FakeBinary([string]$path) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllText($path, 'discovery fixture only, never executed')
    return $path
}
function Test-Discovery([string]$name, [scriptblock]$setup, [switch]$Missing) {
    $root = Join-Path $fixture $name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    [Environment]::SetEnvironmentVariable('PATH', $root)
    [Environment]::SetEnvironmentVariable('CODEX_BINARY', $null)
    [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'AMD64')
    [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITEW6432', $null)
    $expected = & $setup $root
    $actual = $null
    $missingSeen = $false
    try { $actual = $resolve.Invoke($null, $null) }
    catch {
        # PowerShell 5.1 wraps reflected exceptions in MethodInvocationException;
        # inspect the underlying cause rather than relying on the wrapper type.
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        if (-not $Missing -or $failure -isnot [IO.FileNotFoundException]) {
            throw "FAIL ${name}: executable discovery rejected the fixture"
        }
        $missingSeen = $true
    }
    if (($Missing -and (-not $missingSeen -or $null -ne $actual)) -or (-not $Missing -and $actual -ne $expected)) {
        throw "FAIL ${name}: wrong executable selected"
    }
    $script:cases++
    Write-Output "PASS $name"
}
try {
    Test-Discovery 'native-path' { param($root) New-FakeBinary (Join-Path $root 'codex.exe') }
    Test-Discovery 'legacy-npm' { param($root)
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
    }
    Test-Discovery 'legacy-vendor-layout' { param($root)
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex.exe')
    }
    Test-Discovery 'modern-npm-nested' { param($root)
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
    }
    Test-Discovery 'modern-npm-hoisted' { param($root)
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
    }
    Test-Discovery 'quoted-npm-path' { param($root)
        [Environment]::SetEnvironmentVariable('PATH', '"' + $root + '"')
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
    }
    Test-Discovery 'arm64-nested' { param($root)
        [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'ARM64')
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex\node_modules\@openai\codex-win32-arm64\vendor\aarch64-pc-windows-msvc\bin\codex.exe')
    }
    Test-Discovery 'arm64-hoisted' { param($root)
        [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITEW6432', 'ARM64')
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex-win32-arm64\vendor\aarch64-pc-windows-msvc\bin\codex.exe')
    }
    Test-Discovery 'arm64-x64-node-install' { param($root)
        [Environment]::SetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'ARM64')
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
    }
    Test-Discovery 'native-priority' { param($root)
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe') | Out-Null
        New-FakeBinary (Join-Path $root 'codex.exe')
    }
    Test-Discovery 'modern-priority' { param($root)
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\bin\codex.exe') | Out-Null
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
    }
    Test-Discovery 'explicit-override' { param($root)
        New-FakeBinary (Join-Path $root 'codex.exe') | Out-Null
        $binary = New-FakeBinary (Join-Path $root 'custom\codex.exe')
        [Environment]::SetEnvironmentVariable('CODEX_BINARY', $binary)
        $binary
    }
    Test-Discovery 'missing-override-fallback' { param($root)
        [Environment]::SetEnvironmentVariable('CODEX_BINARY', (Join-Path $root 'missing.exe'))
        New-FakeBinary (Join-Path $root 'codex.exe')
    }
    Test-Discovery 'path-order' { param($root)
        $second = Join-Path $root 'second'
        [Environment]::SetEnvironmentVariable('PATH', $root + [IO.Path]::PathSeparator + $second)
        New-FakeBinary (Join-Path $second 'codex.exe') | Out-Null
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
    }
    Test-Discovery 'invalid-path-entry' { param($root)
        [Environment]::SetEnvironmentVariable('PATH', 'invalid|entry;' + $root)
        New-FakeBinary (Join-Path $root 'codex.exe')
    }
    Test-Discovery 'missing-binary' { param($root) } -Missing
    Test-Discovery 'ignore-wrong-architecture' { param($root)
        New-FakeBinary (Join-Path $root 'node_modules\@openai\codex-win32-arm64\vendor\aarch64-pc-windows-msvc\bin\codex.exe') | Out-Null
    } -Missing
    Write-Output "Executable discovery: $script:cases cases passed"
    exit 0
} catch {
    # Stdout makes the expected red run unambiguous even under PowerShell 5.1's
    # native-stderr handling in a parent process with ErrorActionPreference=Stop.
    Write-Output $_.Exception.Message
    exit 1
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}
