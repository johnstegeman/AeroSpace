# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is AeroSpace

AeroSpace is an i3-like tiling window manager for macOS written in Swift. It consists of a macOS app (`AeroSpace.app`) that acts as a server and an `aerospace` CLI binary that acts as a client. They communicate via a Unix socket.

## Build & Development Commands

All entry points are shell scripts in the repo root:

```sh
./build-debug.sh        # Debug build to .debug/ (SPM only, no Xcode)
./run-debug.sh          # Run debug AeroSpace.app
./run-cli.sh [args]     # Run aerospace CLI, forwarding args
./run-tests.sh          # Full test suite
./run-swift-test.sh     # Swift tests only (faster)
./format.sh             # Format code (SwiftFormat)
./lint.sh               # Lint code (SwiftLint)
./generate.sh           # Regenerate AeroSpace.xcodeproj and *Generated.swift files
./build-release.sh      # Release build to .release/ (Xcode required)
```

Makefile provides shortcuts: `make build`, `make test`, `make swift-test`, `make format`, `make lint`.

## Project Structure

```
Sources/
  AppBundle/      # AeroSpace.app server (SPM library consumed by Xcode)
    command/      # Command implementations
    config/       # TOML config parsing
    tree/         # Tree model (window/workspace state)
    layout/       # Layout engine
  Cli/            # aerospace CLI client (pure SPM, no Xcode)
  Common/         # Shared: command-line arg parsing, utilities
  AppBundleTests/ # Tests
  PrivateApi/     # Single private API wrapper (_AXUIElementGetWindow only)
xcode-app-bundle-launcher/  # Xcode entry point (minimal; real code is in AppBundle)
AeroSpace.xcodeproj/        # Generated from project.yml — do not edit directly
docs/                       # Asciidoc sources for site and man pages
dev-docs/                   # Developer documentation
grammar/                    # Shell completion BNF grammar
```

## Architecture

**Client/Server model:** `aerospace` CLI parses args, sends them to `AeroSpace.app` over a Unix socket, server re-parses and executes, returns stdout/stderr/exit code.

**Xcode/SPM hybrid:** All business logic lives in SPM (`Sources/`). The Xcode project (`AeroSpace.xcodeproj`) is generated from `project.yml` and only used for release builds and the app bundle entry point. Open `Package.swift` in Xcode for day-to-day development, not the `.xcodeproj`.

**Workspaces:** Custom workspace emulation — does not use macOS native Spaces.

**Accessibility API:** Uses public macOS Accessibility API throughout. The only private API is `_AXUIElementGetWindow` in `PrivateApi/`.

**Tree model:** Mutable double-linked tree representing window/workspace hierarchy (planned future refactor to immutable).

## Adding a New Command

When adding a command, follow this checklist from `dev-docs/architecture.md`:
- Implement args in `Sources/Common/cmdArgs/`
- Implement command in `Sources/AppBundle/command/`
- Add documentation in `docs/aerospace-*` and `docs/commands.adoc`
- Add to shell completion grammar in `grammar/commands-bnf-grammar.txt`
- Consider `--window-id` and `--workspace` flags

## First-Time Setup

1. Install Xcode (App Store), `swiftly` (`brew install swiftly`)
2. For release builds: create a self-signed codesign certificate named `aerospace-codesign-certificate` in Keychain Access (`Certificate Assistance → Create a Certificate... → Code Signing`)
3. Optional: `brew install xcbeautify` for readable Xcode build logs

## Generated Files

`AeroSpace.xcodeproj` and any `*Generated.swift` source files are generated — run `./generate.sh` to regenerate them. Do not edit generated files manually.

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
