#!/usr/bin/env bash
#
# dialer-superpatch.sh
# --------------------
# One-shot installer that applies ALL our customizations to the Dialer.io
# Chrome extension on this machine:
#
#   1. Auto-dial:  clicking any intercepted phone number (or the "Call with
#      device" icon on hover in HubSpot) DIALS IMMEDIATELY. No more "click,
#      then click Call again in the popup."
#
#   2. Ctrl+Option+X:  hang up the current call → open the disposition menu
#      → pick "No Contact". Fires when the Dialer.io popup has focus.
#
#   3. Ctrl+Option+Z:  finds and clicks the phone icon on whatever HubSpot
#      page you're currently looking at, which (thanks to #1) auto-dials.
#      Registered inside the interceptor content script, so it fires while
#      HubSpot has focus — not just the popup.
#
# Platforms: macOS + Google Chrome. Idempotent. Reversible (--revert).
#
# Usage
#   chmod +x dialer-superpatch.sh
#   ./dialer-superpatch.sh                 # install everything
#   ./dialer-superpatch.sh --revert        # restore .bak backups
#
#   # Unpacked/Developer-mode install? Point at the extension folder:
#   DIALER_EXT_DIR=/path/to/dialer-io-ext/<version>_0 ./dialer-superpatch.sh
#
# After running, open chrome://extensions and click ⟳ on Dialer.io so
# Chrome reloads the edited files.
#
# WARNING: with auto-dial on, a stray click on any intercepted phone number
# IS a real outbound call. Also, Chrome auto-updates the extension in the
# background — re-run this script after each Dialer.io release.

set -euo pipefail

CHROME_BASE="${CHROME_BASE:-$HOME/Library/Application Support/Google/Chrome}"
ACTION="${1:-install}"
DIALER_EXT_DIR="${DIALER_EXT_DIR:-${2:-}}"

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# --- discovery -------------------------------------------------------------

find_manifests() {
  find "$CHROME_BASE"/*/Extensions -mindepth 3 -maxdepth 3 -name manifest.json 2>/dev/null || true
}

is_dialer() {
  grep -q '"name"[[:space:]]*:[[:space:]]*"Dialer.io"' "$1" 2>/dev/null
}

enumerate_targets() {
  if [[ -n "$DIALER_EXT_DIR" ]]; then
    printf '%s\n' "$DIALER_EXT_DIR/manifest.json"
    return
  fi
  find_manifests
}

find_interceptor_bundle() {
  # Filename hash rotates across releases (interceptor.ts-<hash>.js), so
  # match by content: the real bundle references SetContactPhoneNumber.
  # Exclude the loader shim. `|| true` on both greps so a no-match doesn't
  # abort the script under set -e / pipefail.
  local ext_dir="$1"
  { grep -l 'SetContactPhoneNumber' "$ext_dir"/assets/interceptor.ts-*.js 2>/dev/null || true; } \
    | { grep -v -- '-loader-' || true; } \
    | head -n1
}

find_popup_html() {
  local ext_dir="$1"
  local candidate="$ext_dir/src/ui/popup/index.html"
  [[ -f "$candidate" ]] && echo "$candidate"
}

find_offscreen_bundle() {
  # Filename hash rotates across releases (offscreen-<hash>.js). Match by
  # content: the offscreen bundle references Twilio Device construction
  # (`new o(t,r)` in this build's minified form). `|| true` keeps a no-match
  # grep from killing the script under set -e / pipefail.
  local ext_dir="$1"
  { grep -l 'new o(t,r)' "$ext_dir"/assets/offscreen-*.js 2>/dev/null || true; } | head -n1
}

# --- hotkeys.js payload (dropped into the extension root) ------------------

write_hotkeys_js() {
  local dest="$1"
  # Keep this heredoc in sync with hotkeys.js in the working extension folder.
  cat > "$dest" <<'HOTKEYS_JS_EOF'
// Dialer.io in-popup hotkeys.
// Ctrl+Shift+X: End call -> Set disposition -> No Contact.

(() => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  const visible = (el) => {
    if (!el) return false;
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return false;
    const s = getComputedStyle(el);
    return s.visibility !== "hidden" && s.display !== "none" && s.opacity !== "0";
  };

  const findByText = (pattern) => {
    const re = new RegExp(pattern, "i");
    const tags = 'button, [role="button"], [role="option"], [role="menuitem"], li, div, span';
    return [...document.querySelectorAll(tags)].find((el) => {
      if (!visible(el)) return false;
      const own = (el.textContent || "").trim();
      if (!re.test(own)) return false;
      return ![...el.querySelectorAll("*")].some(
        (c) => visible(c) && re.test((c.textContent || "").trim())
      );
    }) || null;
  };

  const findByAria = (pattern) => {
    const re = new RegExp(pattern, "i");
    return [...document.querySelectorAll('button, [role="button"]')].find((el) => {
      if (!visible(el)) return false;
      return (
        re.test(el.getAttribute("aria-label") || "") ||
        re.test(el.getAttribute("title") || "")
      );
    }) || null;
  };

  const click = (el) => {
    el.scrollIntoView({ block: "center" });
    for (const t of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
      el.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, view: window }));
    }
  };

  const waitFor = async (fn, timeout = 4000) => {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const el = fn();
      if (el) return el;
      await sleep(80);
    }
    return null;
  };

  // Hang up (if a call is live) and set a specific disposition. `matchPattern`
  // is a case-insensitive regex fragment matched against the disposition-menu
  // entry's own text; `searchLabel` is what gets typed into the menu's search
  // box to narrow the list first (make it a substring of the target dispo).
  //
  // Guarded so a second click (another dispo button, or a shortcut mid-flow)
  // cannot re-enter and race the first flow. Guard is cleared on completion
  // or thrown error.
  let dispoFlowRunning = false;
  async function dispositionFlow(matchPattern, searchLabel) {
    if (dispoFlowRunning) {
      console.log("[hotkeys] disposition flow already running — ignoring click");
      return;
    }
    dispoFlowRunning = true;
    try {
      return await _dispositionFlowImpl(matchPattern, searchLabel);
    } finally {
      dispoFlowRunning = false;
    }
  }
  async function _dispositionFlowImpl(matchPattern, searchLabel) {
    console.log("[hotkeys] disposition flow →", searchLabel);

    let hangup = findByAria("hang|end call|^end$|hangup");
    if (!hangup) {
      hangup = [...document.querySelectorAll("button")].find((b) => {
        if (!visible(b)) return false;
        const bg = getComputedStyle(b).backgroundColor;
        const m = bg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);
        if (!m) return false;
        const [r, g, bl] = [+m[1], +m[2], +m[3]];
        return r > 180 && g < 130 && bl < 130;
      });
    }
    if (hangup) {
      click(hangup);
      console.log("[hotkeys] hang-up clicked");
    } else {
      console.log("[hotkeys] no hang-up button — assuming call already ended");
    }

    const setDispoText = await waitFor(() => findByText("set disposition|^disposition$"), 5000);
    if (!setDispoText) {
      console.warn("[hotkeys] Set Disposition button never appeared");
      return;
    }
    const setDispo = setDispoText.closest('button, [role="button"]') || setDispoText;
    click(setDispo);

    const search = await waitFor(
      () => document.querySelector('input[placeholder*="Search" i], input[type="search"]'),
      2000
    );
    if (search) {
      const setter = Object.getOwnPropertyDescriptor(
        window.HTMLInputElement.prototype,
        "value"
      ).set;
      setter.call(search, searchLabel);
      search.dispatchEvent(new Event("input", { bubbles: true }));
      search.dispatchEvent(new Event("change", { bubbles: true }));
      await sleep(150);
    }

    // Find the matching dispo entry INSIDE the dialer's own menu — skip our
    // injected button row, whose button text happens to equal the dispo name.
    // Without this guard, clicking "DQ - DNC" would re-match our own button
    // and loop.
    const findDispoOption = (pattern) => {
      const re = new RegExp(pattern, "i");
      const tags = '[role="option"], [role="menuitem"], li, button, [role="button"], div, span';
      return [...document.querySelectorAll(tags)].find((el) => {
        if (el.closest("#" + DISPO_ROW_ID)) return false;
        if (!visible(el)) return false;
        const own = (el.textContent || "").trim();
        if (!re.test(own)) return false;
        return ![...el.querySelectorAll("*")].some(
          (c) => visible(c) && re.test((c.textContent || "").trim())
        );
      }) || null;
    };

    const dispoText = await waitFor(() => findDispoOption(matchPattern), 2000);
    if (!dispoText) {
      console.warn("[hotkeys] disposition not found:", matchPattern);
      return;
    }
    const dispo =
      dispoText.closest('[role="option"], [role="menuitem"], li, button, [role="button"]') ||
      dispoText;
    click(dispo);
    console.log("[hotkeys] disposition selected:", searchLabel);
  }

  // Ctrl+Option+X shortcut target — preserved as its own function name.
  async function noContactFlow() {
    return dispositionFlow("^no contact$", "No Contact");
  }

  // In-call disposition buttons. Left-to-right in this array = left-to-right
  // on screen. Colors chosen for at-a-glance meaning; edit as you like.
  const DISPO_BUTTONS = [
    { label: "F - Offer And Accept",         match: "^f\\s*-\\s*offer and accept$",             bg: "#16a34a" }, // green — win
    { label: "Schedule Callback",            match: "^schedule callback$",                      bg: "#2563eb" }, // blue — followup
    { label: "DQ - DNC",                     match: "^dq\\s*-\\s*dnc$",                         bg: "#7f1d1d" }, // dark red — do-not-contact
    { label: "DQ - Wrong Avatar",            match: "^dq\\s*-\\s*wrong avatar$",                bg: "#4b5563" }, // slate — neutral DQ
    { label: "DQ - Wrong Contact Information", match: "^dq\\s*-\\s*wrong contact information$", bg: "#0d9488" }, // teal — wrong-data DQ
    { label: "DQ - Financial",               match: "^dq\\s*-\\s*financial$",                   bg: "#d97706" }, // amber — budget DQ
    { label: "DQ - Not Interested",          match: "^dq\\s*-\\s*not interested$",              bg: "#ea580c" }, // orange — soft DQ
    { label: "Hangup - Intro",               match: "^hangup\\s*-\\s*intro$",                   bg: "#7c3aed" }, // purple — early bail
  ];

  const DISPO_ROW_ID = "__dispo_buttons";

  function buildDispoRow() {
    const row = document.createElement("div");
    row.id = DISPO_ROW_ID;
    row.style.cssText =
      "display:flex;flex-wrap:wrap;gap:6px;padding:8px 12px;justify-content:center;box-sizing:border-box;";
    for (const dispo of DISPO_BUTTONS) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.textContent = dispo.label;
      btn.style.cssText =
        "background:" + dispo.bg + ";color:#fff;border:none;border-radius:6px;" +
        "padding:8px 10px;font-size:12px;font-weight:600;cursor:pointer;" +
        "flex:1 1 auto;min-width:100px;line-height:1.1;";
      btn.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        dispositionFlow(dispo.match, dispo.label);
      });
      row.appendChild(btn);
    }
    return row;
  }

  // Mount the button row whenever the dialer is in a state where a dispo
  // decision is possible — either a call is live (hangup button visible)
  // OR the call has ended and the dialer is waiting for a disposition
  // (Set Disposition button visible, no hangup button). Without the second
  // case, the row disappears the moment the other party hangs up, which
  // leaves the user with no way to click a dispo. Runs on a 500ms poll
  // because React re-renders can wipe out our injected DOM.
  function syncDispoRow() {
    const hangup = findByAria("hang|end call|^end$|hangup");
    const setDispoText = hangup
      ? null
      : findByText("set disposition|^disposition$");
    const anchorEl =
      hangup ||
      (setDispoText
        ? setDispoText.closest('button, [role="button"]') || setDispoText
        : null);

    const existing = document.getElementById(DISPO_ROW_ID);

    if (!anchorEl) {
      if (existing) existing.remove();
      return;
    }
    if (existing) return;

    // Walk up from the anchor to the row that contains it (Mute/Keypad/
    // Hangup during a call, or just Set Disposition after). First ancestor
    // holding at least 1 button-ish child wins; the "contains at least N"
    // bar is relaxed to 1 because the post-call row may only have the
    // Set Disposition button.
    let controlRow = anchorEl.parentElement;
    for (let i = 0; i < 5 && controlRow; i++) {
      const buttons = controlRow.querySelectorAll("button, [role='button']");
      if (buttons.length >= 1) break;
      controlRow = controlRow.parentElement;
    }
    if (!controlRow || !controlRow.parentElement) return;

    controlRow.parentElement.insertBefore(buildDispoRow(), controlRow);
  }

  setInterval(syncDispoRow, 500);

  // Fixed-position Reload button in the bottom-right corner of the popup.
  // Calling chrome.runtime.reload() restarts the whole extension (service
  // worker, content scripts, popup) — same as hitting ⟳ on
  // chrome://extensions, without having to navigate there. The popup
  // window closes as a side effect; click the Dialer.io toolbar icon to
  // reopen it.
  const RELOAD_BTN_ID = "__reload_btn";
  function ensureReloadButton() {
    if (document.getElementById(RELOAD_BTN_ID)) return;
    if (!document.body) return;
    const btn = document.createElement("button");
    btn.id = RELOAD_BTN_ID;
    btn.type = "button";
    btn.textContent = "⟲ Reload";
    btn.title = "Reload the Dialer.io extension";
    btn.style.cssText =
      "position:fixed;bottom:8px;right:8px;z-index:2147483647;" +
      "background:#374151;color:#fff;border:none;border-radius:6px;" +
      "padding:4px 10px;font-size:11px;font-weight:600;cursor:pointer;" +
      "opacity:0.55;transition:opacity 120ms;line-height:1.2;";
    btn.addEventListener("mouseenter", () => (btn.style.opacity = "1"));
    btn.addEventListener("mouseleave", () => (btn.style.opacity = "0.55"));
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      try {
        chrome.runtime.reload();
      } catch (err) {
        console.warn("[hotkeys] reload failed:", err);
      }
    });
    document.body.appendChild(btn);
  }
  setInterval(ensureReloadButton, 1000);

  // "From: <number>" picker in the bottom-left corner of the popup.
  // Reads the agent's available caller IDs via dialer:query-call-origins and
  // the current preferred one via dialer:query-preferred-call-origin; clicking
  // the pill opens a dropdown that lists every caller ID the agent can dial
  // from. Picking one calls dialer:set-preferred-call-origin, same as the
  // dialer's own settings UI.
  const FROM_PILL_ID = "__from_pill";
  const FROM_DROPDOWN_ID = "__from_dropdown";

  async function sendCommand(key, input) {
    // Matches the shape used by assets/commandbus-*.js: envelope is
    // {command: {key, input}}, response is {output}|{error}. The service
    // worker may be asleep on first try (returns undefined); retry briefly
    // the same way the dialer's own command bus does.
    let lastErr;
    for (let i = 0; i < 10; i++) {
      try {
        const resp = await chrome.runtime.sendMessage({ command: { key, input } });
        if (resp === undefined) {
          await new Promise((r) => setTimeout(r, 50));
          continue;
        }
        if (typeof resp !== "object" || !resp) throw new Error("invalid response");
        if ("error" in resp) throw resp.error;
        return "output" in resp ? resp.output : undefined;
      } catch (err) {
        lastErr = err;
      }
    }
    throw lastErr || new Error("no response after retries");
  }

  const formatPhone = (num) => {
    if (!num) return "";
    if (num.startsWith("+1") && num.length === 12) {
      return "+1 (" + num.slice(2, 5) + ") " + num.slice(5, 8) + "-" + num.slice(8);
    }
    return num;
  };

  async function fetchCallOrigins() {
    try {
      const [origins, preferred] = await Promise.all([
        sendCommand("dialer:query-call-origins"),
        sendCommand("dialer:query-preferred-call-origin"),
      ]);
      return {
        origins: Array.isArray(origins) ? origins : [],
        preferred: preferred || null,
      };
    } catch (err) {
      console.warn("[hotkeys] fetchCallOrigins failed:", err);
      return { origins: [], preferred: null };
    }
  }

  async function refreshFromPill() {
    const pill = document.getElementById(FROM_PILL_ID);
    if (!pill) return;
    const { origins, preferred } = await fetchCallOrigins();
    const num =
      preferred?.callerId?.phoneNumber || origins[0]?.callerId?.phoneNumber;
    if (!num) {
      pill.textContent = "From: —";
      pill.disabled = true;
      pill.style.cursor = "default";
      return;
    }
    // Always clickable (even with 1 origin, so you get visible feedback and
    // can confirm which number is active). Chevron shown only when there's
    // more than one to pick from.
    const chevron = origins.length > 1 ? " ▾" : "";
    pill.textContent = "From: " + formatPhone(num) + chevron;
    pill.disabled = false;
    pill.style.cursor = "pointer";
    pill.dataset.count = String(origins.length);
  }

  async function toggleFromDropdown() {
    console.log("[hotkeys] From pill clicked");
    const existing = document.getElementById(FROM_DROPDOWN_ID);
    if (existing) {
      existing.remove();
      return;
    }

    const pill = document.getElementById(FROM_PILL_ID);
    if (!pill) return;
    const rect = pill.getBoundingClientRect();

    // Mount the dropdown shell immediately so clicks always get *some*
    // visible feedback, then fill in the content once we have data.
    const dd = document.createElement("div");
    dd.id = FROM_DROPDOWN_ID;
    dd.style.cssText =
      "position:fixed;" +
      "bottom:" + (window.innerHeight - rect.top + 4) + "px;" +
      "left:" + rect.left + "px;" +
      "z-index:2147483647;" +
      "background:#1f2937;color:#fff;border:1px solid #374151;" +
      "border-radius:6px;padding:4px 0;font-size:12px;" +
      "min-width:" + Math.max(220, rect.width) + "px;" +
      "max-height:260px;overflow-y:auto;" +
      "box-shadow:0 4px 12px rgba(0,0,0,0.4);";

    const placeholder = document.createElement("div");
    placeholder.style.cssText = "padding:8px 12px;color:#9ca3af;";
    placeholder.textContent = "Loading caller IDs…";
    dd.appendChild(placeholder);
    document.body.appendChild(dd);

    let origins = [];
    let preferred = null;
    try {
      const r = await fetchCallOrigins();
      origins = r.origins;
      preferred = r.preferred;
      console.log("[hotkeys] origins:", origins.length, "preferred:", preferred?.callerId?.phoneNumber || "(none)");
    } catch (err) {
      console.warn("[hotkeys] dropdown fetch failed:", err);
    }

    dd.innerHTML = "";

    if (origins.length === 0) {
      const empty = document.createElement("div");
      empty.style.cssText = "padding:8px 12px;color:#fca5a5;";
      empty.textContent =
        "No caller IDs available. Check that you're signed in to Dialer.io.";
      dd.appendChild(empty);
    } else {
      const preferredPhone = preferred?.callerId?.phoneNumber;
      for (const origin of origins) {
        const phone = origin.callerId?.phoneNumber;
        if (!phone) continue;
        const country = origin.callerId?.countryCode || "";
        const orgName = origin.organization?.name || "";
        const row = document.createElement("button");
        row.type = "button";
        const isCurrent = phone === preferredPhone;
        row.style.cssText =
          "display:block;width:100%;text-align:left;border:none;" +
          "color:#fff;padding:6px 12px;cursor:pointer;font-size:12px;" +
          "line-height:1.3;background:" + (isCurrent ? "#2563eb" : "transparent") + ";" +
          "font-weight:" + (isCurrent ? "700" : "400") + ";";
        const parts = [formatPhone(phone)];
        if (country) parts.push("(" + country + ")");
        if (orgName) parts.push("— " + orgName);
        row.textContent = parts.join(" ");
        row.addEventListener("mouseenter", () => {
          if (!isCurrent) row.style.background = "#374151";
        });
        row.addEventListener("mouseleave", () => {
          if (!isCurrent) row.style.background = "transparent";
        });
        row.addEventListener("click", async (e) => {
          e.preventDefault();
          e.stopPropagation();
          try {
            await sendCommand("dialer:set-preferred-call-origin", phone);
          } catch (err) {
            console.warn("[hotkeys] set preferred failed:", err);
          }
          dd.remove();
          await refreshFromPill();
        });
        dd.appendChild(row);
      }
    }

    // Dismiss on any click outside the dropdown or pill.
    const dismiss = (e) => {
      if (dd.contains(e.target) || pill.contains(e.target)) return;
      dd.remove();
      document.removeEventListener("click", dismiss, true);
    };
    setTimeout(() => document.addEventListener("click", dismiss, true), 0);
  }

  function ensureFromPill() {
    if (document.getElementById(FROM_PILL_ID)) return;
    if (!document.body) return;
    const pill = document.createElement("button");
    pill.id = FROM_PILL_ID;
    pill.type = "button";
    pill.textContent = "From: loading…";
    pill.style.cssText =
      "position:fixed;bottom:8px;left:8px;z-index:2147483646;" +
      "background:#374151;color:#fff;border:none;border-radius:6px;" +
      "padding:4px 10px;font-size:11px;font-weight:600;cursor:pointer;" +
      "opacity:0.55;transition:opacity 120ms;line-height:1.2;" +
      "max-width:260px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;";
    pill.addEventListener("mouseenter", () => (pill.style.opacity = "1"));
    pill.addEventListener("mouseleave", () => {
      if (!document.getElementById(FROM_DROPDOWN_ID)) pill.style.opacity = "0.55";
    });
    pill.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      toggleFromDropdown();
    });
    document.body.appendChild(pill);
    refreshFromPill();
  }

  setInterval(ensureFromPill, 1000);

  // Custom background image for the popup. Data-URL so it stays
  // self-contained in hotkeys.js (and in the shareable superpatch
  // heredoc). A dark rgba overlay on #root keeps the dialer's text
  // readable without hiding the image completely.
  const BG_DATA_URL = "data:image/jpeg;base64,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";
  const BG_STYLE_ID = "__bg_style";
  function ensureBackground() {
    if (document.getElementById(BG_STYLE_ID)) return;
    if (!document.head) return;
    const style = document.createElement("style");
    style.id = BG_STYLE_ID;
    style.textContent =
      "html, body {" +
        "background: #000 url('" + BG_DATA_URL + "') center/cover no-repeat fixed !important;" +
      "}" +
      "#root {" +
        "background-color: rgba(10, 15, 25, 0.72) !important;" +
        "min-height: 100vh;" +
      "}";
    document.head.appendChild(style);
  }
  setInterval(ensureBackground, 1000);

  // Periodic refresh so the pill tracks changes made in the dialer's own
  // settings UI (another tab, another device).
  setInterval(refreshFromPill, 10000);

  // "⚡ Call Now" button — appears whenever the dialer's own "Call from ..."
  // button is on screen (i.e., a contact number is loaded and ready to dial).
  // Clicking it skips the "Call from" picker entirely: queries the loaded
  // contact number, picks the country-matched caller ID (US for +1/+61,
  // UK otherwise, with fallback to the other if the first errors out), and
  // fires workspace:initiate-outbound-call directly.
  const QUICK_CALL_BTN_ID = "__quick_call_btn";

  async function doQuickCall() {
    const btn = document.getElementById(QUICK_CALL_BTN_ID);
    if (btn) { btn.disabled = true; btn.style.opacity = "0.6"; }
    try {
      let phoneNumber;
      try {
        phoneNumber = await sendCommand("dialer:query-contact-phone-number");
      } catch (err) {
        console.warn("[hotkeys] quick call: query phone failed", err);
        return;
      }
      if (!phoneNumber) {
        alert("No contact phone number is loaded to call.");
        return;
      }
      let origins = [];
      try {
        const r = await sendCommand("dialer:query-call-origins");
        if (Array.isArray(r)) origins = r;
      } catch (err) {
        console.warn("[hotkeys] quick call: query origins failed", err);
      }
      const useUs = phoneNumber.startsWith("+1") || phoneNumber.startsWith("+61");
      const want = useUs ? "US" : "GB";
      const primary = origins.find((o) => o && o.callerId && o.callerId.countryCode === want);
      const fallback = origins.find((o) => o && o.callerId && o.callerId.countryCode !== want);
      const order = [];
      for (const x of [primary, fallback]) if (x && !order.includes(x)) order.push(x);
      if (order.length === 0) {
        try {
          const pref = await sendCommand("dialer:query-preferred-call-origin");
          if (pref) order.push(pref);
        } catch (_) {}
        if (order.length === 0 && origins.length) order.push(origins[0]);
      }

      let placed = false;
      let lastErr = null;
      for (const cand of order) {
        try {
          try {
            await sendCommand("dialer:set-preferred-call-origin", cand.callerId.phoneNumber);
          } catch (_) {}
          await sendCommand("workspace:initiate-outbound-call", {
            callOrigin: cand,
            contactPhoneNumber: phoneNumber,
          });
          placed = true;
          console.log("[hotkeys] quick call placed via", cand.callerId.phoneNumber, "->", phoneNumber);
          break;
        } catch (err) {
          lastErr = err;
          console.warn("[hotkeys] quick call via", cand.callerId && cand.callerId.phoneNumber, "failed:", err);
        }
      }
      if (!placed) {
        const msg = lastErr && (lastErr.message || String(lastErr));
        alert("Dialer.io could not place a call to " + phoneNumber + (msg ? "\n\n" + msg : ""));
      }
    } finally {
      const btn2 = document.getElementById(QUICK_CALL_BTN_ID);
      if (btn2) { btn2.disabled = false; btn2.style.opacity = "1"; }
    }
  }

  // Visually distinct helpers for the two buttons:
  //   • Dialer.io's own "Call from ..." button — we recolor it PURPLE
  //     (same violet as our Hangup-Intro dispo button) so users can tell
  //     at a glance that it's the slow path (opens the caller-ID picker).
  //   • Our injected "Call" button — GREEN, styled to match the dialer's
  //     original call-button appearance, sits right next to "Call from...".
  //     Clicking it skips the picker and dials via the country-matched
  //     caller ID directly.
  const QUICK_CALL_GREEN = "#22c55e";
  const QUICK_CALL_GREEN_HOVER = "#16a34a";
  const CALL_FROM_PURPLE = "#7c3aed";

  function syncQuickCallBtn() {
    const callFromText = findByText("^call from");
    const anchor = callFromText
      ? callFromText.closest('button, [role="button"]') || callFromText
      : null;
    const existing = document.getElementById(QUICK_CALL_BTN_ID);

    if (!anchor) {
      if (existing) existing.remove();
      return;
    }

    // Recolor the dialer's own "Call from..." button to purple. React may
    // overwrite inline styles on re-render, which is why this runs on the
    // same 500ms poll as the injection.
    anchor.style.setProperty("background", CALL_FROM_PURPLE, "important");
    anchor.style.setProperty("background-color", CALL_FROM_PURPLE, "important");
    anchor.style.setProperty("background-image", "none", "important");

    // Only re-inject our button when it's missing OR its parent changed
    // (React may have moved the surrounding row).
    if (existing && existing.parentNode === anchor.parentNode) return;
    if (existing) existing.remove();

    const parent = anchor.parentNode;
    if (!parent) return;

    const btn = document.createElement("button");
    btn.id = QUICK_CALL_BTN_ID;
    btn.type = "button";
    btn.textContent = "☎ Call";
    btn.title =
      "Dial immediately with the country-matched caller ID " +
      "(US for +1/+61, UK otherwise). Skips the Call from picker.";
    const base =
      "background:" + QUICK_CALL_GREEN + " !important;" +
      "color:#fff !important;border:none !important;" +
      "border-radius:12px !important;" +
      "padding:12px 24px !important;" +
      "font-size:16px !important;font-weight:600 !important;" +
      "cursor:pointer !important;" +
      "display:inline-flex !important;align-items:center !important;" +
      "gap:8px !important;line-height:1.2 !important;" +
      "margin-left:8px !important;" +
      "box-shadow:0 2px 6px rgba(0,0,0,0.25) !important;" +
      "transition:background 100ms !important;";
    btn.style.cssText = base;
    btn.addEventListener("mouseenter", () =>
      btn.style.setProperty("background", QUICK_CALL_GREEN_HOVER, "important")
    );
    btn.addEventListener("mouseleave", () =>
      btn.style.setProperty("background", QUICK_CALL_GREEN, "important")
    );
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      doQuickCall();
    });

    // Insert immediately AFTER the Call from button so they sit side by
    // side (the picker is slow path on the left/original, our quick call
    // is the fast path on the right).
    if (anchor.nextSibling) {
      parent.insertBefore(btn, anchor.nextSibling);
    } else {
      parent.appendChild(btn);
    }
  }

  setInterval(syncQuickCallBtn, 500);

  // "📱 FaceTime" button — appears alongside the Dialer.io "Call from ..."
  // and our "Call" button when a contact number is loaded. Opens the
  // currently-loaded number via the macOS facetime-audio:// URL scheme
  // (Chrome prompts to open FaceTime; checking "Always allow" skips the
  // prompt on future clicks).
  //
  // Sky-blue so it's visually distinct from the green Call and purple
  // Call-from buttons.
  const FACETIME_BTN_ID = "__facetime_btn";
  const FACETIME_BLUE = "#0ea5e9";
  const FACETIME_BLUE_HOVER = "#0284c7";

  async function doFaceTime() {
    let phoneNumber;
    try {
      phoneNumber = await sendCommand("dialer:query-contact-phone-number");
    } catch (err) {
      console.warn("[hotkeys] facetime: query phone failed", err);
      return;
    }
    if (!phoneNumber) {
      alert("No contact phone number is loaded.");
      return;
    }
    const url = "facetime-audio://" + encodeURIComponent(phoneNumber);
    try {
      // Open in a background tab so the popup/current tab aren't disturbed;
      // the OS handler takes over almost immediately. Close the stub tab
      // once FaceTime has had a chance to launch.
      chrome.tabs.create({ url, active: false }, (tab) => {
        if (chrome.runtime.lastError) {
          console.warn("[hotkeys] facetime tab create failed:", chrome.runtime.lastError);
          return;
        }
        if (tab && tab.id) {
          setTimeout(() => {
            try { chrome.tabs.remove(tab.id); } catch (_) {}
          }, 1500);
        }
      });
      console.log("[hotkeys] facetime audio →", phoneNumber);
    } catch (err) {
      console.warn("[hotkeys] facetime failed:", err);
      alert("Could not launch FaceTime: " + (err.message || err));
    }
  }

  function syncFaceTimeBtn() {
    const callFromText = findByText("^call from");
    const anchor = callFromText
      ? callFromText.closest('button, [role="button"]') || callFromText
      : null;
    const existing = document.getElementById(FACETIME_BTN_ID);
    if (!anchor) {
      if (existing) existing.remove();
      return;
    }
    // Place it after our quick-call button if that's present; otherwise
    // directly after the Call from button.
    const quickCall = document.getElementById(QUICK_CALL_BTN_ID);
    const insertAfter = quickCall || anchor;
    const parent = insertAfter.parentNode;
    if (!parent) return;
    if (existing && existing.parentNode === parent) return;
    if (existing) existing.remove();

    const btn = document.createElement("button");
    btn.id = FACETIME_BTN_ID;
    btn.type = "button";
    btn.textContent = "\uD83D\uDCF1 FaceTime";
    btn.title = "Open the loaded number in FaceTime Audio (macOS).";
    btn.style.cssText =
      "background:" + FACETIME_BLUE + " !important;" +
      "color:#fff !important;border:none !important;" +
      "border-radius:12px !important;" +
      "padding:12px 24px !important;" +
      "font-size:16px !important;font-weight:600 !important;" +
      "cursor:pointer !important;" +
      "display:inline-flex !important;align-items:center !important;" +
      "gap:8px !important;line-height:1.2 !important;" +
      "margin-left:8px !important;" +
      "box-shadow:0 2px 6px rgba(0,0,0,0.25) !important;" +
      "transition:background 100ms !important;";
    btn.addEventListener("mouseenter", () =>
      btn.style.setProperty("background", FACETIME_BLUE_HOVER, "important")
    );
    btn.addEventListener("mouseleave", () =>
      btn.style.setProperty("background", FACETIME_BLUE, "important")
    );
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      doFaceTime();
    });
    if (insertAfter.nextSibling) {
      parent.insertBefore(btn, insertAfter.nextSibling);
    } else {
      parent.appendChild(btn);
    }
  }

  setInterval(syncFaceTimeBtn, 500);

  // Keep the dialed number in the dialer after a disposition is set, so
  // you can see what you just called (and redial it) without re-loading
  // the contact. The dialer normally clears it on DispositionCall; this
  // polls dialer:query-contact-phone-number and re-sets the number via
  // dialer:set-contact-phone-number the moment it transitions from a
  // real value to null. If you intentionally clear the field via the UI
  // and want to type a new number, just type over it — the restore only
  // fires once per clear, not continuously.
  let __lastDialedPhone = null;
  let __lastSeenPhone = null;
  async function persistPhoneNumber() {
    let current;
    try {
      current = await sendCommand("dialer:query-contact-phone-number");
    } catch (err) {
      return;
    }
    if (current) {
      __lastDialedPhone = current;
      __lastSeenPhone = current;
      return;
    }
    if (__lastDialedPhone && __lastSeenPhone !== null) {
      __lastSeenPhone = null;
      try {
        await sendCommand("dialer:set-contact-phone-number", __lastDialedPhone);
        console.log("[hotkeys] restored contact number after clear:", __lastDialedPhone);
      } catch (err) {
        console.warn("[hotkeys] restore failed:", err);
      }
    }
  }
  setInterval(persistPhoneNumber, 500);


  // Reach into the user's active HubSpot tab and click the "Call with device"
  // phone icon (the receiver icon that appears next to the Phone Number
  // field on hover). Combined with the interceptor auto-dial patch, this
  // places the call in a single keystroke — no popup click needed.
  //
  // Silently no-ops if there's no active tab we can reach, or the tab has
  // no intercepted tel: link on it.
  async function clickHubSpotCallingIcon() {
    let tab;
    try {
      const win = await chrome.windows.getLastFocused({
        populate: true,
        windowTypes: ["normal"],
      });
      tab = win?.tabs?.find((t) => t.active);
    } catch (err) {
      console.warn("[hotkeys] getLastFocused failed:", err);
      return;
    }
    if (!tab?.id) {
      console.log("[hotkeys] no active normal-window tab to click into");
      return;
    }
    let results;
    try {
      results = await chrome.scripting.executeScript({
        target: { tabId: tab.id, allFrames: true },
        func: () => {
          // The interceptor tags every tel: link it claims with
          // data-telephony-handler. Prefer HubSpot's "Call with device" icon
          // over other tel: links on the page.
          const el =
            document.querySelector(
              'a[data-telephony-handler][href^="tel:"][aria-label*="Call" i]'
            ) ||
            document.querySelector('a[data-telephony-handler][href^="tel:"]');
          if (!el) return { clicked: false };
          el.click();
          return { clicked: true, href: el.getAttribute("href") };
        },
      });
    } catch (err) {
      console.warn("[hotkeys] executeScript failed:", err);
      return;
    }
    const hit = results?.find((r) => r?.result?.clicked);
    if (hit) {
      console.log("[hotkeys] clicked calling icon on tab", tab.id, hit.result.href);
    } else {
      console.log("[hotkeys] no calling icon found on tab", tab.id);
    }
  }

  document.addEventListener(
    "keydown",
    (e) => {
      console.log(
        `[hotkeys] keydown key=${JSON.stringify(e.key)} code=${e.code} alt=${e.altKey} ctrl=${e.ctrlKey} shift=${e.shiftKey} meta=${e.metaKey}`
      );
      if (
        e.ctrlKey &&
        e.altKey &&
        !e.metaKey &&
        !e.shiftKey &&
        e.code === "KeyX"
      ) {
        e.preventDefault();
        e.stopPropagation();
        noContactFlow();
      }
      if (
        e.ctrlKey &&
        e.altKey &&
        !e.metaKey &&
        !e.shiftKey &&
        e.code === "KeyZ"
      ) {
        e.preventDefault();
        e.stopPropagation();
        clickHubSpotCallingIcon();
      }
    },
    true
  );

  console.log(
    "[hotkeys] loaded — " +
      "Ctrl+Option+X = End call → Disposition → No Contact | " +
      "Ctrl+Option+Z = click HubSpot phone icon on active tab"
  );
})();
HOTKEYS_JS_EOF
}

# --- steps -----------------------------------------------------------------

install_hotkeys_js() {
  local ext_dir="$1"
  local dest="$ext_dir/hotkeys.js"
  if [[ -f "$dest" ]] && [[ ! -f "$dest.superpatch.bak" ]]; then
    cp "$dest" "$dest.superpatch.bak"
  fi
  write_hotkeys_js "$dest"
  log "  hotkeys.js installed → $(basename "$dest")"
}

revert_hotkeys_js() {
  local ext_dir="$1"
  local dest="$ext_dir/hotkeys.js"
  if [[ -f "$dest.superpatch.bak" ]]; then
    mv "$dest.superpatch.bak" "$dest"
    log "  hotkeys.js reverted"
  elif [[ -f "$dest" ]]; then
    rm "$dest"
    log "  hotkeys.js removed (no prior version to restore)"
  fi
}

wire_hotkeys_into_popup() {
  local html="$1"
  if grep -q 'hotkeys\.js' "$html"; then
    log "  popup already references hotkeys.js"
    return 0
  fi
  cp "$html" "$html.superpatch.bak"
  # Insert `<script defer src="/hotkeys.js"></script>` right before </head>.
  perl -i -pe 's{</head>}{  <script defer src="/hotkeys.js"></script>\n  </head>}' "$html"
  if grep -q 'hotkeys\.js' "$html"; then
    log "  popup wired: <script defer src=\"/hotkeys.js\"> injected before </head>"
  else
    warn "  ERROR: could not find </head> in popup HTML — restoring backup"
    mv "$html.superpatch.bak" "$html"
    return 1
  fi
}

revert_popup_wiring() {
  local html="$1"
  if [[ -f "$html.superpatch.bak" ]]; then
    mv "$html.superpatch.bak" "$html"
    log "  popup wiring reverted"
  fi
}

patch_interceptor_autodial() {
  local file="$1"
  if grep -q 'workspace:initiate-outbound-call' "$file"; then
    log "  interceptor auto-dial: already patched"
    return 0
  fi
  [[ -f "$file.superpatch.bak" ]] || cp "$file" "$file.superpatch.bak"

  perl -i -0777 -pe '
    s/await\s+(\w+)\(\s*(\w+)\.SetContactPhoneNumber\s*,\s*(\w+)\s*\)\s*,\s*await\s+\1\(\s*(\w+)\.FocusUI\s*\)/await $1($2.SetContactPhoneNumber,$3);try{let __l=await $1(\x60dialer:query-call-origins\x60);if(!Array.isArray(__l))__l=[];let __us=$3.startsWith("+1")||$3.startsWith("+61");let __wc=__us?"US":"GB";let __p=__l.find(__o=>__o\&\&__o.callerId\&\&__o.callerId.countryCode===__wc);let __f=__l.find(__o=>__o\&\&__o.callerId\&\&__o.callerId.countryCode!==__wc);let __q=[];for(let __x of [__p,__f])if(__x\&\&!__q.includes(__x))__q.push(__x);if(__q.length===0){let __pr=await $1(\x60dialer:query-preferred-call-origin\x60);if(__pr)__q.push(__pr);else if(__l.length)__q.push(__l[0])}let __ok=false,__le=null;for(let __c of __q){try{try{await $1(\x60dialer:set-preferred-call-origin\x60,__c.callerId.phoneNumber)}catch(_){}await $1(\x60workspace:initiate-outbound-call\x60,{callOrigin:__c,contactPhoneNumber:$3});__ok=true;break}catch(__er){__le=__er}}if(!__ok\&\&__le)throw __le}catch(__e){throw __e}await $1($4.FocusUI)/g
  ' "$file"

  if grep -q 'workspace:initiate-outbound-call' "$file"; then
    log "  interceptor auto-dial: patched"
  else
    warn "  ERROR: auto-dial pattern not found in $file — restoring backup"
    mv "$file.superpatch.bak" "$file"
    return 1
  fi
}

patch_interceptor_hotkey() {
  local file="$1"
  if grep -q '__hk' "$file"; then
    log "  interceptor Ctrl+Option+Z hotkey: already installed"
    return 0
  fi
  [[ -f "$file.superpatch.bak" ]] || cp "$file" "$file.superpatch.bak"

  # Inject a keydown listener before the closing brace of the load() function,
  # right after the observer's unloadActions.push. Registers with the
  # existing unloadActions so hot-reloads don't stack listeners.
  perl -i -0777 -pe '
    s/,g\.push\(\(\)=>\{e\.disconnect\(\)\}\)\}function b\(e\)/,g.push(()=>{e.disconnect()});function __hk(k){if(k.ctrlKey\&\&k.altKey\&\&!k.metaKey\&\&!k.shiftKey\&\&k.code==="KeyZ"){k.preventDefault();k.stopPropagation();let el=document.querySelector(\x27a[data-telephony-handler][href^="tel:"][aria-label*="Call" i]\x27)||document.querySelector(\x27a[data-telephony-handler][href^="tel:"]\x27);if(el){el.click();a("hotkey Ctrl+Option+Z: clicked "+el.getAttribute("href"))}else{a("hotkey Ctrl+Option+Z: no calling icon on this page")}}}window.addEventListener("keydown",__hk,true);g.push(()=>window.removeEventListener("keydown",__hk,true))}function b(e)/
  ' "$file"

  if grep -q '__hk' "$file"; then
    log "  interceptor Ctrl+Option+Z hotkey: installed"
  else
    warn "  ERROR: hotkey injection pattern not found in $file"
    warn "         (variable names may differ in this build — file left unchanged)"
    return 1
  fi
}

patch_interceptor_cellclick() {
  local file="$1"
  if grep -q '__cl' "$file"; then
    log "  interceptor cell-click auto-dial: already installed"
    return 0
  fi
  [[ -f "$file.superpatch.bak" ]] || cp "$file" "$file.superpatch.bak"

  # Inject a capturing document.click handler AFTER the hotkey listener.
  # Only fires on plain left-clicks inside table cells (td/[role=cell]/
  # [role=gridcell]) whose text contains a phone-shaped substring starting
  # with +. Blocks HubSpot's row-navigation for those clicks and dials the
  # number instead. Depends on the auto-dial injection (uses the same
  # command-bus calls).
  perl -i -0777 -pe '
    s/g\.push\(\(\)=>window\.removeEventListener\("keydown",__hk,true\)\)\}function b\(e\)/g.push(()=>window.removeEventListener("keydown",__hk,true));async function __cl(ev){if(ev.button!==0||ev.ctrlKey||ev.metaKey||ev.shiftKey||ev.altKey)return;if(ev.target.closest(\x27a[data-telephony-handler][href^="tel:"]\x27))return;const cell=ev.target.closest(\x27td,[role="cell"],[role="gridcell"]\x27);if(!cell)return;const raw=((cell.textContent||"")+" "+(cell.getAttribute("aria-label")||"")).trim();const m=raw.match(\/(\\+\\d[\\d\\s\\-().]{6,}\\d)\/);if(!m)return;const digits=m[1].replace(\/[^\\d+]\/g,"");if(digits.replace(\/\\D\/g,"").length<7)return;ev.preventDefault();ev.stopPropagation();try{await r(o.SetContactPhoneNumber,digits);try{let k=await r("dialer:query-preferred-call-origin");if(!k){let ll=await r("dialer:query-call-origins");k=Array.isArray(ll)\&\&ll.length?ll[0]:null}if(k)await r("workspace:initiate-outbound-call",{callOrigin:k,contactPhoneNumber:digits})}catch(err){a(e(err),err)}await r(c.FocusUI);a("cell click auto-dial: "+digits)}catch(err){a(e(err),err)}}document.addEventListener("click",__cl,true);g.push(()=>document.removeEventListener("click",__cl,true))}function b(e)/
  ' "$file"

  if grep -q '__cl' "$file"; then
    log "  interceptor cell-click auto-dial: installed"
  else
    warn "  ERROR: cell-click injection pattern not found in $file"
    warn "         (depends on hotkey injection — run this step after that one)"
    return 1
  fi
}

revert_interceptor() {
  local file="$1"
  if [[ -f "$file.superpatch.bak" ]]; then
    mv "$file.superpatch.bak" "$file"
    log "  interceptor reverted"
  fi
}

patch_offscreen_silence() {
  # Silence the Twilio SDK's default "disconnect" beep that plays at the end
  # of every call. Wraps each Twilio Device construction in an IIFE that
  # calls device.audio.disconnect(false) immediately after creation.
  local file="$1"
  if [[ -z "$file" ]]; then
    warn "  offscreen bundle: not found (skipping hangup-sound silencer)"
    return 0
  fi
  if grep -q '__d\.audio' "$file"; then
    log "  offscreen hangup-sound silencer: already installed"
    return 0
  fi
  [[ -f "$file.superpatch.bak" ]] || cp "$file" "$file.superpatch.bak"

  perl -i -pe 's/new o\(t,r\)/(()=>{let __d=new o(t,r);try{__d.audio\&\&__d.audio.disconnect(false)}catch(_e){}return __d})()/g' "$file"

  if grep -q '__d\.audio' "$file"; then
    log "  offscreen hangup-sound silencer: installed"
  else
    warn "  ERROR: silencer pattern not found in $file"
    warn "         (Twilio Device construction may look different in this build)"
    mv "$file.superpatch.bak" "$file"
    return 1
  fi
}

revert_offscreen() {
  local file="$1"
  if [[ -n "$file" ]] && [[ -f "$file.superpatch.bak" ]]; then
    mv "$file.superpatch.bak" "$file"
    log "  offscreen bundle reverted"
  fi
}

# --- main ------------------------------------------------------------------

main() {
  local hits=0 done=0 failed=0

  while IFS= read -r manifest; do
    [[ -z "$manifest" ]] && continue
    is_dialer "$manifest" || continue

    hits=$((hits + 1))
    local ext_dir bundle html offscreen
    ext_dir="$(dirname "$manifest")"
    bundle="$(find_interceptor_bundle "$ext_dir")"
    html="$(find_popup_html "$ext_dir")"
    offscreen="$(find_offscreen_bundle "$ext_dir")"

    log "Dialer.io: $ext_dir"

    case "$ACTION" in
      install|patch)
        if [[ -z "$html" ]]; then
          warn "  ERROR: popup index.html not found under src/ui/popup/"
          failed=$((failed + 1)); continue
        fi
        if [[ -z "$bundle" ]]; then
          warn "  ERROR: interceptor bundle not found under assets/"
          failed=$((failed + 1)); continue
        fi

        install_hotkeys_js         "$ext_dir"
        wire_hotkeys_into_popup    "$html"    || failed=$((failed + 1))
        patch_interceptor_autodial "$bundle"  || failed=$((failed + 1))
        patch_interceptor_hotkey   "$bundle"  || failed=$((failed + 1))
        patch_offscreen_silence    "$offscreen" || failed=$((failed + 1))
        done=$((done + 1))
        ;;

      --revert|revert|uninstall)
        [[ -n "$html"     ]] && revert_popup_wiring "$html"
        [[ -n "$bundle"   ]] && revert_interceptor  "$bundle"
        [[ -n "$offscreen" ]] && revert_offscreen   "$offscreen"
        revert_hotkeys_js "$ext_dir"
        done=$((done + 1))
        ;;

      *)
        warn "usage: $0 [install|--revert] [ext_dir]"
        exit 2
        ;;
    esac
  done < <(enumerate_targets)

  echo
  if (( hits == 0 )); then
    warn "No Dialer.io install found."
    if [[ -n "$DIALER_EXT_DIR" ]]; then
      warn "  Checked: $DIALER_EXT_DIR/manifest.json"
    else
      warn "  Scanned Chrome profiles under: $CHROME_BASE"
      warn ""
      warn "If Dialer.io is installed as an UNPACKED extension (Developer Mode),"
      warn "point the script at its folder instead:"
      warn "  DIALER_EXT_DIR=/path/to/dialer-io-ext/<version>_0 $0 $ACTION"
    fi
    exit 1
  fi

  log "Done. $done / $hits install(s) processed. Failures: $failed."
  log ""
  log "Next: open chrome://extensions and click the reload icon (⟳) on Dialer.io."
  log ""
  log "Then test:"
  log "  • Click any phone number in HubSpot → should dial immediately"
  log "  • Ctrl+Option+X (popup focused)     → end call + No Contact dispo"
  log "  • Ctrl+Option+Z (HubSpot focused)   → clicks phone icon → dials"

  (( failed == 0 ))
}

main
