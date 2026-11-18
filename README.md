# Mixer

A menu bar app for per-app volume on macOS (14.4 or later).

- Volume slider and mute for every running app, from 0% to 200% (above 100% is boost, shown in orange)
- Remembers each app's level, mute and output and restores them when the app is reopened
- Master volume and mute for the current output device
- Pick the system output device, or send a single app to a different device (⋯ menu on its row)
- "Open at login" checkbox

## Install from the DMG

1. Download `Mixer-<version>.dmg` from the Releases page and open it.
2. Drag **Mixer** onto the **Applications** shortcut.
3. The app isn't notarized by Apple, so the first launch is blocked. Open it once, then go to
   System Settings → Privacy & Security and click **Open Anyway**. You can also run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Mixer.app
   ```

## Build from source

Needs macOS 14.4+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh install
```

This builds `build/Mixer.app`, copies it to `/Applications` and launches it. `./build.sh` alone only builds,
and `./build.sh dmg` also creates `build/Mixer-<version>.dmg`.

The first time you move a slider away from 100%, macOS asks for the **System Audio Recording** permission. Allow it.
If you declined, use **Audio Permission…** in the panel footer, or go to System Settings → Privacy & Security → Screen & System Audio Recording.

## How it works

An app at 100%, unmuted and on the system output is left completely alone. When you change an app's setting, Mixer:

1. Creates a Core Audio process tap on that app's audio processes (including helpers such as browser renderer processes), which silences its normal output.
2. Creates a private aggregate device made of that tap plus the chosen output device.
3. Plays the tapped audio back at the new gain. When boosting, a soft limiter keeps loud peaks from crackling.

When you quit Mixer, every tap is removed and all apps return to their normal output.

## Notes

- The app has an ad-hoc signature (no developer certificate). After each rebuild macOS may ask for the audio permission again.
- The slider follows a perceptual curve, so 50% sounds about half as loud.
- Apps that haven't opened audio yet are shown dimmed. Any setting you give them takes effect as soon as they play sound.

## License

MIT. See [LICENSE](LICENSE).
