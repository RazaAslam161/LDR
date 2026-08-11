import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/theme/chat_theme.dart';
import 'package:miles/features/chat/theme/chat_theme_controller.dart';

Future<void> showChatThemePicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: MilesColors.surface1,
    builder: (_) => const _ChatThemeSheet(),
  );
}

class _ChatThemeSheet extends ConsumerStatefulWidget {
  const _ChatThemeSheet();

  @override
  ConsumerState<_ChatThemeSheet> createState() => _ChatThemeSheetState();
}

class _ChatThemeSheetState extends ConsumerState<_ChatThemeSheet> {
  bool _uploading = false;

  Future<void> _pickFromGallery() async {
    final file = await PhotoPickerService.pickFromSheet(context);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final uid = SupabaseService.currentUserId!;
      final path = '$uid/bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await SupabaseService.client.storage
          .from(chatBgBucket)
          .upload(path, file);
      // The PATH, not the signed URL. Persisting the URL stored a 24h expiry
      // in a column read for years: the background went black a day after it
      // was chosen, on every device, with nothing to point at.
      await ref.read(chatThemeProvider).setCustomBackground(path);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() => _uploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not set the background.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = ref.watch(chatThemeProvider);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Chat background',
              style: TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,),),
          const SizedBox(height: 4),
          const Text('Only you see this — your partner keeps her own.',
              style: TextStyle(color: MilesColors.taupe, fontSize: 12.5),),
          const SizedBox(height: 18),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.78,
            children: [
              for (final t in chatThemes)
                _Swatch(
                  theme: t,
                  selected: ctrl.themeId == t.id,
                  onTap: () => ctrl.setTheme(t.id),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _Tile(
            icon: _uploading ? null : Icons.photo_library_outlined,
            label: _uploading ? 'Uploading…' : 'Choose from gallery',
            selected: ctrl.themeId == 'custom',
            busy: _uploading,
            onTap: _uploading ? null : _pickFromGallery,
          ),
          const SizedBox(height: 8),
          _Tile(
            icon: Icons.refresh,
            label: 'Reset to default',
            selected: false,
            busy: false,
            onTap: () => ref.read(chatThemeProvider).setTheme('velvet'),
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(
      {required this.theme, required this.selected, required this.onTap,});
  final ChatTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: theme.bg.length == 1
                      ? [theme.bg.first, theme.bg.first]
                      : theme.bg,
                ),
                border: Border.all(
                  color: selected ? MilesColors.gilt : Colors.transparent,
                  width: 2,
                ),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bubble(theme.partnerBubble, false),
                  const SizedBox(height: 5),
                  _bubble(theme.myBubble, true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(theme.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: selected ? MilesColors.gilt : MilesColors.taupe,
                  fontSize: 10.5,),),
        ],
      ),
    );
  }

  Widget _bubble(Color c, bool mine) => Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 34,
          height: 11,
          decoration:
              BoxDecoration(color: c, borderRadius: BorderRadius.circular(6)),
        ),
      );
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.busy,
    required this.onTap,
  });
  final IconData? icon;
  final String label;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: MilesColors.surface2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? MilesColors.gilt : Colors.transparent,),
        ),
        child: Row(
          children: [
            if (busy)
              const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),)
            else
              Icon(icon, color: MilesColors.gilt, size: 20),
            const SizedBox(width: 12),
            Text(label,
                style:
                    const TextStyle(color: MilesColors.cream50, fontSize: 14),),
          ],
        ),
      ),
    );
  }
}
