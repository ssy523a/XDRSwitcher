# XDRSwitcher

XDRSwitcher is a lightweight macOS menu bar application that automatically switches the display Reference Mode according to the currently active application.

It is designed for Macs equipped with an XDR display, where different applications may benefit from different display presets. For example, XDRSwitcher can activate **HDR Video (P3-ST 2084)** when GeForce NOW or an HDR video application becomes active, then restore **Apple XDR Display (P3-1600 nits)** when returning to normal desktop applications.

## Features

* Runs quietly as a macOS menu bar application
* Detects the currently active application
* Assigns a display Reference Mode to any selected macOS application
* Uses the application’s Bundle Identifier for reliable rule matching
* Automatically restores the default Reference Mode for applications without a specific rule
* Allows automatic switching to be paused or resumed
* Provides a configurable delay to prevent unnecessary switching during rapid application changes
* Avoids repeatedly applying a Reference Mode that is already active
* Stores application rules and preferences locally
* Supports launching automatically at login
* Does not require an external command-line utility

## Example Configuration

| Application                            | Reference Mode                   |
| -------------------------------------- | -------------------------------- |
| GeForce NOW                            | HDR Video (P3-ST 2084)           |
| Final Cut Pro                          | HDR Video (P3-ST 2084)           |
| Adobe Photoshop                        | Photography (P3-D65)             |
| Safari, Finder, and other applications | Apple XDR Display (P3-1600 nits) |

## How It Works

XDRSwitcher monitors changes to the frontmost macOS application. When an application becomes active, the app compares its Bundle Identifier with the enabled application rules.

If a matching rule exists, XDRSwitcher applies the assigned Reference Mode. If no matching rule is found, it restores the user-selected default Reference Mode.

A short switching delay is applied after each application change. If another application becomes active before the delay expires, the previous request is cancelled. This helps prevent rapid or unnecessary display mode changes when switching between applications.

## Typical Uses

* Automatically enabling an HDR reference mode for HDR games
* Switching to an HDR video preset for video editing and review
* Using a photography preset when editing photographs
* Using an sRGB preset for web design and content review
* Returning to the standard Apple XDR preset for everyday work

## Important Notice

XDRSwitcher uses dynamically loaded private CoreDisplay APIs because macOS does not currently provide a public API for changing display Reference Modes programmatically.

As a result:

* The application is intended primarily for personal and experimental use.
* It is not intended for distribution through the Mac App Store.
* Compatibility may change after a macOS update.
* Available Reference Modes depend on the connected display and Mac model.
* Some Reference Modes may disable or limit True Tone, Night Shift, automatic brightness, or manual brightness controls.
* Users should verify that the selected mode is appropriate for their content and viewing environment.

XDRSwitcher does not use an external Reference Mode command-line tool and does not directly link the private CoreDisplay framework. Required CoreDisplay symbols are resolved dynamically at runtime, and unsupported configurations are handled without intentionally terminating the application.

## Compatibility

XDRSwitcher is intended for supported Apple displays that provide macOS Reference Modes, including compatible MacBook Pro models with Liquid Retina XDR displays and supported external Apple XDR displays.

The exact list of available presets depends on the display model and installed macOS version.

## Disclaimer

This project is not affiliated with, endorsed by, or supported by Apple Inc.

Apple, macOS, MacBook Pro, Pro Display XDR, Studio Display, and related names are trademarks of Apple Inc.
