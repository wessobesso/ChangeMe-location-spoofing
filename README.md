//
//  README.md
//  ChangeMe
//

# ChangeMe

Native macOS utility for choosing a map location and attempting developer location simulation on a connected iPhone using Apple-supported Xcode tooling.

## Requirements

- macOS 14+ (project currently targets the Xcode project’s macOS deployment target)
- Full **Xcode** app (not only Command Line Tools)
- A paired iPhone with Developer Mode enabled for physical-device workflows

## Sandbox

App Sandbox is **disabled** so ChangeMe can invoke `xcrun` / `devicectl` / `simctl`. This is intentional for a local developer utility.

## Location simulation

| Target | Mechanism |
| --- | --- |
| iOS Simulator | `xcrun simctl location <udid> set <lat>,<lon>` and `clear` |
| Physical iPhone (Xcode 26.6) | **Not available via CLI.** Use Xcode **Debug → Simulate Location** while debugging an app. ChangeMe still generates a GPX file you can use there. |
| Future Xcode | If `devicectl device simulate location …` appears, ChangeMe probes for and uses it. |

## iPhone setup

1. Connect the iPhone (USB for first pairing)
2. Trust this Mac
3. Settings → Privacy & Security → Developer Mode → On
4. Confirm the device appears in Xcode
