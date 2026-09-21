# <img src="./web/public/logo-light.svg#gh-dark-mode-only" alt="MacID logo" width="26" height="45" align="center" /><img src="./web/public/logo-dark.svg#gh-light-mode-only" alt="MacID logo" width="26" height="45" align="center" /> MacID

Face unlock for the macOS lock screen. Wake your Mac, press Return on the empty
password field, and if the camera recognizes you, you're in.

Download it from [macid.akshith.io](https://macid.akshith.io), or build it:

    make
    sudo make install

[How it works](https://akshith.io/notes/macid) covers the details.

## Before you install

- **A webcam isn't Face ID.** A good photo of you can unlock it. Turn on
  **Require a blink** to stop a still photo; it won't stop a video.
- **Your password always works.** If anything fails, you get the normal
  password prompt. MacID can't lock you out.
- **macOS updates can break it**, since the lock screen's PAM stack isn't an
  official API.

## Licence

The code is MIT. The bundled face model isn't: InsightFace's weights are for
non-commercial use only. See [NOTICE](NOTICE).
