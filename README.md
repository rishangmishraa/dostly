# Dostly — Real-time chat web app

React + Vite frontend, Supabase Auth/Postgres/Realtime/Storage backend, and Vercel deployment target.

## Local setup

1. Install Node.js LTS and Git.
2. In this folder run `npm install` then `npm run dev`.
3. Create a Supabase project at https://supabase.com/dashboard.
4. In Supabase SQL Editor, run the complete `supabase/schema.sql` script.
5. In Supabase Authentication settings, configure email/password. Turn off Confirm email only if you specifically want immediate unverified signup.
6. Copy `.env.example` to `.env`, then set `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` from Supabase Project Connect/API Keys.
7. Restart `npm run dev` after editing `.env`.

Never put the Supabase service-role/secret key in frontend code. The schema creates a private `dostly-files` bucket and RLS policies. Review the SQL and test using two separate accounts before production use.

## Deploy to Vercel

1. Push the project to a GitHub repository (do not commit `.env`).
2. Import that repository at https://vercel.com/new.
3. Framework preset: Vite. Build command: `npm run build`; output directory: `dist`.
4. Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` in Vercel Project Settings → Environment Variables.
5. Redeploy after setting variables.

## Current implementation scope

Implemented in this starter: email/password auth, permanent profile rows and IDs, profile editing, exact-ID lookup, private and group conversations, database-backed messages with Supabase Realtime, private file uploads and signed URLs, and text/photo statuses filtered by 24-hour expiry.

Before public production use, extend/test creator-only group member management, group avatar editing, unread/read receipts, robust status cleanup scheduling, abuse/rate limiting, moderation/reporting, and end-to-end security. This starter does not claim end-to-end encryption. Status expiry is enforced when queried; physical deletion of expired status rows/files requires a scheduled cleanup job configured separately.
