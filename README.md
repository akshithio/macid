# MacID

Face unlock for the macOS lock screen.

Wake the Mac, press Return on the empty password field, and if the camera
recognizes you, you are in.

    curl -fsSL https://macid.akshith.io/install.sh | bash

## How it works

    you press Return at the lock screen
        |
        v
    pam_macid.so  (auth sufficient, first line of /etc/pam.d/screensaver_new)
        asks VERIFY over ~/Library/Application Support/MacID/agent.sock
        |
        v
    agent (inside MacID.app, or `macid run` under launchd for CLI installs)
        camera on -> Vision detection -> featureprint -> compare
        eyes open (attention), optionally a blink
        answers from what it sees now, then camera off
        |
        v
    pam_macid.so
        OK      -> PAM_SUCCESS, stack short-circuits, you are in
        NO/fail -> PAM_IGNORE, password stack runs as normal

### Why `screensaver_new`

macOS 26 does not use `/etc/pam.d/screensaver`. It uses `screensaver_new`, and
it calls the stack with the typed password already collected — including when
that password is empty. That empty submission is the hook the whole thing hangs
on, and it was confirmed empirically with `pam/pam_macidprobe.c` before any of
this was written. See [The probe](#the-probe).

## Install

    curl -fsSL https://macid.akshith.io/install.sh | bash

or from a clone:

    make
    sudo make install

### The app

Open MacID. Setup walks through camera access, enrolling your face, and turning
on face unlock (macOS asks for your password once, for the lock screen change).
After that it lives in the menu bar and starts at login. The app runs the agent
itself, so the camera permission macOS shows is MacID's, not Terminal's.

    open -a MacID

The app bundle carries the `macid` tool and `pam_macid.so` in
`Contents/Helpers`, and installs them through the standard administrator
prompt by running the same `macid install` every other path uses.

### The command line

`enroll` calibrates the match threshold from how much your own samples vary — a
threshold not derived from your face is just a guess.

| command | |
|---|---|
| `macid enroll [n]` | Capture n samples (default 8) and calibrate |
| `macid test` | Run recognition live |
| `macid status` | Show what is wired up |
| `macid run` | The agent itself; launchd does this for you |
| `sudo macid install` | Wire the PAM stack and load the agent |
| `sudo macid uninstall` | Remove everything, restore the PAM backup |
| `macid reset` | Delete enrolled face data |

## Security

Read this part.

**A webcam is not Face ID.** Apple's Face ID projects ~30,000 infrared dots and
matches a depth map. This matches a 2D image. By default MacID unlocks when it
sees the enrolled face with eyes open — so a good photo of that face can unlock
it too. Turning on **Require a blink** stops a still photo; it will not stop a
video. Treat this as a convenience over typing, not as a security upgrade over
your password.

**Failure is always toward the password.** `pam_macid.so` returns only
`PAM_SUCCESS` or `PAM_IGNORE`, never `PAM_AUTH_ERR`. Agent crashed, socket
missing, camera denied, face not recognized, agent slow past the module's 5s
timeout — every one of those falls through to the normal password prompt.
Breaking MacID cannot lock you out of your Mac.

**Recognition happens at the moment of the unlock.** Pressing Return is what
starts the camera; the agent answers from what it sees right then and turns the
camera back off. There is no standing window during which the machine will
open — walk up an hour later and it still just works, and a face recognized
earlier never carries an unlock. Only the root PAM module may ask; a VERIFY from
any other process is refused.

**Path checks before trust.** The PAM module runs as root and refuses the socket
unless both it and its directory are owned by the target user and not
group/world writable. Otherwise another account could plant a socket that always
answers OK. The agent checks the peer uid on its side too.

**Known limitation:** a process already running as *you* could bind that socket
path if the agent were not running, and vouch for you. Defending against that
needs peer code-signature verification, which is not implemented here.

**Nothing leaves the machine.** Recognition runs on-device through Vision. No
image, no featureprint, no telemetry. The camera indicator light is
hardware-wired and stays on only between lock and a match (or a 60s timeout).

## The probe

`pam/pam_macidprobe.c` and `scripts/probe.sh` are the diagnostic scaffolding
used to find all this out. Kept because they are the fastest way to answer "is
my PAM stack even being called" on a future macOS version, which is the question
that will break this first.

    sudo ./scripts/probe.sh go      # log every auth attempt, change nothing
    ./scripts/probe.sh log
    sudo ./scripts/probe.sh remove all

Findings on macOS 26.5.2:

| stack | consulted at lock screen |
|---|---|
| `screensaver` | no |
| `screensaver_new` | **yes** — `authtok` pre-filled, `authtok_len=0` on empty Return |
| `screensaver_la` | no (LocalAuthentication path: Touch ID / Watch) |
| `sudo` | yes, `authtok` not set — module runs before the prompt |

## Caveats

- **Recognition quality.** Uses `VNGenerateImageFeaturePrintRequest`, a general
  image descriptor, not a dedicated face embedding. It ships with the OS, so
  there is no model to download or keep in sync, but it separates similar faces
  less well than ArcFace or FaceNet would. `FaceEngine.Descriptor` is the only
  type the rest of the code sees, so swapping in a CoreML embedding is a
  one-file change.
- **Camera permission** must be granted while unlocked — no TCC prompt can
  appear at the lock screen. `macid enroll` is what triggers it.
- **Ad-hoc signing.** Binaries are signed `-`, so their code identity is a
  cdhash that changes on every rebuild. Rebuilding can drop the camera grant;
  re-grant in System Settings > Privacy & Security > Camera.
- **macOS upgrades will break this.** `screensaver_new` is not API. Re-run the
  probe after any major update.

## Repo layout

This is a monorepo. One Swift package at the root builds the shared library,
the CLI, and the app so the three can never disagree about what counts as a
match.

    Package.swift          root SwiftPM manifest: MacIDCore + macid + MacIDApp
    Makefile               build, install, dist
    install.sh             the curl installer

    core/Sources/MacIDCore/
      FaceEngine.swift     detect, crop, featureprint, compare
      Camera.swift         AVCaptureSession -> CGImage
      Agent.swift          the unlock agent, hosted by the app or `macid run`
      Recognizer.swift     identity, attention, optional blink
      Calibration.swift    threshold and open-eye baseline from enrollment
      Enrollment.swift     storage, paths, config
      LockScreen.swift     read-only PAM wiring checks
      SocketServer.swift   VERIFY/STATUS socket, root-only VERIFY, peer uid check
      LockMonitor.swift    screenIsLocked / screenIsUnlocked

    agent/Sources/macid/
      main.swift           CLI: enroll / test / run / status / reset
      Install.swift        PAM wiring + launchd, shared by every install path

    app/Sources/MacIDApp/  MacID.app: setup, home, menu bar, enroll/test panels
    tools/make-icons.swift renders app/Resources/MacID.icns
    pam/                   pam_macid.c, pam_macidprobe.c
    scripts/               probe.sh and helpers
    web/                   macid.akshith.io — Next.js, TypeScript, Tailwind

## Development

    make            # pam modules + swift + MacID.app
    make icons      # re-render the app icon
    make dist       # source tarball into web/public for the site
    cd web && npm run dev

## License

MIT
