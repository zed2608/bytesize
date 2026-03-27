
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    print('Firebase initialization failed: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Chat',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final List<String> _messages = [];
  bool _isLoading = false;
  String? _documentContext;
  String? _fileName;

  Future<void> _pickDocument() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'md', 'pdf'],
    );

    if (result != null) {
      PlatformFile file = result.files.first;
      setState(() {
        _fileName = file.name;
      });

      // For simplicity, we'll handle text-based files.
      // PDF parsing would require a more complex setup.
      if (file.extension == 'txt' || file.extension == 'md') {
        try {
          _documentContext = utf8.decode(file.bytes!);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('"${file.name}" loaded as context.')),
          );
        } catch (e) {
          print('Error reading file: $e');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error reading file: $e')),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unsupported file type. Please select a .txt or .md file.')),
        );
      }
    } else {
      // User canceled the picker
    }
  }

  Future<void> _sendMessage(String message) async {
    if (message.trim().isEmpty) return;

    setState(() {
      _messages.add('You: $message');
      _isLoading = true;
    });

    _textController.clear();

    try {
      final model = FirebaseVertexAI.instance.generativeModel(model: 'gemini-1.5-flash');
      
      String prompt;
      if (_documentContext != null) {
        prompt = 'Based on the following document, answer the user\'s question.\n\n---\n\n$_documentContext\n\n---\n\nUser question: $message';
      } else {
        prompt = message;
      }

      final response = await model.generateContent([Content.text(prompt)]);

      setState(() {
        _messages.add('Gemini: ${response.text}');
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _messages.add('Error: $e');
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Chat with Documents'),
      ),
      body: Column(
        children: [
          if (_fileName != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Chip(
                label: Text('Context: $_fileName'),
                onDeleted: () {
                  setState(() {
                    _documentContext = null;
                    _fileName = null;
                  });
                },
              ),
            ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final reversedIndex = _messages.length - 1 - index;
                return ListTile(
                  title: Text(_messages[reversedIndex]),
                );
              },
            ),
          ),
          if (_isLoading) const CircularProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _pickDocument,
                  tooltip: 'Upload Document',
                ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      hintText: 'Enter a message',
                    ),
                    onSubmitted: _sendMessage,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: () => _sendMessage(_textController.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
