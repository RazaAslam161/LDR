/// Bottom-nav tab labels, indexed by `shellTabProvider`. Index 2 (Camera) is a
/// push button, not a persisted tab, but kept here so the indices line up.
///
/// The screen a user is in is published by `PresenceRouteObserver`, which sees
/// every route. Tabs are the one move it cannot see — switching tabs is a
/// setState, not a navigation — so AppShell tells it directly via
/// `publishActiveTab()`. There is deliberately no second reporting function
/// here: eleven screens used to report from initState and dispose, duplicating
/// what the observer already does and holding their own idea of what had last
/// been said.
/// Every tab name the bar can carry, in order. The bar itself may show fewer.
const List<String> kTabScreens = [
  'Home',
  'Chat',
  'Camera',
  'Touch',
  'Closer',
];

/// The tabs actually on screen, in nav-index order.
///
/// Touch is hidden while modest mode is on, and it sits in the MIDDLE — so
/// indexing [kTabScreens] directly told the partner "they are in Touch" while
/// the user was standing in Closer. Anything mapping a nav index to a name has
/// to be built from the same flag the bar was.
List<String> visibleTabScreens({required bool showTouch}) =>
    [for (final t in kTabScreens) if (showTouch || t != 'Touch') t];
