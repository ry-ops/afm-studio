# Roadmap

What's planned for AFM Studio, in rough order. Each item says what it does, how it should work, and what has to be true before it ships.

## Fixes

Known problems to fix, ahead of the features below. Each one says what's wrong, why it happens and how to fix it.

### Help menu shows "Help isn't available for AFM Studio"

**What's wrong.** Choosing **Help › AFM Studio Help** shows an alert that says "Help isn't available for AFM Studio." The menu offers help the app doesn't have.

**Why.** The app doesn't define a Help menu, so macOS adds its standard **AFM Studio Help** item. That item opens the app's Apple Help Book. The app ships no Help Book, and `Info.plist` has no `CFBundleHelpBookName` or `CFBundleHelpBookFolder`, so macOS shows the alert.

**Fix.** Replace the standard item with `CommandGroup(replacing: .help)` in `Sources/AFMStudio/App.swift`. Don't build a Help Book, since those are hard to maintain and nothing else in the app needs one. The new Help menu should have:

- **AFM Studio Help**, which opens the README on GitHub, at the release tag the app was built from.
- **Command-Line Reference**, which opens the CLI section of the README. It could show `afm help` in the terminal pane instead.
- **Release Notes**, which opens the GitHub release for the installed version.
- **Report an Issue…**, which opens a new GitHub issue with the app version and macOS version filled in.

Opening a link goes through the browser, so nothing leaves the Mac until the person clicks.

**Done when.** No Help menu item shows the alert. Every item opens the right page. The links are tested in `afm-selftest`, since they're built from the version and the repo URL.

### GitHub search fails with "Validation Failed" for questions about your orgs

**Status.** Fixed in 0.2.3.

**What was wrong.** Asking "what open PRs do I have across my repos and my orgs?" failed with "Tool github_search failed: GitHub: Validation Failed," or answered "none" from the wrong tool.

**Why.** The on-device model wrote GitHub search syntax itself. GitHub has no qualifier for "all my orgs", and the model can't know the org names, so it guessed one, such as `repo:org/username`, and GitHub rejected the query. The error also dropped GitHub's explanation. And no chat tool covered PRs that other people or bots opened in your repos.

**What changed.**

- **A `github_open_prs` chat tool** takes a scope of `mine`, `orgs` or `all`. It looks up your orgs, builds the query and pages through the results itself. The model gets totals, a split between your repos and your orgs' repos, counts per owner and repo, and the latest few PRs.
- **Free-form `github_search` left the on-device chat.** It stays a tool for Claude over MCP.
- **Search errors keep GitHub's details**, such as which org couldn't be searched. Empty queries are refused, and `author:me` becomes `author:@me`.
- **`github_read` reads at most two items per answer.** In testing, the model read seven PRs in a row and overflowed its 4K context.

**Tested.** `afm-selftest` covers the query builder, scopes, the summary, the `me` rewrite, error parsing and the per-answer cap. Live runs on the on-device model against real GitHub data:

| Question | 0.2.2 | Fixed |
| --- | --- | --- |
| Open PRs in my repos and my orgs | 1 of 3 answered, wrongly "none". 2 of 3 failed with "Validation Failed" | 7 of 7 picked the right tool and scope |
| Open PRs in my repos | | 5 of 5 answered 49 |
| Open PRs in my orgs' repos | | 5 of 5 answered 143 |
| PRs I opened, reviews waiting on me | | Right tool every time. 1 run overflowed context before the cap, 1 later run read PRs it didn't need |

**Known limits.** The model still slips sometimes. One run said 199 when the tool said 192. Another added up the org count wrongly, which is why the summary now gives the split ready-made. One listed Dependabot's PRs as yours after the tool said you had none. The numbers it's given are right, so the answers are worth checking against the tool call. Old answers also anchor it. In a chat that began before this fix, its earlier "no open PRs" answer stayed in the history, and the model repeated it in 3 of 3 replays even though the new tool returned 193. In fresh chats, with the same instructions and tools, it reported the right totals in 9 of 9. Start a new chat after a fix like this.

### New chats don't get integration tools

**Status.** Fixed in 0.2.3.

**What was wrong.** With GitHub's **Tools in chat** switch on, a new chat still answered "I don't have access to your repositories." Its GitHub toggle in the side panel started off, so the model never got the GitHub tools.

**Fix.** New chats, in the app and in `afm chat`, start with every integration whose chat tools are on. The per-chat toggle still turns one off.

### Long messages fail with "Provided 24,025 tokens, but the maximum allowed is 4,096"

**Status.** Fixed in 0.2.3.

**What was wrong.** Pasting a long transcript into chat failed, and the message vanished back into the input box. Two causes:

- **Every chat sent its first message twice.** Starting a session rebuilt the history from saved messages, including the one being sent, then sent it again as the prompt. In a new chat, a 2,175-token message came to 4,777 tokens and failed.
- **The chat had no way to read a message bigger than the context.** Recipes split long documents, but chat sent everything as one prompt.

**Fix.**

- **The pending message is left out of the rebuilt history**, so it's sent once.
- **A message that doesn't fit is read in parts.** The model first states the request in one sentence from the start and end of the message. Then it takes notes of up to 120 words on each part, combines them only if they still don't fit, and answers from the notes. The chat shows progress. The message keeps the original text for display and saves the notes, so follow-up questions rebuild from the notes.
- **The answer is capped at the room left in the context**, so a long answer stops cleanly instead of failing partway through.

**Tested.** Live runs on the on-device model, with transcripts built from this README and roadmap:

| Input | Before | After |
| --- | --- | --- |
| 2,175-token message, new chat | Failed: 4,777 tokens | Answered |
| 10,451-token transcript | Failed | 5 parts, highlights across the whole text, about 1.5 minutes |
| 20,893-token transcript | Failed | 9 parts, highlights across the whole text, about 3 minutes |
| Follow-up in that chat | | Answered from the saved notes: "macOS 27.1 or later, no Xcode app" |

**Progress you can see.** The first version reported progress only in a small caption that hid itself after 5 seconds, so a 3-minute read looked stuck. Now a card in the conversation shows the size, the number of parts, a progress bar, the elapsed time and a countdown, with a Stop button that returns the message to the input box. The estimate starts at 13 seconds per part plus 30 for the answer, then uses the measured speed. A line after the answer records the parts and the time, such as "Read this 11,276-token message in 5 parts in 1 min 34 s." In a live run, the estimate went from about 2 minutes to under a minute as parts finished, and the whole read took 1 minute 34 seconds. The caption timer also restarts for each new notice, so later notices aren't hidden.

**Known limits.** The model often makes one pointless calculator call before answering, because the notes contain numbers. Quoting the end of the message directly made it summarize only the end, which is why the request is worked out first.

## 1. Self-update from GitHub

**Status.** The first part shipped after 0.1.0. AFM Studio checks GitHub's latest release, when you turn that on or ask, and shows an **Update available** button with the release notes and the steps to update. `afm update check` does the same from Terminal. The build records `AFMSourcePath`, `AFMSourceBranch` and `AFMCommit` in `Info.plist`. `scripts/make-signing-identity.sh` gives builds a stable signature, which settles the Keychain question below. Still to do: one-click **Update and Restart**, `afm update` installing by itself, and `afm update rollback`.

AFM Studio is built from source, so updating it now means pulling the repo and running `scripts/build-app.sh --install` by hand. The update tool does that for you. It checks GitHub for new commits, pulls them, rebuilds, installs, and restarts the app if it was running.

### What you'll see

- **App:** an **Updates** card in Settings, and **AFM Studio > Check for Updates…** in the menu bar. It shows the commits you'd get, then offers **Update and Restart**.
- **CLI:** three commands.

```bash
afm update check     # compare this install with GitHub, list new commits
afm update           # pull, rebuild, test, install, restart the app if it's open
afm update rollback  # put the previous build back
```

### How it works

1. **Know the source.** At build time, `build-app.sh` writes the checkout path, the branch and the commit into the app's `Info.plist` under the keys `AFMSourcePath`, `AFMSourceBranch` and `AFMCommit`. Today the installed app has no way to find its source, and the version string never changes, so the commit is the real version.
2. **Check.** Run `git fetch origin` in the checkout and compare `HEAD` with `origin/<branch>`. If the checkout is missing or isn't a git repo, fall back to the GitHub API (`GET /repos/ry-ops/afm-studio/commits/main`) and offer to clone it again.
3. **Pull safely.** Only fast-forward. Stop and explain if the working tree has uncommitted changes, the branch has diverged, or you're on a branch other than the one the app was built from. Never stash, reset or force anything.
4. **Build and test before installing.** Build into `build/`, then run `afm-selftest --offline`. A failed build or test leaves the installed app untouched and shows the log.
5. **Install and restart.** The app can't replace itself while it runs, so a small detached helper does it. The helper waits for the app to quit, installs the new copy the way `--install` does, relinks `afm`, and reopens the app with `open -a "AFM Studio"`. Before quitting, the app saves open chats. It also warns when terminal tabs are running something, because restarting ends those shells.
6. **Keep a way back.** The previous app is kept as `build/AFM Studio.previous.app`, and `afm update rollback` reinstalls it.

### Rules it follows

- **Off until you turn it on.** Like every other network feature, update checks start off. When on, the app checks at most once a day, and only `git fetch` or one GitHub API call goes out. Nothing about you or your use is sent.
- **Asks before changing anything.** A check can run in the background. Pulling, installing and restarting always need a click or `afm update`.
- **The CLI works without the app.** `afm update` does the same steps from Terminal. It restarts the app only if the app is already open.

### Open questions

- **Keychain prompts.** Settled: builds signed with the local identity from `scripts/make-signing-identity.sh` keep the same identity, so Keychain approvals survive updates. Ad-hoc builds still ask again.
- **Swift toolchain changes.** A macOS or Command Line Tools update can break the build. The update tool should say when the failure looks like a toolchain problem rather than a code problem.
- **Releases versus commits.** Settled for now: updates follow tagged releases. A setting to follow every commit on `main` could come later for people who build from source.

## 2. macOS 27 and AFM 3

AFM Studio now requires macOS 27, so these can use the macOS 27 SDK directly.

- **Image input.** Attach images in chat, recipes and batch runs, and accept image content in the OpenAI-compatible API and MCP tools.
- **Private Cloud Compute model.** Offer Apple's server model alongside the on-device one, with a clear label wherever a request leaves the Mac.
- **Dynamic Profiles.** Switch model, tools and instructions within one chat, for example handing a hard step to the server model.
- **Evaluations.** Run a recipe against saved test cases and report regressions, and add an `afm eval` command.
- **Adapters for AFM 3.** The macOS 27 SDK removed the adapter API, so AFM Studio removed adapter support. Bring it back if Apple ships a replacement.
