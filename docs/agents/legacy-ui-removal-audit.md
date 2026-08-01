# Legacy WebUI UI removal audit (Issue #34)

## Scope and evidence

Hermes Nest has one App target (`HermesMobile`) and one XCTest target
(`HermesMobileTests`). The production launch graph is:

```text
HermesMobileApp
└── CompanionRootView
    ├── OnboardingView
    ├── CompanionFoundationStatusView
    └── CompanionSessionListView
        ├── CompanionWorkspaceView
        ├── CompanionMemoryView
        └── CompanionDiscoveryView
```

Before deletion, the App target's `PBXSourcesBuildPhase` contained 75 unique
Swift files and the XCTest phase contained 21. The App set exactly matched the
75-entry `Config/PersonalSideloadSources.txt` release allowlist: there were no
files present in one set but absent from the other. The branch keeps that App
set unchanged and expands the XCTest phase to 25 entries solely to compile the
preserved read-only WebUI boundary and its focused contract/security tests.
Consequently, a legacy candidate is removable only when all of the following
hold:

1. it is absent from both source sets;
2. no retained production or CI-fixture source references it;
3. it is not part of an explicitly preserved out-of-process feature;
4. any tests, project references, and localizations removed with it are
   exclusive to that candidate graph.

The removed files were PBX group references only. They were not members of
either Sources build phase. Removing them therefore does not change a Companion
endpoint, model shape, credential path, or release-root navigation route.

## Preserve boundary

The following code stays:

- every file in the App target source phase / personal-sideload allowlist;
- `CompanionSessionListView`, its view models and services, Workspace, built-in
  Memory, Skills & Toolsets discovery, onboarding, Keychain, persistence, and
  connection restoration/degraded-state handling;
- shared transcript rendering: message bubbles, Markdown/math, reasoning,
  tool cards, media/audio/link previews, streaming animation, and shared file
  export;
- `CoreChatLabView`, `StreamingLabView`, and `StreamingLabReplay`, including
  the core-chat, long-chat, streaming, compact-width, and iPad debug launch
  hooks used by CI;
- `AppIntents/`, `LiveActivities/`, `Features/Share/SharedDraftStore.swift`,
  and their tests. Personal-v1 deliberately excludes these capabilities from
  its App-only source list, but Issue #34 explicitly excludes them from this
  cleanup;
- the two verified, read-only WebUI requests still needed by those preserved
  features are isolated in `PreservedWebUIReadService`; it keeps the existing
  `/api/profiles` and `/api/chat/stream/status?stream_id=...` contracts,
  owner-configured headers, cookie behavior, and cross-origin redirect guard
  without retaining the general WebUI `APIClient` graph. The service and
  `CustomHeader` and credential reader compile in the XCTest target together
  with focused route, decoding, header-precedence, cookie, redirect, and scoped
  credential-selection tests; they remain excluded from the personal-v1 App
  target alongside their out-of-process consumers;
- `PreservedWebUICredentialReader` keeps the existing scoped-Keychain-first,
  legacy-global-fallback custom-header lookup shared by the profile picker and
  Live Activity reconciler, without restoring the old mutable account graph;
- `CustomHeader.swift` and `KeychainStore.swift`, which supply that narrow
  preserved service without entering the Companion release source graph;
- historical documentation. It is labeled historical and is not a product
  route or contract.

## Remove boundary

All paths below are absent from both source phases unless a retained exception
is stated explicitly.

| Candidate graph | Files/types removed | Retained exceptions |
| --- | --- | --- |
| Legacy session shell | `SessionListView`, `SessionListViewModel`, `SessionListComponents`, `SessionNavigationState`, `SessionListActionConfirmations`, `SessionMutator`, `SessionHaptics`, `ProjectCreationSheet`, `SessionRenameSheet` | `Companion*` session files and shared `SessionRowView` |
| Legacy Chat/session transport | `ChatView`, `ChatViewModel`, old composer/coordinator/overlay/goal/slash-command/context-window/marker helpers, direct-SSE/API session/chat/upload/transcribe/TTS/export clients, and their exclusive models/tests | all 75 release sources, including shared transcript/rendering/streaming/media types |
| Old Settings | `SettingsView`, app-icon/default-model/default-profile/archive/provider/session-sync views and models | Core Chat and Streaming lab fixtures |
| Kanban | all `Features/Kanban`, Kanban model/network stream/API code, and Kanban tests | none; Companion v1 does not expose the WebUI Kanban contract |
| Tasks/Cron | all `Features/Tasks`, Cron model/API code, and exclusive tests | none |
| Insights | all `Features/Insights` and exclusive tests | none |
| Legacy Skills | `Features/Skills`, WebUI Skills model/API code, and exclusive tests | production `CompanionDiscoveryView` |
| Legacy Memory | `Features/Memory`, WebUI Memory model/API code, and exclusive tests | production `CompanionMemoryView` and Companion contract models/service |
| Legacy workspace/Git | old browser/preview/Git/registry/manager UI, WebUI workspace/Git models/API code, and exclusive tests | `CompanionWorkspaceView`, Companion workspace models/service, shared `FileExportSupport` |
| Old account/settings support | `AuthManager`, `AppConfig`, `AppIconChoice`, `CustomHeadersEditor`, old server-account registry code, and exclusive tests | `CompanionConnectionManager`, Keychain, preserved App Intent dependency closure |
| Orphan debug preview | `AdaptiveGlassDebugFixture` | production `AdaptiveGlassModifier` and its test |

The Xcode project cleanup removes the matching stale PBX build-file,
file-reference, group-child, and test-group entries. Empty legacy feature
groups are removed; mixed groups retain only the files named above.

## Localization boundary

Localization keys are removed only when their source key occurs exclusively in
the deleted Swift/test graph. Keys found in retained Swift, scripts, resources,
or dynamic lookup allowlists remain. Kanban-specific assertions are removed
from `LocalizationCatalogTests` together with the Kanban UI; the general
English/Simplified-Chinese completeness checks remain.

## Validation required after deletion

- project references resolve, the 75-file App source set remains unchanged,
  and the 25-file XCTest set contains only the previous tests plus the preserved
  service, its header/credential dependencies, and its focused test suite;
- personal-sideload release readiness, promotion, UI smoke, localization JSON,
  and project-balance checks pass;
- full XCTest passes on macOS;
- signed Debug builds install and launch on an iPhone and an available
  13-inch iPad Pro simulator;
- final Standards + Spec review confirms that every deletion stays on the
  unreachable side of this boundary.
