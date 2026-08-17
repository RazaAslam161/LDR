import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A notepad that really keeps notes.
///
/// The notes are genuinely persisted, because the failure mode of a fake app is
/// someone opening it twice: a notepad that forgets what you typed is a notepad
/// that announces itself. They are stored in plain SharedPreferences under an
/// innocuous key and are deliberately NOT part of the couple's encrypted data —
/// they are set dressing, and treating them as private data would be the tell.
///
/// The way in is a **long-press on the empty-state illustration** — reachable
/// only when there are no notes on screen, so it cannot be hit by someone
/// actually using the pad.
class NotesCover extends StatefulWidget {
  const NotesCover({required this.onAuthenticated, super.key});

  final VoidCallback onAuthenticated;

  @override
  State<NotesCover> createState() => _NotesCoverState();
}

class _NotesCoverState extends State<NotesCover> with CoverGate<NotesCover> {
  static const _storeKey = 'notes_cover_items';

  List<_Note> _notes = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void onCoverUnlocked() => widget.onAuthenticated();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storeKey) ?? const [];
    if (!mounted) return;
    setState(() {
      _notes = raw.map(_Note.decode).whereType<_Note>().toList();
      _loaded = true;
    });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_storeKey, _notes.map((n) => n.encode()).toList());
  }

  Future<void> _edit([_Note? existing]) async {
    final result = await Navigator.of(context).push<_Note>(
      MaterialPageRoute(builder: (_) => _NoteEditor(note: existing)),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (existing == null) {
        _notes.insert(0, result);
      } else {
        _notes[_notes.indexOf(existing)] = result;
      }
    });
    await _persist();
  }

  Future<void> _delete(_Note note) async {
    setState(() => _notes.remove(note));
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFBF7),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Notes',
          style: TextStyle(
            color: Color(0xFF202124),
            fontWeight: FontWeight.w500,
            fontSize: 20,
          ),
        ),
        // The visible door.
        actions: [
          CoverExitButton(
            onPressed: runEntryGate,
            color: const Color(0xFF5F6368),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _edit,
        backgroundColor: const Color(0xFFF4B400),
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
      ),
      body: !_loaded
          ? const SizedBox.shrink()
          : _notes.isEmpty
              ? _EmptyState(onSecretHold: runEntryGate)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
                  itemCount: _notes.length,
                  itemBuilder: (context, i) {
                    final n = _notes[i];
                    return Dismissible(
                      key: ValueKey(n.createdMs),
                      background: Container(
                        color: const Color(0xFFE0E3E7),
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child: const Icon(Icons.delete_outline,
                            color: Color(0xFF5F6368),),
                      ),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => _delete(n),
                      child: _NoteCard(note: n, onTap: () => _edit(n)),
                    );
                  },
                ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSecretHold});

  final VoidCallback onSecretHold;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        // The door. Only present when the pad is empty, so nobody using the
        // notepad normally can land on it.
        onLongPress: onSecretHold,
        behavior: HitTestBehavior.opaque,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sticky_note_2_outlined,
                size: 72, color: Color(0xFFDADCE0),),
            SizedBox(height: 16),
            Text(
              'Notes you add appear here',
              style: TextStyle(color: Color(0xFF80868B), fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note, required this.onTap});

  final _Note note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: const Color(0xFFFFF8E1),
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFF0E3B8)),
      ),
      child: ListTile(
        onTap: onTap,
        title: Text(
          note.title.isEmpty ? 'Untitled' : note.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF202124),
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: note.body.isEmpty
            ? null
            : Text(
                note.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF5F6368), fontSize: 13),
              ),
      ),
    );
  }
}

class _NoteEditor extends StatefulWidget {
  const _NoteEditor({this.note});

  final _Note? note;

  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  late final _title = TextEditingController(text: widget.note?.title ?? '');
  late final _body = TextEditingController(text: widget.note?.body ?? '');

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty && _body.text.trim().isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(
      context,
      _Note(
        title: _title.text.trim(),
        body: _body.text.trim(),
        createdMs: widget.note?.createdMs ??
            DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFBF7),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF5F6368)),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save',
                style: TextStyle(color: Color(0xFFF4B400)),),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              autofocus: widget.note == null,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w500,
                color: Color(0xFF202124),
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'Title',
                hintStyle: TextStyle(color: Color(0xFFBDC1C6)),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _body,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 15, color: Color(0xFF3C4043)),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Start typing',
                  hintStyle: TextStyle(color: Color(0xFFBDC1C6)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Note {
  const _Note({
    required this.title,
    required this.body,
    required this.createdMs,
  });

  final String title;
  final String body;
  final int createdMs;

  String encode() =>
      jsonEncode({'t': title, 'b': body, 'c': createdMs});

  static _Note? decode(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return _Note(
        title: (m['t'] ?? '') as String,
        body: (m['b'] ?? '') as String,
        createdMs: (m['c'] ?? 0) as int,
      );
    } catch (_) {
      return null; // a corrupt entry must not take the whole pad down
    }
  }
}
