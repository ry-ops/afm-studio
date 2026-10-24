# AFM Studio

**Apple's on-device foundation model, everywhere you work on a Mac.** A native SwiftUI app, a command-line tool (`afm`), an MCP server for Claude, and a local OpenAI-compatible API. All of it is one Swift package with no third-party dependencies.

![Recipes](docs/images/recipes.png)

The model is the roughly 3-billion-parameter model behind Apple Intelligence. It runs on the Mac itself. It's free and works offline, and nothing you send it leaves the machine.

## What's inside

| Surface | What it gives you |
| --- | --- |
| **AFM Studio app** | Chat with tools, 21 recipes, a structured-output builder, batch runs over folders, side-by-side comparisons, a token inspector, benchmarks, history, adapters, and a menu-bar quick-ask panel. |
| **`afm` CLI** | Pipe-friendly prompts, recipes, JSON extraction, resumable chats, token counts and benchmarks. |
| **MCP server** (`afm mcp`) | 15 tools that let Claude hand text work to the on-device model. Files are processed locally with `path`, so their contents never enter Claude's context. |
| **OpenAI-compatible API** (`afm serve`) | `/v1/chat/completions` on `127.0.0.1`, with streaming and `response_format: json_schema`. |
| **Claude section** | Your Anthropic API key in the macOS Keychain, on-device vs. Claude comparisons with cost, and automatic MCP registration in Claude Code and Claude Desktop. |

## Requirements

- A Mac with Apple silicon, running macOS 26.4 or later
- Apple Intelligence turned on in System Settings
- The Xcode Command Line Tools with the macOS 26 SDK. The full Xcode app is optional.

Run `afm status` to check whether the model is ready.

## Install

```bash
git clone https://github.com/ry-ops/afm-studio.git
cd afm-studio

bash scripts/build-app.sh            # builds "build/AFM Studio.app" with the afm CLI inside
bash scripts/build-app.sh --install  # same, then copies it to ~/Applications
bash scripts/install.sh              # CLI only: links afm into ~/.local/bin
```

The app is ad-hoc signed for local use. On first launch it links `~/.local/bin/afm` to its bundled CLI and registers the MCP server with Claude. You can turn that off in the Claude section.

## The app

![Structured output](docs/images/structured.png)

- **Chat:** streaming replies with tool calls shown inline: date and time, an exact calculator, and system info. Opt-in tools can read files in your home folder or fetch a web page. Chats are saved, and they appear in the sidebar whether you started them in the app, in Terminal or from Claude. When the 4,096-token context fills up, older turns are summarized automatically.
- **Recipes:** summarize, key points, ask-the-document, rewrite, proofread, translate, sentiment, classify, entities, action items, meeting notes, tags, quiz, commit messages and more. Inputs longer than the context are split on paragraph and sentence boundaries, run piece by piece, and combined. You can write your own recipes in the app or as JSON files.
- **Structured output:** build a schema with fields or paste JSON Schema, then watch valid JSON stream in. Apple's constrained decoding guarantees the result matches the schema. One click exports the schema as Swift `@Generable` code.
- **Batch:** drop files or folders, pick a recipe, then export the results as JSON Lines, CSV or Markdown.
- **Compare:** run one prompt with several sampling settings at once.
- **Tokens:** exact counts from the on-device tokenizer, measured against the context window.
- **Benchmark:** time to first token and tokens per second on your Mac, charted.
- **History:** every run from every surface, stored only on this Mac.
- **Model:** availability, supported languages, and custom `.fmadapter` adapters.
- **Menu bar:** ask a question, or summarize, proofread, rewrite or translate whatever is on the clipboard.

## The CLI

```bash
afm "Explain DNS like I'm new to networking"
git diff | afm run commit-message
afm run summarize -f report.md -p style="an executive summary"
pbpaste | afm run translate -p language=Japanese
afm extract --fields "vendor:string, total:number, items:[string]" < receipt.txt
afm --tool safe "What's 17.5% of 2,340, and what day is it?"
afm chat --session ideas          # resumable; /help inside for commands
afm tokens -f big-file.txt
afm bench
afm recipes                       # lists recipes and their -p parameters
```

Streaming is on by default in a terminal. Add `--json` for machine-readable output and `--stats` for timing and token counts. `afm --help` lists everything.

## Claude integration

![Claude section](docs/images/claude.png)

### MCP server

AFM Studio registers `afm` with Claude Code at user scope and with Claude Desktop. It re-checks the registration every time it opens. Before changing the Claude Desktop config it writes a backup next to the file, and it leaves your other settings alone. To manage the registration yourself:

```bash
afm claude hook      # register in Claude Code and Claude Desktop
afm claude status    # key, model and registration status
afm claude unhook    # remove both registrations
```

| Tool | What it does |
| --- | --- |
| `afm_summarize`, `afm_ask_document` | Summarize text or a file, or answer a question from it. Long inputs are chunked. |
| `afm_extract`, `afm_structured` | JSON that matches `fields` shorthand or a JSON Schema. |
| `afm_classify`, `afm_tag` | Pick a label from your list, or tag topics with Apple's content-tagging model. |
| `afm_rewrite`, `afm_proofread`, `afm_translate` | Text transformations. |
| `afm_generate`, `afm_chat` | Free-form prompts and saved multi-turn chats. |
| `afm_recipes`, `afm_run_recipe` | Run any recipe, including your own. |
| `afm_count_tokens`, `afm_status` | Tokenizer and model status. |

Most tools accept `path` instead of `text`. With `path`, Claude can have a 50-page file summarized without reading it into its own context. File access is limited to your home folder. Set `AFM_ALLOWED_PATHS` (colon-separated) to allow other folders.

### Your Anthropic API key

The key is stored in the macOS login Keychain as a "this device only" item. It is never written to the repo, the settings file or any other file. You can add it in the app's Claude section, or from Terminal:

```bash
afm claude key set           # paste the key when prompted (input is hidden), or pipe it in
afm claude key status        # shows where the key comes from, masked
afm claude "Review this plan" --model claude-opus-5-5 --effort high
afm claude compare "Explain mutexes vs semaphores"   # on-device vs Claude, with cost
```

`ANTHROPIC_API_KEY` works as a fallback. Claude Opus 5.5 is the default model. Requests opt into server-side refusal fallbacks on the models that support them.

## OpenAI-compatible API

```bash
afm serve --port 11535            # or toggle it in the app's Integrations pane
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:11535/v1", api_key="unused")
r = client.chat.completions.create(model="apple-foundation-model",
                                   messages=[{"role": "user", "content": "Hello!"}])
```

The server offers three models. `apple-foundation-model` uses the default guardrails. `apple-foundation-model-permissive` uses looser guardrails for transforming your own text. `apple-foundation-model-tagging` uses Apple's content-tagging model.

It supports `stream`, `temperature`, `top_p`, `seed`, `max_tokens`, and `response_format` with `json_schema` or `json_object`. It also serves `GET /afm/recipes` and `POST /afm/recipes/{id}`. The server only listens on `127.0.0.1` and sends no CORS headers. `--token` adds bearer-token auth.

## Know the model

- **Good at:** summaries, extraction, classification, tagging, rewriting, short drafts, and translation in 15 languages (23 locales).
- **Not good at:** world knowledge, multi-step math, long reasoning and writing code. Treat its output as a draft. The calculator tool exists because the model alone gets arithmetic wrong.
- **Context:** 4,096 tokens for instructions, prompt and reply combined. AFM Studio works around this with chunking and chat compaction.
- **Guardrails:** Apple's safety filter sometimes blocks harmless prompts. The permissive mode, `--permissive`, helps when you're transforming text you supplied.

## Project layout

```
Sources/AFMKit       engine: generation, schemas, tools, recipes, chunking, chats, Claude client, Keychain, hooks
Sources/AFMServer    MCP stdio server and OpenAI-compatible HTTP server
Sources/afm          the CLI
Sources/AFMStudio    the SwiftUI app
Tests/SelfTest       self-test (swift run afm-selftest)
scripts/             app bundle, icon and install scripts
```

```bash
swift build
swift run afm-selftest            # unit checks, plus a live model check when Apple Intelligence is available
swift run afm-selftest --offline  # skip the live check
```

The self-test is a plain executable because Swift Testing doesn't run under the Command Line Tools alone. It needs no Xcode.

Data such as chats, recipes, history and settings lives in `~/Library/Application Support/AFMStudio`. Set `AFM_HOME` to use a different folder.
