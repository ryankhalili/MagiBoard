# MagiBoard Mac companion

This original, Python-standard-library companion connects the native iPad canvas to the installed Codex CLI using its supported ChatGPT sign-in. It launches its own agent processes: requests do **not** go through the chat that built the app. The iPad must reach this Mac on the same trusted local network; the Mac must stay awake. No API key or ChatGPT token is copied into the iPad app.

## Start without an open chat

On the Mac, double-click **Start MagiBoard.command** in this folder. The companion runs independently in the background; you can close its Terminal window and the development chat. Use **Stop MagiBoard.command** to stop it. These launchers do not register a login item, install a daemon, or start automatically after reboot.

Requirements: macOS, Python 3.9 or newer, and an installed Codex CLI or supported Codex/ChatGPT desktop bundle. The launcher searches the current PATH, common standalone/Homebrew locations, and app bundles. If your installation is elsewhere, use `--codex /path/to/codex`.

For initial iPad pairing, double-click **Pair iPad.command**. Finder selects the private `pairing.canvaspair` file. AirDrop it to the iPad and import it in MagiBoard Account settings. The companion advertises this Mac's name through Bonjour (`_magiboard._tcp.`), so the app can find a nearby Mac without asking you to type an IP address. Discovery does not grant access: new devices must still import the pairing file. Existing paired devices can use discovery to update the connection address after a network change.

Command-line equivalents, from the project directory:

```sh
python3 bridge/companion.py start
python3 bridge/companion.py status
python3 bridge/companion.py pair
python3 bridge/companion.py stop
```

The legacy state directory is intentionally preserved at `~/Library/Application Support/CanvasStudio/bridge`, so existing pairing survives the MagiBoard rename. Its token, pairing file, process record, and log stay outside the repository. Pairing files are private: their bearer token grants access to this companion. Runtime files are restricted to your Mac user. The prototype uses HTTP on the local network; use it on your own trusted network, not an exposed public server. Bonjour publishes only a display name and protocol version, never the pairing token.

For foreground development use `python3 bridge/server.py --lan`; Ctrl-C stops it. The foreground default without `--lan` binds only to localhost. The background launcher listens on local IPv4 interfaces so Bonjour remains useful across network changes. `--no-discovery` disables Bonjour. No ports are forwarded or publicly hosted by this app.

The app can start official device-code sign-in: open the returned OpenAI verification URL and enter the displayed one-time code. Codex itself stores and refreshes credentials. This companion reuses the Mac's Codex sign-in, so changing accounts changes that shared Codex account. Disconnecting the iPad rotates the companion pairing token and leaves the Mac's Codex account signed in. For a full Mac-wide logout, use `codex logout` yourself.

Optional `--model MODEL` chooses a model available to the signed-in account; the default uses Codex's model default. Use `--port 8247` or `--state-dir PATH` for a separate companion instance. Account switching affects the shared Mac Codex sign-in. If a foreground companion is already running, the background launcher leaves it alone; stop the original process before switching launch methods.

## Voice

This bridge receives text requests, including text recognized by the iPad's native speech recognizer, and returns structured operations plus a short reply for system speech synthesis. That supports a conversational hands-free UI, but it is not OpenAI speech-to-speech audio streaming. The installed Codex runtime exposes experimental realtime RPCs; a real subscription-only probe rejected audio startup with `realtime conversation requires API key auth`. This version therefore reports `voiceTransport: native_speech_text` and `subscriptionRealtimeAudio: false`, and does not offer an unsupported subscription voice promise. See [VOICE_NOTES.md](VOICE_NOTES.md) for the evidence and integration boundary.

## Protocol

All endpoints require `Authorization: Bearer <pairing token>` and reject browser `Origin` requests. JSON only, with a 16 MiB request limit. There is no CORS or unauthenticated status endpoint.

- `GET /status` or `/auth/status`: `connected`, `provider`, `plan`, `name`, `displayName`, `busy`, `activeRequests`, `maxConcurrentRequests`, `capabilities`, `voiceTransport`, `subscriptionRealtimeAudio`, and current login result.
- `POST /auth/start` with `{}`: `verificationUrl`, `userCode`, `loginId`, `type`, from official Codex `account/login/start` with `chatgptDeviceCode`.
- `POST /auth/cancel` with `loginId`: cancel pending sign-in.
- `POST /disconnect` with `{}`: revoke this pairing token and write a new local pairing file.
- `POST /generate`: `{prompt, objects, reference?, selectedIDs?, imageBase64?, documentText?}`. Returns `{message, operations:[{type,id,object?}]}`. Types are `add`, `update`, `delete`. Use an HTTP timeout of at least 420 seconds.
- `GET /catalog/status`: whether the separately configured Databricks object catalog is connected.
- `GET /catalog/objects`: `{objects:[{id,title,kind,createdAt,schemaVersion}],truncated}` for immutable saved versions.
- `POST /catalog/objects` with `{object}`: explicitly save one validated canvas object; returns `{entry}`.
- `GET /catalog/objects/{snapshot UUID}`: `{entry,object}`. Native import assigns a new object identity and places it in the current notebook.

A reference contains `x,y,width,height` in canvas coordinates. A small rectangle acts as a waypoint. PNG/JPEG image context is optional; PDF content should be extracted to `documentText` by the native app. Existing image bytes are excluded from the textual object prompt.

Canvas objects include `id` (UUID), `kind` (`text`, `shape`, `graph`, `image`, `widget`, `latex`, `frame`), `title`, `x,y,width,height`, `color`, `text`, `properties` (numeric dictionary), `propertySpecs`, `code` (self-contained widget HTML), `shape`, `pattern`. Each property spec declares `key,label,control,min,max,step,unit,choices`; controls are slider, number, toggle, or numeric choice. The parameter must exist and fit its declared bounds. Strict model output uses a JSON-encoded property dictionary internally; the bridge normalizes and validates it before responding.

Up to four independent generation requests can run concurrently. Each freezes its reference and nested object context, uses a separate temporary directory, and launches its own ephemeral, read-only Codex turn. A fifth request gets a capacity message. There is no shared conversation thread between requests. Host command tools, connected apps, plugins, browser control, hooks, memory, and delegation are disabled. Hosted web search is available. Native widgets run in a constrained web view with no external network or arbitrary host access; their only native interface is the app's validated, explicitly enabled Interact API for creating, duplicating, and updating canvas objects. Generation cannot act as a general-purpose Mac command executor.

This version supports model-authored canvas objects, interactive HTML widgets, image understanding, handwriting transcription when given a screenshot, web research, and subscription raster image generation. Subscription image generation is connected: the CLI creates the raster asset, then the companion attaches its base64 bytes as `imageData`. It reads only images inside the exact Codex turn's generated-image directory, rejects path escapes and symlinks, and limits each image to 8 MiB. Voice capture and PDF extraction belong to the native app. The [Databricks cloud object catalog](DATABRICKS.md) supports explicit save/list/load with separate local configuration; its optional SQL data-chart adapter remains disabled and unwired. Arbitrary backend execution and API-key mode are not configured.

## Validation

```sh
cd bridge
python3 -m unittest discover -v
```

The tests cover authorization, browser-origin rejection, token revocation, device-login response shape, object IDs, finite geometry, property validation, uppercase Swift UUIDs, confinement of generated-image paths, secret-free Bonjour metadata, voice capability reporting, executable discovery, and stale-process safeguards. A live subscription smoke test on 2026-11-15 confirmed account status and created a green triangle with 49°, 52°, and 79° angles through the real Codex CLI. It used no API key. Further live tests generated a tappable coin-duplication HTML widget and a raster coin image with attached image bytes. The background launcher was tested in an isolated state directory for start, duplicate-start prevention, authenticated status, private file permissions, and graceful stop.

## Official integration references

- [Codex App Server](https://learn.chatgpt.com/docs/app-server): account RPCs and device-code flow.
- [Codex authentication](https://learn.chatgpt.com/docs/auth): ChatGPT sign-in and device login requirements.
- The installed `codex exec --help` documents `--output-schema`, `--ephemeral`, `--ignore-user-config`, and `--sandbox read-only` used by this implementation.

These references informed protocol integration only. No third-party application source was copied.
