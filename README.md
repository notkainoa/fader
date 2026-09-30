# Sliders

[![CI](https://github.com/notkainoa/sliders/actions/workflows/ci.yml/badge.svg)](https://github.com/notkainoa/sliders/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/notkainoa/sliders)](https://github.com/notkainoa/sliders/releases/latest) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A macOS menu bar app for audio output switching and per-app volume. Switch the output device in one click, connect Bluetooth headphones, set a separate volume for every app, and play audio to several devices at once. Site: [sliders.pages.dev](https://sliders.pages.dev).

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/hero-dark.png"><img src="docs/hero-light.png" alt="Three overlapping Sliders popovers: the output tab with audio devices, an app routed to two output devices with per-device volume, and Bluetooth headphones with Connect"></picture></p>

No telemetry, no kernel extension, no virtual audio driver — the source is open, check for yourself. Requires macOS 15+ on Apple silicon.

Sliders is a fork of [Fader](https://github.com/pantafive/fader) by pantafive, extended with a now-playing view for every app and browser tab.

## Install

Download [the latest dmg](https://github.com/notkainoa/sliders/releases/latest/download/Sliders.dmg). The app updates itself.

## Features

- **Output switching** — headphones, speakers, displays, and AirPlay targets, one click each. Paired Bluetooth headphones connect from the same list.
- **Auto-switch** — drag rows to rank devices; Sliders follows the best one present.
- **Several outputs at once** — drag a device onto the Output section and both play together, each with its own slider.
- **Per-app volume** — a slider and mute for every app that plays sound; levels persist. Apps at full volume play untouched, bit-perfect.
- **Per-app output** — drag one or more devices onto an app to play it through exactly those outputs, each with its own volume; everything else stays on your main output.
- **Now playing** — every track, video, and browser tab that's playing shows under its app with artwork, play/pause, and scrubbing. Control Center shows one; Sliders shows all of them.
- **Microphone** — switch the default input, set gain, and see which apps are listening.
- **In sync** — system volume follows the volume keys and Control Center; scrolling over any slider adjusts it.

## Permissions

- **System Audio Recording**, for per-app volume: macOS gates audio taps behind it, and Sliders asks the first time you move an app's slider. The tapped audio never leaves the Mac.
- **Automation**, for now playing: macOS asks once per app. For a browser, that happens the first time the popover is open while it plays; Sliders then lists its tabs and runs a small script in them that reads and controls the page's media. For Spotify, Music, and TV, it happens on the first play/pause or scrub that macOS can't route on its own. Listing each tab separately also needs "Allow JavaScript from Apple Events" turned on in the browser; Sliders shows where when it's needed.

Artwork for a browser tab loads from the image address the page itself provides, the same one the browser would show.

## Development

```sh
brew install xcodegen swiftlint swiftformat
make run
```

Swift 6, strict concurrency. The Xcode project is generated from `project.yml` — edit that, not the `.xcodeproj`. `make` drives local work: `gen`, `build`, `test`, `lint`, `run`, `clean`. Pushing a `v*` tag builds, signs, notarizes, and publishes a release.

## Contributing

Bug reports and pull requests are welcome; for anything bigger than a fix, open an issue first. `make test` and `make lint` must pass; commits follow [Conventional Commits](https://www.conventionalcommits.org). The real-time audio callback allows no allocation, locks, Objective-C, or logging — changes there get extra scrutiny. Anything that phones home will be declined.

## Security

Report security issues privately via [GitHub security advisories](https://github.com/notkainoa/sliders/security/advisories/new), not public issues.

## License

[MIT](LICENSE). Sliders keeps Fader's original copyright notice alongside its own.
