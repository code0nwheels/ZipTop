# How to install ZipTop

This guide is for everyone, including people who don't usually install
programs by hand. Follow the part for your computer, step by step, and you'll
be watching TV in a few minutes.

**Jump to:** [Windows](#windows) · [Mac](#mac) · [Linux](#linux) ·
[Signing in](#signing-in-same-on-every-computer) ·
[Updates](#updates) · [Removing ZipTop](#removing-ziptop) ·
[Something went wrong](#something-went-wrong)

---

## Not sure which computer you have?

- **Windows:** there's a Start button (the Windows logo) in the bottom-left
  or bottom-middle of the screen.
- **Mac:** there's an Apple logo () in the top-left corner of the screen.
- **Linux:** you'd probably know. If you use Ubuntu, Linux Mint, Fedora,
  Pop!_OS or similar, it's Linux.

## Where to download it

Everything comes from one page:

**https://github.com/code0nwheels/ZipTop/releases/latest**

Scroll down to the section called **Assets**. You'll see a few files. Pick
the one for your computer:

| Your computer | Click this file |
|---|---|
| Windows | `ZipTop-Setup-<version>.exe` |
| Mac | `ZipTop-<version>-macos-arm64.dmg` |
| Linux | `ZipTop-<version>-x86_64.AppImage` |

`<version>` is just a number like `1.4.2`. Ignore the files called
"Source code"; those are for programmers.

---

## Windows

**You need:** Windows 10 or 11, 64-bit (almost every PC from the last ten
years). You do **not** need to be an administrator.

1. On the download page, click **`ZipTop-Setup-<version>.exe`**. Your browser
   saves it, usually to your **Downloads** folder.
   - If your browser says the file "isn't commonly downloaded" or might be
     unsafe, choose **Keep** (in Edge: click the **…** next to the file,
     then **Keep**, then **Keep anyway**).
2. Open the file you just downloaded (click it at the bottom/top of the
   browser, or double-click it in your Downloads folder).
3. A blue window may appear saying **"Windows protected your PC"**. This is
   normal for small apps that aren't from a big company.
   - Click **More info** (small text under the message).
   - Click **Run anyway**.
4. The ZipTop installer opens. Click **Next** / **Install** until it's done.
   - Want an icon on your desktop? Tick **Create a desktop shortcut** when
     you see it.
5. Leave **Start ZipTop** ticked and click **Finish**.

ZipTop opens. Now go to [Signing in](#signing-in-same-on-every-computer).

**Opening it later:** click the Start button and type **ZipTop**, or use the
desktop shortcut if you made one.

---

## Mac

**You need:** a Mac with an **Apple chip** (M1, M2, M3, M4 or newer) running
**macOS 13 Ventura or newer**.

> **How to check:** click the Apple logo () in the top-left corner and
> choose **About This Mac**. Next to **Chip** it should say **Apple M…**. If
> it says **Intel** instead, ZipTop won't run on that Mac, sorry.

> **Heads-up:** the Mac version is brand new and hasn't been tested much on
> real Macs yet. If something doesn't work, please
> [tell us](https://github.com/code0nwheels/ZipTop/issues).

### Install it

1. On the download page, click **`ZipTop-<version>-macos-arm64.dmg`**. It
   goes to your **Downloads** folder.
2. Open the downloaded file (double-click it). A small window appears with
   the ZipTop icon and an **Applications** folder.
3. **Drag the ZipTop icon onto the Applications folder.** That's the actual
   install.
4. You can close that window now. (In Finder's sidebar you'll see a
   "ZipTop" drive with an eject button ⏏; click it to tidy up.)

### Open it the first time (one-time extra step)

ZipTop isn't registered with Apple (that costs money every year), so the
first time macOS blocks it. You only have to do this once:

1. Open **Finder**, click **Applications** in the sidebar, and double-click
   **ZipTop**.
2. macOS says it can't check ZipTop for malicious software. Click **Done**
   (don't click "Move to Trash").
3. Click the Apple logo () → **System Settings** → **Privacy & Security**
   (in the left list).
4. Scroll down until you see **"ZipTop" was blocked…**. Click
   **Open Anyway**.
5. macOS asks again. Click **Open Anyway** once more and type your Mac
   password (or use Touch ID) if it asks.

ZipTop opens. Now go to [Signing in](#signing-in-same-on-every-computer).

**Opening it later:** it's in your Applications folder, or press
**⌘ Command + Space**, type **ZipTop** and press **Return**. To keep it in
your Dock, right-click its Dock icon while it's open → **Options** →
**Keep in Dock**.

> **Important:** always open ZipTop from **Applications**, not from the
> download window. A copy opened straight from the download can't update
> itself.

---

## Linux

**You need:**

- A normal 64-bit PC (Intel or AMD). Raspberry Pi and other ARM computers
  aren't supported.
- A fairly recent system: **Ubuntu 22.04 or newer**, or anything from about
  2022 onward (Linux Mint 21+, Fedora 36+, Debian 12+, Pop!_OS 22.04+…).

On Linux, ZipTop is one single file called an **AppImage**. There's nothing
to "install": you download it, allow it to run, and double-click it.

### Install it

1. On the download page, click **`ZipTop-<version>-x86_64.AppImage`**. It
   goes to your **Downloads** folder.
2. **Move it somewhere it can stay.** ZipTop updates itself by replacing
   this file, so don't leave it somewhere you clean out. A good spot:
   - Open your **Home** folder, make a new folder called **Applications**,
     and move the file in there.
3. **Allow it to run as a program.** Linux won't run downloaded files until
   you say so. Right-click the file → **Properties**, then:
   - **Ubuntu / GNOME:** switch on **Executable as Program** (older
     versions: **Permissions** tab → tick **Allow executing file as
     program**).
   - **Linux Mint:** **Permissions** tab → tick **Allow executing file as
     program**.
   - **KDE (Kubuntu, Fedora KDE…):** **Permissions** tab → tick
     **Is executable**.

   <details><summary>Prefer the terminal? Click here.</summary>

   ```bash
   chmod +x ~/Applications/ZipTop-*-x86_64.AppImage
   ```

   </details>
4. Double-click the file. ZipTop opens. Now go to
   [Signing in](#signing-in-same-on-every-computer).

**Opening it later:** double-click the same file again. If you'd like ZipTop
in your app menu, a free helper app such as *Gear Lever* (from your Software
Center) can add AppImages to the menu.

### If double-clicking does nothing

- **Ubuntu (and others): you may need FUSE**, a small system piece AppImages
  use. Open a terminal and run:

  ```bash
  sudo apt install fuse3
  ```

  (Fedora: `sudo dnf install fuse3`.) Then try again.
- **It asks for a "keyring" password, or won't remember your sign-in:**
  ZipTop keeps your sign-in in your system's password keyring. Most desktops
  have one already. If yours doesn't, install **GNOME Keyring**
  (`sudo apt install gnome-keyring`) or use KDE's **KWallet**.
- **No tray icon on Ubuntu:** stock GNOME hides tray icons. ZipTop will
  minimize normally instead, which is fine. To get the tray icon, enable the
  *AppIndicator* extension.

---

## Signing in (same on every computer)

You sign in through the ZipStreams website. You don't type a password into
ZipTop itself.

1. Click **Sign in with your browser**. Your web browser opens the
   ZipStreams sign-in page.
2. Sign in with your ZipStreams account there if it asks.
3. The page asks **Sign in ZipTop on** *your computer's name*? Click
   **Approve**.
4. Go back to ZipTop. It notices within a few seconds and opens your TV
   channels by itself.

Would rather use your phone? Under **Or sign in from another device**,
ZipTop also shows a **short code** and a **QR code**. Scan the QR code with
your phone camera, or go to the web address shown (it ends in **/link**) and
type in the code. If the code runs out of time, ZipTop shows a new one
automatically. Just use the new one.

You only sign in once. ZipTop remembers you after that.

### Signing out

**Settings → Sign out** signs this computer out, on the ZipStreams website
too. Your account page on the website also lists every computer and TV
signed in to your account under **Signed-in devices**, and **Remove** signs
one out from there, for example a computer you no longer have.

---

## Updates

You don't need to download ZipTop again for new versions. When an update is
out, ZipTop tells you when it starts (or check any time in **Settings**).
Say yes, and it downloads the new version, installs it and restarts.

- **Mac:** after an update, macOS may ask if ZipTop can use something from
  your "keychain". Click **Always Allow**. (That's ZipTop reading its own
  saved sign-in.)
- **Linux:** this only works if the AppImage is in a folder you own, like
  the Home → Applications folder suggested above.

---

## Removing ZipTop

- **Windows:** Start → **Settings** → **Apps** → **Installed apps**, find
  **ZipTop**, click **…** → **Uninstall**.
- **Mac:** open **Applications** and drag **ZipTop** to the **Trash**.
- **Linux:** delete the AppImage file.

Your recordings are **not** deleted. They stay in your Videos folder
(**Movies** on a Mac) in a folder called **ZipTop**, unless you chose a
different place in settings. Delete that folder yourself if you don't want
them.

---

## Something went wrong

| Problem | What to do |
|---|---|
| Windows says "Windows protected your PC" | Click **More info**, then **Run anyway**. See [Windows](#windows) step 3. |
| Mac says ZipTop "can't be opened" or "is damaged" | Do the [one-time extra step](#open-it-the-first-time-one-time-extra-step). If it says "damaged", delete ZipTop from Applications, download the DMG again and repeat. |
| Mac says it won't run on this Mac | Your Mac has an Intel chip. Only Apple-chip Macs (M1 and newer) are supported. |
| Linux: double-clicking does nothing, or opens a text editor | You skipped step 3: allow the file to run as a program. Then see [If double-clicking does nothing](#if-double-clicking-does-nothing). |
| The sign-in code stays on screen forever | Check the computer is online. In the browser, make sure you clicked **Approve**, or that you typed the code on the **/link** page exactly as shown. |
| Clicking **Sign in with your browser** does nothing | Click **Copy link** and paste the link into your browser, or use the code on your phone. |
| ZipTop went back to the sign-in screen by itself | It was signed out, from the website's account page or by a password change. Sign in again. |
| I'm never offered updates | Mac: open ZipTop from Applications, not from the download window. Linux: keep the AppImage in a folder you own. |
| Something else | [Open an issue](https://github.com/code0nwheels/ZipTop/issues) and say which computer you have and what you see on screen. A screenshot helps a lot. |
