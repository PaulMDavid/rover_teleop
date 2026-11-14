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
- `/teleop/phone/rover_cmd` / `/teleop/rover_state`: arms the rover's `robot_control`
  and switches its modes through orintwo, which presses `/joy` for it and tracks
  (guesses) its state (navigation_ws #23).
- Pins its sockets to Wi-Fi (`MainActivity.kt`): orintwo's access point has no internet,
  and Android would otherwise route the app over mobile data.
- Keeps the screen on, vibrates on STOP, remembers the robot address (default
  `10.42.0.1`, orintwo's access point; tap the address at the bottom to change it).
- Landscape only (either way up), full screen. Four pages, left to right
  System, Wheels, Controls, Camera, opening on Controls:
  - **System** (swipe right from Wheels or *‹ System*): brings the robots up over ssh to
    orintwo, which runs `scripts/phone_ctl.sh` (navigation_ws #27). On the left, each
    step as phone_ctl.sh streams it (✓ ok with its time, ✗ fail with the reason in red,
    ⟳ running, ! warn, – skipped; rows from an earlier run dimmed); long-press a row for
    its log (`log <step>`). On the right: *UP* (`up`), *STOP* (`stop`; always on, also
    cancels a running verb), *Camera on* (`camera`), *Status* (`status`), *Recenter
    wheels…* (explains, tick FL 11 / FR 12 / RL 13 / RR 14, confirm → `zero <ids>`, shows
    its steps) and *Show public key* (copy / share).
    - ssh: user `orintwo`, to `orintwo.local`, then the address typed on this page (tap
      the host in the header), then the robot address. The key is ed25519, generated on
      the phone on first use and kept in Android secure storage; `phone_link.sh` installs
      it on orintwo, restricted to `phone_ctl.sh`. orintwo's host key is trusted on first
      use and pinned (MD5, as `ssh-keygen -l -E md5` prints it); a different key refuses
      the connection with a red banner until you accept it.
  - **Wheels** (swipe right or *‹ Wheels*): robot_control's modes as orintwo tracks them
    (input, steering, motion, last command; "⚠ GUESSED STATE" while `tracked`) and the
    mux state on the left. On the right: *Input → /cmd_vel*, *Crab | Ackermann*,
    *Resume*, *HOLD TO ARM* (hold 1 s: mux to Manual, then `arm`), *Reset* (after
    robot_control restarts, with a confirm) and the same STOP. The buttons are off, with
    the reason, without a link or when the mux source isn't `phone`; STOP always works.
    A drag that starts on a button doesn't turn the page. The Wheels column also goes up
    and down: *Autonav* above (Nav2 goals, navigation_ws #30), *Record* below.
  - **Record** (swipe up from Wheels or *⌄ Record*; navigation_ws #29): starts and stops
    a bag on orintwo through `phone_ctl.sh record …` over the System page's ssh. Preset
    (`drive` preselected), its groups as checkboxes, *All topics…* (`record topics`:
    search, type, Hz, MB/s; ticks become `+/topic` / `-/topic` on START). *● START*,
    *■ STOP* (asks first; stops the recording only) and the live `record status` while
    the page shows: elapsed, bag, size, rate, free SSD, hours left, silent topics,
    unclosed bags. The rover's mux STOP is the small *MUX STOP* in the header.
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

`lib/foxglove.dart` is the protocol client, `lib/main.dart` the UI,
`lib/phone_ctl.dart` the ssh layer and the system page's state, `lib/system_page.dart`
its UI, `lib/record.dart` / `lib/record_page.dart` the record page's state and UI,
`test/wheels_page_test.dart`, `test/system_page_test.dart` and
`test/record_page_test.dart` widget tests (the last two with a fake ssh layer) (`flutter test`, in the
same builder container). The iOS project is
generated but has never been built (needs macOS).
