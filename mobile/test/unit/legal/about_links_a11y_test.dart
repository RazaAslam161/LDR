import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The About links' accessibility, pinned as shape.
///
/// _AboutLink fronts the FAQ, Terms, Privacy Policy, Child Safety and security
/// disclosure pages — for a TalkBack user those five underlined links are the
/// only route to the app's legal and safety documents. The widget is private,
/// and the one public widget in its file reads `SupabaseService.client`, a
/// `static late final` with no injection seam (the wall
/// chat_signed_out_send_test.dart documents), so the real semantics tree
/// cannot be pumped here. What can be pinned is the shape that makes a screen
/// reader work at all: the link role and label on the one node TalkBack gets,
/// the tap action on that same node — excludeSemantics throws away the
/// detector's — and the 48dp floor under 12px of text.
void main() {
  final src =
      File('lib/features/settings/settings_screen.dart').readAsStringSync();

  /// The body of one class, cut by brace depth.
  String classBody(String name) {
    final at = src.indexOf('class $name ');
    expect(at, greaterThan(-1),
        reason: '$name is gone from settings_screen.dart — retarget this test '
            'at whatever replaced it.',);
    final open = src.indexOf('{', at);
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) return src.substring(open, i);
      }
    }
    fail('unterminated class $name');
  }

  /// The Semantics argument list inside _AboutLink, up to the subtree it
  /// wraps — so a flag asserted here is on the node TalkBack reads, not
  /// somewhere below it.
  String aboutLinkNode() {
    final body = classBody('_AboutLink');
    final sem = body.indexOf('Semantics(');
    expect(sem, greaterThan(-1),
        reason: '_AboutLink no longer builds a Semantics node — the About '
            'links are back to plain text for a screen reader.',);
    final child = body.indexOf('child:', sem);
    expect(child, greaterThan(sem));
    return body.substring(sem, child);
  }

  group('_AboutLink is a link a screen reader can find and open', () {
    test('announced as a link, named by its own text', () {
      final node = aboutLinkNode();
      expect(node, contains('link: true'));
      expect(node, contains('label: label'));
    });

    test('the node itself carries the tap', () {
      // excludeSemantics drops the GestureDetector's action, so without onTap
      // on the Semantics, TalkBack announces a link that double-tap cannot
      // open.
      final node = aboutLinkNode();
      expect(node, contains('excludeSemantics: true'));
      expect(node, contains('onTap: onTap'));
    });

    test('48dp of target under 12px of text', () {
      final body = classBody('_AboutLink');
      expect(body, contains('minWidth: 48'));
      expect(body, contains('minHeight: 48'));
      // deferToChild only hit-tests the text itself, which is the old ~15dp
      // target wearing a bigger box.
      expect(body, contains('HitTestBehavior.opaque'));
    });
  });

  test('the avatar button says what tapping it does', () {
    // With a photo set the avatar renders an unlabeled image, so without a
    // named node TalkBack walks straight past the only way to change it.
    expect(src, contains("label: 'Change profile photo'"));
    expect(src, contains('button: true'));

    // The NODE, not the file: onTap and enabled must sit on the same
    // Semantics that carries the label, or TalkBack announces a button
    // nothing opens. A whole-file contains stayed green when onTap was
    // deleted from the node — the exact hole the _AboutLink slice above
    // closes for the links.
    final at = src.indexOf("label: 'Change profile photo'");
    expect(at, greaterThan(0));
    final node = src.substring(at - 300 < 0 ? 0 : at - 300, at + 300);
    expect(node, contains('onTap: _changingAvatar ? null : _changeAvatar'));
    expect(node, contains('enabled: !_changingAvatar'));
  });
}
