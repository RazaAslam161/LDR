import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

/// A player for audio a PERSON made — a voice note, a capsule recording, a
/// clip on the recorder cover — as opposed to the app's own cues.
///
/// Content plays on the media stream. It did not, anywhere in this app, and
/// the reason is one line in another file: this app configures exactly ONE
/// AudioSession, and JustAudioEngine sets it to sonification so a 200ms cue
/// ducks the user's music instead of seizing focus
/// (just_audio_engine.dart, _ensureSession — warmed from main at launch, so
/// it is configured before the first note can be tapped). just_audio then
/// pushes THAT session's attributes onto every player it builds
/// (just_audio.dart:1683-1691), and USAGE_ASSISTANCE_SONIFICATION maps to
/// STREAM_SYSTEM in AudioAttributes.toVolumeStreamType — a stream Android
/// mutes outright in vibrate and silent, and one the media rocker does not
/// move. So every recording in the app played into a stream that is zero on
/// a phone in the state most phones are in, which is why the vault could be
/// heard and the chat bubble could not: the vault plays through video_player,
/// which sets its own USAGE_MEDIA.
///
/// The pair is the fix: attributes of our own, and
/// androidApplyAudioAttributes:false so the cue session cannot overwrite them
/// the next time it is configured. Both halves are required — either alone
/// leaves the session free to win.
///
/// The attribute call cannot be awaited from a field initialiser, and it does
/// not need to be: just_audio records the attributes synchronously and
/// re-applies them to the platform on every activation, before the source
/// loads. A failure is not swallowed — an unhandled async error reaches
/// platformDispatcher.onError, which main wires to ErrorReporter.
AudioPlayer newContentPlayer() {
  final player = AudioPlayer(androidApplyAudioAttributes: false);
  unawaited(player.setAndroidAudioAttributes(const AndroidAudioAttributes(
    contentType: AndroidAudioContentType.speech,
    usage: AndroidAudioUsage.media,
  ),),);
  return player;
}
