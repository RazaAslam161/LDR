import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/theme.dart';

/// Inline frosted-glass pill that toggles precise live-location sharing.
///
/// Used by both the inline map card and the full-screen map so the toggle is
/// always one tap away — never buried in Settings.
class LocationToggleBar extends StatefulWidget {
  const LocationToggleBar({
    super.key,
    required this.coupleId,
    required this.partnerName,
  });

  final String coupleId;
  final String partnerName;

  @override
  State<LocationToggleBar> createState() => _LocationToggleBarState();
}

class _LocationToggleBarState extends State<LocationToggleBar> {
  bool _sharing = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _seed();
  }

  Future<void> _seed() async {
    try {
      final mine = await PresenceService.fetchMine(widget.coupleId);
      if (mounted) {
        setState(() {
          _sharing = mine?.locationSharingMode == 'precise';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _loading = true);
    try {
      if (value) {
        // Need permission (incl. background) before we can start.
        final perm = await LocationService.ensurePermission();
        if (LocationService.blocked(perm) ||
            perm != LocationPermission.always) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                    'Location access needed — "Allow all the time" required.'),
                action: SnackBarAction(
                  label: 'Open Settings',
                  onPressed: Geolocator.openAppSettings,
                ),
              ),
            );
          }
          setState(() => _loading = false);
          return;
        }
        await PresenceService.setSharingMode(widget.coupleId, 'precise');
        await LocationService.startLiveSharing(widget.coupleId);
        if (mounted) {
          setState(() {
            _sharing = true;
            _loading = false;
          });
        }
      } else {
        await LocationService.stopLiveSharing(widget.coupleId);
        await PresenceService.clearLiveLocation(widget.coupleId);
        if (mounted) {
          setState(() {
            _sharing = false;
            _loading = false;
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: MilesColors.surfaceGlass,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: MilesColors.gilt, width: 0.8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.location_on_rounded,
                size: 18,
                color: _sharing ? MilesColors.ember : MilesColors.faint,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _sharing
                      ? 'Sharing live with ${widget.partnerName} 💚'
                      : 'Your location is hidden',
                  style: TextStyle(
                    color: _sharing ? MilesColors.cream50 : MilesColors.taupe,
                    fontSize: 12,
                    fontFamily: 'Inter',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: MilesColors.ember),
                )
              else
                Switch(
                  value: _sharing,
                  onChanged: _toggle,
                  activeColor: MilesColors.ember,
                  activeTrackColor:
                      MilesColors.ember.withValues(alpha: 0.3),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
