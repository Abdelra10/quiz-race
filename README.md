# Quiz Race Lite

A mobile-first, no-login multiplayer trivia game. The browser is only the display/input layer; room state, answer validation, question deadlines, and scoring are controlled by Supabase PostgreSQL through a server-side RPC exposed by a Supabase Edge Function.

## Accounts needed
1. GitHub — stores the source code.
2. Supabase — database, Edge Function, and Realtime Broadcast.
3. Vercel — public HTTPS website.

Free tiers are intended for a small friend group, subject to provider limits and current terms.

## 1. Create the Supabase project
1. Open https://database.new and create a project.
2. Choose a project name, database password, and region.
3. Wait for the database to finish provisioning.
4. Open **SQL Editor → New query**.
5. Open `supabase/migrations/001_quiz_race.sql` from this project, copy the entire file, paste it into SQL Editor, and click **Run**.
6. Check that the query completes successfully. In **Table Editor**, confirm `quiz_questions` contains 36 rows and the other `quiz_*` tables exist.

## 2. Deploy the server API
1. In Supabase, open **Project Settings → Edge Functions** or **Edge Functions → Secrets** (the menu wording can vary).
2. Confirm the built-in secrets `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are available to Edge Functions. Do not paste the service-role key into the website or share it.
3. Deploy the `game-api` function from `supabase/functions/game-api/index.ts`.
   - Easiest CLI route: install the Supabase CLI, run `supabase login`, `supabase link --project-ref YOUR_PROJECT_REF`, then `supabase functions deploy game-api --no-verify-jwt`.
   - The `supabase/config.toml` sets `verify_jwt = false`; every game operation still validates a per-player random session token in the database.
4. Check **Edge Functions → game-api → Logs** after a test call. It should show no runtime or missing-secret errors.

## 3. Configure the website
1. In Supabase, open **Project Settings → API**.
2. Copy the Project URL and the anon/public key. Never use the `service_role` key in Vercel.
3. In the project root, create a file named `.env` with:
   ```
   VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
   VITE_SUPABASE_ANON_KEY=YOUR_ANON_OR_PUBLISHABLE_KEY
   ```
4. Run `npm install` and `npm run build`. The build should create a `dist` folder.

## 4. Publish on Vercel
1. Import the GitHub repository `Abdelra10/quiz-race` into Vercel.
2. Set Framework Preset to **Vite**.
3. Add environment variables:
   - `VITE_SUPABASE_URL` = your Supabase Project URL
   - `VITE_SUPABASE_ANON_KEY` = your Supabase anon/public key
4. Click **Deploy**. Open the generated `https://....vercel.app` link. No player account or install is required.

## 5. Two-device acceptance test
1. Open the public URL on your laptop. Enter a name and create a room.
2. Open the same public URL on a phone (or private/incognito browser). Enter a different name and the four-letter code.
3. Check that both players appear in the same lobby.
4. Host starts the game. Both devices should show the same question and the same server deadline countdown.
5. Answer on one device. That answer must lock and not be changeable.
6. Answer on the second device. Both should show the answer reveal and same leaderboard.
7. Wait through all 12 questions and confirm the winner screen.
8. Host clicks Play Again. Confirm both players return to the lobby with scores reset.
9. Join a room after a round starts from a third browser. Confirm the player appears under “Next round” and is included when the host starts the next round.

## Lite limitations
- No account login; a random player session token is stored in the browser only for the current session.
- No advanced reconnection/session recovery.
- No automatic host transfer.
- A client calls the server `advance` action when its display reaches the deadline; the server checks its own clock before changing state. If every client closes at the same time, progression waits until a client reconnects.
- This first cut is designed for a small private group, not abuse-resistant public tournaments. Add rate limiting and moderation before opening it to a large audience.

## Important security note
Never expose `SUPABASE_SERVICE_ROLE_KEY` in browser code, Vercel `VITE_` variables, screenshots, or chat. Only the Edge Function should use it.
