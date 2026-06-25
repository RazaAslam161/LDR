import 'package:flutter/material.dart';

/// A chat theme: a background (gradient or solid) + the two bubble colours +
/// text colour. Six built-ins, on-brand with Velvet Aurora, plus a 'custom'
/// theme that pairs with a user-picked background image (see chat_bg_image_url).
class ChatTheme {
  const ChatTheme({
    required this.id,
    required this.name,
    required this.bg,
    required this.myBubble,
    required this.partnerBubble,
    required this.text,
    required this.subtext,
  });

  final String id;
  final String name;

  /// 1 colour = solid; 2+ = top-left → bottom-right gradient.
  final List<Color> bg;
  final Color myBubble;
  final Color partnerBubble;
  final Color text;
  final Color subtext;

  bool get isCustom => id == 'custom';
}

const chatThemes = <ChatTheme>[
  ChatTheme(
    id: 'velvet',
    name: 'Midnight Boudoir',
    bg: [Color(0xFF1A0E16), Color(0xFF2A1320)],
    myBubble: Color(0xFFC97B92),
    partnerBubble: Color(0xFF2E2230),
    text: Color(0xFFF7ECE4),
    subtext: Color(0xFFB59CA8),
  ),
  ChatTheme(
    id: 'ember',
    name: 'Candlelit',
    bg: [Color(0xFF2A160E), Color(0xFF4A2614)],
    myBubble: Color(0xFFD9763E),
    partnerBubble: Color(0xFF31201A),
    text: Color(0xFFF7ECE4),
    subtext: Color(0xFFCBA68F),
  ),
  ChatTheme(
    id: 'aurora',
    name: 'Aurora',
    bg: [Color(0xFF241640), Color(0xFF103A3E)],
    myBubble: Color(0xFF7A57C9),
    partnerBubble: Color(0xFF1C2A3A),
    text: Color(0xFFF3EEFB),
    subtext: Color(0xFFAFA6C8),
  ),
  ChatTheme(
    id: 'rose',
    name: 'Blush',
    bg: [Color(0xFF3A1A28), Color(0xFF2A1320)],
    myBubble: Color(0xFFE08AA0),
    partnerBubble: Color(0xFF34232C),
    text: Color(0xFFFBEEF2),
    subtext: Color(0xFFC9A3B0),
  ),
  ChatTheme(
    id: 'midnight',
    name: 'Starlit',
    bg: [Color(0xFF0E1A3A), Color(0xFF0A0F22)],
    myBubble: Color(0xFF3F5FB0),
    partnerBubble: Color(0xFF161F38),
    text: Color(0xFFEDF1FB),
    subtext: Color(0xFF9DA8C8),
  ),
  ChatTheme(
    id: 'dawn',
    name: 'Dawn',
    bg: [Color(0xFFF5E6DC), Color(0xFFEAD3CB)],
    myBubble: Color(0xFFE0A0B0),
    partnerBubble: Color(0xFFFFFFFF),
    text: Color(0xFF3A2030),
    subtext: Color(0xFF8A6B78),
  ),
];

/// Custom-image theme (dark bubbles + scrim handle legibility over any photo).
const customChatTheme = ChatTheme(
  id: 'custom',
  name: 'Your photo',
  bg: [Color(0xFF1A0E16)],
  myBubble: Color(0xFFC97B92),
  partnerBubble: Color(0xCC2E2230),
  text: Color(0xFFF7ECE4),
  subtext: Color(0xFFD8C8D0),
);

ChatTheme chatThemeById(String? id) {
  if (id == 'custom') return customChatTheme;
  for (final t in chatThemes) {
    if (t.id == id) return t;
  }
  return chatThemes.first; // velvet default
}
