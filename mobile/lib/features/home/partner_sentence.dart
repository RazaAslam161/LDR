/// One line that answers the question people actually open this app to ask.
///
/// Not *where is she* — that is Find My's question, and it is a more sinister
/// one. The question is **can I talk to her right now**, and its answer is made
/// of time, not distance: is it dark there, is she up, how long until she is.
///
/// Every row below is a true statement or it does not render. That constraint
/// is the whole design. A map that says "asleep" while she is actively typing
/// has not made a small error — it has told you something about your partner
/// that is false, in the one place you go to feel close to her.
///
/// Precedence is strict: the first matching row wins, and the rows are ordered
/// so that the most direct evidence beats the most inferred.
library;

import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/time/tz_helper.dart';

/// What the card should say, and how sure it is.
class PartnerSentence {
  const PartnerSentence(this.text, {this.confident = true});

  final String text;

  /// False when the line is hedged because the inputs disagree. The UI renders
  /// these quieter rather than differently — an uncertain claim in a confident
  /// voice is the failure this whole file exists to avoid.
  final bool confident;
}

/// Build the line for [partner] as seen by a viewer in [myTimezone].
///
/// [now] is injectable so the rules can be tested at 3am in Lahore without
/// waiting until 3am in Lahore.
PartnerSentence partnerSentence({
  required Presence? presence,
  required Profile? partner,
  required String? myTimezone,
  required String partnerName,
  DateTime? now,
}) {
  final at = now ?? DateTime.now().toUtc();
  final tz = partner?.timezone;

  // ── 1. She is in the app. Beats every inference below it. ───────────────
  //
  // app_last_active_at is server-stamped and has nothing to do with GPS, so it
  // is available even when location sharing is off entirely. Without this row
  // the card can announce "asleep" to someone whose partner is typing to them
  // in the next tab — the single worst thing this feature could do.
  final active = presence?.appLastActiveAt;
  if (active != null && at.difference(active.toUtc()).inMinutes < 5) {
    final t = tz == null ? null : _clock(at, tz);
    return PartnerSentence(
      t == null ? '$partnerName is here' : "$partnerName is here · it's $t there",
    );
  }

  if (tz == null || tz.isEmpty) {
    return PartnerSentence('$partnerName is somewhere', confident: false);
  }

  final theirClock = _clock(at, tz);
  final theirHour = TzHelper.inZone(at, tz).hour;

  // ── 2. The declared zone disagrees with the shared position. ────────────
  //
  // profiles.timezone is self-set and goes stale the moment someone flies.
  // When longitude says one thing and the profile says another, local time,
  // the sleep verdict and any sunrise countdown are ALL untrustworthy together
  // — so the line hedges once rather than asserting three wrong things.
  final lon = presence?.longitude;
  if (lon != null) {
    final solarOffsetHours = lon / 15.0;
    final declaredHours = TzHelper.offsetMinutes('UTC', tz) / 60.0;
    if ((solarOffsetHours - declaredHours).abs() > 1.5) {
      return PartnerSentence(
        "it's around $theirClock where $partnerName is",
        confident: false,
      );
    }
  }

  // ── 3. The sleep window, when BOTH ends of it are known. ────────────────
  //
  // One end is not a schedule. A wake time with no sleep time was enough for
  // the old code to decide someone was awake, which is true for exactly as
  // long as the day is.
  final wake = _minutes(partner?.wakeTime);
  final sleep = _minutes(partner?.sleepTime);
  if (wake != null && sleep != null) {
    final nowMin = theirHour * 60 + TzHelper.inZone(at, tz).minute;
    // The wrap is explicit. A window like 23:00 -> 07:00 crosses midnight, and
    // testing it as a simple range inverts the answer for every night owl.
    final asleep = sleep <= wake
        ? (nowMin >= sleep && nowMin < wake)
        : (nowMin >= sleep || nowMin < wake);
    if (asleep) {
      final until = _untilLabel(nowMin, wake);
      return PartnerSentence('$partnerName is asleep · $until until morning');
    }
    final untilSleep = _untilLabel(nowMin, sleep);
    if (myTimezone != null && myTimezone.isNotEmpty) {
      final mine = TzHelper.inZone(at, myTimezone);
      final myWake = _minutes(partner?.wakeTime);
      // Only claim "you're both awake" about MY waking hours if I have any
      // idea what they are; otherwise just report hers.
      if (myWake != null && mine.hour >= 6 && mine.hour < 23) {
        return PartnerSentence(
          "you're both awake · $partnerName sleeps in $untilSleep",
        );
      }
    }
    return PartnerSentence("$partnerName is up · it's $theirClock there");
  }

  // ── 4. No schedule: say the time and the gap, and nothing about sleep. ──
  if (myTimezone != null && myTimezone.isNotEmpty && myTimezone != tz) {
    return PartnerSentence(
      "it's $theirClock there · ${TzHelper.offsetLabel(myTimezone, tz)}",
    );
  }
  return PartnerSentence("it's $theirClock where $partnerName is");
}

String _clock(DateTime at, String tz) {
  final t = TzHelper.inZone(at, tz);
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m${t.hour < 12 ? 'am' : 'pm'}';
}

/// "HH:mm" -> minutes past midnight, or null.
int? _minutes(String? hhmm) {
  if (hhmm == null || hhmm.isEmpty) return null;
  final parts = hhmm.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// How long from [fromMin] to [toMin], wrapping midnight, said as people say it.
String _untilLabel(int fromMin, int toMin) {
  var delta = toMin - fromMin;
  if (delta < 0) delta += 24 * 60;
  final h = delta ~/ 60;
  final m = delta % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}
