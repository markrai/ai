# AI Operator (`ai`)

A tiny Windows/Ollama ai command for asking local models repo-aware questions using real ripgrep evidence.
A minimal Windows helper that runs **local models through [Ollama](https://ollama.com/)** with sensible defaults: model aliases, automatic model routing from your prompt, and lightweight **project or file context** injected into the prompt (no IDE required).

## Prerequisites

- **Windows** with **PowerShell** (the entry point is `ai.cmd` calling `ai.ps1`).
- **[Ollama](https://ollama.com/)** installed and on your `PATH`, so `ollama run` works from a terminal.
- Pull the models you reference in [`.ai-config.json`](.ai-config.json) (or use `ollama pull <model>` after editing aliases).

## Optional

- **[ripgrep](https://github.com/BurntSushi/ripgrep)** (`rg` on your `PATH`) for `ai rg` and automatic repo search. Without it, the script warns and falls back to the older context or file-snippet paths.


## Files

| File | Role |
|------|------|
| [`ai.cmd`](ai.cmd) | Batch launcher; forwards arguments to PowerShell without breaking quoted prompts. |
| [`ai.ps1`](ai.ps1) | Main logic: config load, parsing, context building, `ollama run`. |
| [`.ai-config.json`](.ai-config.json) | Default model, **aliases** (short names → Ollama model tags), and **routing** rules. |

If `.ai-config.json` is missing, `ai.ps1` creates one with built-in defaults the first time you run it.

## Installation

1. Clone or copy this folder anywhere you like.
2. Add that folder to your user **PATH** (or call `ai.cmd` with a full path).

From any directory, run:

```bat
ai
```

with no arguments to print help.

## Configuration (`.ai-config.json`)

- **`DefaultModel`**: Either an Ollama model tag (e.g. `qwen2.5-coder:32b`) or an **alias** key from `Aliases`.
- **`Aliases`**: Short names you can pass as the first argument, e.g. `ai q30 "..."` → resolves to the mapped model.
- **`Routing`**: Ordered list of `{ "Pattern": "regex", "Model": "alias or full name" }`. The script lowercases the prompt and runs the **first** matching pattern; if none match, **`DefaultModel`** is used.

Edit the JSON to match the models you actually have installed (`ai ls`).

## Usage

```text
ai                          Show help
ai help                     Same

ai ls                       List installed Ollama models (ollama list)

ai "your prompt"            Use git repo or current folder context
ai alias "your prompt"      Force a model via alias (e.g. ai r1 "why does this hang?")

ai path\to\file.ext "..."   Attach file contents to the prompt
ai a.go b.go "compare"      Multiple explicit files

ai folder "..."             Targets resolved paths under that folder (same parsing rules)
```

### Context modes

1. **Repo / folder context** (no file arguments): Builds a prompt that includes either:
   - **Git**: repository root and up to **50** paths from `git ls-files`, or  
   - **Non-git**: current directory and up to **50** file names in that folder.

2. **Explicit targets** (files or globs that resolve): Full file contents (for files) are embedded in the prompt, with instructions to use only that material.

### Locator-style prompts on files

If you pass one or more **files** and the prompt looks like a “where / find / locate” question (e.g. starts with `where is`, or contains patterns like `where … defined`), the script **searches those files** for keyword terms, extracts small line windows around hits, and sends that **snippet bundle** to the model instead of the entire file. Useful for large files.

## Examples

For a larger command cookbook, see [EXAMPLES.md](EXAMPLES.md).

```bat
ai "What stack are we using?"
ai q30 "How should dependencies be organized?"
ai r1 "Why might this deadlock?"
ai coder "Write a PowerShell regex to strip BOM"
ai src\app.ts "Summarize this module"
ai ls
```

## Requirements and limits

- Depends on **`ollama`** being available in the shell.
- Repo context is capped at **50** tracked files; explicit mode sends **whole file** text for targeted files (except locator mode).
- **Auto-created** `.ai-config.json` (when missing) may differ slightly from the committed sample (e.g. default model); compare with this repo’s [`.ai-config.json`](.ai-config.json) if you want the same aliases out of the box.

## Manual acceptance (ripgrep paths)

Run these in a real git repo with **`rg`** and **`ollama`** available when checking model output:

- `ai "find the project wall routes"` — search plan should include **wall**, **project**, **routes** (not only **routes**); evidence or follow-up behavior should reflect that vocabulary.
- `ai internal/mcp "find json-rpc handler"` — if ripgrep finds no hits, fallback must **not** widen to whole-repo file-list context; it stays scoped to the chosen targets (empty-evidence or target-scoped prompt).
- `ai rg "where is bearer token validation?"` — with no hits, **Ollama** still runs with the **empty-evidence** instruction path.
- `ai "write a PowerShell script that prints hello"` — must **not** trigger **auto-rg** (generative prompt).
- `ai q30 internal/mcp rg "explain the MCP routing"` — the **q30** alias must still select the **q30** model after resolution.
