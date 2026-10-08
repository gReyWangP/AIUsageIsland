# Mac Multi-Platform Usage Implementation Plan

> **For agentic workers:** Implement inline in this session; keep each data boundary testable.

**Goal:** Add a DeepSeek/Zhipu selection to the macOS island, preserving DeepSeek behavior and showing only GLM CodingPlan quotas for Zhipu.

**Architecture:** Keep DeepSeek's existing account client. Add a separate Zhipu WebKit session that loads the official personal usage page and observes only its quota response. A platform enum drives the model and alternate views. The app never copies Zhipu web credentials into its own storage.

**Tech Stack:** SwiftUI, AppKit, WebKit, Swift Package Manager.

**Spec:** User request in this chat, including no Zhipu API Key entry.

## Global Constraints

- Preserve existing DeepSeek grant and UI behavior.
- Zhipu uses official personal CodingPlan data: 5-hour and weekly windows; no pay-as-you-go API usage or wallet balance.
- Embedded login uses persistent WebKit website data. Do not expose authentication headers, cookies, or tokens to Swift.
- Treat the platform quota endpoint as an undocumented frontend endpoint and show errors when its response changes.

## Review Focus

- A saved DeepSeek grant selects DeepSeek after upgrade.
- Zhipu is only considered connected after a valid two-window response.
- Switching platform clears stale metrics and prevents late responses from crossing accounts.
- Logging out of Zhipu removes its app WebKit website data.
- Credit-based and legacy token-based quota windows parse distinctly.

## Tasks

- [x] Add platform state and a tested CodingPlan quota parser.
- [x] Add a WebKit login/refresh session bound to official BigModel hosts and quota responses.
- [x] Route model refresh, login, logout, and persistence by selected platform.
- [x] Add platform picker and CodingPlan-specific compact/detail UI.
- [x] Verify parser/model tests, build app, package app/source ZIPs, and document the browser-session limitation.
