# pi.nvim

A Neovim plugin for interacting with [pi](https://pi.dev) - the minimal cli agent.

<p align="center">
<a href="https://asciinema.org/a/RuG4c2kkhrLx1ChZ">
  <img src="https://github.com/pablopunk/pi.nvim/blob/main/assets/asciinema.gif?raw=true&forceUpdate" width="100%" />
</a>
</p>

It's funny that all AI plugins for Neovim are quite complex to interact with, like they want to imitate all current IDE features, while those are trending towards the simplicity of the CLI (which is the reason most users choose neovim in the first place). [pi.dev](https://pi.dev/) is the best example of this philosophy, and the perfect candidate to integrate in neovim.

## Features

- **Context aware**: Sends your current buffer, cwd, selection, and optional diagnostics as context.
- **Unsaved-buffer aware**: Tells pi to treat the sent Neovim buffer content as the source of truth, even if the on-disk file is stale.
- **Simple configuration**: Set your preferred AI model and thinking level.
- **Persistent RPC sessions**: Pi sessions are stored in Pi's JSONL format and can be resumed from Neovim or the CLI.
- **Live transcript**: A dedicated split renders thinking, assistant text, tool calls/output, retries, compaction, and usage state.
- **CLI-compatible controls**: Abort, steer, follow up, compact, fork, clone, tree, stats, and HTML export are exposed as Neovim commands.

## Requirements

- [Neovim](https://neovim.io/) 0.10+
- [pi](https://github.com/badlogic/pi-mono) installed globally: `curl -fsSL https://pi.dev/install.sh | sh`
- Your preferred models availble in pi: `pi --list-models`

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{ "ronakpjain/pi.nvim" }
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use "ronakpjain/pi.nvim"
```

### Using [mini.deps](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-deps.md)

```lua
MiniDeps.add("ronakpjain/pi.nvim")
```

## Config

All config is optional:

```lua
require("pi").setup()
```

Override only the ones you need:

```lua
require("pi").setup({
  binary = "~/.bin/pi", -- or { "env", "FOO=1", "pi-wrapper" }
  provider = "openrouter",
  model = "openrouter/free",
  thinking = "off", -- off, minimal, low, medium, high, xhigh, or max
  system_prompt = "You are a helpful assistant.",
  append_system_prompt = "Always respond concisely.",
  context = {
    max_bytes = 24000,
    ask = {
      surrounding_lines = 80,
    },
    selection = {
      surrounding_lines = 40,
    },
    diagnostics = {
      enabled = false,
    },
  },
  skills = true,
  extensions = true,
})
```

| Prop | Default | Description |
|------|---------|-------------|
| `binary` | `"pi"` | The binary to run when invoking pi. Can be a string or an array of strings. When omitted it is set to `"pi"`. Useful for custom pi installations or wrappers. |
| `provider` | `nil` | pi provider to use. If omitted, pi uses its own default configuration. |
| `model` | `nil` | Model name to use. If omitted, pi uses its own default configuration. |
| `thinking` | `"off"` | Sets pi's thinking level (`--thinking`). Supported values: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`. |
| `system_prompt` | `nil` | Passes a custom system prompt to pi (`--system-prompt`). Use with care, since this overrides pi's generated baseline instructions. |
| `append_system_prompt` | `nil` | Appends text to the system prompt (`--append-system-prompt`). pi.nvim adds buffer freshness guidance and describes the live Neovim interaction. |
| `context.max_bytes` | `24000` | Maximum size in bytes for sent context before trimming. |
| `context.ask.surrounding_lines` | `80` | Number of lines before and after the current cursor line to include for `:PiAsk`. |
| `context.selection.surrounding_lines` | `40` | Number of lines before and after the current visual selection to include for `:PiAskSelection`. |
| `context.diagnostics.enabled` | `false` | Includes Neovim diagnostics in the sent context. `:PiAsk` sends all buffer diagnostics; `:PiAskSelection` sends only diagnostics overlapping the selected lines. |
| `skills` | `true` | Whether pi discovers and loads skills. Set to `false` to pass `--no-skills`. |
| `extensions` | `true` | Whether pi discovers and loads extensions. Set to `false` to pass `--no-extensions`. |

Use `pi --list-models` to see available models.

**Examples:**

This is basically the same as doing `pi --provider <provider> --model <model>`, so you can test it out on the cli to make sure it works.
```lua
-- OpenRouter kimi-k2.5
{ provider = "openrouter", model = "moonshotai/kimi-k2.5" }

-- OpenAI overriding the default thinking level
{ provider = "openai", model = "gpt-5-mini", thinking = "high" }

-- OpenRouter haiku-4.5
{ provider = "openrouter", model = "anthropic/claude-haiku-4.5" }

-- Anthropic haiku-4-5
{ provider = "anthropic", model = "claude-haiku-4-5" }

-- OpenAI
{ provider = "openai", model = "gpt-4.1-mini" }
```

Run `pi --list-models` to see available options.

### Keymaps

No keymaps by default. You choose.

```lua
-- Ask pi with the current buffer as context
vim.keymap.set("n", "<leader>ai", ":PiAsk<CR>", { desc = "Ask pi" })

-- Ask pi with visual selection as context
vim.keymap.set("v", "<leader>ai", ":PiAskSelection<CR>", { desc = "Ask pi (selection)" })
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Pi` | Open and focus the persistent transcript split |
| `:PiAsk` | Prompt with current-buffer context in a **new persistent session** |
| `:PiAskSelection` | Prompt with visual-selection context in a new session |
| `:PiAskSession` | Prompt in the current/resumed session |
| `:PiCancel` | Request abort of the active turn; the session remains locked until settled |
| `:PiSteer` / `:PiFollowUp` | Queue an instruction while Pi is working / send the next prompt after it settles |
| `:PiCompact` | Compact the current session, optionally with instructions |
| `:PiSessionNew` | Create a fresh session without prompting |
| `:PiSessionResume` / `:PiSessionResumeAll` | Pick a JSONL session for the current project / all projects |
| `:PiSessionSwitch {path}` | Switch to an explicit JSONL session path |
| `:PiSessionClone` / `:PiSessionFork` | Clone the current branch / fork from a selected user message |
| `:PiSessionTree` | Render the active session tree in the transcript |
| `:PiSessionName` / `:PiSessionPath` | Set a name / copy the JSONL path |
| `:PiSessionStats` | Show tokens, context usage, and cost |
| `:PiSessionExport` | Export the active session as HTML |
| `:PiSessionStop` | Stop the persistent RPC process |
| `:PiLog` | Open the pi.nvim session log |

## Behavior

- Runs asynchronously through Pi's JSONL RPC mode and keeps editing nonblocking.
- Keeps one persistent RPC process per Neovim instance; concurrent turns on that process are rejected.
- Uses Pi's own session files, so sessions created by the CLI can be resumed in Neovim and vice versa. Do not run two writers against the same session simultaneously.
- Renders live activity in a dedicated transcript split. The split follows its originating buffer/window and closes when that buffer is deleted/wiped or its window is closed. Fidget (when configured) can display brief notifications, while detailed output stays in the transcript.
- Reloads changed loaded buffers on successful settlement so Pi's on-disk edits are reflected in Neovim.
- Treats sent buffer/selection context as newer than disk, so unsaved Neovim changes are the source of truth for the agent.
- Optionally includes Neovim diagnostics from LSPs/linters via `vim.diagnostic`.
- Trims oversized context for speed instead of always sending the full file.


## API

`pi.nvim` exposes `get_cmd()`, `get_rpc_cmd()`, `run()`, `resume_session()`, and session/model control methods for programmatic use. `run()` starts a new persistent session by default; pass `new_session = false` to continue the current session. See [this gist](https://gist.github.com/nhlmg93/49c1e5ec1e1df20b5050c770840cd7b2) for a minimal programmatic command.

## License

MIT

## Related

If you like this plugin you might like my agent coordinator app: [Fractal](https://github.com/pablopunk/fractal). It can run pi, claude, codex, opencode... actually, any cli you want; you can even automate neovim as if it was an agent!
