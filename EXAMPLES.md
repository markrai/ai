# AI Operator Examples

A practical cookbook for using `ai` with local Ollama models, file targets, folder targets, and ripgrep-backed repo evidence. Run these from a repo root or the folder you care about. Put the `ai` folder on your PATH, or call `ai.cmd` with a full path.

## Basic commands

```bat
ai
ai help
ai ls
ai "What stack are we using?"
```

With no arguments, `ai` prints help. `ai help` does the same. `ai ls` runs `ollama list`. A quoted prompt is sent to the model using the current folder or git repo context (file list only, unless auto-search kicks in).

## Force a model alias

```bat
ai q30 "explain the architecture"
ai r1 "why might this deadlock?"
ai coder "write a git cleanup command"
```

Aliases come from `.ai-config.json`. Putting an alias first fixes the model for that run and overrides automatic routing from the prompt.

## Repo search with `ai rg`

```bat
ai rg "where is auth checked?"
ai rg "where is POST /mcp/rpc handled?"
ai rg "where are SSE events broadcast?"
ai rg "find transient wall events"
```

`ai rg` forces ripgrep-backed evidence mode. The model is instructed to use only search hits; when there are hits, answers should cite paths and line numbers. With no hits, the script still calls the model with an empty-evidence prompt.

## Automatic repo search

```bat
ai "where is config loaded?"
ai "find the project wall routes"
ai "where is SCRUMBOY_WALL_ENABLED used?"
ai "why would bearer auth fail even with a token?"
```

Search-like prompts can trigger ripgrep automatically when `rg` is on PATH. Pure generation prompts (for example, asking only for a new script) should not trigger that path.

## Folder-scoped search

```bat
ai internal\mcp rg "explain the MCP routing"
ai internal\wall rg "where is persistence handled?"
ai q30 internal\mcp rg "explain the tool invocation flow"
```

Folder targets limit search roots. You can place `rg` before or after targets. A model alias before paths still applies.

## File targets

```bat
ai ai.ps1 ".ai-config.json" "does config routing match script behavior?"
ai main.go auth.go "compare how auth state flows between these files"
ai README.md "make this clearer for new users"
```

Explicit file targets embed file contents in the prompt (leaf files only). Use this for review, comparison, or focused rewrite suggestions.

## Debugging with r1 and rg

```bat
ai r1 rg "why would wall updates not persist?"
ai r1 rg "why would session auth fail?"
ai r1 rg "why is this setting not taking effect?"
```

`r1` is suited to root-cause style questions. `rg` grounds answers in repo evidence when hits exist.

## Architecture with q30 and rg

```bat
ai q30 rg "explain how auth is wired together"
ai q30 internal\mcp rg "explain how MCP requests are routed"
ai q30 internal\wall rg "explain the wall persistence flow"
```

Use a stronger general model for subsystem maps. Scoped folders reduce noise from the rest of the repo.

## Code generation with coder

```bat
ai coder "write a PowerShell script that prints hello"
ai coder "write a regex for matching semantic versions"
ai coder "give me a docker command to rebuild this image"
```

Pure generation does not need ripgrep. The `coder` alias matches routing for scripts, shell commands, regex, Docker, and git-style tasks.

## PR and maintenance checks

```bat
ai CHANGELOG.md VERSION "check whether the version bump is consistent"
ai rg "where is the app version displayed?"
ai rg "where is changelog referenced?"
```

Useful before tagging or merging small maintenance branches. If `VERSION` is not a path on disk, only paths that resolve are attached as file targets; adjust file names to match your repo.

## Good patterns

- Use `ai rg` when you want answers tied to real ripgrep hits.
- Use folder targets when you already know the subsystem.
- Use file targets when you want full-file review or a diff-style question.
- Use `r1` for why, debug, and root-cause style questions (when that alias is configured).
- Use `q30` for broad architecture questions (when that alias is configured).
- Use `coder` for scripts, commands, regex, Docker, and git snippets.

## Bad patterns

- Do not treat "no ripgrep hits" as proof something is absent from the repo.
- Do not rely on repo-wide search when you only mean one folder or file; pass that target.
- Do not trust citations without opening the cited paths and lines yourself.
- Do not ask vague whole-repo questions when a folder or file scope would sharpen the answer.
