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
const List<String> kTabScreens = [
  'Home',
  'Chat',
  'Camera',
  'Touch',
  'Closer',
];
