# Vision: a Mac that only has what you need

AFM Studio already brings Apple's on-device model to the app, the terminal and Claude. This document describes where it's headed next: helping keep a Mac clean, so that everything installed on it is there for a reason you can name.

It isn't a cleaner. Cache and junk cleaners already do that job well. AFM Studio's part is knowing **what you have, why you have it and what still needs it**, so that cleaning up never breaks something.

## The problem

A developer's Mac collects tools. Each project, tutorial and experiment installs something: a Python package into the system Python, a second Node version, an AI tool's settings folder, a toolchain for a board you no longer use. Months later nobody remembers which of them still matter.

The two usual answers both fail:

- **Leave everything.** The Mac fills up with tens of gigabytes nobody needs, and old copies shadow the right ones on `PATH`, so the wrong `pip` or `pio` runs.
- **Delete what looks unused.** Something that looked dead turns out to be a hidden dependency: a project's image script imports a package that lives only in the system Python, or a tool's hooks call one Node version by its full path. Deleting it breaks work that runs fine today.

Size and age don't tell you what's safe. Only knowing what depends on what does.

## The idea

Everything installed on the Mac should exist because something needs it: a project, a tool you use every day, or macOS itself. Anything that can't point to one of those is **surplus**. Anything a project needs but doesn't have, or has in the wrong version, is **drift**.

## Three layers

| Layer | What belongs there | Examples |
| --- | --- | --- |
| **1. Comes with macOS** | Never managed or added to by you | git and jq from Apple, zsh, `/usr/bin/python3` |
| **2. Mac-wide tools** | A short, deliberate list, each with one install method | Homebrew and the tools you installed with it, a Node version manager, uv, Claude Code, your apps |
| **3. Inside each project** | Everything else, declared in the repo | dev dependencies in `package.json`, Rust crates, a script's Python packages |

**Rule:** nothing installs into layer 1. A tool moves into layer 2 only when two or more projects, or you personally, need it. Everything else stays in layer 3.

## Each project says what it needs

Each repo states what it needs from layers 1 and 2, mostly in files it already has:

- `package.json` `engines.node`, `.nvmrc` or `.node-version`
- `rust-toolchain.toml`
- `pyproject.toml`, or [PEP 723](https://peps.python.org/pep-0723/) inline metadata at the top of a single script, run with `uv run`
- A short `NEEDS.md`, or a section in the repo's `CLAUDE.md`, for anything else: a Mac-wide CLI, Keychain entries, a browser, an MCP server

You keep the same kind of list for yourself: the apps and tools you use outside any project, and the reason for each.

## Three lists, compared

1. **Installed:** what a scan of the Mac finds, with sizes, last-used dates and the links between items.
2. **Needed:** everything every project and you have declared, combined.
3. **The difference:**
   - **Surplus:** nothing needs it. Examples: an old AI tool's virtual environment, machine-learning libraries in the system Python, a headless browser downloaded once, a background agent whose app was deleted.
   - **Missing or drifted:** declared but not met. Example: a project asks for Node 24.22 or later, and the Mac has 24.11.
   - **Hidden dependency:** works today, but nothing declares it. Examples: a project script that imports Pillow from the system Python, or a tool's hooks hardcoded to one Node version. These are fixed first, by declaring them or moving them into the project, before anything is removed.

## How the links are found

The links between items are facts code can check, not guesses for a model to make. For example:

- A virtual environment's `pyvenv.cfg` names its base Python, so the environment depends on that install.
- A background agent points at an app bundle that isn't there anymore, so it's left over.
- A folder earlier on `PATH` holds its own copy of a command, so it shadows the copy you meant to run.
- A tool's settings file contains a full path to a runtime, so that runtime is in use.
- A project's manifest asks for a version range, and the installed version falls outside it.

The on-device model doesn't do this work. It writes the explanation once the facts are known ("Pillow is here because this project's cutout script imports it"). In testing it reads well-organized facts accurately, and leaves out details when asked to shorten them, so the facts always stay visible beside its wording.

## Who does what

- **AFM Studio inventory (planned, read-only).** A local module, off until you turn it on like the other integrations. It scans what's installed, reads each repo's declarations, checks the links above in Swift, and shows the three lists in an Inventory pane. Its MCP tools give Claude the same view without running dozens of shell commands (`afm_inventory`, `afm_inventory_why`, `afm_inventory_orphans`). It never deletes anything.
- **A Claude Code skill.** Helps a repo write down what it needs, and carries out the cleanups you approve, showing each command before it runs it.
- **Your existing cleaner.** Caches and system junk, as now.

## Done looks like

- Every item in layers 2 and 3 has a reason you can point to.
- A new project's needs can be set up from what its repo declares.
- A scan reports no surplus and no hidden dependencies.
- Deleting a project's folder removes everything it brought with it.
