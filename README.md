# dialer-superpatch

One-shot installer that applies our Dialer.io extension customizations on macOS + Google Chrome.

## What it installs
- **Auto-dial, HubSpot only** — clicking any phone number (or the "Call with device" icon on hover) places the call immediately on HubSpot. No second click in the popup. Everywhere else the interceptor is switched off entirely: a phone number on WhatsApp Web, Gmail or anywhere else is left alone, and clicking it does nothing.
- **Ctrl+Option+D** — brings the popup forward (focuses the existing window, or opens it). Assign/confirm it at `chrome://extensions/shortcuts` and set the scope to **Global** so it works from any app.
- **Ctrl+Option+X** — in the Dialer.io popup: End call → Set Disposition → No Contact.
- **Ctrl+Option+Z** — on any HubSpot page: finds and clicks the phone icon (which, with auto-dial on, dials immediately).
- **Hangup-sound silencer** — mutes the Twilio SDK's default disconnect beep at the end of calls.
- **In-call disposition buttons** — a row of colored buttons on the in-call screen (No Contact, F – Offer And Accept, Schedule Callback, DQ – DNC, DQ – Wrong Avatar, DQ – Wrong Contact Information, DQ – Financial, DQ – Not Interested, Hangup – Intro). One click = end call + set that disposition. Also shows after the other party hangs up.
- **Idle auto-disposition** — if a finished call sits without a disposition for 60 seconds of no clicks, keypresses or scrolling, "No Disposition" is set automatically. Any interaction restarts the clock, and an open disposition menu holds it off. Tune or disable with `IDLE_DISPO_MS` in `hotkeys.js`.
- **HubSpot contact-name banner** — the full name of the contact being called, shown directly above the number in the popup. Read out of the active HubSpot tab (list row, record header, or tab title, in that order).
- **Dial over a live call** — asking to dial someone else while a call is up hangs up, dispositions the old call as "No Contact", then places the new call. If a call is somehow still live after the disposition, the new call is NOT placed, rather than risk dialing twice.
- **"From:" caller-ID picker** — pill in the bottom-left of the popup. Click to see every caller ID you can dial from and switch the preferred one.
- **Reload button** — pill in the bottom-right of the popup. Reloads the extension without opening `chrome://extensions`.
- **Custom background** — Rolex watch image behind the popup.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Pierrelifestyle10/dialer-superpatch/main/dialer-superpatch.sh)
```

Or clone and run:

```bash
git clone https://github.com/Pierrelifestyle10/dialer-superpatch.git
cd dialer-superpatch
bash dialer-superpatch.sh
```

Then open `chrome://extensions` and click ⟳ on Dialer.io so Chrome re-reads the patched files.

## Run Dialer.io unpacked

Chrome content-verifies Web Store extensions against a signed list of file hashes, so a patched store install eventually shows **"This extension may have been corrupted"**. Clicking Repair re-downloads clean files and wipes every patch. Run Dialer.io unpacked instead — unpacked extensions aren't content-verified:

1. Copy the patched extension somewhere stable, e.g. `~/Documents/dialer-io-ext/<version>_0`, and delete the `_metadata` folder from the copy.
2. `chrome://extensions` → **Remove** the Web Store Dialer.io. Two installs can't share one ID.
3. Turn on **Developer mode** → **Load unpacked** → select the copy.

The manifest ships a `key`, so the unpacked copy keeps the same extension ID. Expect to sign in to Dialer.io again: uninstalling clears the extension's stored data, and a same-ID reinstall doesn't restore it.

Chrome can no longer auto-update an unpacked extension, so patches survive — but Dialer.io upgrades become manual: install from the store, patch it, re-copy, remove the store copy.

```bash
DIALER_EXT_DIR=~/Documents/dialer-io-ext/<version>_0 bash dialer-superpatch.sh
```

## Revert

```bash
bash dialer-superpatch.sh --revert
```

Restores every `.superpatch.bak` — interceptor, service worker, manifest, offscreen bundle and popup HTML — and removes the injected `hotkeys.js`.

## Re-running

The script is idempotent and safe to re-run. Every step checks for its own marker first and skips if it's already applied.

## What gets patched

| File | Change |
|---|---|
| `hotkeys.js` (new) | Everything in the popup: dispositions, pills, name banner, idle auto-dispo, dial-over-live-call, background |
| `src/ui/popup/index.html` | Loads `hotkeys.js` |
| `assets/interceptor.ts-*.js` | Auto-dial on click (hostname-gated to HubSpot) + Ctrl+Option+Z |
| `assets/index.ts-*.js` | Startup tab injection filtered to HubSpot — the service worker otherwise pushes the interceptor into **every open tab**, ignoring the manifest's match patterns |
| `manifest.json` | `content_scripts.matches` restricted to HubSpot; `_execute_action` command for the popup shortcut |
| `assets/offscreen-*.js` | Hangup-beep silencer |

Three independent layers keep phone numbers from dialing outside HubSpot: the content script isn't registered for other sites, the startup injection skips their tabs, and the click handler itself checks the hostname before dialing.

## Caveat
On HubSpot, a stray click on any phone number IS a real outbound call. Don't run this on a shared machine where that would surprise someone.
