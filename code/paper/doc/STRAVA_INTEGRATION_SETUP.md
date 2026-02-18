# Strava App Setup and Integration Guide

This guide explains how to set up a Strava API application and wire it into the `paper` Flutter web app.

## 1) Create a Strava API App (Step-by-Step)
1. Sign in to your Strava account in a browser.
2. Open the Strava API settings page:
   - https://www.strava.com/settings/api
3. In **My API Application**, fill in app fields:
   - `Application Name`: e.g. `Data Collector`
   - `Category`: choose a suitable category (e.g. Training/Analytics)
   - `Club`: optional
   - `Website`: your app URL (for local dev you can use `http://localhost:8080`)
   - `Authorization Callback Domain`: your host only (no protocol/path), e.g. `localhost`
4. Save/Create the application.
5. Copy and store these values securely:
   - `Client ID`
   - `Client Secret`

### Quick Verification Checklist
- App is visible under https://www.strava.com/settings/api
- `Client ID` and `Client Secret` are available
- Callback domain matches where your app runs (`localhost`, staging domain, or production domain)

## 2) Configure Authorization Callback (Redirect URI)
In Strava app settings, set **Authorization Callback Domain** and allow the callback URL used by your web app.

Common local dev example:
- App URL: `http://localhost:8080`
- Redirect URI used by app: `http://localhost:8080/` (same page, query includes `?code=...`)

If you run on another port, use that exact origin.

## 3) Required Scopes
This app requests:
- `read`
- `activity:read_all`

These are required to fetch athlete activities and detailed streams.

## 4) Where to Configure in Code
File: `paper/lib/main.dart`

Class: `StravaAuthService`

Update these constants:
- `clientId = TODO:<STRAVA_CLIENT_ID>`
- `clientSecret = TODO:<STRAVA_CLIENT_SECRET>`
- `scope = TODO:<STRAVA_SCOPE>` (if needed)

Current auth flow:
- Build authorize URL with `buildAuthorizeUri(...)`
- On callback, read `code` from `Uri.base.queryParameters`
- Exchange code for tokens via `exchangeCodeForTokens(...)`
- Store tokens in `SharedPreferences`
- Refresh token on `401` in API calls

## 5) Data Fetch Endpoints Used
From `StravaApiClient` in `paper/lib/main.dart`:

- Activities list:
  - `GET /api/v3/athlete/activities`
- Activity streams:
  - `GET /api/v3/activities/{id}/streams`
  - keys: `time,heartrate,velocity_smooth,cadence,grade_smooth`

## 6) Stream-to-Analysis Mapping
- `time` -> `ts = start_time + seconds`
- `heartrate` -> `hr`
- `velocity_smooth` -> `pace_sec_per_km = 1000 / velocity`
- `cadence` -> `cadence_spm = raw * 2`
- `grade_smooth` -> `grade_pct = raw * 100`

## 7) Run and Verify
From `paper/`:

```bash
flutter pub get
flutter run -d chrome --web-port 8080
```

Then in app:
1. Click `Connect Strava`
2. Approve scopes
3. Return to app callback URL
4. Click `Fetch & Analyze`

## 8) Production Security (Important)
Current implementation keeps `clientSecret` in frontend code for convenience.

For production:
1. Move token exchange to backend.
2. Keep `clientSecret` only on server.
3. Frontend should only redirect to authorize and call backend exchange endpoint.
4. Optionally store tokens server-side and issue your own session token.

## 9) Troubleshooting
- `No Strava token found`:
  - Ensure callback completed and `code` exchange succeeded.
- `401` from Strava:
  - Check refresh token flow and app credentials.
- Redirect mismatch:
  - Ensure Strava app callback domain and app origin/port match.
- Empty data:
  - Ensure activities are Run type and streams include required keys.

## 10) Repo Files Related to Strava
- `paper/lib/main.dart` (auth + API + analysis pipeline)
- `paper/lib/csv_download.dart` (CSV export helper)
- `paper/lib/csv_download_web.dart` (web download implementation)
- `paper/lib/csv_download_stub.dart` (non-web stub)
