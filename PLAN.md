# Swipe-to-hide results, quad URL sync, perma-disabled exclusion, burn fix

**1. Auto-exclude permanently disabled credentials**

- Any credential that has ever returned the "been disabled" phrase is recorded as permanently disabled and skipped on every future RCR run (single and quad), in addition to the existing temp-disabled cooldown.
- Applies even after pressing RCR a second time to restart the vault — permanently disabled stays excluded forever (until cleared via Results → Clear All).

**2. Swipe-to-hide live result pill**

- The floating RCR queue pill (single + each of the 4 quad pills) can be swiped down to dismiss off-screen while RCR keeps running silently.
- A small "Show queue" chevron tab peeks at the bottom edge to bring it back. Swiping up restores it. Position state is remembered for the rest of the session.
- Works independently per pill in quad mode (each can be hidden separately).

**3. Quad-mode URL bar applies to all 4 windows**

- Typing a URL and submitting in 2×2 mode loads that URL into all 4 sessions simultaneously, each keeping its fully isolated cookies / storage / cache / fingerprint.
- When toggling from single → quad mode, the current single-tab URL is automatically loaded into all 4 cells (replacing the default home for that switch).
- When toggling quad → single, the focused cell's current URL becomes the single tab's URL.
- The URL bar in quad mode displays the focused cell's URL and stays editable (no longer disabled by quad mode alone — only locked while RCR is running, as before).

**4. Fix the burn (flame) button**

- The current burn only deletes data records whose display name contains the domain string, which fails for many real sites (subdomains, third-party cookies, IDN, etc.).
- Rewrite to wipe the entire website data store for that tab (cookies, cache, local storage, IndexedDB, service workers, session storage) since the tab is meant to be a clean-slate burn — then delete browsing history for the domain and reload the captured URL.
- In quad mode, the flame button burns the focused cell's isolated store the same way.
- Adds a brief confirmation toast (respecting the existing notifications toggle).

