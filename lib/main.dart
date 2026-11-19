import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- REQUIRED FIREBASE, AI, & FILE IMPORTS ---
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_vertexai/firebase_vertexai.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'dart:convert';

// ==========================================
// 1. STATE MANAGEMENT, DATA & DATABASE LOGIC
// ==========================================
class Flashcard {
  String question;
  String answer;
  Flashcard({required this.question, required this.answer});
}

class Document {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  String extractedText;
  String generatedSummary;
  List<Flashcard> flashcards;
  Uint8List? rawImageBytes;

  Document({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.extractedText,
    this.generatedSummary =
        "No summary generated yet. Adjust the Explain-o-Meter and tap Generate!",
    this.flashcards = const [],
    this.rawImageBytes,
  });
}

class ByteSizeProvider extends ChangeNotifier {
  bool isDarkMode = true;
  double textScale = 1.0;

  String userName = "Scholar";
  String userBio = "Ready to learn!";
  Uint8List? profilePicBytes;

  List<Document> documents = [];
  Document? currentDocument;

  List<Map<String, dynamic>> chatMessages = [];

  // --- LOADING STATES ---
  bool isDocumentLoading = false; // NEW: For camera/upload loading screen!
  bool isChatLoading = false;
  bool isSummaryLoading = false;
  bool isCardsLoading = false;

  ByteSizeProvider() {
    _loadDatabase();
  }

  // --- DATABASE: LOAD DATA ---
  Future<void> _loadDatabase() async {
    final prefs = await SharedPreferences.getInstance();
    userName = prefs.getString('userName') ?? "Scholar";
    userBio = prefs.getString('userBio') ?? "Ready to learn!";
    textScale = prefs.getDouble('textScale') ?? 1.0;

    String? docsJson = prefs.getString('savedDocuments');
    if (docsJson != null) {
      List<dynamic> decoded = jsonDecode(docsJson);
      documents = decoded
          .map(
            (d) => Document(
              id: d['id'],
              title: d['title'],
              subtitle: d['subtitle'],
              icon: Icons.description,
              extractedText: d['extractedText'],
              generatedSummary: d['generatedSummary'],
            ),
          )
          .toList();
    }
    notifyListeners();
  }

  // --- DATABASE: SAVE DATA ---
  Future<void> saveData() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('userName', userName);
    prefs.setString('userBio', userBio);
    prefs.setDouble('textScale', textScale);

    List<Map<String, dynamic>> docsMap = documents
        .map(
          (d) => {
            'id': d.id,
            'title': d.title,
            'subtitle': d.subtitle,
            'extractedText': d.extractedText,
            'generatedSummary': d.generatedSummary,
          },
        )
        .toList();
    prefs.setString('savedDocuments', jsonEncode(docsMap));
  }

  void toggleTheme() {
    isDarkMode = !isDarkMode;
    notifyListeners();
  }

  void updateTextScale(double scale) {
    textScale = scale;
    saveData();
    notifyListeners();
  }

  void updateProfile(String name, String bio) {
    if (name.trim().isNotEmpty) userName = name;
    if (bio.trim().isNotEmpty) userBio = bio;
    saveData();
    notifyListeners();
  }

  Future<void> updateProfilePicture() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      profilePicBytes = await image.readAsBytes();
      notifyListeners();
    }
  }

  void selectDocument(Document doc) {
    currentDocument = doc;
    chatMessages.clear();
    notifyListeners();
  }

  void updateDocumentText(String newText) {
    if (currentDocument != null) {
      currentDocument!.extractedText = newText;
      saveData();
      notifyListeners();
    }
  }

  void removeDocument(Document doc) {
    documents.remove(doc);
    if (currentDocument == doc) currentDocument = null;
    saveData();
    notifyListeners();
  }

  Future<void> pickAndProcessDocument(
    BuildContext context,
    bool isCamera,
  ) async {
    try {
      String rawText = "";
      String fileName = "";
      IconData fileIcon = Icons.description;
      Uint8List? savedImage;

      if (isCamera) {
        final ImagePicker picker = ImagePicker();
        final XFile? photo = await picker.pickImage(source: ImageSource.camera);
        if (photo == null) return; // User cancelled, do nothing

        // TURN ON LOADING SCREEN
        isDocumentLoading = true;
        notifyListeners();

        fileName = "Camera_Scan_${DateTime.now().second}.jpg";
        fileIcon = Icons.camera_alt;
        savedImage = await photo.readAsBytes();

        final model = FirebaseVertexAI.instance.generativeModel(
          model: 'gemini-2.5-flash',
        );
        final response = await model.generateContent([
          Content.multi([
            TextPart(
              "Extract all readable text from this image. If the image is completely blank, blurry, or nonsensical, output EXACTLY this phrase: 'ERROR_NONSENSE'.",
            ),
            InlineDataPart('image/jpeg', savedImage),
          ]),
        ]);
        rawText = response.text ?? "";
      } else {
        FilePickerResult? result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['txt', 'md', 'pdf'],
          withData: true,
        );
        if (result == null) return; // User cancelled, do nothing

        // TURN ON LOADING SCREEN
        isDocumentLoading = true;
        notifyListeners();

        PlatformFile file = result.files.first;
        fileName = file.name;
        fileIcon = Icons.picture_as_pdf;

        if (file.extension == 'pdf') {
          final PdfDocument document = PdfDocument(inputBytes: file.bytes);
          rawText = PdfTextExtractor(document).extractText();
          document.dispose();
        } else {
          rawText = utf8.decode(file.bytes!);
        }
      }

      if (rawText.contains("ERROR_NONSENSE") || rawText.trim().isEmpty) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '❌ The uploaded document/image could not be analyzed or contains no readable text.',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        return; // Finally block will handle turning off the loader
      }

      final newDoc = Document(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: fileName,
        subtitle: isCamera ? 'Camera Scan' : 'Uploaded File',
        icon: fileIcon,
        extractedText: rawText,
        rawImageBytes: savedImage,
      );

      documents.insert(0, newDoc);
      selectDocument(newDoc);
      saveData();

      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🎉 $fileName ready!'),
          backgroundColor: Colors.green.shade600,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent),
      );
    } finally {
      // THIS ENSURES THE LOADING SCREEN ALWAYS TURNS OFF
      isDocumentLoading = false;
      notifyListeners();
    }
  }

  Future<void> generateSummary(double complexity) async {
    if (currentDocument == null || currentDocument!.extractedText.isEmpty)
      return;
    isSummaryLoading = true;
    notifyListeners();

    String toneInstruction = complexity < 33
        ? "Explain this to me like I am 5 years old. Use simple analogies, basic vocabulary, and short sentences."
        : complexity < 66
        ? "Provide a standard high-school level summary. Highlight the main concepts cleanly."
        : "Provide an academic, expert-level analysis. Maintain complex terminology.";

    try {
      final model = FirebaseVertexAI.instance.generativeModel(
        model: 'gemini-2.5-flash',
      );
      final prompt =
          '$toneInstruction\n\nPlease format it nicely using Markdown. If the text provided makes absolutely no sense, output: "ERROR_NONSENSE"\n\nSummarize this text:\n---\n${currentDocument!.extractedText}\n---';
      final response = await model.generateContent([Content.text(prompt)]);

      if (response.text != null && response.text!.contains("ERROR_NONSENSE")) {
        currentDocument!.generatedSummary =
            "The document text does not contain coherent information to summarize.";
      } else {
        currentDocument!.generatedSummary =
            response.text ?? "Failed to generate.";
      }
      saveData();
    } catch (e) {
      currentDocument!.generatedSummary = "Error: $e";
    }
    isSummaryLoading = false;
    notifyListeners();
  }

  Future<void> generateFlashcards(String customPrompt) async {
    if (currentDocument == null || currentDocument!.extractedText.isEmpty)
      return;
    isCardsLoading = true;
    notifyListeners();

    try {
      final model = FirebaseVertexAI.instance.generativeModel(
        model: 'gemini-2.5-flash',
      );
      final prompt =
          '''
        Create exactly 5 study flashcards based ONLY on the following text. 
        User Focus/Request: "$customPrompt"
        If the text does not contain information to fulfill the user's focus, DO NOT hallucinate. 
        Instead, make the answer say: "The attached document does not contain enough information about this."
        Format your response EXACTLY as a JSON array of objects, with keys "q" for question and "a" for answer. Do not include markdown code blocks.
        Example: [{"q":"What is the mitochondria?","a":"The powerhouse of the cell."}]
        ---
        ${currentDocument!.extractedText}
      ''';
      final response = await model.generateContent([Content.text(prompt)]);
      String cleanJson = response.text!
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      List<dynamic> parsed = jsonDecode(cleanJson);
      currentDocument!.flashcards = parsed
          .map((item) => Flashcard(question: item['q'], answer: item['a']))
          .toList();
    } catch (e) {
      print("Flashcard error: $e");
    }
    isCardsLoading = false;
    notifyListeners();
  }

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty || currentDocument == null) return;
    chatMessages.insert(0, {'isUser': true, 'text': text});
    isChatLoading = true;
    notifyListeners();

    try {
      final model = FirebaseVertexAI.instance.generativeModel(
        model: 'gemini-2.5-flash',
        systemInstruction: Content.system(
          'You are ByteSize AI. Strictly answer using only the provided document. If the answer is not in the text, clearly state "I cannot find the answer to this in the uploaded document." Use markdown for formatting.',
        ),
      );
      final prompt =
          'DOCUMENT CONTENT:\n---\n${currentDocument!.extractedText}\n---\n\nUSER QUESTION: $text';
      final response = await model.generateContent([Content.text(prompt)]);
      chatMessages.insert(0, {
        'isUser': false,
        'text': response.text ?? "Error.",
      });
    } catch (e) {
      chatMessages.insert(0, {
        'isUser': false,
        'text': "AI Connection Error: $e",
      });
    }
    isChatLoading = false;
    notifyListeners();
  }
}

// ==========================================
// 2. MAIN APP & INIT
// ==========================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase init error: $e');
  }
  runApp(
    ChangeNotifierProvider(
      create: (_) => ByteSizeProvider(),
      child: const ByteSizeApp(),
    ),
  );
}

class ByteSizeApp extends StatelessWidget {
  const ByteSizeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<ByteSizeProvider>(
      builder: (context, provider, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'ByteSize AI',
          themeMode: provider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            scaffoldBackgroundColor: const Color(0xFFF4F7FB),
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF3B82F6),
              secondary: Color(0xFF8B5CF6),
              surface: Colors.white,
              onSurface: Color(0xFF1E293B),
            ),
            textTheme: GoogleFonts.outfitTextTheme(
              ThemeData.light().textTheme,
            ).apply(fontSizeFactor: provider.textScale),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF0B0F19),
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF60A5FA),
              secondary: Color(0xFFA78BFA),
              surface: Color(0xFF1E293B),
              onSurface: Colors.white,
            ),
            textTheme: GoogleFonts.outfitTextTheme(
              ThemeData.dark().textTheme,
            ).apply(fontSizeFactor: provider.textScale),
          ),
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(provider.textScale)),
              child: child!,
            );
          },
          home: const WelcomeScreen(),
        );
      },
    );
  }
}

// ==========================================
// 3. UI UTILS & NAVIGATION
// ==========================================
void showAppInfo(BuildContext context, String title, String description) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.info_outline,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Text(title),
        ],
      ),
      content: Text(
        description,
        style: const TextStyle(fontSize: 16, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text("Got it!"),
        ),
      ],
    ),
  );
}

class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned(
          top: -150,
          left: -100,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 140, sigmaY: 140),
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(
                  context,
                ).colorScheme.primary.withOpacity(isDark ? 0.25 : 0.15),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: -50,
          right: -100,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 140, sigmaY: 140),
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(
                  context,
                ).colorScheme.secondary.withOpacity(isDark ? 0.25 : 0.15),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsets padding;
  final bool isVibrant;
  final VoidCallback? onTap;
  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 30,
    this.padding = const EdgeInsets.all(24),
    this.isVibrant = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withOpacity(isVibrant ? 0.08 : 0.04)
                    : Colors.white.withOpacity(0.85),
                borderRadius: BorderRadius.circular(borderRadius),
                border: Border.all(
                  color: Colors.white.withOpacity(isDark ? 0.08 : 0.4),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.3 : 0.05),
                    blurRadius: 40,
                    spreadRadius: -5,
                  ),
                ],
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});
  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;
  final List<Widget> _screens = [
    const DashboardScreen(),
    const StudyScreen(),
    const AskMyNotesScreen(),
    const FlashcardScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bool isKeyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          _screens[_currentIndex],
          if (!isKeyboardOpen)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.only(bottom: 24, left: 24, right: 24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(40),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF0F172A).withOpacity(0.8)
                            : Colors.white.withOpacity(0.8),
                        borderRadius: BorderRadius.circular(40),
                        border: Border.all(
                          color: Colors.white.withOpacity(isDark ? 0.1 : 0.5),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 30,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _buildNavItem(Icons.dashboard_rounded, 'Home', 0),
                          _buildNavItem(Icons.auto_awesome, 'Study', 1),
                          _buildNavItem(Icons.chat_bubble_rounded, 'Chat', 2),
                          _buildNavItem(Icons.style_rounded, 'Cards', 3),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isSelected = _currentIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: EdgeInsets.symmetric(
          horizontal: isSelected ? 20 : 12,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withOpacity(0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade500,
              size: 26,
            ),
            if (isSelected) ...[
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

void _showDocumentViewer(BuildContext context, ByteSizeProvider provider) {
  if (provider.currentDocument == null) return;
  TextEditingController textCtrl = TextEditingController(
    text: provider.currentDocument!.extractedText,
  );

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.85,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    "Source: ${provider.currentDocument!.title}",
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const SizedBox(height: 16),

            if (provider.currentDocument!.rawImageBytes != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.memory(
                  provider.currentDocument!.rawImageBytes!,
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                "Extracted Text (Editable):",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
            ],

            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: TextField(
                  controller: textCtrl,
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: "Document text...",
                  ),
                  style: const TextStyle(fontSize: 15, height: 1.6),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: () {
                  provider.updateDocumentText(textCtrl.text);
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Document updated successfully!'),
                    ),
                  );
                },
                icon: const Icon(Icons.save),
                label: const Text(
                  "Save Changes",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class GlobalDocHeader extends StatelessWidget {
  const GlobalDocHeader({super.key});
  @override
  Widget build(BuildContext context) {
    return Consumer<ByteSizeProvider>(
      builder: (context, provider, _) {
        return Container(
          margin: const EdgeInsets.only(bottom: 24),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            borderRadius: 20,
            isVibrant: true,
            child: Row(
              children: [
                if (provider.currentDocument != null &&
                    provider.currentDocument!.rawImageBytes != null)
                  Container(
                    margin: const EdgeInsets.only(right: 16),
                    width: 45,
                    height: 45,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      image: DecorationImage(
                        image: MemoryImage(
                          provider.currentDocument!.rawImageBytes!,
                        ),
                        fit: BoxFit.cover,
                      ),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.5),
                      ),
                    ),
                  )
                else
                  Container(
                    margin: const EdgeInsets.only(right: 16),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.description,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                  ),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Active Document",
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        provider.currentDocument?.title ?? "None Selected",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (provider.currentDocument != null)
                  IconButton(
                    icon: Icon(
                      Icons.edit_document,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    tooltip: "View/Edit Source Text",
                    onPressed: () => _showDocumentViewer(context, provider),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ==========================================
// 4. SCREENS
// ==========================================
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _bioCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          Positioned(
            top: -50,
            left: -100,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
              child: Container(
                width: 400,
                height: 400,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -100,
            right: -50,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
              child: Container(
                width: 400,
                height: 400,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(
                    context,
                  ).colorScheme.secondary.withOpacity(0.5),
                ),
              ),
            ),
          ),

          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 40),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      'assets/icon.png',
                      height: 90,
                      width: 90,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Icons.auto_awesome,
                        size: 60,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    "Welcome to",
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                    ),
                  ),
                  const Text(
                    "ByteSize.",
                    style: TextStyle(
                      fontSize: 56,
                      fontWeight: FontWeight.w900,
                      height: 1.1,
                      letterSpacing: -2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "Your ultimate AI-powered study companion. Let's personalize your workspace.",
                    style: TextStyle(
                      fontSize: 16,
                      color: isDark
                          ? Colors.grey.shade400
                          : Colors.grey.shade700,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 40),

                  GlassCard(
                    padding: const EdgeInsets.all(20),
                    borderRadius: 24,
                    child: Column(
                      children: [
                        TextField(
                          controller: _nameCtrl,
                          decoration: InputDecoration(
                            labelText: "Your Name",
                            hintText: "e.g. Alex",
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            filled: true,
                            fillColor: Theme.of(
                              context,
                            ).colorScheme.surface.withOpacity(0.5),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _bioCtrl,
                          decoration: InputDecoration(
                            labelText: "Course or Goal",
                            hintText: "e.g. Pass my CS Midterm",
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            filled: true,
                            fillColor: Theme.of(
                              context,
                            ).colorScheme.surface.withOpacity(0.5),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 40),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        elevation: 10,
                        shadowColor: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.5),
                      ),
                      onPressed: () {
                        Provider.of<ByteSizeProvider>(
                          context,
                          listen: false,
                        ).updateProfile(
                          _nameCtrl.text.isEmpty ? "Scholar" : _nameCtrl.text,
                          _bioCtrl.text.isEmpty
                              ? "Ready to learn!"
                              : _bioCtrl.text,
                        );
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const MainNavigation(),
                          ),
                        );
                      },
                      child: const Text(
                        "Start Studying",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  void _showProfileModal(BuildContext context, ByteSizeProvider provider) {
    TextEditingController nameCtrl = TextEditingController(
      text: provider.userName,
    );
    TextEditingController bioCtrl = TextEditingController(
      text: provider.userBio,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
              left: 32,
              right: 32,
              top: 32,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () async {
                    await provider.updateProfilePicture();
                    setModalState(() {});
                  },
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      CircleAvatar(
                        radius: 45,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.2),
                        backgroundImage: provider.profilePicBytes != null
                            ? MemoryImage(provider.profilePicBytes!)
                            : null,
                        child: provider.profilePicBytes == null
                            ? Icon(
                                Icons.person,
                                size: 40,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                      ),
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.camera_alt,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: "Display Name",
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: bioCtrl,
                  decoration: InputDecoration(
                    labelText: "Bio / Goal",
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "Text Size (Accessibility)",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Slider(
                  value: provider.textScale,
                  min: 0.8,
                  max: 1.5,
                  divisions: 7,
                  label: provider.textScale.toStringAsFixed(1),
                  activeColor: Theme.of(context).colorScheme.primary,
                  onChanged: (val) {
                    provider.updateTextScale(val);
                    setModalState(() {});
                  },
                ),

                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () {
                      provider.updateProfile(nameCtrl.text, bioCtrl.text);
                      Navigator.pop(ctx);
                    },
                    child: const Text(
                      "Save Settings",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ByteSizeProvider>(
      builder: (context, provider, _) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Scaffold(
          body: Stack(
            children: [
              const AmbientBackground(),
              SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 120),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        GestureDetector(
                          onTap: () => _showProfileModal(context, provider),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary.withOpacity(0.2),
                                backgroundImage:
                                    provider.profilePicBytes != null
                                    ? MemoryImage(provider.profilePicBytes!)
                                    : null,
                                child: provider.profilePicBytes == null
                                    ? Icon(
                                        Icons.person,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Hello,",
                                    style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    provider.userName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                Icons.info_outline,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              onPressed: () => showAppInfo(
                                context,
                                "Dashboard",
                                "This is your Library. Tap 'Scan Text' to open your camera and read text from real life, or 'Upload' to add PDFs. Tap a document below to select it!",
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                isDark ? Icons.light_mode : Icons.dark_mode,
                                size: 28,
                              ),
                              onPressed: provider.toggleTheme,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 40),
                    const Text(
                      "Study Smarter,\nNot Harder.",
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                        letterSpacing: -1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      provider.userBio,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 40),

                    Row(
                      children: [
                        Expanded(
                          child: GlassCard(
                            onTap: () =>
                                provider.pickAndProcessDocument(context, true),
                            borderRadius: 32,
                            isVibrant: true,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.camera_alt,
                                    color: Colors.white,
                                    size: 32,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                const Text(
                                  "Scan Text",
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "Use hardware camera",
                                  style: TextStyle(
                                    color: Colors.grey.shade500,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: GlassCard(
                            onTap: () =>
                                provider.pickAndProcessDocument(context, false),
                            borderRadius: 32,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondary.withOpacity(0.2),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.upload_file,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.secondary,
                                    size: 32,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                const Text(
                                  "Upload",
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "PDFs & Docs",
                                  style: TextStyle(
                                    color: Colors.grey.shade500,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 40),
                    const Text(
                      "Library Vault",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 20),

                    if (provider.documents.isEmpty)
                      Text(
                        "No documents yet. Upload one above!",
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontStyle: FontStyle.italic,
                        ),
                      ),

                    ...provider.documents.map(
                      (doc) => Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: GlassCard(
                          onTap: () => provider.selectDocument(doc),
                          padding: const EdgeInsets.all(16),
                          borderRadius: 24,
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Icon(
                                  doc.icon,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      doc.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      doc.subtitle,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (provider.currentDocument?.id == doc.id)
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                ),
                                onPressed: () => provider.removeDocument(doc),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // --- NEW: FULL SCREEN LOADING OVERLAY ---
              if (provider.isDocumentLoading)
                Container(
                  color: isDark
                      ? Colors.black.withOpacity(0.7)
                      : Colors.white.withOpacity(0.7),
                  child: Center(
                    child: GlassCard(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            "Analyzing with AI...",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            "Extracting text and formatting.",
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class StudyScreen extends StatefulWidget {
  const StudyScreen({super.key});
  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  double _complexity = 50;
  @override
  Widget build(BuildContext context) {
    return Consumer<ByteSizeProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          body: Stack(
            children: [
              const AmbientBackground(),
              SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 120),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Expanded(child: GlobalDocHeader()),
                        IconButton(
                          icon: Icon(
                            Icons.info_outline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          onPressed: () => showAppInfo(
                            context,
                            "Explain-o-Meter",
                            "Slide the meter to adjust how the AI explains your document. Once generated, you can copy the text to your clipboard!",
                          ),
                        ),
                      ],
                    ),
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Explain-o-Meter",
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Slider(
                            value: _complexity,
                            min: 0,
                            max: 100,
                            divisions: 2,
                            activeColor: Theme.of(context).colorScheme.primary,
                            onChanged: (v) => setState(() => _complexity = v),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "Simple",
                                style: TextStyle(
                                  color: Colors.grey.shade500,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                "Standard",
                                style: TextStyle(
                                  color: Colors.grey.shade500,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                "Expert",
                                style: TextStyle(
                                  color: Colors.grey.shade500,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 18,
                                ),
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                              onPressed: provider.isSummaryLoading
                                  ? null
                                  : () => provider.generateSummary(_complexity),
                              icon: provider.isSummaryLoading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.auto_awesome),
                              label: const Text(
                                "Generate Smart Bite",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Summary Result",
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 20,
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.copy,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.secondary,
                                ),
                                onPressed: () {
                                  if (provider.currentDocument != null) {
                                    Clipboard.setData(
                                      ClipboardData(
                                        text: provider
                                            .currentDocument!
                                            .generatedSummary,
                                      ),
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          '📝 Summary copied to clipboard! Paste it anywhere.',
                                        ),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Divider(),
                          ),
                          MarkdownBody(
                            data:
                                provider.currentDocument?.generatedSummary ??
                                "*Upload a document and tap generate!*",
                            styleSheet: MarkdownStyleSheet(
                              p: const TextStyle(height: 1.7),
                              h1: const TextStyle(fontWeight: FontWeight.w900),
                              h2: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class AskMyNotesScreen extends StatefulWidget {
  const AskMyNotesScreen({super.key});
  @override
  State<AskMyNotesScreen> createState() => _AskMyNotesScreenState();
}

class _AskMyNotesScreenState extends State<AskMyNotesScreen> {
  final TextEditingController _textController = TextEditingController();

  Widget _buildChatPill(String text, ByteSizeProvider provider) {
    return GestureDetector(
      onTap: () => provider.sendMessage(text),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isKeyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
    return Consumer<ByteSizeProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          body: Stack(
            children: [
              const AmbientBackground(),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 10,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Expanded(child: GlobalDocHeader()),
                          IconButton(
                            icon: Icon(
                              Icons.info_outline,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            onPressed: () => showAppInfo(
                              context,
                              "Smart Chat",
                              "Ask the AI any question! It will strictly read your active document and find the answer for you.",
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        itemCount:
                            provider.chatMessages.length +
                            (provider.isChatLoading ? 1 : 0),
                        itemBuilder: (ctx, i) {
                          if (provider.isChatLoading && i == 0)
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(20.0),
                                child: CircularProgressIndicator(),
                              ),
                            );
                          final msg = provider
                              .chatMessages[provider.isChatLoading ? i - 1 : i];
                          bool isUser = msg['isUser'];
                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 16),
                              padding: const EdgeInsets.all(20),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.85,
                              ),
                              decoration: BoxDecoration(
                                color: isUser
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(24)
                                    .copyWith(
                                      bottomRight: Radius.circular(
                                        isUser ? 0 : 24,
                                      ),
                                      bottomLeft: Radius.circular(
                                        isUser ? 24 : 0,
                                      ),
                                    ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 15,
                                    spreadRadius: -5,
                                  ),
                                ],
                              ),
                              child: MarkdownBody(
                                data: msg['text'],
                                styleSheet: MarkdownStyleSheet(
                                  p: TextStyle(
                                    color: isUser
                                        ? Colors.white
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                    if (provider.currentDocument != null)
                      Container(
                        height: 40,
                        margin: const EdgeInsets.only(
                          left: 24,
                          right: 24,
                          bottom: 12,
                        ),
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            _buildChatPill("Summarize this", provider),
                            _buildChatPill("What are the key terms?", provider),
                            _buildChatPill("Make a 5-question quiz", provider),
                            _buildChatPill("Explain the conclusion", provider),
                          ],
                        ),
                      ),

                    Container(
                      margin: EdgeInsets.fromLTRB(
                        24,
                        0,
                        24,
                        isKeyboardOpen ? 16 : 100,
                      ),
                      child: GlassCard(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        borderRadius: 32,
                        child: Row(
                          children: [
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextField(
                                controller: _textController,
                                decoration: const InputDecoration(
                                  hintText: "Ask your notes...",
                                  border: InputBorder.none,
                                ),
                              ),
                            ),
                            Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon: const Icon(
                                  Icons.arrow_upward,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  provider.sendMessage(_textController.text);
                                  _textController.clear();
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class FlashcardScreen extends StatefulWidget {
  const FlashcardScreen({super.key});
  @override
  State<FlashcardScreen> createState() => _FlashcardScreenState();
}

class _FlashcardScreenState extends State<FlashcardScreen> {
  bool _showAnswer = false;
  int _cardIndex = 0;
  final TextEditingController _focusController = TextEditingController();

  void _editCardDialog(
    BuildContext context,
    Flashcard card,
    ByteSizeProvider provider,
  ) {
    TextEditingController qCtrl = TextEditingController(text: card.question);
    TextEditingController aCtrl = TextEditingController(text: card.answer);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Edit Flashcard"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qCtrl,
              decoration: const InputDecoration(labelText: "Question"),
              maxLines: null,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: aCtrl,
              decoration: const InputDecoration(labelText: "Answer"),
              maxLines: null,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                card.question = qCtrl.text;
                card.answer = aCtrl.text;
              });
              provider.saveData();
              Navigator.pop(ctx);
            },
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ByteSizeProvider>(
      builder: (context, provider, _) {
        final doc = provider.currentDocument;
        final hasCards = doc != null && doc.flashcards.isNotEmpty;

        return Scaffold(
          body: Stack(
            children: [
              const AmbientBackground(),
              SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 100),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Expanded(child: GlobalDocHeader()),
                        IconButton(
                          icon: Icon(
                            Icons.info_outline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          onPressed: () => showAppInfo(
                            context,
                            "Study Cards",
                            "Tell the AI what you want to study, and it will read your document to automatically generate a custom deck of flashcards for you!",
                          ),
                        ),
                      ],
                    ),
                    if (provider.isCardsLoading)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(40.0),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (!hasCards)
                      GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.auto_awesome,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.secondary,
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  "Custom Deck Builder",
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            TextField(
                              controller: _focusController,
                              maxLines: 3,
                              decoration: InputDecoration(
                                hintText:
                                    "What do you want to focus on?\n(e.g. 'Only create cards about formulas and definitions')",
                                filled: true,
                                fillColor: Theme.of(
                                  context,
                                ).colorScheme.surface.withOpacity(0.5),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.all(18),
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.primary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                                onPressed: () => provider.generateFlashcards(
                                  _focusController.text,
                                ),
                                icon: const Icon(Icons.style),
                                label: const Text(
                                  "Generate Smart Cards",
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            "Card ${_cardIndex + 1} of ${doc.flashcards.length}",
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 20,
                            ),
                          ),
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                tooltip: "Edit Card",
                                onPressed: () => _editCardDialog(
                                  context,
                                  doc.flashcards[_cardIndex],
                                  provider,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_sweep,
                                  color: Colors.red,
                                ),
                                tooltip: "Delete Deck",
                                onPressed: () => setState(() {
                                  doc.flashcards.clear();
                                  provider.saveData();
                                  _cardIndex = 0;
                                  _showAnswer = false;
                                }),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      GestureDetector(
                        onTap: () => setState(() => _showAnswer = !_showAnswer),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOutQuart,
                          width: double.infinity,
                          height: 420,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(40),
                            color: _showAnswer
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.surface,
                            boxShadow: [
                              BoxShadow(
                                color: Theme.of(context).colorScheme.primary
                                    .withOpacity(_showAnswer ? 0.4 : 0.1),
                                blurRadius: 40,
                                spreadRadius: -10,
                              ),
                            ],
                          ),
                          child: Text(
                            _showAnswer
                                ? doc.flashcards[_cardIndex].answer
                                : doc.flashcards[_cardIndex].question,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              height: 1.3,
                              color: _showAnswer
                                  ? Colors.white
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 40),
                      if (_showAnswer)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.all(20),
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.secondary,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                            ),
                            onPressed: () {
                              setState(() {
                                _showAnswer = false;
                                if (_cardIndex < doc.flashcards.length - 1)
                                  _cardIndex++;
                                else
                                  _cardIndex = 0;
                              });
                            },
                            child: const Text(
                              "Next Card ➡️",
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        )
                      else
                        const Center(
                          child: Text(
                            'Tap card to flip ✨',
                            style: TextStyle(
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
