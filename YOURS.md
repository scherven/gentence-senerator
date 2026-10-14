# Before the next TestFlight build

Rebuilt Oct 13 from session notes; the original was lost.

1. **Commit the open work on `quality-pass`.** Uncommitted:
   - grading v3: score = works said to a native (`Tutor`, `Schemas`, `LanguagePacks`, eval);
   - lessons removed from findings;
   - UI tweaks: underline not strike, Words only on Today, copy fixes, quiz headers, "comes back" label on findings.

   Decide whether `design/` and `huaspec.md` belong in the repo.
2. **Deploy the worker** if it hasn't gone out since `4b5e6e4`. That commit adds spend per code, the $2 daily cap, disputes, `/stats`, and the Sonnet 5.5 cap at 32k. Testers were hitting undeployed worker bugs.
   ```
   cd worker && npx wrangler deploy
   ```
3. **Merge** `quality-pass` → `main`. Fast-forward `testflight` if you still use it.
4. **Bump** `CURRENT_PROJECT_VERSION`. It is 3 now; use 4 if build 3 was uploaded.
5. **Archive** in Xcode 27 (release, not beta), Release config, then upload.
   - Release leaves out ChinesePod (`dialogues.json`, `cp-*.m4a`).
   - Korean and Spanish are off by default.
6. **Push.** Claude's pushes get a 403.
7. **New testers:** `worker/invite.sh new <name>`.
