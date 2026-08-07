# Open-Wispr

Open-source voice dictation for macOS. Hold **fn**, speak, release — your words
are typed wherever the cursor already is, in any app. Transcription runs through
[OpenRouter](https://openrouter.ai) with **your own** API key, so you pay cents
per hour instead of a subscription.

A menu-bar app in plain Swift: no Electron, no account, no telemetry, no server
of ours anywhere in the path.

## Why Open-Wispr

- **Sharper than a local model.** Dictation apps that run entirely on your Mac
  are limited to whatever a laptop can fit in memory. Open-Wispr calls
  full-size transcription models, so names, jargon and accents survive — with no
  fans spinning up and no gigabytes of model files on disk.
- **It learns from you.** Fix a word right after it lands and that fix is
  remembered — the next time you say it, it comes out right by itself. No
  training, no setup; just correct it once.
- **No “um”, no “uh”, no stutters.** Filler words, false starts and repeated
  words are stripped before the text is pasted, so what lands is what you meant
  to say — not a transcript of you thinking out loud.
- **Free forever, and open source.** MIT licensed, no subscription, no account,
  no paid tier waiting for you. You bring your own
  [OpenRouter](https://openrouter.ai) key and pay them cents per hour of
  dictation, directly, at cost.
- **Private by default.** Your key never leaves your Mac, your transcripts and
  dictionary stay in `~/.config/openwispr`, and there is no analytics of any kind.

## Quickstart

1. Download the DMG from [Releases](https://github.com/soorower/Open-Wispr/releases)
   and drag Open-Wispr to Applications. On first launch macOS asks you to allow
   it once — [four clicks, no Terminal](#the-apple-could-not-verify-warning).
2. Paste your [OpenRouter key](https://openrouter.ai/keys) in Settings →
   **Transcription** → Save.
3. System Settings → Keyboard → **“Press 🌐 key to” → “Do Nothing”**, and grant
   Accessibility, Input Monitoring and Microphone when asked.
4. **Hold fn, talk, let go.** The text types itself wherever your cursor is.
   (Or tap fn once to go hands-free, tap again to finish.)

## Install (macOS 13 or newer)

1. Download the latest `Open-Wispr-x.y.dmg` from
   [Releases](https://github.com/soorower/Open-Wispr/releases).
2. Open it and drag **Open-Wispr** onto **Applications**.
3. First launch only: macOS warns that it can't verify the app. Press **Done**,
   then System Settings → **Privacy & Security** → **Security** → **Open
   Anyway**. Full walkthrough (and a one-line Terminal alternative)
   [below](#the-apple-could-not-verify-warning).
4. The settings window opens. Paste your own OpenRouter key under
   **Transcription** → **Save**, then hit **Verify**. Get a key at
   [openrouter.ai/keys](https://openrouter.ai/keys). **No key ships with the
   app** — yours is written only to `~/.config/openwispr/.env` (chmod 600) and
   is sent nowhere but OpenRouter.
5. System Settings → Keyboard → set **“Press 🌐 key to” → “Do Nothing”**,
   otherwise every fn tap opens the emoji picker instead of dictating.
6. Grant the permissions the app asks for:
   - **Accessibility** — to paste into the focused field.
   - **Input Monitoring** — to see the fn key.
   - **Microphone** — allow when prompted.

*Clean up speech* and *Learn my corrections* are on out of the box; both can be
switched off in Settings or from the menu-bar icon.

### The “Apple could not verify” warning

> **“Open-Wispr” Not Opened** — Apple could not verify “Open-Wispr” is free of
> malware that may harm your Mac or compromise your privacy.

Every app that isn't **notarised** by Apple gets this, and notarising requires a
paid Apple Developer account. It's Gatekeeper saying *unknown developer* — not a
malware finding. You allow it once and never see it again.

**Without Terminal — four clicks:**

1. Double-click **Open-Wispr**. The warning appears; press **Done**.
2. Open **System Settings → Privacy & Security**, scroll down to **Security**.
   You'll see *“Open-Wispr” was blocked to protect your Mac*.
3. Click **Open Anyway** and confirm with Touch ID or your password.
4. Click **Open Anyway** once more when the app relaunches. That's it — it opens
   normally forever after.

Do step 2 straight after step 1: the button only stays for about an hour.

**With Terminal — one line**, if you'd rather not click through Settings:

```sh
xattr -dr com.apple.quarantine /Applications/Open-Wispr.app
```

Right-clicking the app and choosing *Open* used to work — **Apple removed that
shortcut in macOS 15**, so on current macOS use one of the two above.

Trust nothing and verify instead: this whole app is a few thousand lines of
Swift in this repo. Clone it, read it, `./build.sh` — macOS never warns about
software you compiled yourself.

## Using it

- **Hold fn** while speaking → release → transcribes & pastes.
- **Tap fn** → hands-free recording → **tap fn again** → transcribes & pastes.
- A rounded **pill floats at the bottom of whichever screen your cursor is on**:
  dim dots when idle, colourful bars that react to your voice while recording, a
  soft wave while transcribing, green flash on paste.
- **Click the pill** → popup with the last transcript and a **Copy** button
  (clicking during recording stops and transcribes). The pill turns **orange**
  when a paste couldn't land — the text is kept for you.
- Menu-bar icon: the waveform mark — monochrome idle (adapts to light/dark),
  **red** recording, **violet** transcribing.
- Your previous clipboard is restored ~1s after the paste.
- **Clean up speech** (on by default) removes filler words (“um”, “uh”, “er”…),
  cut-off fragments (“al- already” → “already”) and stutters (“I, I” → “I”)
  before pasting. It only trims noise — it never changes which real words you
  said. Valid doubles like “that that” and names are protected.

## Settings window

Opens on launch, and any time from the menu-bar icon → *Open Main Window* (⌘,).
Four panes: **General** (API key + Verify, model, behaviour toggles, live
permission status), **Dictionary** (word replacements), **Activity** (every
dictation + the log), **About**. Closing it leaves the app running in the menu
bar. When launchd starts it at login it stays quiet (`--background`).

The eye button reveals the whole key, wrapped across as many lines as it needs.

## Providers and models

Pick a provider at the top of Settings → Transcription. Each keeps its own key
and its own model, so switching back and forth never costs you a re-paste.

- **OpenRouter** (default) — one key, many vendors' models. Default
  `openai/gpt-4o-mini-transcribe`; the box also suggests
  `microsoft/mai-transcribe-1.5`, `openai/gpt-4o-transcribe`, `openai/whisper-1`
  and `mistralai/voxtral-mini-transcribe`.
- **OpenAI** — straight to the source. Use this for models OpenRouter hasn't
  picked up yet, and for live streaming. Default `gpt-4o-mini-transcribe`.

Any model that accepts audio on the provider's transcriptions endpoint works.
Image- or chat-only models will fail.

## Live streaming (OpenAI only)

Settings → Transcription → **Live streaming**. Instead of recording a clip and
uploading it when you let go, the app opens a WebSocket the moment you press fn
and streams 24 kHz audio as you talk. Transcript deltas come back in flight and
show up in the HUD, so releasing fn pastes almost immediately instead of waiting
out an upload.

Default model `gpt-live-transcribe` — a streaming-only model that bills
**$0.017 per minute** of audio. It lives on the realtime endpoint
(`wss://api.openai.com/v1/realtime?intent=transcription`) and cannot be used for
normal uploads, which is why live mode keeps its own model setting.

Nothing is written to disk in this mode — the audio never becomes a file. Your
replacement dictionary is sent along as keyword hints, so the words the model
usually gets wrong come back right more often. Cleanup, the dictionary and
auto-learn all still run on the final text exactly as before.

If the socket drops mid-sentence, whatever was already transcribed is still
pasted rather than thrown away.

## Word replacements

Your own “heard this → type that” list, applied to every transcript *after*
cleanup, so your spelling always wins.

- Matched as **whole words, ignoring case** — “rekki” and “Rekki” both become
  “ReqKey”. A capitalised match keeps its capital (“Rekki is live” → “ReqKey is live”).
- **Phrases work**: “realty API” → “RealtyAPI”. Longer entries win over shorter ones.
- Tick **Aa** on a row to require exact capitalisation (used by case-only fixes).
- Edit either column in place; ✕ or the ⌫ key removes a row. `Uses` counts how
  often each rule has fired.
- Stored in `~/.config/openwispr/replacements.json`.

## Learning your corrections

With **Learn my corrections** on (default), fixing a word by hand right after a
paste teaches Open-Wispr that word. Say a name, watch “Janish” land, change it to
“Janice”, and the pill flashes teal with *✓ Learned “Janish” → “Janice”* — the
next dictation types it correctly by itself. Learned entries appear in the
Dictionary marked **Learned** (*Forget learned…* clears just those).

It is deliberately cautious, and only ever learns from a genuine single-word
substitution inside the text it just pasted:

- same number of words, exactly one of them different;
- the new word spelled similarly to the old one (so a rewrite teaches nothing);
- the text has sat still for ~1.1s, so half-typed words aren't learned;
- typing *more* text, deleting, or rewriting the sentence is ignored;
- it re-learns onto the original word, so “Janish”→“Jan”→“Janice” ends up as one
  rule, not two.

It reads the focused field through the **Accessibility** permission the app
already needs in order to paste, purely to spot the changed word — only the word
pair is saved, and nothing leaves your Mac.

### Chromium and Electron apps

Chrome, and Electron apps like Slack, don't build an accessibility tree until an
assistive client asks for one — so the field you dictated into is simply
invisible, and auto-learn does nothing (the log says `no focused element`). When
auto-learn is on, Open-Wispr asks the app you're dictating into to publish its
tree, by setting `AXEnhancedUserInterface` on it — the same switch VoiceOver and
other assistive tools use. Notes:

- Asked **once per app per session**, and only while *Learn my corrections* is on.
  Turn that toggle off and Open-Wispr never touches other apps.
- The request goes out when **recording starts**, because Chrome needs a few
  seconds to build the tree — by the time your text is pasted it's ready.
- Chrome's own `AXManualAccessibility` attribute is unsupported (error −25205);
  `AXEnhancedUserInterface` is the one that works.
- A browser with the tree enabled uses a little more memory and CPU.

Terminals and anything else that doesn't publish its text still can't be watched;
the log names the app, and dictation itself is unaffected.

## Privacy and permissions

- **Your key is yours.** No API key ships with the app; you paste your own on
  first run and it stays in `~/.config/openwispr/.env` (chmod 600), read only by
  this app on your Mac.
- **Permissions are only ever requested.** Open-Wispr triggers Apple's standard
  Accessibility / Input Monitoring / Microphone prompts and can open the right
  System Settings pane for you. It never edits your privacy database, never asks
  for admin rights, and every grant stays revocable in System Settings.
- **Audio** goes to OpenRouter for transcription and is not kept on disk beyond
  the clip being transcribed.
- **Everything else stays local**: transcripts, dictionary and logs live in
  `~/.config/openwispr`. No analytics, no update pinger, no account.
- Releases are built by `make_dmg.sh`, which refuses to package a build that
  contains an API key, a private key or any credential file.

## Build from source

Needs the Xcode command line tools. No packages, no dependencies.

```sh
git clone https://github.com/soorower/Open-Wispr.git
cd Open-Wispr
./build.sh
open Open-Wispr.app
```

Package a DMG the same way releases are cut (writes `dist/Open-Wispr-x.y.dmg`):

```sh
./make_dmg.sh
```

> Rebuilding changes the code signature, so old permission grants go stale (the
> toggle in System Settings shows ON but is dead) — re-grant Accessibility and
> Input Monitoring after a rebuild. To keep grants across rebuilds, create a
> self-signed code-signing certificate in Keychain Access named
> `Open-Wispr Dev`, or point `SIGN_IDENTITY` at your own identity.
>
> `OPENWISPR_RESET_TCC=1 ./build.sh` additionally clears this app's own
> Accessibility entry via `tccutil` so the next launch re-prompts cleanly. It is
> opt-in, it only touches this one app on your own machine, and nothing in the
> shipped app does anything like it.

## Config (`~/.config/openwispr/.env`)

Written with the defaults below on first run, and editable from the settings
window; the file is just where it lands.

```
PROVIDER=openrouter              # openrouter (default) or openai
OPENROUTER_API_KEY=sk-or-v1-…    # yours, added on first run — never shipped
OPENAI_API_KEY=sk-…              # only needed when PROVIDER=openai
MODEL=openai/gpt-4o-transcribe   # optional override, OpenRouter
OPENAI_MODEL=gpt-4o-transcribe   # optional override, OpenAI
LIVE=0                           # 1 = stream live over the realtime socket (OpenAI only)
LIVE_MODEL=gpt-live-transcribe   # optional override, live mode only
CLEANUP=1                        # 1 = remove fillers/stutters (default), 0 = off
AUTOLEARN=1                      # 1 = learn words you fix after a paste (default)
SOUNDS=1                         # 1 = start/stop/error sound cues (default)
```

Alongside it: `replacements.json` (your dictionary), `history.json` (last 200
dictations), `openwispr.log`. *Launch at login* writes
`~/Library/LaunchAgents/com.openwispr.app.plist` and takes effect next login.

`OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `OPENWISPR_PROVIDER` and
`OPENWISPR_MODEL` in the environment override the file.

## Testing the API without the app

```sh
./test_api.sh    # upload path: `say` synthesizes speech, sent as the app sends it
./test_live.py   # live path: streams that audio over the realtime socket, prints deltas as they land
```

`test_live.py` speaks the same protocol as the app, so it's the quickest way to
tell whether a key has access to `gpt-live-transcribe`. Needs `pip3 install websockets`.

## Troubleshooting

- Log file: `~/.config/openwispr/openwispr.log` (also via menu → View Log).
- fn does nothing → re-grant Input Monitoring + Accessibility (updates and
  rebuilds invalidate them).
- Emoji picker pops up → set “Press 🌐 key to” to “Do Nothing”.
- “⚠️ Copied — grant Accessibility” pill → the paste permission is missing or
  stale; the transcript is left on the clipboard so ⌘V works meanwhile.
- Recordings shorter than 0.4s are discarded; recordings auto-stop at 5 min.
- If another fn-key dictation app is running, both react to fn — quit one.
- A correction wasn't learned → check Activity → Log. `Auto-learn: watching …`
  means it's live; `couldn't read the text of the field in <app>` means that app
  won't publish its content (add the word by hand in the Dictionary); `ignored
  “x” → “y”` means the edit didn't look like a misheard-word fix. Rewriting the
  sentence, or changing two words at once, is ignored on purpose.
- A rule you don't want → Dictionary → ✕ on the row (or *Forget learned…*).

## Upgrading from Wispr-Soro

This app was previously called Wispr-Soro. The first launch moves
`~/.config/wisprsoro` to `~/.config/openwispr` and re-registers the login item,
so your key, dictionary and history come with you. macOS sees a new bundle, so
re-grant **Accessibility** and **Input Monitoring**, then delete the old
`Wispr-Soro.app`.

## Files

- `main.swift` — the menu-bar app: fn hotkey, pill/HUD, recorder, OpenRouter call, paste.
- `Config.swift` — `.env` settings, first-run defaults, log, dictation history.
- `Replacements.swift` — the replacement dictionary and how it's applied.
- `Corrections.swift` — auto-learn: the Accessibility diff that spots a fixed word.
- `Theme.swift` — colours, labels, cards, toggle/status rows for the settings window.
- `SettingsUI.swift` — window shell + General and About panes.
- `SettingsPanes.swift` — Dictionary and Activity panes.
- `build.sh` — compiles every `*.swift` (except `make_icon.swift`) into `Open-Wispr.app`.
- `make_dmg.sh` — builds the app and packages `dist/Open-Wispr-x.y.dmg`.
- `make_icon.swift` — draws `AppIcon.icns` (violet squircle + waveform).
- `Info.plist` — bundle metadata (menu-bar-only app, mic usage string).
- `test_api.sh` — end-to-end API smoke test without the mic.

## License

MIT — see [LICENSE](LICENSE).
