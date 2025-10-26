# Project Folder Manual

A concise, shareable guide for navigating and using the project folders. This structure separates **UI**, **state/logic**, and **infrastructure** so you can scale cleanly, test easily, and keep code readable.

---

## 1) Overview

```
lib/
  main.dart
  app.dart
  shared/
    theme/app_theme.dart
    widgets/
      logo.dart
      round_arrow_button.dart
      field_label.dart
  features/
    auth/
      presentation/
        pages/
          login_page.dart
          register_page.dart
        widgets/
          auth_scaffold.dart
          pill_text_field.dart
      controllers/
        auth_controller.dart
  services/
    auth_service.dart
  core/
    validators.dart
assets/
  brand/
    skillup_whitelogo.svg
```

---

## 2) What Goes Where

### `main.dart`
- **Purpose:** App entry point. Calls `runApp`.
- **Rule:** No business logic. Minimal code only.

### `app.dart`
- **Purpose:** Root `MaterialApp` (theme + routing).
- **Do here:** Register routes (e.g., `LoginPage.route`), set global theme via `AppTheme.light()`.

### `shared/` (feature-agnostic, reusable UI & styling)
- `theme/app_theme.dart`  
  Single source of truth for colors, typography, `ColorScheme`, Material 3 options.
- `widgets/`  
  Reusable UI building blocks:
  - `logo.dart` → renders the SVG logo
  - `round_arrow_button.dart` → circular CTA with loader
  - `field_label.dart` → bold label for inputs  
  **Rule:** No business logic or API calls.

### `features/` (organized by feature/domain)
- `auth/`
  - `presentation/`
    - `pages/` → full screens (e.g., `login_page.dart`, `register_page.dart`)
    - `widgets/` → UI parts specific to the feature (e.g., `auth_scaffold.dart`, `pill_text_field.dart`)  
    **Rule:** UI only; no direct service calls.
  - `controllers/`  
    Feature logic & state (validation, submit flows). **Controllers call services**; UI talks to controllers.
  - *(Optional as you grow)* `domain/` (entities/use cases) and `data/` (repositories/datasources).

### `services/`
- **Purpose:** External integrations (Firebase/Supabase/REST).
- **Example:** `auth_service.dart` with `signIn`, `signUp`, `signOut`.
- **Rule:** No widget imports; pure IO/business operations.

### `core/`
- **Purpose:** Cross-cutting utilities (non-UI).
- **Examples:** `validators.dart`, custom exceptions, formatters.
- **Rule:** Keep generic; no feature-specific code to avoid circular dependencies.

### `assets/`
- **Purpose:** Static resources.
- **Logo path:** `assets/brand/skillup_whitelogo.svg`
- **Remember:** Declare assets in `pubspec.yaml`.

---

## 3) Dependency Flow (Recommended)

```
presentation (UI) --> controllers (feature logic) --> services (IO/API)
shared/widgets ----^
core --------------^
```

- UI never calls services directly.
- Shared widgets and core utilities can be used anywhere, but don’t depend on features.

---

## 4) Naming Conventions

- Pages: `something_page.dart`
- Widgets: `something_widget.dart` (or `something.dart` if obvious)
- Controllers: `something_controller.dart`
- Services: `something_service.dart`
- Each page exposes `static const route = '/something'` for routing.

---

## 5) Adding a New Feature (Example: “profile”)

1. Create folders:
   ```
   lib/features/profile/
     presentation/
       pages/profile_page.dart
       widgets/...
     controllers/profile_controller.dart
     # optional later: domain/, data/
   ```
2. Build UI under `presentation/`.
3. Add logic in a **controller** (state, submit, error handling).
4. Add APIs in `services/` (or `features/profile/data/` if using clean architecture).
5. Register the route in `app.dart`.

---

## 6) Managing the Logo (SVG)

- Place your file at: `assets/brand/skillup_whitelogo.svg`
- In `pubspec.yaml`:
  ```yaml
  dependencies:
    flutter:
      sdk: flutter
    google_fonts: ^6.2.1
    flutter_svg: ^2.0.10+1

  flutter:
    assets:
      - assets/brand/skillup_whitelogo.svg
  ```
- Use it via `shared/widgets/logo.dart` (with `flutter_svg`):
  ```dart
  import 'package:flutter_svg/flutter_svg.dart';
  import 'package:flutter/material.dart';

  class AppLogo extends StatelessWidget {
    final double height;
    const AppLogo({super.key, this.height = 88});

    @override
    Widget build(BuildContext context) {
      return SvgPicture.asset(
        'assets/brand/skillup_whitelogo.svg',
        height: height,
        fit: BoxFit.contain,
        // If the SVG isn't already white, enforce a white tint:
        colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
      );
    }
  }
  ```

---

## 7) Common Tasks

### Add a shared widget
- Put it in `lib/shared/widgets/`.
- Keep it stateless and dependency-free (no services).

### Add a field validator
- Put it in `lib/core/validators.dart`.
- Reuse across features.

### Wire a backend call
- Implement in `lib/services/*_service.dart`.
- Inject/use it in a **controller**, not in the page/widget.

### Update global styles
- Edit `lib/shared/theme/app_theme.dart`.
- Avoid scattering local style overrides.

---

## 8) Do’s & Don’ts

**Do**
- Keep UI “dumb”: render + delegate to controller.
- Reuse shared widgets across features.
- Centralize styles in `AppTheme`.

**Don’t**
- Call services from pages/widgets.
- Import feature code into `shared/`.
- Scatter theme/typography across pages.

---

## 9) Scaling Tips (Optional)

- **State management:** Add Riverpod/BLoC in `controllers/`.
- **Routing:** Migrate to `go_router` with guards (auth redirects).
- **DI:** Use `get_it` or Riverpod for injecting services into controllers.
- **Full Clean Architecture:** Add `domain/` + `data/` inside each feature.

---

## 10) Quick Checklist

- [ ] New UI? → `features/<feat>/presentation/pages/`
- [ ] Feature-specific widget? → `features/<feat>/presentation/widgets/`
- [ ] Reusable widget? → `shared/widgets/`
- [ ] Submit/validation logic? → `features/<feat>/controllers/`
- [ ] API/Firebase call? → `services/`
- [ ] New asset? → `assets/...` + declare in `pubspec.yaml`
- [ ] New route? → register in `app.dart`
