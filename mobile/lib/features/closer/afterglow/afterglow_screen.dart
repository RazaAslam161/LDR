import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/crypto_core.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/closer/closer_crypto.dart';

/// Afterglow — the soft wind-down after intimacy. Both partners enter one
/// gratitude each (and optionally a photo); on "seal" the entry is added to
/// their shared timeline.
///
/// Storage: `afterglow_entries` table. Per spec §F3 the photo and gratitude are
/// E2EE. The schema gives us a single shared `nonce_a` / `nonce_b` column used
/// for the gratitude line; the optional photo is encrypted with its own nonce
/// packed into the blob via [packFull].
class AfterglowScreen extends ConsumerStatefulWidget {
  const AfterglowScreen({super.key});

  @override
  ConsumerState<AfterglowScreen> createState() => _AfterglowScreenState();
}

class _AfterglowScreenState extends ConsumerState<AfterglowScreen> {
  bool _loading = true;
  String? _error;
  List<AfterglowEntry> _entries = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureKeyAndLoad();
  }

  Future<void> _ensureKeyAndLoad() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    if (couple == null || me == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Link your partner to use Afterglow.';
      });
      return;
    }

    setState(() => _loading = true);
    try {
      await ensureSharedKey(session);
      await _refresh(couple.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _refresh(String coupleId) async {
    try {
      final entries = await AfterglowRepository.fetchEntries(coupleId);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _startNew() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    if (couple == null || me == null) return;

    await context.push<bool>(
      '/app/closer/afterglow/new',
    );
    // After the form seals, refresh.
    if (!mounted) return;
    await _refresh(couple.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              title: 'Afterglow',
              subtitle: 'The tenderness after.',
              onBack: () => context.pop(),
            ),
            Expanded(child: _body),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: FilledButton.icon(
                onPressed: _loading ? null : _startNew,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Start a moment'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget get _body {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return _ErrorState(
        message: _error!,
        onRetry: _ensureKeyAndLoad,
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🌙', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 16),
              Text(
                'Afterglow',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: const Color(0xFFFBF8F4),
                    ),
              ),
              const SizedBox(height: 12),
              const Text(
                'A soft wind-down after intimacy. Share a gratitude, '
                'an optional photo. Sealed for the two of you.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0x99F5EFE6), height: 1.5),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _AfterglowCard(entry: _entries[i]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onBack,
  });
  final String title;
  final String subtitle;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0x80F5EFE6)),
            onPressed: onBack,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0x66F5EFE6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                color: Color(0xFFEF6F58), size: 36,),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xCCF5EFE6), height: 1.5),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single sealed afterglow entry — two gratitude lines side by side.
class _AfterglowCard extends ConsumerStatefulWidget {
  const _AfterglowCard({required this.entry});
  final AfterglowEntry entry;

  @override
  ConsumerState<_AfterglowCard> createState() => _AfterglowCardState();
}

class _AfterglowCardState extends ConsumerState<_AfterglowCard> {
  String? _gratitudeA;
  String? _gratitudeB;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _decrypt();
  }

  Future<void> _decrypt() async {
    try {
      // gratitude_a/b were encrypted with the author's uid as associated data;
      // the alphabetically-first uid is "A". Pass it back or the MAC fails.
      final session = ref.read(sessionProvider);
      final ids = [
        session.profile?.id ?? '',
        session.partner?.id ?? '',
      ]..sort();
      final adA = ids[0];
      final adB = ids[1];
      final results = await Future.wait([
        if (widget.entry.gratitudeABytes != null)
          _decryptGratitude(widget.entry.gratitudeABytes!,
              widget.entry.nonceABytes!, adA,),
        if (widget.entry.gratitudeBBytes != null)
          _decryptGratitude(widget.entry.gratitudeBBytes!,
              widget.entry.nonceBBytes!, adB,),
      ]);
      if (!mounted) return;
      setState(() {
        var i = 0;
        if (widget.entry.gratitudeABytes != null) {
          _gratitudeA = results[i++];
        }
        if (widget.entry.gratitudeBBytes != null) {
          _gratitudeB = results[i];
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not decrypt: $e';
        _loading = false;
      });
    }
  }

  Future<String> _decryptGratitude(
      Uint8List blob, Uint8List nonce, String ad,) async {
    // Afterglow schema has dedicated nonce columns but no separate MAC column,
    // so the blob is packed as `mac || ciphertext`. The author uid is the AD.
    final payload = unpackMacAndCiphertext(blob: blob, nonce: nonce);
    return CryptoCore.decryptString(payload, associatedData: ad);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.entry.happenedAt.toLocal();
    final dateStr =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF141B26).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFEF6F58).withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🌙', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Text(
                dateStr,
                style: const TextStyle(
                  color: Color(0xFFF4937E),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (widget.entry.retention == 'ephemeral')
                const Text(
                  'Ephemeral',
                  style: TextStyle(fontSize: 10, color: Color(0x80F5EFE6)),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFEF6F58), fontSize: 12),
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _gratitudeBlock('You', _gratitudeA)),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  color: const Color(0x33F5EFE6),
                ),
                Expanded(child: _gratitudeBlock('Partner', _gratitudeB)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _gratitudeBlock(String label, String? text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: Color(0x80F5EFE6),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          text ?? '—',
          style: const TextStyle(
            color: Color(0xFFFBF8F4),
            height: 1.5,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

// ─── Repository ───────────────────────────────────────────────────────────

/// One row from `afterglow_entries`. Bytes are kept raw here so the UI can
/// decrypt lazily (and so we don't block the list on decrypting every photo).
class AfterglowEntry {
  AfterglowEntry({
    required this.id,
    required this.happenedAt,
    required this.retention,
    this.gratitudeABytes,
    this.nonceABytes,
    this.photoABytes,
    this.gratitudeBBytes,
    this.nonceBBytes,
    this.photoBBytes,
  });

  final String id;
  final DateTime happenedAt;
  final String retention;
  final Uint8List? gratitudeABytes;
  final Uint8List? nonceABytes;
  final Uint8List? photoABytes;
  final Uint8List? gratitudeBBytes;
  final Uint8List? nonceBBytes;
  final Uint8List? photoBBytes;
}

class AfterglowRepository {
  AfterglowRepository._();

  static final _c = SupabaseService.client;

  /// Returns sealed afterglow entries for [coupleId], newest first.
  static Future<List<AfterglowEntry>> fetchEntries(String coupleId) async {
    final res = await _c
        .from('afterglow_entries')
        .select()
        .eq('couple_id', coupleId)
        .not('sealed_at', 'is', null)
        .order('happened_at', ascending: false);

    final entries = <AfterglowEntry>[];
    for (final row in res as List) {
      try {
        entries.add(_entryFromJson(row as Map<String, dynamic>));
      } catch (_) {
        // Skip a malformed row so one bad entry can't blank the whole list.
      }
    }
    return List<AfterglowEntry>.unmodifiable(entries);
  }

  static AfterglowEntry _entryFromJson(Map<String, dynamic> json) {
    return AfterglowEntry(
      id: JsonUtils.parseString(json['id']),
      happenedAt: JsonUtils.parseDate(json['happened_at']).toUtc(),
      retention: JsonUtils.parseStringOrNull(json['retention']) ?? 'ephemeral',
      gratitudeABytes: _maybeBytes(json['gratitude_a']),
      nonceABytes: _maybeBytes(json['nonce_a']),
      photoABytes: _maybeBytes(json['photo_a']),
      gratitudeBBytes: _maybeBytes(json['gratitude_b']),
      nonceBBytes: _maybeBytes(json['nonce_b']),
      photoBBytes: _maybeBytes(json['photo_b']),
    );
  }

  static Uint8List? _maybeBytes(dynamic v) => v == null ? null : byteaToBytes(v);

  /// Inserts a new entry as "started" — only the current partner's side is set.
  /// Returns the new row id so the partner's side can be filled in later.
  ///
  /// [myId] and [partnerId] together decide which side (A or B) the writer
  /// fills: the alphabetically-first UUID is "partner A". Both clients compute
  /// this identically so they never collide on the same column.
  static Future<String> startEntry({
    required String coupleId,
    required String myId,
    required String partnerId,
    required String gratitude,
    required bool ephemeral, Uint8List? photoBytes,
  }) async {
    final isA = _isPartnerA(myId, partnerId);
    final side = myId; // bound as associated data
    final encText =
        await CryptoCore.encryptString(gratitude, associatedData: side);
    final textBlob = packMacAndCiphertext(encText);
    final nonceBytes = Uint8List.fromList(base64Decode(encText.nonceB64));

    Uint8List? photoBlob;
    if (photoBytes != null) {
      final encPhoto = await CryptoCore.encryptBytes(
        photoBytes,
        associatedData: '${side}_photo',
      );
      photoBlob = packFull(encPhoto);
    }

    final now = DateTime.now().toUtc();
    final res = await _c.from('afterglow_entries').insert({
      'couple_id': coupleId,
      'happened_at': now.toIso8601String(),
      if (isA) ...{
        'gratitude_a': bytesToBytea(textBlob),
        'nonce_a': bytesToBytea(nonceBytes),
        if (photoBlob != null) 'photo_a': bytesToBytea(photoBlob),
      } else ...{
        'gratitude_b': bytesToBytea(textBlob),
        'nonce_b': bytesToBytea(nonceBytes),
        if (photoBlob != null) 'photo_b': bytesToBytea(photoBlob),
      },
      'retention': ephemeral ? 'ephemeral' : 'keep',
    }).select().single();
    return res['id'] as String;
  }

  /// Adds the current partner's side to an existing entry and seals it.
  static Future<void> completeAndSeal({
    required String entryId,
    required String myId,
    required String partnerId,
    required String gratitude,
    Uint8List? photoBytes,
  }) async {
    final isA = _isPartnerA(myId, partnerId);
    final side = myId;
    final encText =
        await CryptoCore.encryptString(gratitude, associatedData: side);
    final textBlob = packMacAndCiphertext(encText);
    final nonceBytes = Uint8List.fromList(base64Decode(encText.nonceB64));

    Uint8List? photoBlob;
    if (photoBytes != null) {
      final encPhoto = await CryptoCore.encryptBytes(
        photoBytes,
        associatedData: '${side}_photo',
      );
      photoBlob = packFull(encPhoto);
    }

    await _c.from('afterglow_entries').update({
      if (isA) ...{
        'gratitude_a': bytesToBytea(textBlob),
        'nonce_a': bytesToBytea(nonceBytes),
        if (photoBlob != null) 'photo_a': bytesToBytea(photoBlob),
      } else ...{
        'gratitude_b': bytesToBytea(textBlob),
        'nonce_b': bytesToBytea(nonceBytes),
        if (photoBlob != null) 'photo_b': bytesToBytea(photoBlob),
      },
      'sealed_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', entryId);
  }

  /// Fetches the most recent un-sealed entry for this couple, if any. Used by
  /// the form to know whether to start fresh or complete the partner's side.
  static Future<AfterglowEntry?> fetchPending(String coupleId) async {
    final res = await _c
        .from('afterglow_entries')
        .select()
        .eq('couple_id', coupleId)
        .isFilter('sealed_at', null)
        .order('happened_at', ascending: false)
        .limit(1)
        .maybeSingle();
    if (res == null) return null;
    return _entryFromJson(res);
  }

  /// True if [myId] is the "A" partner relative to [partnerId]. The
  /// alphabetically-first UUID is partner A — both clients compute identically.
  static bool _isPartnerA(String myId, String partnerId) =>
      myId.compareTo(partnerId) < 0;
}
