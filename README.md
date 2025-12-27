# Bragi

A lightweight, fast application launcher for Linux written in Odin, inspired by rofi and dmenu.

![Odin](https://img.shields.io/badge/Odin-0.13+-blue)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

## Building

#### Dependencies

- Odin compiler (0.13+)
- Linux with X11 or Wayland (via XWayland)

```bash
# Clone the repository
git clone https://github.com/vlshields/bragi.git
cd bragi

# Build release binary
odin build ./src -out:bragi -o:speed

# Or debug build
odin build ./src  -out:bragi -debug
```

## Installation

```bash
# Copy to your path
sudo cp bragi /usr/local/bin/

# Or install to user directory
cp bragi ~/.local/bin/

# Or use symlinks (Recommended)
sudo ln -s $(pwd)/bragi /usr/local/bin/bragi
```
using a symlink is the prefered method because you don't have to remember to copy the binary again after
any updates.


## Usage

```bash
# Launch the application
bragi

# Bind to a hotkey in your window manager
# Example for i3/sway:
# bindsym $mod+d exec bragi

# Example for Hyprland:
# bind = $mainMod, D, exec, bragi
```

## Keybindings

| Key | Action |
|-----|--------|
| `Enter` | Launch selected application |
| `Escape` | Close launcher |
| `Up` / `Down` | Navigate through results |
| `Backspace` | Delete character from search |
| Any character | Add to search query |

## How It Works

The launcher scans for `.desktop` files in these directories:

- `/usr/share/applications`
- `/usr/local/share/applications`
- `~/.local/share/applications`

It parses the `Name` and `Exec` fields, filters out entries marked `NoDisplay=true`, and presents them in a searchable list. The fuzzy matching algorithm scores results based on:

- Character matches (+10 points)
- Consecutive character matches (+5 bonus)
- Matches at the start of words (+15 bonus)

## Configuration

Currently configuration is done by modifying constants in the source:

```odin
VISIBLE_ITEMS :: 10      // Number of items shown at once
ITEM_HEIGHT :: 32        // Height of each list item in pixels
WIDTH :: 600             // Window width
HEIGHT :: 400            // Window height
```

Colors can be adjusted in the `draw` procedure.

## Project Structure

```
.
├── src--odinlauncher.odin    # Main source file
├── README.md
└── LICENSE
```

## Roadmap

- [ ] Icon support (parse `Icon=` field and load from icon themes)
- [ ] Launch history with frecency sorting
- [ ] .desktop file and icon


## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License — see [LICENSE](LICENSE) for details.

## Acknowledgments

- [Odin Programming Language](https://odin-lang.org/)
- [Raylib](https://www.raylib.com/)
