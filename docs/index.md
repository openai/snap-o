---
layout: home
title: Snap-O
description: 'Snap-O is a fast, tidy macOS app for Android inspection: capture screenshots
  and recordings, and inspect network traffic.'
styles:
- index.css
subtitle: Android Inspection System
actions:
- label: Download for macOS
  href: https://github.com/openai/snap-o/releases/latest
  class: btn primary
- label: View on GitHub
  href: https://github.com/openai/snap-o
  class: secondary-link
social:
  og:title: Snap-O
  og:description: Capture screenshots and recordings, and inspect Android app network
    traffic on macOS.
  og:type: website
  og:image: assets/banner.webp
---

# Snap-O

A fast, tidy macOS app for Android developers: capture screenshots and recordings, and inspect network traffic from Android devices and emulators.
{.lead}

Requires macOS 26+ and Android Platform Tools (`adb`).
{.note}

## Network inspector {.product-title}

Inspect HTTP and HTTPS requests, Server-Sent Events (SSE), and WebSocket messages. Edit or mock HTTP responses with Python handlers.
{.product-copy}

[Set up Network](network-inspector.md){.section-link}

## Screen capture {.product-title}

Capture screenshots and recordings, share them with drag and drop, and revisit them in Capture History. Play recordings frame by frame to inspect animations.
{.product-copy}

[Screen capture guide](screen-capture.md){.section-link}

## Tweaks {.product-title}

Adjust values from Compose and other Kotlin code. Change app-owned settings and run actions through the Tool pane, an optional on-device panel, the REST API, or an agent.
{.product-copy}

[Set up Tweaks](tweaks.md){.section-link}

## Build your own tools {.product-title}

Bundle app-specific debugging tools with your Android app. Define HTTP routes and live events, then display a web frontend in Snap-O's Tool pane.
{.product-copy}

[Build a tool](plugins.md){.section-link}
