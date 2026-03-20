# Contributing to PolyfenceCore

PolyfenceCore is the shared native geofencing engine powering [polyfence-flutter](https://github.com/blackabass/polyfence-flutter) and future platform bridges. Contributions are welcome.

## Before You Start

- Check existing [issues](https://github.com/blackabass/polyfence-core/issues) for related work
- For significant changes, open an issue first to discuss the approach
- Read the architecture section below to understand what belongs in this repo vs. the bridge repos

## Architecture

PolyfenceCore contains **platform-agnostic native engines** — pure Kotlin (Android) and Swift (iOS) with zero framework bridge dependencies.

- Geofencing algorithms (haversine, ray-casting, Douglas-Peucker) live here
- Location tracking, activity recognition, and telemetry aggregation live here
- Flutter/React Native bridge code does NOT belong here — that goes in the respective bridge repos

**Critical rule:** Both Kotlin and Swift implementations must stay in sync. If you change an algorithm on one platform, you must update the other.

## Development Setup

### Android (Kotlin)
```bash
cd android
./gradlew build     # Compile + lint
./gradlew test      # Run unit tests
```

### iOS (Swift)
```bash
cd ios
pod lib lint PolyfenceCore.podspec --allow-warnings
```

## Code Style

- **Kotlin:** Follow standard Kotlin conventions. No Flutter imports.
- **Swift:** Follow standard Swift conventions. No Flutter framework imports.
- **Comments:** Short, factual, explain WHY not WHAT. No conversational tone or emojis in production code.
- **Tests:** All new features and bug fixes must include tests.

## Pull Request Process

1. Fork the repo and create a branch from `main`
2. Make your changes with tests
3. Ensure both Android and iOS build successfully
4. Ensure all tests pass
5. Update CHANGELOG.md if adding features or fixing bugs
6. Submit a PR with a clear description of what and why

## What We Check on PRs

- CI must pass (Android build + tests, iOS pod lint)
- No emojis in production code
- No hardcoded secrets or internal references
- Platform parity — both Kotlin and Swift updated if algorithm changes
- Tests included for new functionality

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
