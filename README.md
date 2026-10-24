# rover_teleop

Android app that drives the rover in manual mode. It talks to `app_foxglove_bridge` on
orintwo over the Foxglove WebSocket protocol (`foxglove.sdk.v1`). It is a submodule of
[navigation_ws](https://github.com/PaulMDavid/navigation_ws) at
`src/app_teleop_phone/flutter`; the robot side (modes, deadman, speed limits) is
`src/app_teleop` there.

- Publishes `/teleop/phone/cmd_vel` at 10 Hz, only while the app is in the foreground.
  Leaving the app or locking the screen stops the stream, and the robot's 0.5 s deadman
  stops the rover.
- `/teleop/phone/set_mode`: Autonomous / Manual / Stop. STOP fires on press, not release.
- Shows `/teleop/state`, the mode the robot is actually in, not what the app last sent.
- Pins its sockets to Wi-Fi (`MainActivity.kt`): orintwo's access point has no internet,
  and Android would otherwise route the app over mobile data.
- Keeps the screen on, vibrates on STOP, remembers the robot address (default
  `10.42.0.1`, orintwo's access point; tap the address at the bottom to change it).
- Landscape only (either way up), full screen. Two pages:
  - **Controls:** status, Autonomous / Manual / Stop and STOP on the left; joystick on
    the right.
  - **Camera** (swipe left or *Camera ›*): the robot's camera full screen, with two
    transparent controls. On the left, a hold-to-drive switch: the joystick counts only
    while it's held. On the right, the joystick. *‹ Controls* goes back; swiping is off
    on this page so steering can't turn the page.
  - `/teleop/camera/compressed` (app_teleop's `teleop_camera`, the ZED) is subscribed
    only while the camera page is showing.

## Build

No Flutter or Android SDK on the host; navigation_ws builds it in a container:

```bash
src/app_teleop_phone/build.sh   # -> src/app_teleop_phone/www/rover-teleop.apk
```

orintwo then serves the APK at `http://10.42.0.1:8080/rover-teleop.apk`. The debug
signing key lives in the `navws_flutter_cache` Docker volume on the machine that builds;
an APK signed with a different key won't install over the old one (uninstall first).

`lib/foxglove.dart` is the protocol client, `lib/main.dart` the UI. The iOS project is
generated but has never been built (needs macOS).
