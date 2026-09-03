# AGENTS.md

## Project

- Name: XDRSwitcher
- macOS-only SwiftUI menu bar app
- Minimum supported version follows the current Xcode project's Deployment Target
- Do not use external CLI tools, Homebrew packages, Python, or shell scripts as runtime dependencies
- Do not add third-party Swift packages

## Architecture

- Separate UI, state, model, and system service layers
- Use Apple's public `NSWorkspace` API for active app detection
- Dynamically load CoreDisplay private symbols only for querying and changing Reference Mode
- Do not link private frameworks directly in the project
- Use `dlopen` and `dlsym`
- Do not hardcode preset indexes
- Prefer preset unique IDs and app bundle identifiers over display names
- Treat all private API failures as user-visible errors, not app-terminating failures

## Work Rules

- Do not pre-implement features outside the requested scope for a step
- Inspect the structure before modifying existing files
- Run `xcodebuild` after changes
- Report warnings and errors
- Do not proceed to the next feature if the build fails
- Do not arbitrarily revert the user's existing changes

## Product Requirements

- Stay in the menu bar only and do not appear in the Dock
- Allow the user to associate arbitrary apps with Reference Modes
- Use the user-specified Default Reference Mode for apps without rules
- On first launch, save the current Reference Mode as the Default
- The default switching delay is 0.7 seconds
- Provide a pause control for automatic switching
- Provide Launch at Login
- Mac App Store distribution is not a goal
