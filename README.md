# Boris for iPhone

A small native LiveKit client: tap to talk, mute, end the call, open your session dashboard. It uses the separate Boris server you run on your Mac. The server address and Boris access key are entered on the phone. No credentials are compiled into this app.

## Session notifications

Open connection settings and tap **Enable notifications**, then allow alerts, sounds,
and badges in iPhone Settings. Boris alerts you when a session's turn ends or needs
input, a task completes, or a session fails, pauses, stops, or disconnects. Tapping
an alert opens that session in the dashboard. Alerts contain the session name and
status, never transcripts or coding instructions. `AWAITING_INPUT` does not imply
that the entire task succeeded.

The ordinary free-sideloaded build uses local notifications. It listens independently
of voice while the app is active, and can continue during an ongoing background
voice call. It cannot receive new server events when iOS suspends the app after a
call ends or the app is force-closed. Existing delivered alerts remain in Notification
Center. Enablement and the last event cursor persist, so reconnecting does not replay
already delivered events. The badge counts sessions awaiting input and refreshes while
the app is running.

For remote notifications while Boris is suspended, use a push-enabled Apple signing
team and configure APNs on the control server. This is optional; the ordinary
`project.yml` keeps the existing free-sideloading path. The settings screen explicitly
shows whether remote or local alerts are available.

1. Enable Push Notifications for the `com.sidney.boris` app identifier and create an
   Apple APNs signing key. Keep its `.p8` file on the control server, outside source
   control; provider credentials never belong on the phone.
2. Set `BORIS_APNS_KEY_ID`, `BORIS_APNS_TEAM_ID`, `BORIS_APNS_KEY_PATH`, and
   `BORIS_APNS_TOPIC` (default `com.sidney.boris`) on that server and restart the
   control service. `/api/notifications` reports configuration readiness after sign-in.
3. Generate the push-enabled project using `xcodegen generate --spec project-push.yml`,
   select the matching Apple team, and sign with a profile that includes push.
   Debug uses development APNs; Release uses production APNs. If your distribution
   profile uses a different environment, keep `BORIS_APNS_ENVIRONMENT` and the
   `BORIS_APNS_PRODUCTION` compilation flag consistent with that profile.
4. Enable notifications in the app. It registers the APNs token with your private
   Boris server and retries on reconnect. The server sends queued alerts even with
   no active voice call, retains unsent events across restarts, and removes invalid
   device tokens. Turning notifications off unregisters the device when connected.

Reference behavior: [Vicoa's mobile notifications](https://github.com/vicoa-ai/vicoa/blob/main/apps/mobile/lib/backend/push_notifications/push_notifications_handler.dart).
This native Swift client uses Apple's UserNotifications and APNs directly, without
requiring Vicoa's Firebase configuration. See [Apple's APNs registration guide](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns).

Verification for this change: Python tests cover authenticated device registration,
status alerts without a voice call, durable cursors, retries, and invalid tokens.
The updated Swift source still needs an iPhone SDK build and physical-device testing
of foreground banners, background-call alerts, remote delivery, notification taps,
permission denial, and disabling notifications. The successful build linked below
predates this notification change.

The app owns a `playAndRecord` / `voiceChat` audio session with `mixWithOthers`,
`defaultToSpeaker`, and the iOS audio background mode. Music coexistence is always
enabled during a call, with the microphone open or muted. LiveKit automatic session
configuration is disabled so capture/playout changes cannot remove mixing. Apple
voice processing remains enabled for echo cancellation, with minimum fixed ducking.
Start Spotify playback before or during a call; music uses the iPhone speaker when
no headset or external audio route is connected. Muting only disables microphone
publication and does not deactivate the shared audio session. Ending the call
deactivates it and notifies other audio apps. This is the native path for continuing a call while using other apps. Device behaviour still needs to be verified on your iPhone. Calls stop at the server's configured deadline.

## Voice startup

The app shows which startup step is pending: microphone permission, sign-in,
starting the call, or connecting audio. It starts microphone capture alongside
the LiveKit connection. Audio connection attempts have a 25-second deadline;
sign-in requests time out after 15 seconds and call-start requests after 30.
The server limits room creation and dispatch to 15 seconds, with up to 5 seconds
for cleanup on failure. It does not automatically retry call creation.

The worker preloads the speech-detection model in its idle process. Timing-only
logs record server room/dispatch setup, worker connection/session/greeting, and
iPhone HTTP/audio startup under the `voice-startup` logging category. They contain
no access keys or conversation text. These changes remove avoidable startup work
and help locate remaining delays; physical-device startup latency still needs
measurement with a newly built app.

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

Swift syntax and Info.plist validation passed locally. A full iPhone SDK build succeeded on the standard GitHub runner: https://github.com/sidkennedy/boris-ios/actions/runs/38226939429. Installing on a physical iPhone and testing background audio are still required. The Mac does not currently have full Xcode or an Apple signing identity.

## Noise and music verification

The server uses Silero VAD, not Deepgram, to detect speech and interruptions.
The default speech activation threshold is 0.75 (previously 0.5), with 150 ms of
speech required (previously 50 ms). Interruption requires a recognized word and
650 ms of speech activity (previously zero words and 500 ms); a one-word command
can also interrupt when its transcript arrives. The 500 ms default prefix buffer
preserves speech onset. False interruptions resume after one second. The four
`BORIS_VAD_*` / `BORIS_INTERRUPTION_*` variables in `.env.example` allow tuning.

On an iPhone, play Spotify through the built-in speaker, start a Boris call, mute
and unmute repeatedly, switch to Spotify, and confirm music continues in both
mic states. Check audible agent replies and intentional short speech, including
"stop" and "yes". Repeat outdoors with wind and indoors with background noise;
confirm noise alone does not repeatedly cut off replies. End and reconnect the
call, and test headset routing separately. Music can still be slightly attenuated
by Apple's voice processing; speaker music containing vocals can be recognized
as speech, so physical-device testing is needed to tune this tradeoff.
