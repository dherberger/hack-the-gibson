# The Gibson

# Credit Where Credit Is Due
This is a fork of a repo archived by someone that cared enough to keep it alive - I have merely AI slop coded my way to making it work for my purposes; please credit the original maintainers of this work, paulkiernan and John Serafino. They are truly elite.

> "Mess with the best, die like the rest." - Dade Murphey a.k.a. Crash
> Override a.k.a. Zero Cool

A macOS screensaver that flies you through the Gibson from *Hackers* (1995):
canyons of glass towers covered in glowing data, a circuit-board floor whose
traces catch the towers' light, and a low, banking camera.

# Screenshots

![overhead](media/screenshot1.png)

![low_shot](media/screenshot2.png)

![banking](media/screenshot3.png)

# How it got here

1. **John Serafino** built the original Gibson screensaver for Windows on the
   [Irrlicht](https://irrlicht.sourceforge.io) engine
   ([lazerbladegames](https://sites.google.com/site/lazerbladegames/the-gibson)).
2. **Paul Kiernan** ([paulkiernan/hack-the-gibson](https://github.com/paulkiernan/hack-the-gibson))
   pared it down into a windowed OS X app and opened it up to the community.
3. **This fork** rebuilt it as a native macOS screensaver in SceneKit/Metal and
   reworked the look against frames from the film:
   - **Towers:** dark see-through glass covered in bold glowing text that
     flickers, shifting between electric blue and pale cyan with viewing angle
     and over time, with glowing edges and rims. Packed into tight rows like
     the film's canyons, and 15% taller than the original.
   - **Floor:** a generated circuit board (right-angle routing, round vias,
     two trace weights). The floor stays dark; only the traces reflect the
     towers above them.
   - **Camera:** flies low (about a sixth of tower height), banks into turns,
     and swoops over the rooftops once a loop.
   - **Grade:** bloom, saturation, motion blur and cyan pulses streaking
     through the city.
   - **Format:** ships the way Apple's own screensavers do, as an app
     extension (`.appex`) inside `TheGibson.app`, so it runs in its own process
     instead of inside `legacyScreenSaver`.
   - **Performance:** about 35–40% of one CPU core at 60 fps on Apple Silicon.
   - **Code:** the original Irrlicht app is gone from this fork; everything
     is SceneKit/Metal (Objective-C++). The earlier code is still in the git
     history.

# Requirements

- macOS 14 (Sonoma) or later on **Apple Silicon**. The build is arm64 only.
- Xcode Command Line Tools: `xcode-select --install`.
- Nothing else: no Homebrew, no third-party engine.
- Optional: Python 3, only to regenerate the textures (see
  [Regenerating the textures](#regenerating-the-textures)).

# Install the screensaver

```bash
git clone https://github.com/dherberger/hack-the-gibson.git
cd hack-the-gibson
make install-saver
```

(Plain `make` only builds `dist/TheGibson.app`, without installing it.)

`make install-saver` does the following:
- builds `dist/TheGibson.app` with the screensaver extension inside;
- copies it to `/Applications/TheGibson.app`;
- signs it with the best identity in your keychain (Developer ID, then Apple
  Development, then ad hoc);
- registers the extension with `pluginkit`;
- restarts `WallpaperAgent` so the new build is the one that runs;
- removes any old `Gibson.saver` from `~/Library/Screen Savers`.

Then open **System Settings → Screen Saver** and choose **The Gibson**. It
sits with Apple's screensavers, not under "Other". If it doesn't show up, quit
System Settings completely and reopen it.

To set it as the screensaver directly (idle and hot corners), without going
through System Settings:

```bash
make enable-saver
```

This writes the choice into macOS's wallpaper settings. It backs up the
original file first, as `Index.plist.gibson-bak` next to it in
`~/Library/Application Support/com.apple.wallpaper/Store/`.

To remove it:

```bash
make uninstall-saver
```

## Preview without the screensaver

```bash
make scn
# or: ./src/scn_preview          (Escape or Q to quit)
make run-app
# opens dist/TheGibson.app, a preview window
```

Opening the installed `/Applications/TheGibson.app` also re-registers the
screensaver extension, which helps if System Settings loses track of it.

## Settings

Camera, banking and music settings live in a plain-text file, created on
first install:

```
~/Library/Application Support/TheGibson/config.txt
```

| Key | Default | What it does |
|---|---|---|
| `fly_speed` | `0.55` | Speed along the flight path. The original demo was `0.9`. |
| `bank_strength` | `0.45` | How hard the camera leans into turns; `0` keeps it level, and a negative value flips the direction. |
| `bank_max_degrees` | `32` | The most it will roll, in degrees (0–90). |
| `bank_smoothing` | `0.55` | Seconds of lag on the roll. Higher is smoother. |
| `music` | `music.mp3` | Audio file to loop while the screensaver runs (see [Music](#music)). `off` for silence. |
| `music_volume` | `0.6` | Music volume, 0–1. |

The saver re-reads the file each time it starts. `make install-saver` never
overwrites your values, and it adds any new settings to an older file.

## Music

The screensaver can loop a soundtrack while it runs. No music ships with the
project; bring your own. For example, Simon Boswell's *Hackers* suite:

```bash
cp ~/Downloads/your_track.mp3 ~/Library/Application\ Support/TheGibson/music.mp3
```

- **When it plays:** the track fades in when the screensaver starts and fades
  out when it stops. It plays once even with several displays, and it stays
  silent in System Settings' small preview.
- **Where the file goes:** the screensaver is sandboxed, so the file has to be
  in `~/Library/Application Support/TheGibson/` (next to `config.txt`). Any
  format macOS can play works, such as MP3, AAC/M4A or WAV. To use a different
  name, set `music = name.m4a`.
- **No file?** If there's no file, or `music = off`, it stays silent.

## Sharing it with other Macs

On another Mac you own, you can simply clone the repo and run
`make install-saver` there. To hand someone a pre-built copy that Gatekeeper
accepts, you need a **Developer ID Application** certificate and notarization:

1. Create the certificate at [developer.apple.com](https://developer.apple.com/account/resources/certificates)
   (Certificates → **Developer ID Application**), download it, and double-click
   it to add it to Keychain.
2. Store notary credentials once:
   `xcrun notarytool store-credentials AC_PASSWORD --apple-id you@email.com --team-id TEAMID`
3. Run `make notarize NOTARY_PROFILE=AC_PASSWORD`. This builds, signs,
   notarizes and staples `dist/TheGibson.app`, and leaves a zip at
   `dist/TheGibson.zip`.

# Regenerating the textures

The tower text and the circuit-board floor in `media/` are generated by
`tools/gen_textures.py`, so you can change the look without hand-editing
images.

```bash
python3 -m venv tools/.venv
tools/.venv/bin/pip install pillow numpy
tools/.venv/bin/python tools/gen_textures.py                 # towers + floor
tools/.venv/bin/python tools/gen_textures.py --floor-only    # just the floor
make install-saver                                           # picks up the new media
```

- `--seed N` gives a different layout. The default is `1995`.
- `--floor pcb` (the default) is the circuit-board floor. Its density is
  `PCB_COVERAGE` in the script.
- `--floor movie` is a board laid out from proportions measured on the film's
  floor.
- `--floor legacy` brings back the original floor art. It is drawn at a
  different scale, so set `FLOOR_REPEAT` in `src/scenekit/GibsonSCNScene.mm`
  to `2` to match.
- The tower look (glass opacity, tint, text size) is set by constants near the
  top of the script, such as `BODY_TINT`.

To render frames offscreen, for comparing or making screenshots:

```bash
./src/scn_preview --sequence out/ --count 18 --interval 0.5 --size 1600 1000
```

`tools/trace_analysis.py` is the script that measured the film's floor
traces. It needs `opencv-python-headless` in the same venv, plus movie stills,
which are not included in the repo.

# Classic `.saver` plug-in

The first native version of this screensaver, a classic `.saver` plug-in
that runs inside `legacyScreenSaver` (macOS 11+), can still be built with
`make legacy-saver`. It shows up under "Other" in System Settings.
`make install-saver` removes it so only the app extension is registered.

# Known issues

1. **Black screen after a reinstall:** this happens if `WallpaperAgent` is
   still holding the previous build. `make install-saver` restarts it; if you
   copy the app by hand, run `killall WallpaperAgent` afterwards.
2. **Stale preview in System Settings:** quit System Settings completely and
   reopen it.
3. **Intel Macs are not supported** (the build is arm64 only).

# Credit

All credit goes to the leet [John Serafino](https://sites.google.com/site/lazerbladegames/the-gibson)
for the original Windows version of this screensaver, and to
[Paul Kiernan](https://github.com/paulkiernan/hack-the-gibson) for bringing it
to the Mac.

# License

Licensed under the GPL v3 License.
