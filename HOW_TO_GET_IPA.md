# How to get the IPA (no coding)

This app **cannot** be built on Windows. Apple only allows building on Mac computers.

I set up an automatic **cloud Mac** build on your GitHub repo. You only click a few buttons.

## What you will get

- File name: **VideoPlayer-unsigned.ipa**
- It is **unsigned** on purpose
- You sign it yourself with **Sideloadly** (using your Apple ID)

---

## Step 1 — Upload the latest code (GitHub Desktop)

1. Open **GitHub Desktop**
2. Select the repo **Murtadha-**
3. You should see many changed files
4. Write commit message: `Build IPA support`
5. Click **Commit to main**
6. Click **Push origin**

---

## Step 2 — Build the IPA (GitHub website)

1. Open this page in your browser:  
   https://github.com/MortazaMinoz/Murtadha-/actions
2. On the left, click **Build Unsigned IPA**
3. Click **Run workflow** (right side)
4. Click the green **Run workflow** button
5. Wait 5–15 minutes until it turns green (success)
6. Click the finished run
7. Scroll down to **Artifacts**
8. Download **VideoPlayer-unsigned**
9. Unzip it if needed → you get **VideoPlayer-unsigned.ipa**

---

## Step 3 — Sign & install (Sideloadly)

1. Open **Sideloadly** on your PC
2. Connect your iPhone with USB
3. Drag **VideoPlayer-unsigned.ipa** into Sideloadly
4. Enter your **Apple ID**
5. Click **Start**
6. On iPhone: Settings → General → VPN & Device Management → Trust your developer account
7. Open **VideoPlayer**

---

## If the build fails

- Open the failed run on GitHub Actions
- Copy the red error text
- Send it to me and I will fix it

## Notes

- Free Apple ID signing usually lasts **7 days**, then reinstall with Sideloadly
- The IPA is clean (no malware, just this video player app)
- Direct video links work best (`.mp4`, `.m3u8`) — not normal YouTube page links
