import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/disguise_notification.dart';
import 'package:miles/features/disguise/disguise_profile.dart';

/// A disguise is undone by frequency long before it is undone by wording. These
/// hold the line on which covers may make a sound at all.
void main() {
  // The profiles the app actually ships, not synthetic ones: a cover added to
  // kDisguises without a budget decision should fail here, not ship silent.
  DisguiseNotificationStyle styleOf(DisguiseCover c) =>
      notificationStyleFor(kDisguises.firstWhere((p) => p.cover == c));

  final shippedCovers = kDisguises.map((p) => p.cover).toList();

  test('covers that never notify in real life are marked silent', () {
    // A calculator with anything in the notification shade is a calculator
    // someone picks up and looks at. Same for a spirit level, a unit converter
    // and a storage-info readout: none of them have ever notified anyone.
    for (final cover in [
      DisguiseCover.calculator,
      DisguiseCover.level,
      DisguiseCover.convert,
      DisguiseCover.device,
      DisguiseCover.recorder,
    ]) {
      expect(styleOf(cover).isSilentCover, isTrue,
          reason: '$cover must never put anything in the shade',);
      expect(styleOf(cover).budget, NotificationBudget.none);
    }
  });

  test('news is the only cover allowed to alert frequently', () {
    expect(styleOf(DisguiseCover.news).budget, NotificationBudget.frequent);
    for (final cover in shippedCovers) {
      if (cover == DisguiseCover.news || cover == DisguiseCover.none) continue;
      expect(styleOf(cover).budget, isNot(NotificationBudget.frequent),
          reason: '$cover cannot plausibly alert as often as a news app',);
    }
  });

  test('weather updates one permanent entry rather than adding any', () {
    // The strongest cover: the NUMBER of notifications never changes, so there
    // is nothing new for a bystander to notice.
    expect(styleOf(DisguiseCover.weather).budget,
        NotificationBudget.persistent,);
    expect(styleOf(DisguiseCover.weather).isSilentCover, isFalse);
  });

  test('unread wording counts, and never names anyone', () {
    final news = styleOf(DisguiseCover.news);
    expect(news.unreadBody(1), 'A new story is available');
    expect(news.unreadBody(5), '5 new stories available');
    // No name, no preview, and nothing that reads as a chat app.
    for (final cover in shippedCovers) {
      final s = styleOf(cover);
      for (final body in [s.unreadBody(1), s.unreadBody(9), s.body, s.title]) {
        final lower = body.toLowerCase();
        for (final banned in ['message', 'chat', 'partner', 'miles ']) {
          if (cover == DisguiseCover.none) continue; // undisguised, says Miles
          expect(lower.contains(banned), isFalse,
              reason: '$cover leaks "$banned" in "$body"',);
        }
      }
    }
  });

  test('every cover still resolves a real drawable', () {
    for (final cover in shippedCovers) {
      expect(styleOf(cover).smallIcon, startsWith('@drawable/ic_notif_'),
          reason: 'an icon name that does not resolve makes the plugin throw '
              'and post nothing, silently, in the background isolate',);
    }
  });
}
