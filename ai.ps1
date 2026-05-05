param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArgs
)

$ErrorActionPreference = "Stop"

$CliArgs = @($CliArgs | ForEach-Object { [string]$_ })

$configFile = Join-Path $PSScriptRoot ".ai-config.json"

# Load or Initialize Configuration
if (Test-Path $configFile) {
    $AiConfig = Get-Content $configFile -Raw | ConvertFrom-Json
} else {
    $AiConfig = [pscustomobject]@{
        DefaultModel = "coder"
        Aliases = @{
            "q30"   = "qwen3:30b"
            "q14"   = "qwen3:14b"
            "coder" = "qwen2.5-coder:32b"
            "ds"    = "dagbs/deepseek-coder-v2-lite-instruct:q5_k_m"
            "r1"    = "deepseek-r1:14b"
            "dev"   = "devstral:latest"
        }
        Routing = @(
            @{ Pattern = "architecture|stack|dependency|dependencies|build|run|setup"; Model = "q30" },
            @{ Pattern = "why|reason|race|deadlock|root cause|debug"; Model = "r1" },
            @{ Pattern = "script|powershell|cmd|regex|docker|git"; Model = "coder" }
        )
    }
    $AiConfig | ConvertTo-Json -Depth 10 | Set-Content $configFile
}

function Show-Help {
    $aliasHelp = ($AiConfig.Aliases.PSObject.Properties | ForEach-Object { "  ai $($_.Name.PadRight(8)) $($_.Value)" }) -join "`n"
@"
AI Operator

Usage:
  ai
      Show help

  ai "prompt"
      Use current folder / repo context

  ai file.ext "prompt"
      Target file(s)

  ai file1.ext file2.ext "prompt"
      Compare or inspect multiple files

  ai folder "prompt"
      Target folder

$aliasHelp

  ai ls
      List installed models

Examples:
  ai "What stack are we using?"
  ai scream.html "what does this do?"
  ai main.go auth.go "compare these"
  ai q30 "explain architecture"
"@
}

function Resolve-DefaultModel {
    $m = $AiConfig.DefaultModel
    if ($AiConfig.Aliases.PSObject.Properties.Name -contains $m) {
        return $AiConfig.Aliases.$m
    }
    return $m
}

function Resolve-Model {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return Resolve-DefaultModel
    }

    $k = $Value.ToLowerInvariant()

    if ($AiConfig.Aliases.PSObject.Properties.Name -contains $k) {
        return $AiConfig.Aliases.$k
    }

    return $Value
}

function Drop-First {
    param([object[]]$Array,[int]$Count)

    if ($Array.Count -le $Count) { return @() }

    return @($Array[$Count..($Array.Count - 1)])
}

function Get-GitRoot {
    try {
        $root = git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($root)) {
            return $root.Trim()
        }
    } catch {}
    return $null
}

function Get-TextRaw {
    param([string]$Path)

    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 }
    catch { return Get-Content -LiteralPath $Path -Raw }
}

function Invoke-Ollama {
    param(
        [string]$Model,
        [string]$Prompt
    )

    Write-Host ""
    Write-Host "[Model: $Model]" -ForegroundColor Cyan
    Write-Host ""

    $Prompt | & ollama run $Model
}

function Get-AutoModel {
    param(
        [string]$Prompt,
        [bool]$HasRepo
    )

    $p = $Prompt.ToLowerInvariant()

    foreach ($rule in $AiConfig.Routing) {
        if ($p -match $rule.Pattern) {
            return Resolve-Model $rule.Model
        }
    }

    return Resolve-DefaultModel
}

function Is-LocatorPrompt {
    param([string]$Prompt)

    $p = $Prompt.ToLowerInvariant()

    if ($p -match "^where is ") { return $true }
    if ($p -match "where.*set") { return $true }
    if ($p -match "where.*used") { return $true }
    if ($p -match "where.*defined") { return $true }
    if ($p -match "^find ") { return $true }
    if ($p -match "^locate ") { return $true }

    return $false
}

function Get-Terms {
    param([string]$Prompt)

    $stop = @(
        "where","is","the","a","an","set","used","defined","find","locate",
        "what","why","this","that","for","flag","variable","does","do"
    )

    return @([regex]::Split($Prompt.ToLowerInvariant(),'[^a-z0-9_]+') |
        Where-Object { $_.Length -ge 2 -and $stop -notcontains $_ } |
        Select-Object -Unique)
}

function Search-InFile {
    param(
        [string]$Path,
        [string[]]$Terms
    )

    $raw = Get-TextRaw $Path
    $lines = $raw -split "`r?`n"
    $hits = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $match = $false

        foreach ($term in $Terms) {
            if ($line.ToLowerInvariant().Contains($term)) {
                $match = $true
                break
            }
        }

        if ($match) {
            $start = [Math]::Max(0,$i-3)
            $end = [Math]::Min($lines.Count-1,$i+3)

            for ($j = $start; $j -le $end; $j++) {
                $hits.Add(("{0}: {1}" -f ($j+1),$lines[$j]))
            }

            $hits.Add("-----")
        }

        if ($hits.Count -gt 120) { break }
    }

    return ($hits -join "`n")
}

function Parse-Input {
    param([string[]]$InputArgs)

    $items = @($InputArgs)
    $model = $null

    if ($items.Count -gt 0) {
        $first = $items[0].ToLowerInvariant()

        if ($AiConfig.Aliases.PSObject.Properties.Name -contains $first) {
            $model = Resolve-Model $first
            $items = Drop-First $items 1
        }
    }

    $targets = New-Object System.Collections.Generic.List[string]
    $promptParts = New-Object System.Collections.Generic.List[string]

    $collectingTargets = $true

    foreach ($item in $items) {

        if ($collectingTargets -and (Test-Path -LiteralPath $item)) {
            $resolved = Resolve-Path -LiteralPath $item
            foreach ($r in $resolved) {
                $targets.Add($r.Path)
            }
            continue
        }

        if ($collectingTargets) {
            try {
                $wild = @(Get-ChildItem -Path $item -ErrorAction Stop)
                if ($wild.Count -gt 0) {
                    foreach ($w in $wild) {
                        $targets.Add($w.FullName)
                    }
                    continue
                }
            } catch {
            }
        }

        $collectingTargets = $false
        $promptParts.Add($item)
    }

    return [pscustomobject]@{
        Model = $model
        Targets = @($targets | Select-Object -Unique)
        Prompt = ($promptParts -join " ").Trim()
    }
}

function Build-TargetPrompt {
    param(
        [string]$Prompt,
        [string[]]$Targets
    )

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("You are a local coding and filesystem assistant.")
    [void]$sb.AppendLine("Use only the provided local files.")
    [void]$sb.AppendLine("Be concise and practical.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Task:")
    [void]$sb.AppendLine($Prompt)

    foreach ($t in $Targets) {
        if (Test-Path $t -PathType Leaf) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("File: $t")
            [void]$sb.AppendLine((Get-TextRaw $t))
        }
    }

    return $sb.ToString()
}

function Build-ContextPrompt {
    param([string]$Prompt)

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("You are a local project and coding assistant.")
    [void]$sb.AppendLine("Use the local project context provided below.")
    [void]$sb.AppendLine("Be concise and practical.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Task:")
    [void]$sb.AppendLine($Prompt)

    $root = Get-GitRoot
    
    if ($root) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Context: Git Repository ($root)")
        
        $files = @(git -C $root ls-files | Select-Object -First 50)

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Files (top 50):")
        foreach ($f in $files) {
            [void]$sb.AppendLine("- $f")
        }
    } else {
        $root = Get-Location
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Context: Local Folder ($root)")

        # Fallback to standard file listing if not a git repo
        $files = @(Get-ChildItem -Path $root -File | Select-Object -First 50 | Select-Object -ExpandProperty Name)

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Files (top 50):")
        foreach ($f in $files) {
            [void]$sb.AppendLine("- $f")
        }
    }

    return $sb.ToString()
}

if ($CliArgs.Count -eq 0) {
    Show-Help
    exit 0
}

$cmd = $CliArgs[0].ToLowerInvariant()

if ($cmd -eq "help" -or $cmd -eq "--help" -or $cmd -eq "-h") {
    Show-Help
    exit 0
}

if ($cmd -eq "ls" -or $cmd -eq "models") {
    ollama list
    exit 0
}

$parsed = Parse-Input $CliArgs

$model = $parsed.Model
$targets = $parsed.Targets
$prompt = $parsed.Prompt

if ([string]::IsNullOrWhiteSpace($prompt)) {
    if ($targets.Count -gt 0) {
        $prompt = "Review these targets."
    } else {
        Show-Help
        exit 0
    }
}

$hasRepo = (Get-GitRoot) -ne $null

if (-not $model) {
    $model = Get-AutoModel $prompt $hasRepo
}

if ($targets.Count -gt 0) {

    Write-Host ""
    Write-Host "[Scope: explicit target(s)]" -ForegroundColor Yellow
    Write-Host "[Selected: $($targets.Count)]" -ForegroundColor DarkGray

    foreach ($t in $targets) {
        Write-Host "  $t" -ForegroundColor DarkGray
    }

    if (Is-LocatorPrompt $prompt) {
        $terms = Get-Terms $prompt

        $sb = New-Object System.Text.StringBuilder

        [void]$sb.AppendLine("Answer using only these search hits.")
        [void]$sb.AppendLine("Mention exact lines, variables, symbols.")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Question:")
        [void]$sb.AppendLine($prompt)

        foreach ($t in $targets) {
            if (Test-Path $t -PathType Leaf) {
                [void]$sb.AppendLine("")
                [void]$sb.AppendLine("File: $t")
                [void]$sb.AppendLine((Search-InFile -Path $t -Terms $terms))
            }
        }

        Invoke-Ollama -Model $model -Prompt $sb.ToString()
        exit 0
    }

    $fullPrompt = Build-TargetPrompt -Prompt $prompt -Targets $targets
    Invoke-Ollama -Model $model -Prompt $fullPrompt
    exit 0
}

$contextPrompt = Build-ContextPrompt -Prompt $prompt
Invoke-Ollama -Model $model -Prompt $contextPrompt
