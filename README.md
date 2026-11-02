# Vicky & Nikita – wedding website (GitHub Pages + Supabase Free)

## 1. Database (once)
1. Supabase > SQL Editor > New query > paste all of `supabase-setup.sql` > Run. Safe to run again.
   - Admin login is `vicky.bhoyar11@gmail.com` (set inside `is_owner()` in the SQL).
   - If it stops with "older rsvps/blessings table exists", run the rename it prints, then run it again.
2. `config.js` already holds your Project URL and publishable key. Never add a secret/service_role key or DB password.

## 2. Publish on GitHub Pages
1. Create a public repository. Upload **everything in this folder** (`index.html`, `admin.html`, `config.js`, `images/`, `vendor/`, `.github/`, `README.md`, `supabase-setup.sql`). Hidden `.github` must be included.
2. Settings > Pages > Deploy from a branch > `main` / root > Save.
3. Your site: `https://USERNAME.github.io/REPO/` and admin: `.../REPO/admin.html` (all paths are relative, so the sub-folder is fine).
4. Keep-alive (free projects pause after 7 idle days): Settings > Secrets and variables > Actions > add `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`; then Actions > keep-supabase-awake > Run workflow once.

## 3. Using it
- Guests: RSVP, see the guest wall, send blessings. **Blessings stay hidden until you approve them.**
- Admin (`admin.html`): sign in > view/edit/delete RSVPs, Approve/Unapprove/Delete blessings, export CSV.
- Data: Supabase > Table Editor > `rsvps`, `blessings`.

## 4. Quick live test
Accept with 3 guests (wall shows the name, total 3) > resend from the same phone with 4 (total 4, still one row) > decline from another browser (not on wall) > send a blessing, approve it in admin.html, it appears on the wall.
