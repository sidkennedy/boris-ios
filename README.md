# Boris for iPhone

A small native LiveKit client: tap to talk, mute, end the call, open your session dashboard. It uses the separate Boris server you run on your Mac. The server address and Boris access key are entered on the phone. No credentials are compiled into this app.

The audio session uses `playAndRecord` / `voiceChat` and the iOS audio background mode. This is the native path for continuing a call while using other apps. Device behaviour still needs to be verified on your iPhone. Calls stop at the server's configured deadline.

## Free installation

Apple's paid developer membership is not required for personal sideloading. AltStore Classic uses a free Apple account to sign the compiled `.ipa`. Free signing lasts seven days and allows three active apps (including AltStore). Keep AltServer available on your Mac to refresh regularly. Apple sign-in, device trust, and Developer Mode are actions you complete yourself. Never send your Apple password to Boris.

1. Compile this client once, using either option below.
2. Install AltServer for macOS from https://altstore.io/ and follow https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos.
3. Connect your iPhone, trust the Mac, install AltStore Classic and complete Apple's Developer Mode prompts when requested.
4. Download/unzip the build artifact to get `Boris.ipa`; add it using AltStore's plus button.
5. Enter the current HTTPS address and access key from the Mac's private `.runtime/PHONE-ACCESS.txt` file. Tap the microphone.
6. Test with another app in the foreground. Confirm Boris hears a request and announces a sandbox task completion. Check that End call removes the room and microphone indicator.

This is AltStore **Classic**, not the regional AltStore PAL marketplace. A free app must refresh within seven days; it is not a permanent install.

## Compile without installing Xcode on your Mac

The included manual GitHub Actions workflow builds an unsigned app on a standard macOS runner; it needs no Apple credentials or server secrets. Publish only this `ios` directory as the repository root, then run **Build Boris for free sideloading** under Actions. Download `Boris-unsigned-for-AltStore` after it succeeds. Standard runners are free for public repositories. A private repository uses the account's included allowance and can incur overages; do not assume private builds are free without checking its budget.

Publishing source is a separate choice. No repository has been published by preparing this workflow. Only client code belongs in that repository: never upload the parent workspace's `.env`, `.runtime`, credentials, or application repositories.

## Compile with Xcode

Install Xcode (free), then XcodeGen. Run `xcodegen generate` from this folder and open `Boris.xcodeproj`. Select your own Personal Team under Signing & Capabilities and your connected iPhone, then Run. A paid team is optional. The LiveKit Swift dependency is pinned to 2.17.0.

## Verification status

Swift syntax and Info.plist validation passed locally. An actual iOS SDK build and physical iPhone background-audio test are required before calling the native app verified. The Mac does not currently have full Xcode or an Apple signing identity.
