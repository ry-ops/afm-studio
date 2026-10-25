# Roadmap

What's planned for AFM Studio, in rough order. Each item says what it does, how it should work, and what has to be true before it ships.

## 1. Self-update from GitHub

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

- **Keychain prompts.** The app is ad-hoc signed, so every rebuild looks like a new program to the Keychain. You'll be asked again for the Anthropic API key and the GitHub token after each update. A stable local signing identity would fix that, and is worth doing alongside this item.
- **Swift toolchain changes.** A macOS or Command Line Tools update can break the build. The update tool should say when the failure looks like a toolchain problem rather than a code problem.
- **Releases versus commits.** Following `main` gets every commit. Tagged releases with a real version number would make updates calmer. Start with commits and add a "releases only" setting later.

## 2. macOS 27 and AFM 3

These need the macOS 27 SDK, and each one sits behind `#available(macOS 27, *)` so the app keeps working on macOS 26.

- **Image input.** Attach images in chat, recipes and batch runs, and accept image content in the OpenAI-compatible API and MCP tools.
- **Private Cloud Compute model.** Offer Apple's server model alongside the on-device one, with a clear label wherever a request leaves the Mac.
- **Dynamic Profiles.** Switch model, tools and instructions within one chat, for example handing a hard step to the server model.
- **Evaluations.** Run a recipe against saved test cases and report regressions, and add an `afm eval` command.
- **Adapters for AFM 3.** Document retraining with the new adapter toolkit, and list compatible adapters with `compatibleAdapterIdentifiers`.
