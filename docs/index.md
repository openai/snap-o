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
image:
  src: assets/banner.webp
  width: '1280'
  height: '721'
  fetchpriority: high
  alt: Snap-O interface with a green robot above Earth and the words Fast, Focused,
    Effortless
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

## Network {.product-title}

Inspect HTTP and HTTPS requests, responses, JSON payloads, Server-Sent Events, and WebSocket messages from Android apps. Use Python handlers to edit or mock HTTP responses through the app's OkHttp connection.
{.product-copy}

[Set up Network](network-inspector.md){.section-link}

## Screen capture {.product-title}

Start in Live Preview and Option-drag the current frame to share a screenshot. Recordings open for immediate playback and frame-by-frame inspection. Drag screenshots or clips into pull requests, chats, or docs without saving them first.
{.product-copy}

## Tweaks (Alpha) {.product-title}

Adjust values from Compose, Views, and other Kotlin code. Change app-owned settings and run actions through the Tool pane, an optional on-device panel, the REST API, or an agent.
{.product-copy}

[Set up Tweaks (Alpha)](tweaks.md){.section-link}

## Your own plugins {.product-title}

Bundle app-specific debugging tools with your Android app. Define HTTP routes and live events, then display a web frontend in Snap-O's Tool pane.
{.product-copy}

[Build a tool](plugins.md){.section-link} · [Explore the API](plugin-api.md){.section-link}
