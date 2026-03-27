# Contributing to PolyfenceCore

PolyfenceCore is the shared native geofencing engine powering [polyfence-flutter](https://github.com/polyfence/polyfence-flutter) and future platform bridges. Contributions are welcome.

## Code of Conduct

Be respectful, constructive, and collaborative. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing [issues](https://github.com/polyfence/polyfence-core/issues) to avoid duplicates.

**When filing a bug report, include:**
- **Clear title** describing the issue
- **Platform** (Android API level / iOS version)
- **Steps to reproduce** the behavior
- **Expected vs actual behavior**
- **Code snippet** (minimal reproduction)
- **Logs** (if applicable)

**Label your issue:** `bug`

### Suggesting Features

Before suggesting:
1. Check if it's already requested in issues
2. Ensure it aligns with Polyfence's privacy-first philosophy
3. Consider whether it belongs here (native engine) or in a bridge repo (Flutter/React Native)

**When suggesting a feature:**
- Describe the problem you're trying to solve
- Explain your proposed solution
- Provide use cases or examples

**Label your issue:** `enhancement`

### Asking Questions

Open an issue with the `question` label. For commercial support, see [polyfence.io](https://polyfence.io).

## Architecture

PolyfenceCore contains **platform-agnostic native engines** — pure Kotlin (Android) and Swift (iOS) with zero framework bridge dependencies.

```
android/src/main/kotlin/io/polyfence/core/
├── GeofenceEngine.kt           # Zone detection (haversine, ray-casting)
├── LocationTracker.kt          # GPS management, SmartGPS
├── ActivityRecognitionManager.kt
├── TrackingScheduler.kt        # Time window scheduling
├── SmartGpsConfig.kt           # Accuracy profiles
├── TelemetryAggregator.kt     # Session telemetry
└── PolyfenceCoreDelegate.kt   # Bridge interface

ios/Classes/
├── GeofenceEngine.swift        # Mirror of Kotlin implementation
├── LocationTracker.swift
├── ...                         # Same structure as Android
└── PolyfenceCoreDelegate.swift
```

**What belongs here:** Geofencing algorithms (haversine, ray-casting, point-to-segment distance), location tracking, activity recognition, GPS scheduling, telemetry aggregation.

**What does NOT belong here:** Flutter/React Native bridge code, Dart code, framework-specific dependencies. Those go in the respective bridge repos.

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

### Verification
```bash
# Confirm no framework imports leaked in
grep -rn "import io.flutter" android/   # Must return 0 results
grep -rn "import Flutter" ios/          # Must return 0 results
```

## Code Style

- **Kotlin:** Follow standard Kotlin conventions. Package: `io.polyfence.core`. JVM target 1.8.
- **Swift:** Follow standard Swift conventions. iOS 14.0+ APIs only. Protocol-oriented where possible.
- **Comments:** Short, factual, explain WHY not WHAT. No conversational tone or emojis in production code.
- **Tests:** All new features and bug fixes must include tests on both platforms.

## Commit Messages

Use clear, descriptive commit messages:

```
feat: Add zone clustering for large zone sets
fix: Resolve GPS recovery using wrong config after pause
docs: Update README with platform support table
refactor: Simplify haversine calculation
test: Add point-to-segment distance parity tests
```

**Prefixes:**
- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation
- `refactor:` Code refactoring
- `test:` Tests
- `chore:` Maintenance

## Pull Request Process

1. **Fork the repository** and create your branch from `main`
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**
   - Write tests for both Kotlin and Swift
   - Ensure both platforms build successfully
   - Ensure all tests pass

3. **Verify platform parity**
   - If you changed an algorithm, both implementations must match
   - Run tests on both platforms

4. **Submit a pull request**
   - Reference related issues (e.g., "Fixes #123")
   - Describe your changes clearly
   - Explain testing you performed

5. **Code review**
   - Address feedback constructively
   - Be patient — reviews may take a few days

### What We Look For in PRs

- CI must pass (Android build + tests, iOS pod lint)
- No emojis in production code
- No hardcoded secrets or internal references
- Platform parity — both Kotlin and Swift updated if algorithm changes
- Tests included for new functionality
- Focused scope — one feature or fix per PR

## Areas We Need Help

### High Priority
- [ ] Performance benchmarks (zone count scaling, battery impact)
- [ ] Improved GPS recovery after long pause
- [ ] Additional accuracy profiles

### Medium Priority
- [ ] Better error messages with actionable suggestions
- [ ] Example native app (standalone Kotlin/Swift usage without Flutter)
- [ ] Windows/macOS/Linux location backends

### Low Priority (But Appreciated)
- [ ] Additional algorithm parity tests
- [ ] Code cleanup and refactoring
- [ ] Better code comments
- [ ] Typo fixes

## Testing Guidelines

### What to Test
- **Algorithm parity:** Same inputs produce same outputs across Kotlin and Swift
- **Zone detection:** Haversine distance, ray-casting for polygons, point-to-segment for boundaries
- **GPS scheduling:** SmartGPS interval decisions based on proximity and activity
- **Edge cases:** Empty zone lists, single-point polygons, anti-meridian crossing

### Running Tests
```bash
# Android
cd android && ./gradlew test

# iOS
cd ios && pod lib lint PolyfenceCore.podspec --allow-warnings
```

## Documentation

When adding features, update:
- [ ] README.md (if public API changed)
- [ ] CHANGELOG.md (user-facing changes)
- [ ] Code comments (complex logic)
- [ ] Both platform implementations (if algorithm change)

## License

By contributing, you agree that your contributions will be licensed under the same [MIT License](LICENSE) that covers the project.

## Questions?

- **General questions**: Open an issue with `question` label
- **Security issues**: See [SECURITY.md](SECURITY.md)
- **Commercial support**: [polyfence.io](https://polyfence.io)
