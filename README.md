# Hydra AVD Client

The disk image is [Hydra AVD Client.dmg](mac/HydraRdp/build/Hydra%20AVD%20Client.dmg).

## Opening the app on another Mac

macOS blocks this copy because it is only ad-hoc signed and was downloaded from the internet. Gatekeeper then reports that it cannot verify the app is free of malware. That check is about the missing Apple Developer signature, not a virus found in the app.

Copy **Hydra AVD Client** into Applications, then run this in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Hydra AVD Client.app"
```

Open the app from Applications after that. If macOS still shows the warning, Control-click the app, choose **Open**, and confirm. On newer macOS, the same approval is under **System Settings → Privacy & Security → Open Anyway**.

A normal double-click will keep failing until the app is signed with an Apple Developer ID and notarized.
