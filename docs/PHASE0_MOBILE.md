# Bring the VPN up from your phone, no terminal

This is the whole thing done from a phone browser: create the server, let it
configure itself, and scan your WireGuard QR code. No Cloud Shell, no SSH, no
laptop. It uses the free **AMD** shape, which — unlike the ARM one — is almost
always in stock, so the instance actually gets created.

A note on words used below:
- **instance** = the virtual server (your VPN box) running in Oracle's cloud.
- **shape** = how big that server is. `VM.Standard.E2.1.Micro` is the free AMD one.
- **cloud-init / user data** = a script Oracle runs *once*, automatically, the
  first time the server boots. This is the trick that removes the terminal: the
  server sets itself up.

---

## 1. Create the instance (in the browser)

You are on **Compute → Instances**. Tap **Create instance**.

1. **Name** — type `wg-vpn` (any name is fine).
2. **Image and shape** — tap **Edit**.
   - **Shape**: tap **Change shape → Specialty and previous generation →
     VM.Standard.E2.1.Micro** (this is the Always Free AMD one). Select it.
   - **Image**: leave it as **Canonical Ubuntu 24.04** (change it if it shows
     something else).
3. **Networking** — leave the existing VCN and the **public** subnet selected.
   Make sure **Assign a public IPv4 address** is **Yes**. (Your network was
   already set up in an earlier phase, so these should already be right.)
4. **Add SSH keys** — you don't need SSH for this, but Oracle asks anyway. Pick
   **Paste public key** and paste the one line from `README.md` (the
   `ssh-ed25519 … claude-setup` line). It is safe to publish and only satisfies
   the form. (If you skip keys entirely the setup still works — the script
   handles that — but pasting it is cleaner.)

Now the one important part:

5. Tap **Show advanced options** (bottom of the form) → **Management** tab →
   **Initialization script** (also called *cloud-init* / *user data*). Choose
   **Paste** and paste this **exactly**:

   ```bash
   #!/bin/bash
   export WG_PASS='scan-me-please'
   curl -fsSL https://raw.githubusercontent.com/AttaullahSher/VPN/main/server/phase0-auto.sh -o /root/phase0.sh
   bash /root/phase0.sh >>/var/log/wg-phase0.log 2>&1
   ```

   Change `scan-me-please` to a short password you'll remember — you'll type it
   on your phone in a few minutes to unlock your QR codes. Everything else stays
   as-is.

6. Tap **Create**.

The AMD shape should land right away. If you ever see **"Out of capacity"** (rare
for AMD), just tap **Create** again.

---

## 2. Wait ~5 minutes, then get your QR codes

1. When the instance page shows **State: Running**, copy its **Public IP
   address** (a number like `140.238.x.x`).
2. Wait about **5 minutes**. During this time the server is installing WireGuard
   and setting itself up — you can't see it happening, that's normal.
3. In your phone browser, go to:

   ```
   https://PASTE-THE-PUBLIC-IP/
   ```

   - If the browser says **"can't connect"**, setup isn't finished yet — wait a
     minute and refresh.
   - The browser will warn **"Your connection is not private / not secure"**.
     That is **expected**: this is your own server and it has no domain name, so
     the encryption can't be name-verified — but it *is* encrypted. Tap
     **Advanced → Proceed / Visit anyway**.
   - It asks for a login. **Username: anything.** **Password: the one you set**
     (`scan-me-please` unless you changed it).

4. You'll see a QR code for each device. On your iPhone:
   - Install **WireGuard** from the App Store.
   - Open it → tap **+** → **Create from QR code** → scan **`atta-iphone`**.
   - Toggle it on. You're connected.
   - Hand the other codes to your family members' phones the same way. For a
     computer, use the **Download .conf** link and import that file into the
     desktop WireGuard app.

5. When everyone has scanned, tap **"I've scanned every device — shut this
   down."** The page turns off. (It also turns itself off automatically after
   about an hour.)

That's it — the VPN is running.

---

## What that page is, and why it's safe enough

Each QR code / `.conf` contains a **private key** — the secret that lets a device
onto the VPN. The setup page is the one moment those secrets have to travel to
your phone. It is protected by:

- **your password**, required on every request;
- **encryption** in transit (the "not private" warning only means the
  certificate isn't tied to a domain name, not that it's unencrypted);
- a **time limit** — it shuts itself off after ~1 hour and does not come back on
  reboot — plus the **shut-down button** for when you're done.

The keys are generated on the server and shown only to your logged-in browser.
They are never printed into a chat or saved into this repository.

If you miss the hour-long window: because the AMD instance is free and always
available, the simplest fix is to **terminate** it and repeat from step 1 — you
lose nothing, and new codes are generated.

---

## If the page never loads

The instance is disposable, so the fastest fix is almost always to terminate it
and recreate (step 1). If you want to see what happened first and you *do* have a
way to SSH in later, the full log is on the server at `/var/log/wg-phase0.log`.

Common causes:
- **You picked the ARM shape by mistake** — it may sit "out of capacity." Recreate
  with `VM.Standard.E2.1.Micro`.
- **The 5 minutes weren't up.** WireGuard, the firewall and the DNS resolver all
  install first; the page is the last thing to come up.
