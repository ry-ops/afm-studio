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

### MCP tool answers arrive damaged or incomplete

**Status.** Fixed in 0.2.4.

**What was wrong.** Running every MCP tool from Claude Code turned up these problems:

- `afm_github_summarize` and `afm_github_repo_brief` returned only `{"seconds": …, "chunks": …}`. Claude never saw the summary or the brief.
- Proofread and translate wrapped their answers in `"""`.
- The outline recipe and `afm_github_pr_description` wrapped their Markdown in a code fence. For a PR, the fence was in the pre-filled link too, so the PR would open as one code block.
- `afm_tag` with `max_tags: 8` on a long file returned 12 tags.
- Release notes printed their Features and Fixes sections twice.
- On a long file, ask-the-document answered only one part of a two-part question.
- Triage called a feature PR a bug and invented user frustration. Next steps named files that don't exist.
- Summaries of the roadmap described planned features, such as image input, as shipped.

**Why.**

- The two GitHub tools sent their timing data as `structuredContent`. Clients that read structured content show it in place of the text block, and the text wasn't in it.
- Recipes put their input between `"""` delimiters. The model copies them when its answer is a transformed copy of the input, and nothing removed them.
- Nothing removed a Markdown fence around a prose answer. `JSONRender.unfenced` exists, but only the OpenAI-compatible server used it.
- Each chunk of a long input obeys the schema's `maxItems`, but merging the chunks joined their arrays without applying the limit again.
- Asked for two sentences of highlights, the model sometimes copied the notes, and the copy went in above the real notes.
- The last pass over a long input was told to treat the parts as one document, so it kept one part's answer and dropped the rest.
- The triage, next-steps and summarize prompts didn't rule out those mistakes.

**What changed.**

- The two GitHub tools put their text in the structured reply (`GitHubIntegration.meta`).
- `TextCleanup.tidy` removes `"""` delimiters and a `markdown` or `md` fence around a whole prose answer. A code fence, or one inside a longer answer, is kept. The recipe runner applies it to every prose recipe, which covers the PR drafts.
- `JSONMerge.merge(_:schema:)` cuts each merged array to its schema's `maxItems`, including arrays inside array items. This also covers keywords, quiz and next steps.
- Highlights that hold headings or bullets, or run past 600 characters, are dropped (`GitHubWorkflows.isProseHighlight`).
- The last pass over a long input is told it has one result per section, and to keep every detail that answers the request.
- Triage is told that a `feat:` or `fix:` title states the type and never to describe feelings the text doesn't state. Next steps names a path only if it appears in the material. Summarize keeps planned work planned.
- The PR prompt asks for only "Not stated" when testing isn't described. Before, it could add that line after other bullets.

**Tested.** `afm-selftest` covers the cleanup, the merge limit, nested limits and the highlight check. A script drove `afm mcp` from a build over stdio with each case above. The installed 0.2.3 build failed 9 of the 11 cases. The new build passed all 11. The remaining cases depend on the model, which doesn't always repeat the mistake. The summary fix is the weakest: one run in three still mentioned image input, but described it as a goal rather than a shipped feature.

### Recipes ignore parts of their instructions

**Status.** Fixed in 0.2.4, except where noted.

**What was wrong.** A pass over all 21 built-in recipes ran 63 cases, covering every tone, language, intent, style and count choice. The installed 0.2.3 build passed 30 of them. Besides the `"""` wrappers and fences above:

- A "short" summary of the README ran 553 words. Medium and detailed came out the same length.
- Rewrite in the professional tone, and every email reply, added a "Subject:" line the input didn't have.
- Headlines came back in quotation marks.
- Commit messages used a file name as the scope (`refactor(Chunker.swift)`) and called new behavior a refactor.
- Proofread left "Me and him have been planning".
- Regex fenced its pattern, though it promises the pattern on the first line. It left the ZIP code pattern unanchored and wrote an ISO date pattern that rejects `2026-01-05`.

**What changed.**

- Summarize spells out each length: short is at most 5 bullets or 3 sentences, medium at most 10 or 6, detailed as long as the text needs.
- Rewrite adds nothing the text doesn't have. Email reply outputs no subject line. `TextCleanup.tidy` also drops a leading "Subject:" line the input doesn't have, since the professional tone kept adding one.
- Headlines are asked for without quotation marks.
- Commit messages use feat for new behavior and fix for broken behavior, and the scope names a module. Placing that rule last in the instructions kept the bullet body. Placed in the middle, the body was dropped in two runs out of three.
- Proofread names pronoun case, subject-verb agreement and run-on sentences.
- Regex is told to anchor its patterns and to give the bare pattern on the first line.

**Tested.** The new build passes 58 of the 63 cases. What's still open:

- **Long summaries** come out shorter, at 271 to 350 words instead of 553, and take about half as long. The length limits now hold too, as described under "Summaries and drafts break their own rules" below.
- **Proofread** missed "Me and him" until the instructions gave that exact case as an example. It now returns "He and I have been".
- **Regex** still fences its pattern, and gets one or two of three test patterns wrong. It needs a decision: verify patterns on the Mac, or remove the recipe.

### New recipes: redact, explain an error, draft from notes

**Status.** Added in 0.2.4.

- **Redact** replaces personal details with numbered placeholders, such as `[Person 1]` and `[Email 1]`. The model only lists the names and whole addresses, as JSON. `Redactor` makes the replacements and finds emails, phone numbers, US Social Security numbers and card numbers with patterns. Card numbers must pass their checksum. Nothing else in the text can change, and a name the model invents that isn't in the text is ignored. A last name on its own gets the full name's placeholder. The recipe has a schema, but `transform: .redact` makes it answer in text, so `isStructured` is false. With `path`, Claude can read a redacted copy of a file through `afm_run_recipe`.
- **Explain an error** reads an error message, stack trace or log. It says what failed, quoting the line, then gives the likely cause and one to three next steps. A log longer than the context keeps its end (the new `tail` strategy), with a note that earlier lines were left out. The terminal's Explain button already trims this way.
- **Draft from notes** turns bullet notes into a paragraph, email, short report, chat message or bullet points. It is told to add nothing the notes don't contain.

**Also.** The framework sometimes fails with an unnamed internal error (`LanguageModelError error -1`) during long runs of back-to-back requests. It arrives as a plain `NSError`, so it showed as "The operation couldn't be completed." Recipes now retry such a call once, and the error reads "The on-device model hit an internal error", with advice to retry.

**Tested.** `afm-selftest` covers the redactor, including card checksums, an international phone number, dates and short numbers left alone, one placeholder per value, and bad model output. It also covers the error mapping. Live cases: three redaction texts, a text with nothing to hide that came back unchanged, three address formats in six runs, all five draft formats (no number in a draft that isn't in the notes), and a Swift error, a Python traceback and a 4,000-line log with the error on its last line.

### Summaries and drafts break their own rules

**Status.** Fixed in 0.2.4.

**What was wrong.** A spin through every MCP tool with the afm-studio Claude Code mod watching turned up:

- A short summary of the README had 17 bullets, and of the roadmap 23. Short allows 5. As a paragraph it ran 342 words, where short allows 3 sentences.
- Explain an error quoted the whole traceback, and one of its next steps was a database dump command offered as a way to read logs.
- The repo brief called 0.2.3 the stable release. It was a commit named "release: 0.2.3", and the latest published release was 0.2.2.
- Next steps proposed documenting the chat GitHub tools, which the README already covers.
- `afm_status` couldn't say which build the server runs. After an install, a client still talks to the old server process until it reconnects, and nothing could tell.

**What changed.**

- A recipe can set `maxBullets` and `maxSentences`, keyed by a parameter value. Summarize uses 5 and 3 for short, 10 and 6 for medium. When an answer runs over, the model picks the most important bullets, or shortens the paragraph, in one more pass. If it's still over, `TextCleanup.firstBullets` or `firstSentences` cuts it. Sentences are counted with NaturalLanguage, so "e.g." doesn't end one.
- Explain an error quotes only the line that names the error, and its next steps only inspect or check. It never suggests a command that dumps, deletes, resets or changes data.
- Proofread's instructions include "Me and him has been" becoming "He and I have been".
- The repo material lists the latest published release from GitHub's releases API, and the brief is told a commit that mentions a release isn't one.
- Next steps suggests documentation only when an issue asks for it or the material shows the gap.
- `afm_status` adds `server_commit`, read from the app's `Info.plist` when the server starts, and `server_started`.

**Tested.** `afm-selftest` covers bullet and sentence counting and cutting, the limits, and the new status fields. Live over MCP: short summaries of the README and the roadmap came back with 5 bullets, the short paragraph with 3 sentences, proofread fixed "Me and him", explain-error quoted only the exception line, and the brief named v0.2.2. A summary that has to be cut takes a few seconds longer.

### Long-file work is slow, and next steps guesses

**Status.** Fixed in 0.2.4.

**What was wrong.** Summarizing the README or the roadmap took 33 to 82 seconds, and a PR description 45 to 51. Next steps drafted issues the material didn't support, such as calling a recent fix incomplete.

**Why.** The on-device model reads fast and writes slowly. Reading 2,000 tokens takes about 3 seconds, and writing 300 takes about 10. Running requests in parallel gained 5%, because the model serves one at a time. So the time went to text that was thrown away:

- Each section of a long input was summarized at full length, often with sub-bullets.
- The combining pass then wrote a long answer, 19 seconds for the README, and the length limit cut most of it.
- The PR draft fed each file's patch with its unchanged context lines, asked for a one-sentence note on ten files, and listed every other file. The model wrote a bullet for each of those, inventing what it did.
- Next steps saw only the README and recent commits, so it had nothing real to plan from.

**What changed.**

- With a length limit, section notes are told they are one part of a longer document and to write one-sentence bullets with no sub-bullets. They are capped at 300 tokens, and a last line cut off at the cap is dropped.
- When the notes already have more bullets than the limit, the most important are picked straight from them, without a combining pass.
- The bullet limit applies only to bulleted styles and the sentence limit only to prose. A paragraph summary had come back as bullets.
- PR file notes see only changed lines and hunk headers, up to 4,000 characters. They cover the six largest files in at most 25 words each. Changes get one bullet per note and none for other files, and the title is written from the commit subjects.
- Next steps reads the repo's `ROADMAP.md`, minus sections marked fixed or shipped (`GitHubWorkflows.openRoadmap`). Each issue must name the item it comes from, come from a different item, and put bugs ahead of polish.
- `AFM_TRACE=1` logs each model call's time and sizes to stderr.

**Tested.** `afm-selftest` covers dropping a cut-off line and the roadmap filter. Timed with `AFM_TRACE=1` on this branch:

| Task | Before | After |
| --- | --- | --- |
| Short summary of the README | 47 s | 30 s |
| Short paragraph summary of the README | 46 s | 30 s |
| Short summary of the roadmap | 59 s | 30 s |
| Medium summary of the roadmap | 82 s | 31 s |
| PR description of this branch | 51 s | 22 s |

Next steps, run twice, named a roadmap item in every issue both times, and included the Help menu bug.

**Still open.** Next steps sometimes drafts two issues about the same item, or a weak one such as a version check. Summaries of the roadmap still sometimes call planned work done.

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

## 3. Siri and Shortcuts

**Status.** The code is written, builds with 0.2.5 and lives on the `feat/siri-shortcuts` branch as a draft PR. Integrations come from the registry, so Jev shows up in Siri and Shortcuts without extra code. Siri doesn't list the actions yet, because no build so far has included the App Intents metadata. That needs Xcode, which isn't installed on the build Mac yet. Next: install Xcode, build, install, and check every phrase by voice.

Siri, Spotlight and the Shortcuts app can work with each part of the sidebar: chats, the Workbench, Insights, Integrations and System. Answers come from the on-device model, so a question asked through Siri stays on the Mac.

### What you'll see

- **Chats:** ask a question in a new chat, start a chat, open a previous chat by its title, reply in a chat and hear the answer, read a chat's last reply, and delete a chat after a confirmation.
- **Workbench:** run any recipe on text you give it, count tokens, and open Recipes, Structured Output, Batch, Compare or Tokens.
- **Insights:** hear a count of today's runs from local history, run the benchmark, and open Benchmark or History.
- **Integrations:** turn an integration on or off, hear its status, and open Integrations or GitHub.
- **System:** hear the model's status, start or stop the API server, check for updates, and open Model, Claude or CLI & API.

Apple allows ten Siri phrases per app. The phrases cover Ask, New Chat, Open Chat, Reply in Chat, Open Section, Run Recipe, Recent Activity, integrations, Model Status and the API server. The other six actions are only in the Shortcuts app. The README's Siri and Shortcuts section lists the phrases.

### How it works

1. **Intents in the app.** `Sources/AFMStudio/Siri/` defines the actions as App Intents, plus entities for chats, recipes and integrations, and an enum of sidebar sections. Siri looks chats up by title first, then by message text.
2. **One app state.** `AppState.shared` is the single instance used by the window, the menu bar and the intents. Actions that answer something run in the background. Actions that show something bring the window forward and reopen it if it was closed.
3. **Chats stay in sync.** A reply sent from Siri goes through the chat's view model, so an open chat streams it like a typed message. Chats started from Siri are saved with the source `siri` and show a waveform icon in the sidebar.
4. **Metadata at build time.** `swift build` already compiles the intents and records their constant values and source list. `scripts/app-intents-metadata.sh` then runs Apple's `appintentsmetadataprocessor`, which writes `Contents/Resources/Metadata.appintents` into the bundle. The arguments match Apple's `AppIntentsMetadata.xcspec`, which ships with Swift Build. `build-app.sh` runs the script before signing, and `--install` re-registers the app with Launch Services.

### Dependencies

- **Xcode.** `appintentsmetadataprocessor` ships only with Xcode, not the Command Line Tools. The script finds it in the selected developer directory or in any `Xcode*.app` in `/Applications` or `~/Applications`. Xcode doesn't have to be selected with `xcode-select`. Without Xcode, the build prints a note and skips this step, and the app works as before without Siri actions.
- **Swift Build internals.** The script reads `AFMStudio.SwiftFileList` and `*.swiftconstvalues` from `.build/out/Intermediates.noindex/.../Release/AFMStudio-p.build/Objects-normal/<arch>/`. That layout isn't a public interface, so a SwiftPM update could move it. The script stops with a clear note if it can't find those files.
- **macOS 27 SDK.** The intents use `supportedModes` to say which actions run in the background. That needs the macOS 26 SDK or later, which the build already requires.
- **A stable signature.** Siri and Shortcuts tie actions to the app's identity. Builds signed with the local identity from `scripts/make-signing-identity.sh` keep that identity across rebuilds. Ad-hoc builds may need the app opened again before Siri sees changed actions.
- **Apple Intelligence.** Ask, Reply in Chat, Run Recipe and Run Benchmark need the on-device model. When the model is unavailable, Siri says why instead of failing quietly.

### Before it ships

- Build with Xcode installed and confirm `Metadata.appintents` is in the bundle.
- Run each phrase through Siri and each action in Shortcuts, with the app quit, open in the background, and open with its window closed.
- Reply in a chat that's open on screen, and in one that's busy answering. The busy chat should refuse with a clear message.
- Confirm that Delete Chat asks first, and that turning GitHub off while its pane is showing moves the window to Integrations.
- Self-test checks for the parts that don't need Siri. Done for chat lookup, which moved into `SessionStore.search` so the self-test can reach it. The section-to-pane mapping is an exhaustive `switch`, so the compiler checks it.

### Open questions

- **Which ten phrases.** Benchmark, Count Tokens or Check for Updates could replace a phrase that goes unused.
- **Siri's own chats.** Every question asked through Ask becomes a saved chat. If that crowds the sidebar, add a setting to keep them out of the list or to group them.
- **Spotlight indexing.** Chats could also be indexed so Spotlight finds them by content. That would store chat text in the system index, which is a privacy choice to make explicitly first.
- **Localization.** The phrases are English only. Shortcut names and phrases would need string catalogs to be translated.
