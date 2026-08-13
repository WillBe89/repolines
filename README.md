# RepoLines

A macOS desktop widget that shows the size of a code repository at a glance. It
counts the lines in a folder, splits them into categories, and shows a language
breakdown bar in the style of a GitHub repository page.

The widget sits on the desktop behind your other windows. It has a frosted glass
panel with a live refraction effect along its edge.

## What it shows

- A written total: your code and documentation added together.
- Four buckets: code and config, documentation, core datasets, third-party and
  generated.
- A language bar coloured by language, with anything under one percent grouped
  as Other.

## Features

- Track several repositories as tabs and switch between them with one click.
- A custom display name and logo per repository. The folder is never renamed.
- Live desktop refraction on the bezel, drawn from the screen behind the widget.
- Sits behind application windows but stays interactive.
- A settings panel for the look: centre opacity, distortion, blur, bezel width,
  edge feather, accent colour, text colour, and font.
- Fast rescans. It only re-reads files when the git state changes.

## Requirements

- macOS 14 (Sonoma) or later.
- The refraction effect uses ScreenCaptureKit and needs Screen Recording
  permission. Every other feature works without it.

## Install

1. Download the latest release and unzip it.
2. Move RepoLines.app to your Applications folder.
3. The app is self-signed and not notarized, so macOS blocks it on first launch.
   Right-click the app, choose Open, then confirm. You only do this once.
4. For the refraction effect, open System Settings, go to Privacy and Security,
   then Screen Recording, and turn on RepoLines. Quit and reopen the app so it
   reads the new permission.

## Usage

- Click the plus in the tab row to add a repository folder. A minus appears once
  you have more than one.
- Right-click a tab to rename or remove it.
- Click the name to set a display name. The folder on disk is not changed.
- Click the logo to choose an image for that repository.
- Click the sliders icon to open the glass settings.
- Drag the widget anywhere. It remembers its position.

## How the count works

Files are listed with `git ls-files` when the folder is a git repository, so the
count respects `.gitignore`. For a plain folder it walks the directory and skips
common build folders.

Each file is sorted into a bucket by its path and extension. Lockfiles, minified
files, and vendored paths count as third-party. Data files count as datasets.
Markdown and text count as documentation. Everything else counts as code. The
language bar uses only the code and documentation files, so bundled data does
not distort it.

## Build from source

Requires the Xcode command line tools.

    ./build.sh      # compile into RepoLines.app
    ./install.sh    # build, copy to ~/Applications, set up launch at login

`build.sh` signs the app with a code-signing identity named "RepoLines Local
Signing" if one is present in your keychain. Signing with a stable identity
keeps the Screen Recording permission from resetting on every rebuild. Without
that identity the build still works; it is signed ad-hoc instead.

## License

MIT. See LICENSE.
