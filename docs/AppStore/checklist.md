# App Store Submission Checklist

Step-by-step list of everything that has to be true before you can hit **Submit for Review** in App Store Connect. Items are grouped by where the work happens; tick them off in order.

---

## 1. Host the public URLs (GitHub Pages)

Apple needs publicly reachable URLs for both Privacy Policy and Support before they will approve the app.

1. Push the four files added under `docs/AppStore/` to `main` (you'll do this when squashing the history).
2. On GitHub, open **Settings → Pages**.
3. Under **Build and deployment → Source**, choose **Deploy from a branch**.
4. Pick **`main`** branch and **`/docs`** folder. Save.
5. Wait ~1 minute, then verify both URLs render:
   - `https://bardiabarabadi.github.io/PocketTop/AppStore/privacy.html`
   - `https://bardiabarabadi.github.io/PocketTop/AppStore/support.html`
6. *(Optional but recommended)* drop an empty `docs/.nojekyll` file in a follow-up commit so GitHub serves the files raw without trying to run Jekyll on the existing `*.md` design docs. Without it, Jekyll will still serve the HTML correctly — the `.nojekyll` just suppresses unnecessary processing.

If anything 404s, double-check the Pages source is set to `/docs` and not the repo root.

---

## 2. Xcode project changes

### 2a. Add `ITSAppUsesNonExemptEncryption = NO` to Info.plist

The project uses generated Info.plist (`GENERATE_INFOPLIST_FILE = YES`), so add it as a build setting, not in a static plist.

In Xcode: select the **PocketTop** target → **Build Settings** → search for `Info.plist Values` → click **+** and add a custom user-defined entry, OR — easier — drop this line into both the Debug and Release configurations of the `PocketTop` target inside `project.pbxproj`:

```
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO;
```

After this is set, App Store Connect will stop asking the encryption questionnaire on every build upload.

### 2b. Bump version & build numbers per release

Currently in `project.pbxproj`:

```
MARKETING_VERSION = 1.0;
CURRENT_PROJECT_VERSION = 1;
```

- For TestFlight builds before launch: keep `MARKETING_VERSION = 1.0`, bump `CURRENT_PROJECT_VERSION` (1, 2, 3 …) on every Archive upload.
- For the public 1.0 submission: set `CURRENT_PROJECT_VERSION` to whatever the last TestFlight build was (App Store Connect won't accept a build number it has already seen).

### 2c. Generate the App Icon

`PocketTop/PocketTop/Assets.xcassets/AppIcon.appiconset/` only contains a `Contents.json` — no PNGs. You need a 1024×1024 source icon, then either:

- **Recommended:** use Xcode 14+'s **Single Size** app-icon support — drop a single 1024×1024 PNG (sRGB, no alpha, no transparency) and Xcode will resize for all required slots automatically.
- **Or** generate a full set with a tool like Bakery, Icon Set Creator, or `sips` from a 1024×1024 source.

Apple rejects icons with alpha channels, transparency, or rounded corners (Apple rounds them). Make it a flat, opaque PNG.

### 2d. Confirm orientations & device family

Already correct in `project.pbxproj`:

- `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad)
- iPhone: portrait only.
- iPad: all four orientations.

### 2e. Confirm permission usage strings

Already in place via build settings:

```
INFOPLIST_KEY_NSLocalNetworkUsageDescription = "PocketTop connects to your computers over the local network to show live metrics and manage processes."
```

No other permissions used (no camera, photos, contacts, location, mic, etc.). Nothing else to add.

---

## 3. Screenshots

Apple requires screenshots for at least one iPhone size and (since the app is universal) at least one iPad size. Submit the largest required size for each — App Store Connect down-scales for smaller devices automatically.

### Required iPhone size

- **6.9-inch display** (iPhone 16 Pro Max / 17 Pro Max): **1320 × 2868 px** portrait.
- 3 to 10 screenshots.

### Required iPad size

- **13-inch display** (iPad Pro M4 13"): **2064 × 2752 px** portrait, OR **2752 × 2064 px** landscape.
- 3 to 10 screenshots.

### Suggested set (re-uses what's already in `screenshots/`)

You already have iPhone shots at `screenshots/Shot-{1,2,3}.jpg`. Re-capture them on a real iPhone 16 Pro Max (or the simulator at that resolution) so they're at the exact 1320 × 2868 size.

Suggested screens, in order:
1. **Overview** — CPU/GPU/RAM/disk/net rings + storage rows.
2. **Usage timelines + Power & Thermal** — stacked Swift Charts.
3. **Processes** — sortable table with Show-all expanded.

For the iPad, capture the same three screens on a 13" iPad simulator.

### Marketing tip

You don't need device frames — Apple accepts plain captures. If you want frames or annotated text, do it once and ship it; don't let it block submission.

---

## 4. App Store Connect setup

Walk through this once for the new app record. All textual content lives in `metadata.md`.

1. **App Store Connect → My Apps → +** → **New App**.
2. Platform: **iOS**. Name: `PocketTop`. Primary language: **English (U.S.)**.
3. Bundle ID: select the one you registered (`com.bardiabarabadi.PocketTop`). If it isn't there yet, register it first under **Certificates, Identifiers & Profiles → Identifiers → +**.
4. SKU: `pockettop-ios-001` (or anything unique to you).
5. User Access: Full Access.
6. After the record exists, fill in:
   - **App Information**: subtitle, primary/secondary category, content rights, age rating (run the questionnaire — all "None"), copyright. Values from `metadata.md`.
   - **Pricing and Availability**: Free, all territories.
   - **App Privacy**: answer **No** to "Do you collect data from this app?". That produces the "Data Not Collected" label.
   - **Version 1.0**:
     - Promotional Text, Description, Keywords, Support URL, Marketing URL, What's New (all from `metadata.md`).
     - Upload screenshots.
     - **App Review Information**: Sign-in Required = No, Demo account = blank, paste the Notes block from `metadata.md`.
     - **Version Release**: choose "Manually release this version" so you control the moment it goes live.
7. Build: archive in Xcode (`Product → Archive`), upload via Organizer, wait for processing (~10–20 min), then attach the build to the version.
8. Hit **Add for Review** → **Submit for Review**.

---

## 5. TestFlight before public release

Strongly recommended before pushing **Submit for Review**.

1. Same Archive upload also feeds TestFlight.
2. Add yourself (and a couple of trusted testers if you have any) as Internal Testers via App Store Connect → TestFlight.
3. Run through the full setup flow on a real device against a real Linux box at least once. The reviewer will too.
4. Watch for:
   - Local Network permission prompt fires correctly the first time.
   - SSH password and SSH-key auth both work.
   - Install completes end-to-end and the host appears on Home.
   - Live metrics update.
   - Process kill works.
   - Removing a host removes it cleanly.

---

## 6. Things that commonly trip up first-time submissions

- **App icon has alpha or transparency** → automatic rejection at upload time.
- **Privacy Policy URL not reachable** at the moment Apple's bot fetches it → rejection. Verify in a private browsing window.
- **Demo account left blank without explanation** for an app that obviously needs a backend → rejection. We pre-empt this in the Review Notes by explaining BYO-server.
- **Build uses an entitlement (e.g. push notifications) that the App ID profile doesn't have** → upload fails. We don't use any non-default entitlements, so this should be fine.
- **Local Network permission described too vaguely** → reviewer asks why. The current `NSLocalNetworkUsageDescription` already explains it.
- **Screenshots show simulator status bars** with "Carrier" instead of a clean signal — fine in practice, but if rejected, regenerate via Xcode 15's "Edit → Status Bar Overrides" or capture on a real device.

---

## 7. Once approved

- Tag the release in git: `git tag v1.0 && git push origin v1.0`.
- Create a GitHub Release pointing at the tag with a short note linking to the App Store page.
- Update `README.md` with the App Store badge.
