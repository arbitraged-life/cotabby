# Cotabby — Cotypist-Style Feature Gap Audit

**Auditor:** Automated analysis  
**Date:** 2026-06-02  
**Codebase:** `/Users/c083074/Code/cotabby` (main checkout, read-only)  
**Vision benchmark:** 100% on-device, no accounts, strong privacy controls, inline ghost-text in ANY macOS text field.

> **Important pre-condition:** The main checkout has **unresolved git merge conflicts** in several
> production Swift files. The project will **not compile** in its current state until they are resolved:
> - `Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift`
> - `Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift`
> - `Cotabby/Models/LlamaRuntimeModels.swift`
> - `Cotabby/Support/SuggestionRequestFactory.swift`
> - Several test files (lower priority)
>
> Feature maturity assessments below assume the fork-side (HEAD) variant wins each conflict.

---

## Feature Status Table

| # | Feature | Status | Key Files | Assessment |
|---|---------|--------|-----------|------------|
| 1 | Inline ghost-text overlay near caret | **IMPLEMENTED** | `OverlayController.swift`, `GhostSuggestionLayout.swift`, `GhostFontSizeStabilizer.swift`, `MirrorOverlayLayout.swift` | Fully live: inline + fallback mirror mode, font-size quality tiers, RTL support, alternativeIndicator badge. |
| 2 | AX focus watching + reading focused field text | **IMPLEMENTED** | `FocusTracker.swift`, `FocusSnapshotResolver.swift`, `AXTextGeometryResolver.swift`, `FocusModels.swift` | Live polling with backoff; reads role, subrole, secure-flag, caret rect, preceding/trailing text. ChromiumAccessibilityEnabler handles Electron. |
| 3 | Tab-to-accept: word/phrase/full granularity | **IMPLEMENTED** | `SuggestionCoordinator+Acceptance.swift`, `SuggestionInteractionState.swift`, `SuggestionSessionReconciler.swift` | Word-by-word (default), phrase, and full-accept (dedicated key) all wired and live. Post-exhaustion Tab buffering handles rapid-Tab across regen boundary. |
| 4a | Apple Intelligence backend | **IMPLEMENTED** | `FoundationModelSuggestionEngine.swift`, `FoundationModelPromptRenderer.swift`, `SuggestionEngineRouter.swift` | Live; auto-falls back to llama on unsupported locale. Requires Apple Silicon + macOS 26. |
| 4b | Local GGUF / llama.cpp backend | **IMPLEMENTED** | `LlamaRuntimeCore.swift`, `LlamaRuntimeManager.swift`, `LlamaSuggestionEngine.swift`, `LlamaRuntimeCore+TreeDecode.swift` | Live; tree-decode for multi-candidate alternatives. CONFLICT markers in `LlamaRuntimeModels.swift` — won't build until resolved. |
| 4c | Model picker / management | **IMPLEMENTED** | `EngineAndModelPaneView.swift`, `ModelDownloadManager.swift`, `HuggingFaceSearchService.swift`, `RuntimeBootstrapModel.swift` | Full UI: download catalog, HuggingFace browser, LM Studio path sharing, delete-installed, hardware-fit warning badge. |
| 5 | Per-app behavior policy | **PARTIAL** | `AppCompatibilityPolicy.swift`, `AppCompatibilityStore.swift`, `FieldPolicyResolver.swift`, `AppsPaneView.swift` | Logic is complete and wired into the live pipeline. User UI is **disable-only** (no per-app insertion strategy, debounce, or overlay overrides). `userOverrides` array is never populated from UI. |
| 6 | Field-type awareness driving prompt/behavior | **IMPLEMENTED** | `FieldTypeClassifier.swift`, `FieldPolicyResolver.swift`, `SuggestionRequestFactory.swift` | Classifies code/terminal/chat/url/search/password/prose; classification feeds prompt hints via `effectiveRules`. App-override wins over classifier. |
| 7 | Adaptive/context-aware debounce | **IMPLEMENTED** | `AdaptiveDebounceController.swift` | Four profiles (standard/aggressive/relaxed/terminal), event-type differentiation, deletion-run penalty, per-field acceptance suppression. Wired via `FieldPolicyResolver.debounceProfile`. |
| 8 | Multiple insertion strategies | **PARTIAL** | `InsertionStrategyResolver.swift`, `MultiStrategyInserter.swift`, `SuggestionCoordinator+Acceptance.swift` | All four strategies (`syntheticKeystroke`, `pasteboardPaste`, `pasteAndMatchStyle`, `axAttributeWrite`, `chunkedInjection`) are **fully implemented** in `MultiStrategyInserter`. However, the live accept path in `SuggestionCoordinator+Acceptance` explicitly routes everything through synthetic-keystroke and only logs the resolved strategy. The richer strategies are **decision-wired but not live**. |
| 9 | Privacy controls & secure-field suppression | **IMPLEMENTED** | `AppCompatibilityPolicy.swift`, `FieldTypeClassifier.swift`, `SecureFieldDetector.swift`, `FocusCapabilityResolver.swift`, `SuggestionSettingsModel` (pause), `AdvancedPaneView.swift`, `PermissionsPaneView.swift` | AXSecureTextField suppressed in policy layer. Pause/snooze in menu bar. Per-app disable in Settings. Screen Recording gated on explicit permission. No server logging (all on-device). Visual context requires Screen Recording grant. |
| 10 | Personalization / custom vocab feeding prompt | **PARTIAL** | `PersonalizationEngine.swift`, `InputHistoryStore.swift`, `SuggestionRequestFactory.swift` | Frequency-vocabulary from input history is injected into `effectiveRules` when `personalizationStrength > 0`. CONFLICT in `SuggestionRequestFactory.swift` (fork adds this; upstream removes it for base-model path). Custom rules UI exists but `CustomRulesCatalog.isUserFacingEnabled == false` — suppressed in production. |
| 11 | Visual context (screenshot/OCR feeding model) | **IMPLEMENTED** | `VisualContextCoordinator.swift`, `ScreenshotContextGenerator.swift`, `WindowScreenshotService.swift`, `ScreenTextExtractor.swift`, `LlamaVisualContextSummarizer.swift` | Full pipeline: screenshot → OCR (Vision) → LLM summarization → prompt injection. Requires Screen Recording permission. Gated, session-scoped, debounced. |
| 12 | Acceptance UX niceties | **IMPLEMENTED** | `SuggestionCoordinator+Acceptance.swift`, `SuggestionInteractionState.swift`, `SuggestionModels.swift` | Trailing-space insertion (word granularity, opt-in). Auto-accept trailing punctuation (opt-in). Suggestion cycling next/prev via `cycleAlternative(forward:)` — requires tree-decode alternatives (llama only). |
| 13 | Model management UI | **IMPLEMENTED** | `EngineAndModelPaneView.swift`, `ModelDownloadManager.swift`, `HuggingFaceSearchService.swift` | Download catalog, HuggingFace search, GGUF file picker, LM Studio path, delete, hardware-fit warning. No quantization-level guidance in picker beyond filename. |
| 14 | Onboarding / permissions flow | **IMPLEMENTED** | `WelcomeCoordinator.swift`, `WelcomeView.swift`, `WelcomePermissionStepView.swift`, `PermissionManager.swift`, `PermissionGuidanceController.swift` | Versioned wizard; permission-reminder re-show; drag-source guidance for Accessibility/Input Monitoring; Screen Recording gating. |
| 15 | Menu-bar surface + global enable + shortcuts | **IMPLEMENTED** | `MenuBarView.swift`, `CotabbyApp.swift`, `ShortcutsPaneView.swift` | Global toggle, per-app toggle for frontmost app, pause/snooze controls, engine + model + length pickers, permissions card, Settings link. Keyboard shortcuts configurable. |

---

## Detailed Notes on Key Features

### Feature 1 — Inline Ghost-Text Overlay
`OverlayController` owns a non-activating `NSPanel` (`OverlayPanel`). Two rendering modes:
- **Inline** (`GhostSuggestionView`): ghost text placed right of caret with keycap badge and alternativeIndicator.
- **Mirror** (`MirrorOverlayView`): card anchored below field when caret geometry is unreliable.

`GhostFontSizeStabilizer` prevents font-size flickering as line height jitters. Three quality tiers (`exact/derived/estimated`) cap ghost font size conservatively. RTL support via `TextDirectionDetector`.

### Feature 4 — Inference Backends
`SuggestionEngineRouter` routes between `FoundationModelSuggestionEngine` (Apple Intelligence) and `LlamaSuggestionEngine`. The Apple path auto-falls back to llama on `unsupportedLanguageOrLocale`. Tree-decode in `LlamaRuntimeCore+TreeDecode.swift` produces multi-candidate alternatives for cycling.

**BLOCKER:** `LlamaRuntimeModels.swift` has 3 merge-conflict sections — the project will not build.

### Feature 5 — Per-App Behavior Policy
`AppCompatibilityStore` ships a well-populated built-in table (terminals, password managers, code editors, Slack/Discord/Google Docs/Notion, WeChat). The `policy(for:domain:fieldRole:)` path is live. **Gap:** `userOverrides` is never written from any UI — the Settings "Apps" pane only provides binary enable/disable. Users cannot set per-app insertion strategy, debounce profile, or overlay preference through the UI.

### Feature 8 — Insertion Strategies
`MultiStrategyInserter` implements all strategies including `chunkedInjection`. These are fully functional code. **However,** `SuggestionCoordinator+Acceptance.swift` lines 129–145 explicitly call only `suggestionInserter.insert(insertionChunk)` (the synthetic-keystroke path) and log the resolved strategy without routing to `MultiStrategyInserter`. The comment says: *"Do NOT hot-swap the live inserter here."* This is intentional short-term caution, but it means pasteAndMatchStyle (Slack, Google Docs) and axAttributeWrite are never actually used in production.

### Feature 10 — Personalization
`PersonalizationEngine.buildVocabularyBias` produces a frequency map from `InputHistoryStore`. In `SuggestionRequestFactory.buildRequest` the fork adds top-30 vocabulary words to `effectiveRules` when `personalizationStrength > 0`. This is **in merge conflict** with upstream's removal of the feature. `CustomRulesCatalog.isUserFacingEnabled = false` suppresses custom rule injection in production.

### Feature 11 — Visual Context
Fully wired end-to-end. `VisualContextCoordinator.startSessionIfNeeded` is called per focus change; it debounces, screenshots the focused window, OCRs with `ScreenTextExtractor` (Vision framework), summarizes with `LlamaVisualContextSummarizer`, and delivers an excerpt string to `SuggestionRequestFactory.buildRequest` as `visualContextSummary`. Gated on Screen Recording permission.

### Merge Conflicts (Build-Blocker)
The following production source files have unresolved conflict markers and will cause build failures:
- `Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift` (~line 339)
- `Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift` (~line 28)
- `Cotabby/Models/LlamaRuntimeModels.swift` (3 conflict sections)
- `Cotabby/Support/SuggestionRequestFactory.swift` (~line 74, personalization injection)

---

## Top 5–8 Highest-Value Gaps (Ranked)

### GAP 1 — Build Blocker: Unresolved Merge Conflicts ⚠️ CRITICAL
**Status:** The codebase will not compile.  
**Rationale:** Nothing ships until this is resolved. The conflicts in `SuggestionCoordinator+Prediction`, `SuggestionCoordinator+Input`, `LlamaRuntimeModels`, and `SuggestionRequestFactory` are in core hot-path code.  
**Surface:** 4 files; manual resolution + regression test run.

---

### GAP 2 — Insertion Strategies Not Live (Slack/Docs/Discord regression)
**Status:** PARTIAL  
**Rationale:** The `AppCompatibilityStore` correctly assigns `pasteAndMatchStyle` for Slack, Google Docs, Discord, Notion. `MultiStrategyInserter` implements it. But the live accept path ignores the resolved strategy and always uses synthetic keystrokes. In rich-text editors this produces plaintext insertion that pastes raw characters rather than matching the document's style — a known failure mode.  
**Surface:**
- `SuggestionCoordinator+Acceptance.swift` (~line 128): replace direct `suggestionInserter.insert` call with dispatch through `MultiStrategyInserter.insert(_:using:)` using `resolvedFieldPolicy.insertionStrategy`
- `SuggestionInserter.swift`: deprecate or delegate to `MultiStrategyInserter`
- The comment "Do NOT hot-swap the live inserter here" must be revisited once suppression contracts are aligned.

---

### GAP 3 — Per-App Override UI (Insertion Strategy, Debounce, Overlay)
**Status:** PARTIAL  
**Rationale:** Power users cannot configure per-app insertion strategy, debounce profile, or overlay mode through the UI. The Settings "Apps" pane only shows enable/disable. `AppCompatibilityStore.userOverrides` is never written. This limits the product to Cotabby's hardcoded assumptions for any app not in the built-in table.  
**Surface:**
- `AppsPaneView.swift`: add per-app configuration sheet (strategy picker, debounce picker, overlay picker)
- `SuggestionSettingsModel`: persist `userOverrides` to UserDefaults
- `AppCompatibilityStore`: accept injected user overrides from settings model

---

### GAP 4 — Personalization / Custom Rules Suppressed in Production
**Status:** PARTIAL  
**Rationale:** `CustomRulesCatalog.isUserFacingEnabled == false` means custom rules are never injected even when the user writes them in the CustomRulesEditor. The personalization vocabulary feature (vocabulary bias from typing history) is in a merge conflict and may be dropped by the upstream merge. Both are high-signal differentiators vs generic system autocomplete.  
**Surface:**
- `CustomRulesCatalog.swift`: flip `isUserFacingEnabled` to `true` (after verifying base-model regression)
- `SuggestionRequestFactory.swift`: resolve merge conflict, preserve personalization injection
- `WritingPaneView.swift` / `AdvancedPaneView.swift`: expose personalizationStrength slider

---

### GAP 5 — No Per-App Advanced Policy in AppsPaneView (Beyond Binary Enable)
**Status:** MISSING  
**Rationale:** The "Apps" Settings pane (GAP 3 above) is the right surface but only handles disable. There is no way to say "use mirror overlay in VSCode" or "use aggressive debounce in Slack." This reduces the value of the `AppCompatibilityStore` architecture.  
**Surface:** See GAP 3 surface.

---

### GAP 6 — Model Quantization Guidance in Download Catalog
**Status:** PARTIAL  
**Rationale:** `EngineAndModelPaneView` shows a `ModelFitEvaluator` badge (won't-fit / limited-headroom / recommended) but only for models already in the catalog. The HuggingFace browser returns raw filenames — users see `Qwen3-0.6B-Q8_0.gguf` without guidance on what Q8_0 means vs Q4_K_M or how to choose. No size-vs-quality tradeoff is surfaced for arbitrary downloads.  
**Surface:**
- `HuggingFaceModelBrowserView`: parse GGUF filename quantization tokens and show tooltip/badge
- `DownloadableModelCatalogView`: add size/quality footnotes next to each entry

---

### GAP 7 — Cycling (Next/Prev Alternative) Requires llama Tree-Decode
**Status:** PARTIAL  
**Rationale:** `cycleAlternative(forward:)` is implemented and wired to keyboard shortcuts, but tree-decode is only available in the llama engine. Apple Intelligence users never get alternative cycling. The alternativeIndicator badge in `GhostSuggestionView` is only populated when `alternatives` is non-empty (llama tree-decode mode). Apple Intelligence path always returns a single suggestion.  
**Surface:**
- `FoundationModelSuggestionEngine.swift`: explore running the FM engine N times with different seeds or prompting for N candidates
- Or: document the limitation clearly in onboarding/Settings for Apple Intelligence users

---

### GAP 8 — No 'Never Run Here' Field-Level Veto (Only App-Level)
**Status:** PARTIAL  
**Rationale:** Users can disable Cotabby per-app. But there is no per-field-type or per-URL rule (e.g., "never in Gmail's To: field" or "never in code blocks inside Notion"). `AppCompatibilityStore` supports domain-level overrides but there is no UI path to add a domain rule, only a full-app bundle picker.  
**Surface:**
- `AppsPaneView.swift`: add "Domain rules" section accepting user-entered domains
- `SuggestionSettingsModel`: persist domain overrides
- `AppCompatibilityStore`: domain override already implemented, just needs population from UI

---

## Recommended Next Wave

### Immediate (unblock shipping)
1. **Resolve all merge conflicts** in the 4 production source files. The fork's personalization additions and the upstream's base-model prompt renderer need a deliberate choice, not conflict markers.
2. **Activate `MultiStrategyInserter` in the live accept path.** The implementation is done; only the coordinator wiring is missing. This unblocks Slack, Google Docs, Discord, and Notion paste quality.

### High Impact (core vision gaps)
3. **Re-enable custom rules** (`CustomRulesCatalog.isUserFacingEnabled = true`) and expose the personalizationStrength slider. These are the primary differentiators that make Cotabby feel "trained" to the user rather than generic.
4. **Per-app Advanced Policy UI** in AppsPaneView: wire `userOverrides` to Settings so power users can control insertion strategy, debounce, and overlay per app — the `AppCompatibilityStore` architecture already supports it.

### Quality / Polish
5. **Domain-level disable rules** in the Apps pane (UI for the already-implemented domain-matching in `AppCompatibilityStore`).
6. **Quantization guidance** in the HuggingFace model browser — tooltip/badge for Q4/Q5/Q8 tradeoffs.
7. **Apple Intelligence cycling** — at minimum, document the limitation; ideally seed multiple generations for alternatives.

---

## Summary Scorecard

| Category | Score | Notes |
|----------|-------|-------|
| Core ghost-text rendering | ✅ Excellent | Inline + mirror, font stabilization, RTL, badges |
| AX focus / text reading | ✅ Excellent | Polling, backoff, Chromium, caret geometry |
| Inference backends | ✅ Good | Both backends live; blocked by merge conflicts |
| Privacy / security | ✅ Good | Secure field suppression, pause, per-app disable, no logging |
| Onboarding / permissions | ✅ Good | Versioned wizard, reminder flow, guidance UI |
| Menu-bar surface | ✅ Good | Engine/model/length/pause controls |
| Field-type awareness | ✅ Good | Classifier + prompt hints wired |
| Adaptive debounce | ✅ Good | Four profiles, event-type differentiation |
| Acceptance UX | ✅ Good | Word/phrase/full, trailing space, punctuation, cycling |
| Model management UI | ✅ Good | Download, HuggingFace, LM Studio, hardware-fit |
| Insertion strategies | ⚠️ Partial | All implemented; live path routes through synthetic only |
| Per-app advanced policy UI | ⚠️ Partial | Logic complete; UI is binary enable/disable only |
| Personalization / custom rules | ⚠️ Partial | Suppressed in production; conflict in factory |
| Visual context | ✅ Good | Full pipeline wired; requires Screen Recording |
| BUILD STATUS | 🔴 BROKEN | Unresolved merge conflicts in 4 production files |
