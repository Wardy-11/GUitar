# FRET//FORGE

Static web app (no build step) + Supabase (auth, Postgres, realtime). Installs to the iPhone home screen.

## 1. Supabase
1. Create a project at supabase.com.
2. SQL Editor → paste `supabase/migrations/001_init.sql` → Run.
3. Authentication → Providers → Email. For quick testing turn off "Confirm email"; for real use leave it on and set Authentication → URL Configuration → Site URL to your Netlify URL.
4. Project Settings → API: copy the Project URL and the `anon` public key. Never put the `service_role` key anywhere in this app.

## 2. Netlify
1. Push this folder to GitHub, then Netlify → Add new site → Import from Git. No build settings needed; `netlify.toml` handles them.
2. Site settings → Environment variables: `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
3. Deploy. The build writes those into `config.js`. (Or edit `config.js` by hand and drag-drop the folder.)

## 3. iPhone
Open the site in Safari → Share → Add to Home Screen.

## How it's secured
- Row Level Security on every table. You can only read your own sessions, and profiles of accepted friends.
- Sessions are created and closed only by database functions that time them on the server (4-hour cap), so hours can't be faked from the browser.
- Friends see you as "live" only while a heartbeat arrives within 3 minutes, and only if "share live" is on.

## Next
Metronome and drills, fretboard trainer, challenges, groups, push notifications (needs a service worker + Web Push; iOS requires the home-screen install).
