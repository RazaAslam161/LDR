import 'package:flutter/material.dart';

/// Key on the [AppShell] Scaffold so any tab screen's hamburger can open the one
/// shared nav drawer. The drawer lives on the shell's full-height Scaffold (above
/// the bottom nav), so it always covers the whole screen — unlike a per-screen
/// drawer nested inside the content area.
final GlobalKey<ScaffoldState> rootScaffoldKey = GlobalKey<ScaffoldState>();
