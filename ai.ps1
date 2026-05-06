param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArgs
)

$ErrorActionPreference = "Stop"

$script:MaxHitLines = 400
$script:MaxEvidenceChars = 120000

$CliArgs = @($CliArgs | ForEach-Object { [string]$_ })

$configFile = Join-Path $PSScriptRoot ".ai-config.json"

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
      Use current folder / repo context (auto ripgrep for repo search patterns when rg is available)

  ai rg "prompt"
      Force ripgrep evidence mode (flexible placement: before or after targets)

  ai file.ext "prompt"
      Target file(s)

  ai file1.ext file2.ext "prompt"
      Compare or inspect multiple files

  ai folder "prompt"
      Target folder

  ai q30 internal/mcp rg "question"
  ai internal/mcp rg "question"
  ai rg internal/mcp "question"
  ai q30 rg "question"

$aliasHelp

  ai ls
      List installed models

Examples:
  ai rg "where is auth checked?"
  ai "where is SCRUMBOY_WALL_ENABLED used?"
  ai internal/mcp "find json-rpc handler"
  ai q30 rg "explain the MCP routing from these hits"
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

function Test-RgAvailable {
    $c = Get-Command rg -ErrorAction SilentlyContinue
    return $null -ne $c
}

function Get-RgBaseArgs {
    return @(
        '--line-number',
        '--column',
        '--context', '2',
        '--hidden',
        '--smart-case',
        '--glob', '!**/.git/**',
        '--glob', '!**/node_modules/**',
        '--glob', '!**/dist/**',
        '--glob', '!**/build/**',
        '--glob', '!**/bin/**',
        '--glob', '!**/obj/**',
        '--glob', '!**/vendor/**',
        '--glob', '!**/.next/**',
        '--glob', '!**/coverage/**'
    )
}

function Get-RgGlobArgs {
    return @(
        '--glob', '!**/.git/**',
        '--glob', '!**/node_modules/**',
        '--glob', '!**/dist/**',
        '--glob', '!**/build/**',
        '--glob', '!**/bin/**',
        '--glob', '!**/obj/**',
        '--glob', '!**/vendor/**',
        '--glob', '!**/.next/**',
        '--glob', '!**/coverage/**'
    )
}

function Invoke-RgProcess {
    param([string[]]$ArgumentList)

    $cmd = Get-Command rg -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return @{ Exit = -1; Out = ''; Err = 'rg not found' }
    }

    $exe = $cmd.Source
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()

    try {
        & $exe @ArgumentList 1>$outFile 2>$errFile
        $exit = $LASTEXITCODE
        $out = ''
        if (Test-Path -LiteralPath $outFile) {
            $out = [System.IO.File]::ReadAllText($outFile)
        }
        $err = ''
        if (Test-Path -LiteralPath $errFile) {
            $err = [System.IO.File]::ReadAllText($errFile)
        }
        return @{ Exit = $exit; Out = $out.TrimEnd(); Err = $err.TrimEnd() }
    } finally {
        Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }
}

function Invoke-RgForPattern {
    param(
        [string]$Pattern,
        [bool]$FixedStrings,
        [string[]]$SearchRoots
    )

    $baseArgs = Get-RgBaseArgs
    $fs = @()
    if ($FixedStrings) {
        $fs = @('--fixed-strings')
    }
    $allArgs = @($baseArgs + $fs + '--' + @($Pattern) + $SearchRoots)
    return Invoke-RgProcess -ArgumentList $allArgs
}

function Normalize-RgPathKey {
    param([string]$PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return ''
    }
    try {
        return [System.IO.Path]::GetFullPath($PathText.Trim())
    } catch {
        return $PathText.Trim()
    }
}

function Get-MatchKeyFromRgLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    $m = [regex]::Match($Line, '^(.*):(\d+):(\d+):(.*)$')
    if (-not $m.Success) {
        return $null
    }

    $pathPart = $m.Groups[1].Value
    $lineNum = [int]$m.Groups[2].Value
    $kPath = Normalize-RgPathKey $pathPart
    return "$kPath|$lineNum"
}

function Test-RepoSearchNegative {
    param([string]$PromptLower)

    $p = $PromptLower

    if ($p -match '^\s*write\b') { return $true }
    if ($p -match '\bdraft\b') { return $true }
    if ($p -match 'explain\s+this\s+concept') { return $true }
    if ($p -match 'what\s+model') { return $true }
    if ($p -match 'small\s+powershell') { return $true }
    if ($p -match 'powershell\s+script') { return $true }

    return $false
}

function Test-RepoSearchPrompt {
    param([string]$Prompt)

    $p = $Prompt.ToLowerInvariant()
    if (Test-RepoSearchNegative $p) {
        return $false
    }

    if (Is-LocatorPrompt $Prompt) {
        return $true
    }

    $pos = '(\bwhy\b|where|\bfind\b|\blocate\b|\bused\b|\bdefined\b|\bset\b|\breferenced\b|\bendpoint\b|\broute\b|\bhandler\b|\bconfig\b|\benv\b|\bflag\b|error|\bfail\b|\bcrash\b|\bdebug\b|root cause|auth|session|token|bearer|sse|websocket|event|broadcast)'
    if ($p -match $pos) {
        return $true
    }

    return $false
}

function Test-SearchLikeForTargets {
    param([string]$Prompt)

    $p = $Prompt.ToLowerInvariant()
    if (Test-RepoSearchNegative $p) {
        return $false
    }

    if (Is-LocatorPrompt $Prompt) {
        return $true
    }

    return Test-RepoSearchPrompt $Prompt
}

function Get-RgModel {
    param([string]$Prompt)

    $r1Model = Resolve-Model 'r1'

    foreach ($rule in $AiConfig.Routing) {
        if ($Prompt -match $rule.Pattern) {
            $resolved = Resolve-Model $rule.Model
            if ($resolved -eq $r1Model) {
                return $resolved
            }
        }
    }

    return Resolve-Model 'coder'
}

function Get-RgSearchPlan {
    param([string]$Prompt)

    $plan = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    $add = {
        param($t, $fixed)

        if ([string]::IsNullOrWhiteSpace($t)) { return }
        $k = "$fixed|$t"
        if ($seen.Contains($k)) { return }
        [void]$seen.Add($k)
        $plan.Add([pscustomobject]@{ Text = $t; Fixed = [bool]$fixed }) | Out-Null
    }

    $dq = [regex]::Matches($Prompt, '"([^"]+)"')
    foreach ($m in $dq) {
        & $add $m.Groups[1].Value $true
    }

    $sq = [regex]::Matches($Prompt, "'([^']+)'")
    foreach ($m in $sq) {
        & $add $m.Groups[1].Value $true
    }

    $envTok = [regex]::Matches($Prompt, '\b[A-Z][A-Z0-9_]{1,}\b')
    foreach ($m in $envTok) {
        & $add $m.Value $true
    }

    $slashes = [regex]::Matches($Prompt, '/[a-zA-Z0-9][a-zA-Z0-9_\-./]*')
    foreach ($m in $slashes) {
        $s = $m.Value.Trim()
        if ($s.Length -ge 2) {
            & $add $s $true
        }
    }

    $camel = [regex]::Matches($Prompt, '\b[a-z][a-zA-Z0-9]{2,}\b')
    foreach ($m in $camel) {
        $v = $m.Value
        if ($v -match '^[a-z]+$') { continue }
        & $add $v $false
    }

    $pascal = [regex]::Matches($Prompt, '\b[A-Z][a-z]+[a-zA-Z0-9]*\b')
    foreach ($m in $pascal) {
        & $add $m.Value $false
    }

    $snake = [regex]::Matches($Prompt, '\b[a-z][a-z0-9]+(?:_[a-z0-9]+)+\b')
    foreach ($m in $snake) {
        & $add $m.Value $false
    }

    $stop = @(
        'where','is','the','a','an','find','locate',
        'what','this','that','for','does','do','and','not','are','was','were',
        'how','when','from','into','with','your','our','their','any','all','can','could',
        'would','should','will','just','only','also','like','such','them','then','than',
        'using','based','about','after','before','make','need','want','tell','give',
        'help','show','list','each','some','very','more','most','other','over',
        'client','code','file','path','line'
    )

    $tokens = @([regex]::Split($Prompt.ToLowerInvariant(), '[^a-z0-9_/]+') |
        Where-Object { $_.Length -ge 3 -and $stop -notcontains $_ } |
        Select-Object -Unique)

    foreach ($t in $tokens) {
        & $add $t $false
    }

    if ($plan.Count -eq 0) {
        $words = @([regex]::Split($Prompt, '[^a-zA-Z0-9_]+') | Where-Object { $_.Length -ge 4 } | Select-Object -Unique | Select-Object -First 5)
        foreach ($w in $words) {
            & $add $w $false
        }
    }

    return $plan.ToArray()
}

function Split-RgOutputChunks {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $parts = [regex]::Split($Text, '(?m)^--\s*$')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        $t = $p.TrimEnd()
        if (-not [string]::IsNullOrWhiteSpace($t)) {
            $out.Add($t) | Out-Null
        }
    }

    if ($out.Count -eq 0) {
        return @($Text.TrimEnd())
    }

    return $out.ToArray()
}

function Add-RgTextDeduped {
    param(
        [string]$Text,
        [System.Collections.Generic.HashSet[string]]$SeenKeys,
        [System.Collections.Generic.List[string]]$Blocks
    )

    $chunks = Split-RgOutputChunks $Text
    foreach ($chunk in $chunks) {
        $keysInChunk = New-Object System.Collections.Generic.HashSet[string]
        foreach ($ln in ($chunk -split "`r?`n")) {
            $k = Get-MatchKeyFromRgLine $ln
            if ($null -ne $k) {
                [void]$keysInChunk.Add($k)
            }
        }

        $hasNew = $false
        if ($keysInChunk.Count -eq 0) {
            $hasNew = $true
        } else {
            foreach ($k in $keysInChunk) {
                if (-not $SeenKeys.Contains($k)) {
                    $hasNew = $true
                    break
                }
            }
        }

        if (-not $hasNew) {
            continue
        }

        foreach ($k in $keysInChunk) {
            [void]$SeenKeys.Add($k)
        }

        $Blocks.Add($chunk) | Out-Null
    }
}

function Invoke-RgFileListing {
    param([string[]]$SearchRoots)

    $fileArgs = @('--files', '--hidden', '--smart-case') + (Get-RgGlobArgs) + $SearchRoots
    return Invoke-RgProcess -ArgumentList $fileArgs
}

function Invoke-RgSearchSession {
    param(
        [string]$Prompt,
        [string[]]$SearchRoots
    )

    $result = [pscustomobject]@{
        Failed = $false
        FailureMessage = ''
        TermsUsed = New-Object System.Collections.Generic.List[string]
        EvidenceText = ''
        UniqueMatchKeys = New-Object System.Collections.Generic.HashSet[string]
        Blocks = New-Object System.Collections.Generic.List[string]
    }

    $plan = Get-RgSearchPlan $Prompt

    foreach ($entry in $plan) {
        $termLabel = "$(if ($entry.Fixed) { 'fixed' } else { 'regex' }):$($entry.Text)"
        if (-not $result.TermsUsed.Contains($termLabel)) {
            $result.TermsUsed.Add($termLabel) | Out-Null
        }

        $r = Invoke-RgForPattern -Pattern $entry.Text -FixedStrings $entry.Fixed -SearchRoots $SearchRoots

        if ($r.Exit -eq 1) {
            continue
        }

        if ($r.Exit -ne 0) {
            $result.Failed = $true
            $msg = $r.Err
            if ([string]::IsNullOrWhiteSpace($msg)) {
                $msg = "ripgrep exit code $($r.Exit)"
            }
            $result.FailureMessage = $msg
            return $result
        }

        if ([string]::IsNullOrWhiteSpace($r.Out)) {
            continue
        }

        Add-RgTextDeduped -Text $r.Out -SeenKeys $result.UniqueMatchKeys -Blocks $result.Blocks
    }

    if ($result.UniqueMatchKeys.Count -eq 0 -and $plan.Count -gt 0) {
        $fl = Invoke-RgFileListing -SearchRoots $SearchRoots
        if ($fl.Exit -ne 0 -and $fl.Exit -ne 1) {
            $result.Failed = $true
            $msg = $fl.Err
            if ([string]::IsNullOrWhiteSpace($msg)) {
                $msg = "ripgrep exit code $($fl.Exit)"
            }
            $result.FailureMessage = $msg
            return $result
        }

        $names = @($fl.Out -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $termsForFiles = @([regex]::Split($Prompt.ToLowerInvariant(), '[^a-z0-9_]+') |
            Where-Object { $_.Length -ge 3 } |
            Select-Object -Unique |
            Select-Object -First 8)

        $picked = New-Object System.Collections.Generic.List[string]
        foreach ($n in $names) {
            $bn = [System.IO.Path]::GetFileName($n)
            foreach ($t in $termsForFiles) {
                if ($bn.ToLowerInvariant().Contains($t)) {
                    if ($picked.Count -lt 40) {
                        $picked.Add($n) | Out-Null
                    }
                    break
                }
            }
            if ($picked.Count -ge 40) { break }
        }

        foreach ($pf in $picked) {
            foreach ($t in $termsForFiles | Select-Object -First 3) {
                $r2 = Invoke-RgForPattern -Pattern $t -FixedStrings $true -SearchRoots @($pf)
                if ($r2.Exit -eq 0 -and -not [string]::IsNullOrWhiteSpace($r2.Out)) {
                    $label = "fallback-fixed:$t@$pf"
                    if (-not $result.TermsUsed.Contains($label)) {
                        $result.TermsUsed.Add($label) | Out-Null
                    }
                    Add-RgTextDeduped -Text $r2.Out -SeenKeys $result.UniqueMatchKeys -Blocks $result.Blocks
                }
            }
        }
    }

    $merged = ($result.Blocks -join ("`n" + '--' + "`n"))
    $linesOut = New-Object System.Collections.Generic.List[string]
    $lineBudget = $script:MaxHitLines
    $charBudget = $script:MaxEvidenceChars
    $trunc = ''

    foreach ($ln in ($merged -split "`r?`n")) {
        if ($lineBudget -le 0) {
            $trunc = 'Evidence truncated: max hit lines reached.'
            break
        }
        if ($charBudget -le ($ln.Length + 2)) {
            $trunc = 'Evidence truncated: max total characters reached.'
            break
        }
        $linesOut.Add($ln) | Out-Null
        $lineBudget--
        $charBudget -= ($ln.Length + 1)
    }

    $body = ($linesOut -join "`n")
    if (-not [string]::IsNullOrWhiteSpace($trunc)) {
        $body = $body + "`n" + $trunc
    }

    $result.EvidenceText = $body
    return $result
}

function Build-RgEvidencePrompt {
    param(
        [string]$Question,
        [string]$RepoRootLabel,
        [string[]]$TermsUsed,
        [string]$EvidenceBody,
        [bool]$EmptyEvidence
    )

    $sb = New-Object System.Text.StringBuilder
    if ($EmptyEvidence) {
        [void]$sb.AppendLine('You are answering from real ripgrep results.')
        [void]$sb.AppendLine('There were no matching ripgrep hits for the tried terms.')
        [void]$sb.AppendLine('State clearly that evidence is insufficient.')
        [void]$sb.AppendLine('Do not invent files, functions, line numbers, or behavior.')
    } else {
        [void]$sb.AppendLine('You are answering from real ripgrep results.')
        [void]$sb.AppendLine('Use only the evidence below.')
        [void]$sb.AppendLine('If the evidence is insufficient, say so.')
        [void]$sb.AppendLine('Mention filenames and line numbers.')
        [void]$sb.AppendLine('Do not invent files, functions, or behavior.')
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Question:')
    [void]$sb.AppendLine($Question)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Search terms / passes tried:')
    foreach ($t in $TermsUsed) {
        [void]$sb.AppendLine("- $t")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Repo / search scope: $RepoRootLabel")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Ripgrep evidence:')
    [void]$sb.AppendLine($EvidenceBody)
    return $sb.ToString()
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

function Try-AddTargets {
    param(
        [string]$Item,
        [System.Collections.Generic.List[string]]$Targets
    )

    if (Test-Path -LiteralPath $Item) {
        foreach ($r in Resolve-Path -LiteralPath $Item) {
            $Targets.Add($r.Path) | Out-Null
        }
        return $true
    }

    try {
        $wild = @(Get-ChildItem -Path $Item -ErrorAction Stop)
        if ($wild.Count -gt 0) {
            foreach ($w in $wild) {
                $Targets.Add($w.FullName) | Out-Null
            }
            return $true
        }
    } catch {
    }

    return $false
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

    $rgExplicit = $false
    $targets = New-Object System.Collections.Generic.List[string]
    $promptParts = New-Object System.Collections.Generic.List[string]
    $beforePrompt = $true

    foreach ($item in $items) {
        if ($beforePrompt -and $item -ieq 'rg') {
            $rgExplicit = $true
            continue
        }

        if ($beforePrompt) {
            if (Try-AddTargets -Item $item -Targets $targets) {
                continue
            }
        }

        $beforePrompt = $false
        $promptParts.Add($item) | Out-Null
    }

    return [pscustomobject]@{
        Model = $model
        RgExplicit = $rgExplicit
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
        $root = (Get-Location).Path
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Context: Local Folder ($root)")

        $files = @(Get-ChildItem -Path $root -File | Select-Object -First 50 | Select-Object -ExpandProperty Name)

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("Files (top 50):")
        foreach ($f in $files) {
            [void]$sb.AppendLine("- $f")
        }
    }

    return $sb.ToString()
}

function Write-SearchTermsHost {
    param([System.Collections.Generic.List[string]]$Terms)

    Write-Host ""
    Write-Host "[Search terms / passes used]" -ForegroundColor Magenta
    foreach ($t in $Terms) {
        Write-Host "  $t" -ForegroundColor DarkGray
    }
    Write-Host ""
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

$userModel = $parsed.Model
$rgExplicit = $parsed.RgExplicit
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

$wantRg = $false

if ($rgExplicit) {
    $wantRg = $true
} elseif ($targets.Count -eq 0) {
    if (Test-RepoSearchPrompt $prompt) {
        $wantRg = $true
    }
} else {
    if (Test-SearchLikeForTargets $prompt) {
        $wantRg = $true
    }
}

$defaultRoot = Get-GitRoot
if (-not $defaultRoot) {
    $defaultRoot = (Get-Location).Path
}

$searchRoots = @()
if ($targets.Count -gt 0) {
    $searchRoots = @($targets)
} else {
    $searchRoots = @($defaultRoot)
}

$rgReady = Test-RgAvailable
$useRgPipeline = $wantRg -and $rgReady

if ($wantRg -and -not $rgReady) {
    Write-Warning "rg (ripgrep) not found on PATH; falling back without ripgrep evidence."
}

$rgSession = $null
if ($useRgPipeline) {
    $rgSession = Invoke-RgSearchSession -Prompt $prompt -SearchRoots $searchRoots
    if ($rgSession.Failed) {
        Write-Warning ("ripgrep failed: " + $rgSession.FailureMessage)
        $useRgPipeline = $false
    }
}

$hasHits = $false
if ($null -ne $rgSession) {
    $hasHits = $rgSession.Blocks.Count -gt 0
}

if ($useRgPipeline) {

    $scopeLabel = ($searchRoots -join '; ')

    if ($hasHits) {

        if ($userModel) {
            $model = $userModel
        } else {
            $model = Get-RgModel $prompt
        }

        Write-SearchTermsHost -Terms $rgSession.TermsUsed

        $full = Build-RgEvidencePrompt -Question $prompt -RepoRootLabel $scopeLabel `
            -TermsUsed @($rgSession.TermsUsed) -EvidenceBody $rgSession.EvidenceText -EmptyEvidence $false

        Invoke-Ollama -Model $model -Prompt $full
        exit 0
    }

    if ($rgExplicit) {

        if ($userModel) {
            $model = $userModel
        } else {
            $model = Get-RgModel $prompt
        }

        Write-SearchTermsHost -Terms $rgSession.TermsUsed

        $emptyBody = '[No ripgrep matches returned for the tried terms.]'
        $full = Build-RgEvidencePrompt -Question $prompt -RepoRootLabel $scopeLabel `
            -TermsUsed @($rgSession.TermsUsed) -EvidenceBody $emptyBody -EmptyEvidence $true

        Invoke-Ollama -Model $model -Prompt $full
        exit 0
    }

    if ($targets.Count -gt 0) {

        if (-not $userModel) {
            $model = Get-AutoModel $prompt $hasRepo
        } else {
            $model = $userModel
        }

        Write-SearchTermsHost -Terms $rgSession.TermsUsed

        $emptyBody = '[No ripgrep matches in the selected targets.]'
        $full = Build-RgEvidencePrompt -Question $prompt -RepoRootLabel $scopeLabel `
            -TermsUsed @($rgSession.TermsUsed) -EvidenceBody $emptyBody -EmptyEvidence $true

        Invoke-Ollama -Model $model -Prompt $full
        exit 0
    }

    Write-Host ""
    Write-Host "[Ripgrep: no matches for automatic search; falling back to normal project context.]" -ForegroundColor Yellow
    Write-Host ""

    if (-not $userModel) {
        $model = Get-AutoModel $prompt $hasRepo
    } else {
        $model = $userModel
    }

    $contextPrompt = Build-ContextPrompt -Prompt $prompt
    Invoke-Ollama -Model $model -Prompt $contextPrompt
    exit 0
}

if (-not $userModel) {
    $model = Get-AutoModel $prompt $hasRepo
} else {
    $model = $userModel
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
