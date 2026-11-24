# Display Sound

A small menu bar app for Macs with two Apple Studio Displays, used together as one stereo speaker pair.

macOS can play to both displays through a Multi-Output Device, but once you do, the volume keys and the menu bar volume slider stop working. The two displays also come back from sleep at different volumes now and then. Display Sound fixes both, and adds an optional equalizer.

## What it does

- **Volume keys work again.** Volume up, down and mute set both displays at once, with an on-screen volume indicator.
- **Keeps the two speakers matched.** If one display drifts louder (common after wake), the louder one is lowered to match. It never raises the volume on its own.
- **Shared 5-band equalizer** (bass, 250 Hz, 1 kHz, 4 kHz, treble, ±12 dB). It uses a Core Audio process tap (macOS 14.4+), so there's no virtual audio driver or kernel extension to install. Audio is processed in memory and never leaves the Mac.
- A panel with per-display levels, volume slider, mute and EQ sliders. Settings are remembered.

About 450 lines of Objective-C, no dependencies.

## Requirements

- macOS 14.4 or later
- Two Studio Displays connected (the app looks for two devices named "Studio Display Speakers")
- Xcode command line tools to build

## Setup

Download it from https://display-sound.pages.dev, or clone the source and build it yourself:

```sh
git clone https://github.com/yoniamir/display-sound.git
cd display-sound
```

Then:

```sh
./build.sh "/Applications/Display Sound.app"
open "/Applications/Display Sound.app"
```

`build.sh` signs ad hoc by default. Pass `SIGN_IDENTITY="Apple Development: …"` to sign with your own certificate, which keeps macOS permissions across rebuilds.

On first run:

- Click **Use both displays**. The app combines the two displays into one stereo output called "Both Studio Displays" and switches your Mac to it.
- Click **Enable volume keys…** and allow Display Sound under Privacy & Security → Accessibility. It needs this to see the volume keys.
- Turning on **Shared equalizer** asks for permission to capture system audio. That's how the EQ reads what's playing before sending it to the displays.

## How it works

`Audio.m` reads and sets the volume and mute of each display directly, since the combined device has no volume control of its own. When the EQ is on, it creates a private process tap on the combined device (muting the original stream), runs the audio through five RBJ biquad filters, and writes the result straight to both displays through a private aggregate device. `App.m` is the menu bar item, the panel, the volume key event tap and the on-screen indicator.

## Similar projects

Worth a look if this doesn't fit your setup:

- [Halo](https://github.com/flight-william/Halo) and [MultiSoundChanger](https://github.com/rlxone/MultiSoundChanger): volume keys for any Multi-Output Device.
- [Nearfield](https://producthunt.com/products/nearfield): combines two Studio Displays into one stereo output, using a virtual driver.
- [FineTune](https://github.com/ronitsingh10/FineTune): per-app volume mixer with multi-device output.
- [eqtune](https://docs.rs/eqtune): system-wide equalizer built on process taps.
- [SoundSource](https://rogueamoeba.com/soundsource/) (commercial): volume keys for any output, plus EQ.

Display Sound is narrower than these. It does one setup, two Studio Displays, and adds level matching and an EQ in a single small app.

## License

MIT
