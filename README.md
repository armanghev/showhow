# ShowHow

A menu bar app that looks at your screen and walks you through any task on your Mac. Ask "how do I make a pivot table in Numbers?" and Claude highlights where to click, one step at a time, checks each step worked, and carries on. Switch to Do-it mode and it clicks for you.

It follows the build plan in the project folder (`mac-helper/screen-guide-plan.md`).

## What's in it

| Area | Where |
|---|---|
| Claude API client, streaming, agent loop, computer-use toolset, coordinate mapping, session log, Markdown exporter, MCP protocol, whiteboard model | `Packages/ShowHowCore` (no AppKit, so it also builds and tests on Linux) |
| Menu bar icon and panel, floating chat panel, overlay, ScreenCaptureKit capture, Accessibility reader, CGEvent input, hotkeys, voice, settings, onboarding, whiteboard window, write-up export, screen recording, MCP HTTP server | `ShowHow/` |
| stdio bridge for Claude Desktop (`showhow-mcp`, shipped inside the app) | `MCPBridge/main.swift` |
| Xcode project (generated from `project.yml` by XcodeGen, committed so you don't need XcodeGen) | `ShowHow.xcodeproj` |

## Build and run

You need macOS 14 or later and Xcode 16.3 or later (KeyboardShortcuts 2.4 needs Swift tools 6.1).

1. Clone the repo and open `ShowHow.xcodeproj`. Xcode fetches KeyboardShortcuts and Sparkle the first time.
2. Set up signing so macOS remembers your permissions between builds:
   ```sh
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
   ```
   Then put your team id in it (Xcode > Settings > Accounts shows it). A free Apple ID team works. Without this the app is signed ad hoc, and macOS forgets Screen Recording and Accessibility every time you rebuild.
3. Pick the **ShowHow** scheme and press ⌘R. The app has no Dock icon; look for the pointer icon in the menu bar.
4. The welcome window asks for:
   - your Anthropic API key (stored in your Keychain),
   - **Screen Recording**, which is all Guide mode needs,
   - **Accessibility** (optional), which names buttons precisely and enables Do-it mode,
   - **Microphone and Speech** (optional), for voice.

   After granting Screen Recording, macOS may ask you to quit and reopen the app.
5. Press **⌥Space** anywhere, type what you want to do, and press Return.

From the command line instead:

```sh
xcodebuild -project ShowHow.xcodeproj -scheme ShowHow -configuration Debug build
open "$(xcodebuild -project ShowHow.xcodeproj -scheme ShowHow -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/ShowHow.app"
```

If you change `project.yml`, regenerate the project with `brew install xcodegen && xcodegen generate`.

## Using it

| Shortcut | Does |
|---|---|
| ⌥Space | Tap: open the panel to type. Hold: talk (when voice is on). Starts a queued hand-off. |
| ⌥⇧P | Pause or resume |
| ⌃⌥→ | Next step (when ShowHow didn't notice you finished) |
| ⌥⇧W | Open or close the whiteboard |
| ⌘⇧Escape | Kill switch: stops the request, clears the overlay, stops all synthetic input |

All of them can be changed in Settings > Shortcuts, which warns about clashes with macOS shortcuts. Next step uses ⌃⌥→ rather than the plan's ⌥→ because ⌥→ moves by word in every text field.

- **Guide mode** draws the highlight and waits for you to click or type. It notices your click on its own; typing steps finish after a short pause or Return (that needs Accessibility; otherwise press Next).
- **Do-it mode** clicks and types for you. Anything that sends, submits, pays or deletes asks you first, and it refuses to type into password fields. Grab the mouse and it pauses.
- **Questions mid-step**: type or say them. Claude answers with the screen in view, then the step carries on.
- **Documentation**: say "document this" at any point, ask up front, or use **Document last walkthrough** in the menu bar. You get a folder in `~/Documents/ShowHow/` with `README.md`, annotated screenshots (password fields blurred) and, if you turned it on, `recording.mov`. A preview with Save appears first.
- **Whiteboard**: from the menu bar or ⌥⇧W. Full screen on the display with the mouse; pinch to zoom, two-finger scroll to pan, drop images onto it. While it's open the walkthrough pauses and Claude sees the board instead of your screen. Esc closes it and the walkthrough resumes.
- **Multiple displays**: one overlay per display. Claude gets the list of displays each turn and can switch between them; the panel follows the walkthrough.

## Hand-off from Claude Desktop and Claude Code

ShowHow runs a small MCP server on `127.0.0.1` with a per-install token (Settings > Integrations). A hand-off only queues: the panel shows "Ready when you are" with who asked, and nothing is captured until you press Start (unless you allow starting without you).

- **Claude Code**: Settings > Integrations > **Copy Claude Code command**, then paste it in Terminal. It runs `claude mcp add --transport http showhow http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <token>"`.
- **Claude Desktop**: Settings > Integrations > **Install in Claude Desktop**, then restart Claude Desktop. This adds a `showhow` entry that runs the bundled `showhow-mcp` bridge (a backup of your config is kept next to it).
- **Shortcuts, Raycast, links**: `showhow://walkthrough?task=Make%20a%20pivot%20table&app=Numbers&mode=guide`, plus `showhow://pause`, `resume`, `stop`, `document-last`, `whiteboard`, `summon`.

Tools offered: `request_walkthrough`, `start_now`, `pause`, `resume`, `cancel`, `get_status`, `document_session`, `open_whiteboard`, `whiteboard_draw`.

## How it talks to Claude

- Raw HTTPS to the Messages API (there is no official Swift SDK), streaming, with the `computer_toolset_20260801` computer-use toolset plus app tools (`annotate`, `narrate`, `wait_for_user`, `request_confirmation`, `document_session`, `list_displays`, `switch_display`, `whiteboard_draw`, `whiteboard_snapshot`).
- Default model `claude-opus-5-5` with adaptive thinking; Sonnet 5.5 and Haiku 5.5 in Settings. Server-side fallbacks on Opus and Sonnet.
- Prompt caching on the system prompt and conversation, context editing that trims old screenshots, and server-side compaction for long sessions. If the API rejects either beta, the app turns it off and carries on.
- Screenshots are JPEG at 1568 px on the long edge by default (up to 2576 px), with a 30 MB request guard under the 32 MB API limit.
- The session cost in the menu is an estimate from token usage and list prices.

## Tests

```sh
cd Packages/ShowHowCore && swift test
```

57 tests cover SSE parsing, the streaming accumulator, request building, retries and feature fallback, coordinate mapping across displays with different scale factors, key mapping, Guide-mode translation, the confirmation policy, the agent loop against a fake host (including pause and resume keeping the transcript valid), the MCP protocol and HTTP router, the session log, the Markdown exporter, URL commands and the whiteboard model.

CI (`.github/workflows/ci.yml`) runs those tests on Linux and macOS and builds the app with `xcodebuild` on a macOS runner.

## Releasing

`scripts/release.sh` archives with your Developer ID certificate, makes a DMG, notarizes and staples it. Updates through Sparkle switch on once you set `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_KEY` in `Config/Base.xcconfig` (write `https:/$()/` because `//` starts a comment in xcconfig files).

## Differences from the plan

- Next step defaults to ⌃⌥→ (see above).
- The MCP server is a small Network.framework listener on top of the protocol code in ShowHowCore, rather than the MCP Swift SDK. It speaks Streamable HTTP with JSON responses, which both Claude clients accept, and keeps the dependency list short.
- The Accessibility element list (which makes highlights snap to real buttons) needs Accessibility permission. Without it, Guide mode still works from the screenshot alone.
- The menu bar icon is drawn as animated template images rather than a hosted SwiftUI view, so it always matches the menu bar's appearance.
- PDF export renders the write-up to a single long page.
