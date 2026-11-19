# ByteSize

**AI-Powered Study Companion — Turn Your Notes Into Understanding**

A mobile app built for HCI 010 (Introduction to Human-Computer Interaction), Technological Institute of the Philippines – Quezon City, that helps students study smarter by turning scanned notes and files into summaries, source-grounded answers, and spaced-repetition flashcards.

## What it does

- **Note Scanner ("Snap to Study")** — use the camera to capture handwritten or printed notes; OCR extracts the text instantly, no manual typing.
- **File Upload** — import existing documents (PDFs, images) directly into the library instead of starting from scratch.
- **Explain-o-Meter** — get an AI-generated summary of any note or document, broken down to the level of detail you need.
- **Smart Chat ("Ask My Notes")** — ask questions in natural language and get answers grounded in your own uploaded material, not generic web answers.
- **Smart Review** — auto-generated flashcards with spaced repetition, so review time focuses on what you're actually forgetting.
- **Library Vault** — all scanned notes, uploaded files, and generated flashcards organized and saved for later.

## Tech stack

- **Framework:** Flutter / Dart
- **AI:** Gemini 2.5 Flash (via `firebase_vertexai`), `google_generative_ai`
- **OCR & Vision:** Google ML Kit, `image_picker` for camera capture
- **Backend:** Firebase (Core, Vertex AI)
- **State management:** Provider
- **Storage:** `shared_preferences` for local persistence
- **Other:** `syncfusion_flutter_pdf` for PDF handling, `flutter_markdown`, `file_picker`, `google_fonts`

## Project structure

\`\`\`
lib/
  main.dart              App entry point, state (ByteSizeProvider), and all screens:
                           WelcomeScreen, DashboardScreen, StudyScreen,
                           AskMyNotesScreen, FlashcardScreen
  firebase_options.dart  Firebase project configuration
android/                 Android platform project
web/                      Web platform project
assets/                  App icon and static assets
\`\`\`

## Setup

1. Install [Flutter](https://docs.flutter.dev/get-started/install) (SDK ^3.9.0).
2. Run `flutter pub get` to install dependencies.
3. This project uses Firebase (Vertex AI for Gemini access) — configure your own Firebase project with `flutterfire configure` if running outside the original project.
4. Run with `flutter run`.

## Authors

Andal, Cyrus Austin G. · Masi Jr. · Peralta, Charles Joseph S. · Reyes, Ayzhiedy Jee D.
Computer Science Department, Technological Institute of the Philippines – Quezon City
