# MagiBoard Mac companion

This original, Python-standard-library companion connects the native iPad canvas to the installed Codex CLI using its supported ChatGPT sign-in. It launches its own agent processes: requests do **not** go through the chat that built the app. The iPad must reach this Mac on the same trusted local network; the Mac must stay awake. No long-lived API key or ChatGPT token is copied into the iPad app. Optional API-backed Realtime voice receives only a short-lived client credential.

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

The companion supports two separate voice routes. Apple speech recognition → subscription Codex text requests → Apple speech synthesis remains the native fallback. Optional **OpenAI Realtime API** voice streams PCM24k mono with input transcript events from `gpt-4o-mini-transcribe` audio directly between the iPad and OpenAI, using a short-lived client secret minted by this Mac. Realtime can call `edit_canvas` for bounded native shapes, text, LaTeX, and explicit-function graphs; `submit_canvas_task` queues images, PDF extraction, research, and original custom widgets through the existing subscription agent. A queued acknowledgement is not a completion claim.

Realtime is API-billed, separate from the ChatGPT subscription. `subscriptionRealtimeAudio` remains false; `realtimeAvailable` reports whether the local API-key file is configured, not a guarantee that the key still has credit or model access. See [VOICE_NOTES.md](VOICE_NOTES.md) for verification and limitations.

To configure Realtime, create a private `realtime.json` in the companion state directory (outside this repository), with mode0600:

```json
{"enabled":true,"keyFile":"/absolute/path/to/your/private-api-key-file"}
```

The referenced file must contain exactly one OpenAI API key. Its contents are read only into memory for authenticated API calls. Keep it private and outside the project; never commit it. Set `enabled` to false to disable new voice-session setup. The fixed model is `gpt-realtime-2`; clients cannot override the provider URL, model, tools, or instructions through the bootstrap endpoint. New client secrets expire after60 seconds for establishing a connection; an already established session can continue beyond that deadline and must be closed by the app when stopped. A configured key may expire or exhaust its separate API quota.

## Protocol

All endpoints require `Authorization: Bearer <pairing token>` and reject browser `Origin` requests. JSON only, with a 16 MiB request limit. There is no CORS or unauthenticated status endpoint.

- `GET /status` or `/auth/status`: `connected`, `provider`, `plan`, `name`, `displayName`, `busy`, `activeRequests`, `maxConcurrentRequests`, `capabilities`, `voiceTransport`, `subscriptionRealtimeAudio`, `realtimeAvailable`, `realtimeModel`, and current login result.
- `POST /realtime/session` with `{}`: `{token,model,expiresAt}`. Token is an ephemeral API client secret; use it immediately with the Realtime WebSocket Authorization bearer header. No credential-bearing response is cached or logged.
- `POST /auth/start` with `{}`: `verificationUrl`, `userCode`, `loginId`, `type`, from official Codex `account/login/start` with `chatgptDeviceCode`.
- `POST /auth/cancel` with `loginId`: cancel pending sign-in.
- `POST /disconnect` with `{}`: revoke this pairing token and write a new local pairing file.
- `POST /generate`: `{prompt, objects, reasoningEffort?, reference?, selectedIDs?, imageBase64?, documentText?, documents?}`. Returns `{message, operations:[...]}`. Object operations are `add`, `update`, and `delete`; `insertPDF` carries a document UUID and a one-based page or numbered exercise. Use an HTTP timeout of at least 420 seconds.
- `GET /catalog/status`: whether the separately configured Databricks object catalog is connected.
- `GET /catalog/objects`: `{objects:[{id,title,kind,createdAt,schemaVersion}],truncated}` for immutable saved versions.
- `POST /catalog/objects` with `{object}`: explicitly save one validated canvas object; returns `{entry}`.
- `GET /catalog/objects/{snapshot UUID}`: `{entry,object}`. Native import assigns a new object identity and places it in the current notebook.

A reference contains `x,y,width,height` in canvas coordinates. A small rectangle acts as a waypoint. PNG/JPEG image context is optional; PDF content should be extracted to `documentText` by the native app. Existing image bytes are excluded from the textual object prompt.

`documents` contains only `{id,title,pages}` from the captured local library, never file URLs. A printout uses `{type:"insertPDF",documentID,page?,chapter?,question?,x?,y?}`. Supply a page for a complete-page printout, or a numeric question label such as `2` or `2.2` for the whole exercise, with an optional chapter and page hint. The bridge validates the document, any page hint, chapter1–999, and numeric exercise label; at most four printouts are permitted in one batch. The iPad resolves all requested pages from its original files into bounded image objects before applying any changes; one invalid page rejects the entire response. Missing coordinates use the captured reference, with multiple pages arranged side by side. With a question label the native PDF resolver locates and crops the complete exercise, including its subparts. Ambiguous boundaries fail with a full-page fallback instruction; subpart-only crops and arbitrary model-selected crop rectangles are unsupported. Ordinary canvas requests do not scan PDF text; explicit reference language or a document-title word triggers excerpt retrieval.

`reasoningEffort` accepts `low`, `medium`, `high`, or `xhigh`, and defaults to `low` for older clients. The native Thinking level setting sends its value with each request; the bridge passes it through the actual `model_reasoning_effort` Codex configuration option. Higher levels may take longer, and image generation or web searches add their own latency. The installed runtime advertised all four levels for every available model during validation; support may vary with another account or future model. The bridge does not silently override an unsupported choice. [Official configuration reference](https://developers.openai.com/codex/config-reference/).

Canvas objects include `id` (UUID), `kind` (`text`, `shape`, `graph`, `image`, `widget`, `latex`, `frame`), `title`, `x,y,width,height`, `color`, `text`, `properties` (numeric dictionary), `propertySpecs`, `code` (self-contained widget HTML), `shape`, `pattern`. Each property spec declares `key,label,control,min,max,step,unit,choices`; controls are slider, number, toggle, or numeric choice. The parameter must exist and fit its declared bounds. Strict model output uses a JSON-encoded property dictionary internally; the bridge normalizes and validates it before responding.

Up to four independent generation requests can run concurrently. Each freezes its reference and nested object context, uses a separate temporary directory, and launches its own ephemeral, read-only Codex turn. A fifth request gets a capacity message. There is no shared conversation thread between requests. Host command tools, connected apps, plugins, browser control, hooks, memory, and delegation are disabled. Hosted web search is available. Native widgets run in a constrained web view with no external network or arbitrary host access; their only native interface is the app's validated, explicitly enabled Interact API for creating, duplicating, and updating canvas objects. Generation cannot act as a general-purpose Mac command executor.

This version supports model-authored canvas objects, interactive HTML widgets, image understanding, handwriting transcription when given a screenshot, web research, and subscription raster image generation. Subscription image generation is connected: the CLI creates the raster asset, then the companion attaches its base64 bytes as `imageData`. It reads only images inside the exact Codex turn's generated-image directory, rejects path escapes and symlinks, and limits each image to 8 MiB. Voice capture and PDF extraction belong to the native app. The [Databricks cloud object catalog](DATABRICKS.md) supports explicit save/list/load with separate local configuration; its optional SQL data-chart adapter remains disabled and unwired. Arbitrary host execution is unavailable. Canvas generation continues to use the Codex subscription; the optional API key is used only for Realtime voice bootstrap.

## Validation

```sh
cd bridge
python3 -m unittest discover -v
```

The tests cover authorization, browser-origin rejection, token revocation, device-login response shape, object IDs, finite geometry, property validation, uppercase Swift UUIDs, confinement of generated-image paths, secret-free Bonjour metadata, ephemeral Realtime credential isolation, fixed voice tools, sanitized API failures, voice capability reporting, executable discovery, and stale-process safeguards. A live subscription smoke test on 2026-11-15 confirmed account status and created a green triangle with 49°, 52°, and 79° angles through the real Codex CLI. It used no API key. Further live tests generated a tappable coin-duplication HTML widget and a raster coin image with attached image bytes. The background launcher was tested in an isolated state directory for start, duplicate-start prevention, authenticated status, private file permissions, and graceful stop.

## Official integration references

- [Realtime client secrets](https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create): ephemeral credential setup.
- [Realtime WebSocket guide](https://developers.openai.com/api/docs/guides/realtime-websocket): direct native audio connection and events.
- [Codex App Server](https://learn.chatgpt.com/docs/app-server): account RPCs and device-code flow.
- [Codex authentication](https://learn.chatgpt.com/docs/auth): ChatGPT sign-in and device login requirements.
- The installed `codex exec --help` documents `--output-schema`, `--ephemeral`, `--ignore-user-config`, and `--sandbox read-only` used by this implementation.

These references informed protocol integration only. No third-party application source was copied.
