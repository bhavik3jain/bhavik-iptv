# Releasing Hearth

The owner's runbook for getting Hearth onto TestFlight and keeping iCloud working there. Three parts, in the order you need them the first time: **1** puts the app on TestFlight, **2** gives GitHub what it needs to upload builds by itself, **3** gets the iCloud schema into Production. After the first release, only part 3 (when the household model changes) and the upload itself recur.

Already done (2026-10-24): Xcode is signed in to team Y4M3S6H4NK, and signed builds registered `com.bhavikjain.hearth` and `com.bhavikjain.hearth.dev` for iOS and macOS with the iCloud container `iCloud.com.bhavikjain.hearth` and push notifications.

## 1. Put Hearth on TestFlight (once)

1. **Create the app record** at [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Apps** → **+** → **New App**:
   - Platforms: **iOS** and **macOS** (one record for both: Universal Purchase). Add **tvOS** from the app's page (**+ Platform**) before the first Apple TV upload; until then the workflow's Apple TV job fails at its upload, and the iOS and Mac jobs carry on.
   - Name: **Hearth** (must be unique on the App Store; "Hearth Player" works if it's taken — it can change later).
   - Primary language: English (U.S.). Bundle ID: **com.bhavikjain.hearth**. SKU: `hearth`. User access: Full Access.
2. **Add the household as testers.** Internal testers skip App Review but must be users on your App Store Connect team (up to 100):
   - **Users and Access** → **+** → each person's Apple ID email, role **Developer** (or Marketing; any role can test). They accept the email invitation.
   - The app → **TestFlight** → **Internal Testing** → **+** → a group named **Household** → add those users → turn on **Automatic Distribution** so every new build reaches them.
3. **Deploy the iCloud schema** (part 3) — before the first build, or TestFlight builds keep the household on each device and sharing fails.
4. **Upload the first builds**, either:
   - from this Mac: `scripts/testflight.sh all` in your own Terminal (Xcode signed in; if the export says "No Accounts", sign in again in Xcode → Settings → Accounts, or use the API-key variables from part 2), or
   - from GitHub, once part 2 is done: `gh workflow run TestFlight --ref main` (or push a tag: `git tag v0.1.0 && git push --tags`).
   Both build iOS, macOS and tvOS. Build numbers only go up (the script uses `yyDDDHHMM`; the workflow uses its run number + 100).
   The iOS and Apple TV archives are development-signed before the export re-signs them for the App Store, so a development profile has to exist for each, and Apple only makes one for a platform the team has a registered device for. If the Apple TV archive stops at "Your team has no devices", register the Apple TV: pair it in Xcode (**Window** → **Devices and Simulators**), or add its UDID at developer.apple.com → **Devices** → **+**.
5. **Wait for processing** (5–30 minutes; App Store Connect emails you). Export compliance is answered by the app (`ITSAppUsesNonExemptEncryption = NO`), so builds don't wait on that question.
6. **Install**: the **TestFlight** app from the App Store on iPhone and iPad, from the Mac App Store on the Mac, from the App Store on Apple TV. Accept the invitation; Hearth appears with an Install button. The Debug app ("Hearth Dev") and the TestFlight app are separate and can sit side by side.

External testers (people who aren't team users) go through Beta App Review, where guideline 5.2 (third-party content) applies — see the technical spec's *Build, release and App Review*. Stay internal for the household.

## 2. Secrets for the GitHub TestFlight workflow

`.github/workflows/testflight.yml` reads five secrets from a GitHub **environment** named `testflight` (not repository secrets, so only `main` and `v*` tags can use them). Same names as Multitrack:

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key id (10 characters) |
| `ASC_ISSUER_ID` | Your team's issuer id (a UUID) |
| `ASC_PRIVATE_KEY` | The key's `.p8` file, base64-encoded |
| `IOS_DEV_P12` | Your Apple Development certificate with its private key, exported as `.p12`, base64-encoded |
| `IOS_DEV_P12_PASSWORD` | The password you set when exporting the `.p12` |

**a. The App Store Connect API key.** A key belongs to the team, not an app, so Multitrack's key works here if you still have its `.p8` file (GitHub never shows a secret again, so it can't be copied from Multitrack's repo). Otherwise make a new one:
1. App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys** → **+**.
2. Name `Hearth CI`, access **Admin**. App Manager is not enough: cloud-managed distribution signing fails with "Cloud signing permission error".
3. Note the **Key ID** (in the list) and the **Issuer ID** (above the list).
4. **Download** `AuthKey_<KEYID>.p8`. Apple lets you download it once; keep it in 1Password.

**b. The development certificate.** CI archives with a fixed development identity so it doesn't mint a new certificate every run (Multitrack hit Apple's certificate limit that way).
1. **Keychain Access** → **login** → **My Certificates** → **Apple Development: BHAVIK SUBHASHCHANDRA JAIN (W89V4Z8ATC)**. The disclosure arrow must show a private key under it.
2. Right-click → **Export…** → format **Personal Information Exchange (.p12)** → save as `hearth-dev.p12` → set a password.

**c. The environment.** GitHub → the repo → **Settings** → **Environments** → **New environment** `testflight` → **Deployment branches and tags** → **Selected branches and tags** → add `main` and a tag rule `v*`.

**d. The secrets** (from the folder holding the files; replace the placeholders):

```bash
gh secret set ASC_KEY_ID --env testflight --repo bhavik3jain/bhavik-iptv --body "ABC123DEFG"
```

```bash
gh secret set ASC_ISSUER_ID --env testflight --repo bhavik3jain/bhavik-iptv --body "00000000-0000-0000-0000-000000000000"
```

```bash
base64 -i AuthKey_ABC123DEFG.p8 | gh secret set ASC_PRIVATE_KEY --env testflight --repo bhavik3jain/bhavik-iptv
```

```bash
base64 -i hearth-dev.p12 | gh secret set IOS_DEV_P12 --env testflight --repo bhavik3jain/bhavik-iptv
```

```bash
gh secret set IOS_DEV_P12_PASSWORD --env testflight --repo bhavik3jain/bhavik-iptv
```

(The last one prompts for the value, so the password never lands in your shell history.) Then delete `hearth-dev.p12`; keep the `.p8` in 1Password, not on disk. Nothing secret ever goes in the repo — `.gitignore` blocks `*.p8`, `*.p12` and profiles.

**e. Run it**: `gh workflow run TestFlight --ref main`, and watch with `gh run watch`. The workflow's first step names any secret that's missing.

The same API key also fixes local uploads when Xcode's session misbehaves:

```bash
ASC_KEY_ID=ABC123DEFG ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 ASC_KEY_PATH=~/secure/AuthKey_ABC123DEFG.p8 scripts/testflight.sh all
```

## 3. iCloud schema: Development → Production

CloudKit creates record types in the **Development** environment as Debug builds use them, but **never in Production**. A TestFlight build only talks to Production, so until the schema is deployed there, its household saves on each device and never syncs, and inviting someone fails.

**When**: before the very first TestFlight build, and before any TestFlight build after adding an entity or attribute to the household model (`Packages/HouseholdKit/Sources/HouseholdKit/HouseholdModel.swift`). **Not** needed for: a new case of an enum stored as a raw string (`kindRaw`, `roleRaw`…), anything in CatalogKit (the catalog is local and never synced), or UI changes.

1. Make sure this Mac is signed in to iCloud (System Settings → your name → iCloud) and Xcode is signed in.
2. Send the schema to Development:

   ```bash
   scripts/cloudkit/init-schema.sh
   ```

   It builds a signed Debug Mac app, launches it with `-InitializeCloudKitSchema YES` (throwaway in-memory stores only, never real data), and waits for `[CloudKitSchemaInitializer] Schema sent to Development: …`. If the Mac route fails, `scripts/cloudkit/init-schema.sh --simulator "iPhone 18 Pro"` does the same on a simulator signed in to an Apple Account (Settings app in the simulator).
3. Check it at [icloud.developer.apple.com](https://icloud.developer.apple.com) → **CloudKit Database** → container **iCloud.com.bhavikjain.hearth** → **Development** → **Schema** → **Record Types**. Expect `CD_Household`, `CD_Source`, `CD_Profile`, `CD_Favorite`, `CD_Progress`, `CD_Playback`, `CD_MemberRole` and `cloudkit.share`. On `CD_Source`, the login fields (`CD_macAddress`, `CD_username`, `CD_password`, `CD_playlistURL`, `CD_guideURL`, `CD_serialNumber`, `CD_deviceID`, `CD_deviceID2`, `CD_signature`, `CD_model`, `CD_timeZone`) must show as **encrypted** — encryption can't be added after the first Production deploy.
4. **Deploy Schema Changes…** (Development → Schema) → review the list → **Deploy**. Then switch to **Production** → **Schema** and confirm the record types are there. There's no API for this step; it's Console-only, which is why neither a script nor CI can do it.
5. Upload the TestFlight build (part 1, step 4).

Rules that keep this safe: changes are additive only (Production can never delete or rename a record type or field once deployed), every non-optional attribute has a default, and the schema run is a Debug-only launch argument. Development and Production are separate **data** stores too, so Hearth Dev (Debug) and the TestFlight app never see each other's households.
