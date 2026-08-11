import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:miles/core/services/save_media_service.dart';
import 'package:miles/core/widgets/save_media_button.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:video_player/video_player.dart';

/// Full-screen player with FLAG_SECURE so intimate video can't be
/// screenshotted / screen-recorded / shown in the recents preview.
///
/// Lifted out of chat_screen.dart when the partner's profile grew a media grid
/// that plays the same videos. FLAG_SECURE is the reason it moved rather than
/// being written twice: a second player without it is not a duplicate, it is a
/// screenshot bypass for the one bucket in this app that exists to prevent one.
class FullScreenVideo extends StatefulWidget {
  const FullScreenVideo(
      {required this.url, super.key, this.videoPath, this.senderName = 'a message',});
  final String url;
  final String? videoPath;
  final String senderName;

  @override
  State<FullScreenVideo> createState() => _FullScreenVideoState();
}

class _FullScreenVideoState extends State<FullScreenVideo> {
  VideoPlayerController? _vp;
  ChewieController? _chewie;

  @override
  void initState() {
    super.initState();
    SecureScreen.setSecure();
    _init();
  }

  Future<void> _init() async {
    final vp = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    try {
      await vp.initialize();
    } catch (_) {
      await vp.dispose();
      return;
    }
    if (!mounted) {
      await vp.dispose();
      return;
    }
    setState(() {
      _vp = vp;
      _chewie = ChewieController(
        videoPlayerController: vp,
        autoPlay: true,
        aspectRatio: vp.value.aspectRatio == 0 ? 16 / 9 : vp.value.aspectRatio,
      );
    });
  }

  @override
  void dispose() {
    SecureScreen.clearSecure();
    _chewie?.dispose();
    _vp?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: const BackButton(color: Colors.white),
        actions: [
          if (widget.videoPath != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: SaveMediaButton(
                  size: 24,
                  color: Colors.white,
                  onSave: () => SaveMediaService.saveVideoToVault(
                      path: widget.videoPath!, senderName: widget.senderName,),
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: _chewie == null
            ? const CircularProgressIndicator()
            : Chewie(controller: _chewie!),
      ),
    );
  }
}
