import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/ui/theme.dart';
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
  Stream<List<AfterglowEntry>>? _entriesStream;
  String? _error;

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
        _error = 'Link your partner to use Afterglow.';
      });
      return;
    }

    try {
      await ensureSharedKey(session);
      if (!mounted) return;
      setState(() {
        _entriesStream = AfterglowRepository.streamEntries(couple.id);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
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
    // After the form returns (sealed or cancelled), re-init the stream
    if (!mounted) return;
    _ensureKeyAndLoad();
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
            Expanded(
              child: _error != null
                  ? _ErrorState(message: _error!, onRetry: _ensureKeyAndLoad)
                  : _entriesStream == null
                      ? const Center(child: CircularProgressIndicator())
                      : StreamBuilder<List<AfterglowEntry>>(
                          stream: _entriesStream,
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return _ErrorState(
                                message: snapshot.error.toString(),
                                onRetry: _ensureKeyAndLoad,
                              );
                            }
                            if (!snapshot.hasData) {
                              return const Center(
                                  child: CircularProgressIndicator());
                            }
                            final entries = snapshot.data!;
                            if (entries.isEmpty) {
                              return _emptyState();
                            }
                            return ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                              itemCount: entries.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 12),
                              itemBuilder: (context, i) =>
                                  _AfterglowCard(entry: entries[i]),
                            );
                          },
                        ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: FilledButton.icon(
                onPressed: _entriesStream == null ? null : _startNew,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Start a moment'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
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
            const Icon(
              Icons.cloud_off_outlined,
              color: Color(0xFFEF6F58),
              size: 36,
            ),
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
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _decrypt();
  }

  @override
  void didUpdateWidget(covariant _AfterglowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id ||
        oldWidget.entry.sealedAt != widget.entry.sealedAt) {
      _decrypt();
    }
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
          _decryptGratitude(
            widget.entry.gratitudeABytes!,
            widget.entry.nonceABytes!,
            adA,
          ),
        if (widget.entry.gratitudeBBytes != null)
          _decryptGratitude(
            widget.entry.gratitudeBBytes!,
            widget.entry.nonceBBytes!,
            adB,
          ),
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
    Uint8List blob,
    Uint8List nonce,
    String ad,
  ) async {
    // Afterglow schema has dedicated nonce columns but no separate MAC column,
    // so the blob is packed as `mac || ciphertext`. The author uid is the AD.
    final payload = unpackMacAndCiphertext(blob: blob, nonce: nonce);
    return CryptoCore.decryptString(payload, associatedData: ad);
  }

  Future<void> _completeEntry() async {
    await context.push<bool>(
      '/app/closer/afterglow/new',
    );
  }

  bool get _amPartnerA {
    final session = ref.read(sessionProvider);
    final me = session.profile?.id;
    final partner = session.partner?.id;
    return me != null && partner != null && me.compareTo(partner) < 0;
  }

  bool get _hasMyContribution => _amPartnerA
      ? widget.entry.gratitudeABytes != null
      : widget.entry.gratitudeBBytes != null;

  Future<void> _requestDelete() async {
    final session = ref.read(sessionProvider);
    final me = session.profile?.id;
    if (me == null) return;
    setState(() => _busy = true);
    try {
      await AfterglowRepository.requestDelete(
        entryId: widget.entry.id,
        requestedBy: me,
      );
    } catch (e) {
      // Ignore
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelDelete() async {
    setState(() => _busy = true);
    try {
      await AfterglowRepository.cancelDelete(widget.entry.id);
    } catch (e) {
      // Ignore
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete() async {
    final session = ref.read(sessionProvider);
    final me = session.profile?.id;
    if (me == null) return;
    setState(() => _busy = true);
    try {
      await AfterglowRepository.hardDelete(
        entryId: widget.entry.id,
        deletedBy: me,
      );
    } catch (e) {
      // Ignore
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.entry.happenedAt.toLocal();
    final me = ref.read(sessionProvider).profile?.id;
    final amPartnerA = _amPartnerA;
    final dateStr =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
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
          else if (widget.entry.sealedAt == null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'Pending...',
                  style: TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            if (!_hasMyContribution)
              Center(
                child: FilledButton.icon(
                  onPressed: _completeEntry,
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Complete & Seal'),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Waiting for your partner to add their gratitude.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0x99F5EFE6), fontSize: 12),
                ),
              ),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: _gratitudeBlock(
                        amPartnerA ? 'You' : 'Partner', _gratitudeA)),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  color: const Color(0x33F5EFE6),
                ),
                Expanded(
                    child: _gratitudeBlock(
                        amPartnerA ? 'Partner' : 'You', _gratitudeB)),
              ],
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!widget.entry.deleteRequested)
                _actionChip(
                    'Request delete', Icons.delete_outline, _requestDelete),
              if (widget.entry.deleteRequested &&
                  widget.entry.deleteRequestedBy == me)
                _actionChip('Cancel request', Icons.close, _cancelDelete),
              if (widget.entry.deleteRequested &&
                  widget.entry.deleteRequestedBy != me)
                _actionChip(
                    'Confirm delete', Icons.delete_forever, _confirmDelete),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionChip(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: MilesColors.surface2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: const Color(0xCCF5EFE6)),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xCCF5EFE6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
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
  const AfterglowEntry({
    required this.id,
    required this.happenedAt,
    this.sealedAt,
    required this.retention,
    this.gratitudeABytes,
    this.nonceABytes,
    this.photoABytes,
    this.gratitudeBBytes,
    this.nonceBBytes,
    this.photoBBytes,
    this.deleteRequested = false,
    this.deleteRequestedBy,
  });

  final String id;
  final DateTime happenedAt;
  final DateTime? sealedAt;
  final String retention;
  final Uint8List? gratitudeABytes;
  final Uint8List? nonceABytes;
  final Uint8List? photoABytes;
  final Uint8List? gratitudeBBytes;
  final Uint8List? nonceBBytes;
  final Uint8List? photoBBytes;
  final bool deleteRequested;
  final String? deleteRequestedBy;
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
      sealedAt: JsonUtils.parseDateOrNull(json['sealed_at'])?.toUtc(),
      retention: JsonUtils.parseStringOrNull(json['retention']) ?? 'ephemeral',
      gratitudeABytes: _maybeBytes(json['gratitude_a']),
      nonceABytes: _maybeBytes(json['nonce_a']),
      photoABytes: _maybeBytes(json['photo_a']),
      gratitudeBBytes: _maybeBytes(json['gratitude_b']),
      nonceBBytes: _maybeBytes(json['nonce_b']),
      photoBBytes: _maybeBytes(json['photo_b']),
      deleteRequested: (json['delete_requested'] as bool?) ?? false,
      deleteRequestedBy:
          JsonUtils.parseStringOrNull(json['delete_requested_by']),
    );
  }

  static Uint8List? _maybeBytes(dynamic v) =>
      v == null ? null : byteaToBytes(v);

  /// Returns a real-time stream of ALL afterglow entries for [coupleId], including unsealed ones.
  static Stream<List<AfterglowEntry>> streamEntries(String coupleId) {
    return _c
        .from('afterglow_entries')
        .stream(primaryKey: ['id'])
        .eq('couple_id', coupleId)
        .order('happened_at', ascending: false)
        .map((rows) {
          final entries = <AfterglowEntry>[];
          for (final row in rows) {
            if (row['deleted'] == true) continue;
            try {
              entries.add(_entryFromJson(row));
            } catch (_) {}
          }
          return List<AfterglowEntry>.unmodifiable(entries);
        });
  }

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
    required bool ephemeral,
    Uint8List? photoBytes,
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
    final res = await _c
        .from('afterglow_entries')
        .insert({
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
        })
        .select()
        .single();
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

  static Future<void> requestDelete({
    required String entryId,
    required String requestedBy,
  }) async {
    await _c.from('afterglow_entries').update({
      'delete_requested': true,
      'delete_requested_by': requestedBy,
      'delete_requested_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', entryId);
  }

  static Future<void> cancelDelete(String entryId) async {
    await _c.from('afterglow_entries').update({
      'delete_requested': false,
      'delete_requested_by': null,
      'delete_requested_at': null,
    }).eq('id', entryId);
  }

  static Future<void> hardDelete({
    required String entryId,
    required String deletedBy,
  }) async {
    await _c.from('afterglow_entries').update({
      'deleted': true,
      'deleted_by': deletedBy,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', entryId);
  }
}
