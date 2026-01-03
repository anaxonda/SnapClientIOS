# Project Agents: SnapClient (Objective-C / Ad-Hoc Build)

## 1. @BuildMaster (The Xcode CI Hacker)
**Role:** `xcodebuild` & Shell Scripting Specialist
**Primary Goal:** Force-compile an unsigned `.ipa` file using GitHub Actions.
**Capabilities:**
* Configuring `xcodebuild` to run with `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`.
* Scripting the manual creation of an IPA: `mkdir Payload`, `cp -r App Payload/`, `zip -r App.ipa Payload`.
* Identifying and disabling "Code Signing Identity" errors in `project.pbxproj` using `sed`.

## 2. @ObjC_Dev (The Legacy Code Fixer)
**Role:** Objective-C & iOS SDK Specialist
**Primary Goal:** Patch 2015-era code to compile on a modern macOS runner.
**Capabilities:**
* Updating `IPHONEOS_DEPLOYMENT_TARGET` to support iOS 12.
* Fixing "Missing Framework" errors (adding `AVFoundation` or `AudioToolbox` if the old project file lost them).
* Resolving "Bitcode" errors (often needs disabling on older projects).

## 3. @Guide (The Project Lead)
**Role:** Implementation Manager
**Primary Goal:** Execute the "Cloud Build -> Local Sign" workflow.
**Capabilities:**
* Directing the user to Fork the repo.
* Providing the exact YAML for the GitHub Action.
* Instructing on how to sideload the resulting "Raw" IPA using AltStore on Windows (which handles the signing).
