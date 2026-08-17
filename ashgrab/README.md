# Ashgrab

A single-file web app for saving videos and music from a link, redesigned around
Apple's Human Interface Guidelines and built to be used from the iPhone Share
Sheet.

Everything — markup, styling, icon and logic — lives in [`index.html`](index.html).
There is no build step, no bundler and no dependency to install. Drop the file on
any static host and it works.

## Deploying to GitHub Pages

1. Push this folder to the repository.
2. **Settings → Pages → Build and deployment → Deploy from a branch**, choose the
   branch and the `/ (root)` folder.
3. The app is served at `https://<user>.github.io/<repo>/ashgrab/`.

To serve it at the root of the site instead, move `index.html` to the repository
root (or into a `docs/` folder and point Pages at `docs/`).

Locally, any static server will do:

```
npx http-server . -p 8080
```

Opening the file directly with `file://` mostly works, but browsers block
cross-origin requests from `file://`, so downloads need a real server.

## Connecting a download engine

Ashgrab is a front end. The actual fetching is done by a
[Cobalt](https://github.com/imputnet/cobalt)-compatible server, which the
interface calls a *download engine* so that non-technical users aren't asked to
think about APIs.

There are two ways to point it at one.

**For everyone.** The first-run sheet offers *I run my own engine*, and the
settings sheet has a field for the address. It is stored in the browser only.

**As the default for all visitors.** Edit the `CONFIG.engines` array near the top
of the script block:

```js
const CONFIG = {
  engines: [
    "https://api.cobalt.tools/",
    "https://downloads.example.com/"
  ],
  ...
};
```

Every entry is health-checked in parallel on load and the first one to answer is
used — this is what the interface calls *Automatic Mirror Routing*. If one is
slow or down, the others cover for it. Both the current Cobalt API and the older
`/api/json` shape are supported, detected automatically, so an existing private
server keeps working without changes.

Your engine must send permissive CORS headers, since the browser talks to it
directly. Cobalt does this by default.

The shipped default is the official public instance, which may require its own
access key. If you have one, paste it into **Pass key** in settings.

## The Apple Shortcut

The point of the shortcut is that the page never has to be opened by hand: iOS
shares a link to Ashgrab, and Ashgrab starts immediately.

That works because the page accepts its input from the query string:

| Parameter | Meaning |
|---|---|
| `url` | the link to fetch — always placed last so it can be appended |
| `go=1` | start straight away instead of waiting for a tap |
| `mode` | `video` or `audio`, to skip the format choice |
| `quality` | `max`, `1080`, `720`, `480` |

So `…/ashgrab/?go=1&mode=audio&url=https%3A%2F%2F…` fetches the audio and begins
without any further interaction.

The builder in the page produces a real Shortcuts file — an Apple property list
containing two actions, *URL Encode* on the shared input and *Open URLs* on the
result — marked as an `ActionExtension` so it shows up in the Share Sheet. iOS
asks for confirmation before adding a shortcut that didn't come from Apple; if it
refuses outright, **Settings → Shortcuts → Allow Untrusted Shortcuts** has to be
switched on, and that switch only appears once a shortcut has been run at least
once. The page says so in plain language.

If you would rather hand people a one-tap install, build the shortcut once on
your own iPhone, share it to iCloud, and paste the resulting
`icloud.com/shortcuts/…` link into settings. The **Add iOS Shortcut** button then
opens that link directly and the file download is bypassed.

A hand-built version is also documented in the page itself, behind *Rather build
it by hand?*, for anyone who doesn't want to install a file at all.

## Notes on behaviour

- **Downloads.** On desktop the file is streamed with `fetch` so the progress bar
  reflects real bytes received. On iOS the download is handed to Safari instead,
  which is the only route that reliably reaches Files and Photos. If streaming is
  blocked or the file is very large, it falls back to a direct link.
- **Previews.** Title, artwork and author come from public oEmbed endpoints for
  YouTube, TikTok, Vimeo and SoundCloud — the ones that permit browser requests.
  A preview appears instantly from the link itself and is enriched when the
  lookup returns. Other sites show the platform name and a placeholder. Duration
  is displayed only when the source actually provides it.
- **Storage.** Settings and the five most recent downloads are kept in
  `localStorage` on the device. Nothing is sent anywhere except to the engine.
- **Appearance.** Follows the system light/dark setting by default; the sun
  button in the header cycles Automatic → Light → Dark. Motion is reduced
  automatically when the system asks for it.
