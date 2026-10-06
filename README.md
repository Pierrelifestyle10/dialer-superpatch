# dialer-superpatch

One-shot installer that applies our Dialer.io extension customizations on macOS + Google Chrome.

## What it installs
- **Auto-dial** — clicking any phone number (or the "Call with device" icon on hover in HubSpot) places the call immediately. No second click in the popup.
- **Ctrl+Option+X** — in the Dialer.io popup: End call → Set Disposition → No Contact.
- **Ctrl+Option+Z** — on any HubSpot page: finds and clicks the phone icon (which, with auto-dial on, dials immediately).
- **Hangup-sound silencer** — mutes the Twilio SDK's default disconnect beep at the end of calls.
- **In-call disposition buttons** — a row of colored buttons on the in-call screen (F – Offer And Accept, Schedule Callback, DQ – DNC, DQ – Wrong Avatar, DQ – Wrong Contact Information, DQ – Financial, DQ – Not Interested, Hangup – Intro). One click = end call + set that disposition. Also shows after the other party hangs up.
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

## Revert

```bash
bash dialer-superpatch.sh --revert
```

Restores every `.superpatch.bak` and removes the injected `hotkeys.js`.

## Re-running

The script is idempotent and safe to re-run. Chrome auto-updates Dialer.io in the background, which wipes the patches — re-run the script after each update.

## Unpacked installs

If Dialer.io is loaded as an unpacked extension (Developer Mode), point the script at the folder:

```bash
DIALER_EXT_DIR=/path/to/dialer-io-ext/<version>_0 bash dialer-superpatch.sh
```

## Caveat
Auto-dial means a stray click on any phone number in HubSpot IS a real outbound call. Don't run this on a shared machine where that would surprise someone.
