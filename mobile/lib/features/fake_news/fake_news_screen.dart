import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/features/fake_news/rss_service.dart';
import 'package:miles/features/intro/intro_splash_screen.dart';
import 'package:miles/main.dart';
import 'package:url_launcher/url_launcher.dart';

// Clean Google-News-style light palette — intentionally NOTHING like Miles.
const _bg = Color(0xFFFFFFFF);
const _surface = Color(0xFFF2F2F2);
const _textPrimary = Color(0xFF202124);
const _textMuted = Color(0xFF70757A);
const _accent = Color(0xFF1A73E8);
const _divider = Color(0xFFE0E0E0);

/// A convincing fake "News" reader shown on cold start. Three hidden triggers
/// (5 quick logo taps, the secret search word, a 2.5s long-press on the Local
/// nav item) run the biometric gate; on success [onAuthenticated] swaps the
/// whole app over to the real Miles experience. Everything else behaves like
/// a real news app (live RSS, external article links, pull-to-refresh).
class FakeNewsScreen extends StatefulWidget {
  const FakeNewsScreen({required this.onAuthenticated, super.key});

  final VoidCallback onAuthenticated;

  @override
  State<FakeNewsScreen> createState() => _FakeNewsScreenState();
}

class _FakeNewsScreenState extends State<FakeNewsScreen>
    with WidgetsBindingObserver {
  List<RssArticle> _articles = [];
  bool _loading = true;
  bool _hasError = false;

  // Entry 1 — logo tap counter (5 within 3s).
  int _logoTapCount = 0;
  DateTime? _firstLogoTap;

  // Entry 3 — long-press (2.5s) on the Local nav item.
  Timer? _localHoldTimer;
  bool _localTriggered = false;

  // Re-entrancy guard: only one entry flow (auth → splash → reveal) at a time,
  // so two triggers firing close together can't stack a second splash or
  // double-fire onAuthenticated.
  bool _entering = false;

  // Search + section state.
  final TextEditingController _searchController = TextEditingController();
  bool _searchOpen = false;
  String _query = '';
  int _section = 0; // 0 For You · 1 Headlines · 2 Local

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetEntryState();
    _loadNews();
    // A closed app woken by a call has no router, no shell and no call route —
    // only this cover. Without letting the call open the door, an incoming call
    // is invisible and unanswerable. The lock still stands; only the hidden
    // trigger is skipped, and only because the user tapped a call notification.
    pendingCall.addListener(_openForPendingCall);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _openForPendingCall());
  }

  void _openForPendingCall() {
    if (_entering || pendingCall.value == null) return;
    _triggerEntry(forCall: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pendingCall.removeListener(_openForPendingCall);
    _localHoldTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Returning to the cover: clear any half-finished entry sequence so it
      // can't carry over, and refresh (cache keeps this instant — no blank).
      if (mounted) setState(_resetEntryState);
      _loadNews();
    }
  }

  /// Clears entry counters + search so a partial sequence never carries across
  /// background/foreground cycles.
  void _resetEntryState() {
    _logoTapCount = 0;
    _firstLogoTap = null;
    _localHoldTimer?.cancel();
    _localTriggered = false;
    _searchController.clear();
    _query = '';
    _searchOpen = false;
  }

  Future<void> _loadNews() async {
    // Serve fresh cache instantly; only show the spinner when there's nothing
    // to display yet. The cache is static so it survives the screen being
    // recreated each background cycle — no blank list on re-show.
    final cachedAt = RssService.cachedAt;
    final hasFreshCache = RssService.cached.isNotEmpty &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(minutes: 15);
    if (hasFreshCache) {
      setState(() {
        _articles = RssService.cached;
        _loading = false;
        _hasError = false;
      });
      return;
    }
    setState(() {
      _articles = RssService.cached; // show stale cache (if any) while refreshing
      _loading = RssService.cached.isEmpty;
      _hasError = false;
    });
    try {
      final fetched = await RssService.fetchArticles();
      if (!mounted) return;
      setState(() {
        _articles = fetched;
        _loading = false;
        _hasError = fetched.isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _hasError = _articles.isEmpty;
      });
    }
  }

  // ── The single authentication gate ─────────────────────────────────────────
  Future<void> _triggerEntry({bool forCall = false}) async {
    if (_entering) return; // one entry flow at a time
    _entering = true;
    try {
      // Silent: no toast, no ripple, no loader. authInProgress guards the
      // biometric prompt's own `inactive` state from resetting the cover
      // beneath it. If the app-lock isn't set up, entry is granted immediately.
      MilesApp.authInProgress = true;
      final enabled = await AppLock.isEnabled();
      final passed = !enabled || await AppLock.authenticate();
      MilesApp.authInProgress = false;

      if (!passed) return; // wrong biometric/PIN → stay on news, no error
      if (!mounted) return;

      // Cinematic reveal: fade the wordmark up over the news screen, then hand
      // control to the real app once it finishes (or the user taps). Skipped
      // when answering a call — 1.2s of branding against a ringing caller is
      // the wrong trade.
      if (!forCall) {
        await Navigator.of(context).push(
          PageRouteBuilder<void>(
            pageBuilder: (_, __, ___) => IntroSplashScreen(
              onComplete: () => Navigator.of(context).pop(),
            ),
            transitionsBuilder: (_, anim, __, child) =>
                FadeTransition(opacity: anim, child: child),
          ),
        );
      }

      if (mounted) widget.onAuthenticated();
    } finally {
      // Always clear both guards, even on early return / error.
      MilesApp.authInProgress = false;
      _entering = false;
    }
  }

  // ── Entry 1: 5 logo taps within 3 seconds ─────────────────────────────────
  void _onLogoTap() {
    final now = DateTime.now();
    if (_firstLogoTap == null ||
        now.difference(_firstLogoTap!) > const Duration(seconds: 3)) {
      _logoTapCount = 1;
      _firstLogoTap = now;
    } else {
      _logoTapCount++;
    }
    if (_logoTapCount >= 5) {
      _logoTapCount = 0;
      _firstLogoTap = null;
      _triggerEntry();
    }
  }

  // ── Entry 2: secret search word ───────────────────────────────────────────
  void _onSearchSubmitted(String value) {
    if (value.trim().toLowerCase() == 'home') {
      _searchController.clear();
      setState(() => _query = '');
      _triggerEntry();
      return;
    }
    setState(() => _query = value.trim());
  }

  // ── Entry 3: long-press (2.5s) on the Local nav item ──────────────────────
  void _localHoldStart() {
    _localTriggered = false;
    _localHoldTimer?.cancel();
    _localHoldTimer = Timer(const Duration(milliseconds: 2500), () {
      _localTriggered = true;
      _triggerEntry();
    });
  }

  void _localHoldCancel() => _localHoldTimer?.cancel();

  void _localTap() {
    _localHoldTimer?.cancel();
    if (_localTriggered) return; // the long-press already handled it
    setState(() => _section = 2);
  }

  Future<void> _openArticle(RssArticle a) async {
    try {
      await launchUrl(Uri.parse(a.url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // Never crash on a bad link.
    }
  }

  /// Articles for the current section + search query.
  List<RssArticle> get _visible {
    var list = List<RssArticle>.from(_articles);
    switch (_section) {
      case 1: // Headlines — grouped by source
        list.sort((a, b) {
          final s = a.source.compareTo(b.source);
          return s != 0
              ? s
              : (b.pubDate ?? DateTime(0)).compareTo(a.pubDate ?? DateTime(0));
        });
      case 2: // Local — different ordering so the tab feels distinct
        list = list.reversed.toList();
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list
          .where((a) =>
              a.title.toLowerCase().contains(q) ||
              a.source.toLowerCase().contains(q),)
          .toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          if (_searchOpen) _buildSearchBar(),
          _buildSectionTabs(),
          const Divider(height: 0.5, thickness: 0.5, color: _divider),
          Expanded(child: _buildBody()),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _bg,
      surfaceTintColor: _bg,
      elevation: 1,
      shadowColor: Colors.black12,
      titleSpacing: 12,
      title: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onLogoTap,
            child: const _NewsLogo(),
          ),
          const SizedBox(width: 10),
          const Text(
            'News',
            style: TextStyle(
              color: _textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: Icon(_searchOpen ? Icons.close : Icons.search,
              color: _textMuted,),
          onPressed: () {
            setState(() {
              _searchOpen = !_searchOpen;
              if (!_searchOpen) {
                _searchController.clear();
                _query = '';
              }
            });
          },
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12, left: 4),
          child: Center(
            child: Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                color: Color(0xFF1A73E8),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Text('A',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,),),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: _bg,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: (v) => setState(() => _query = v.trim()),
        onSubmitted: _onSearchSubmitted,
        style: const TextStyle(color: _textPrimary, fontSize: 15),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search news',
          hintStyle: const TextStyle(color: _textMuted, fontSize: 15),
          prefixIcon: const Icon(Icons.search, color: _textMuted, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, color: _textMuted, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: _surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTabs() {
    const labels = ['For You', 'Headlines', 'Local'];
    return Container(
      color: _bg,
      height: 44,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            _SectionTab(
              label: labels[i],
              selected: _section == i,
              onTap: () => setState(() => _section = i),
              // The Local category tab is also a hidden trigger.
              onLongPress: i == 2 ? _triggerEntry : null,
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: _accent, strokeWidth: 2.5),
      );
    }
    if (_hasError) {
      return Center(
        child: InkWell(
          onTap: _loadNews,
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.refresh, color: _textMuted, size: 36),
                SizedBox(height: 12),
                Text("Couldn't load news. Tap to retry.",
                    style: TextStyle(color: _textMuted, fontSize: 14),),
              ],
            ),
          ),
        ),
      );
    }

    final items = _visible;
    return RefreshIndicator(
      color: _accent,
      onRefresh: _loadNews,
      child: items.isEmpty
          ? ListView(
              children: const [
                SizedBox(height: 120),
                Center(
                  child: Text('No results',
                      style: TextStyle(color: _textMuted, fontSize: 14),),
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 0.5, thickness: 0.5, color: _divider),
              itemBuilder: (_, i) =>
                  _ArticleCard(article: items[i], onTap: () => _openArticle(items[i])),
            ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: _bg,
        border: Border(top: BorderSide(color: _divider, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _NavItem(
              icon: Icons.home_outlined,
              activeIcon: Icons.home,
              label: 'For You',
              selected: _section == 0,
              onTap: () => setState(() => _section = 0),
            ),
            _NavItem(
              icon: Icons.article_outlined,
              activeIcon: Icons.article,
              label: 'Headlines',
              selected: _section == 1,
              onTap: () => setState(() => _section = 1),
            ),
            // Local — rightmost. A 2.5s press here is Entry 3.
            _NavItem(
              icon: Icons.location_on_outlined,
              activeIcon: Icons.location_on,
              label: 'Local',
              selected: _section == 2,
              onTap: _localTap,
              onTapDown: _localHoldStart,
              onTapCancel: _localHoldCancel,
            ),
          ],
        ),
      ),
    );
  }
}

/// Recreated "G + colored news lines" logo — reads as a news app, not Miles.
class _NewsLogo extends StatelessWidget {
  const _NewsLogo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('G',
              style: TextStyle(
                  color: _accent,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  height: 1,),),
          const SizedBox(width: 2),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bar(13, const Color(0xFF4285F4)),
              const SizedBox(height: 2.5),
              _bar(13, const Color(0xFFEA4335)),
              const SizedBox(height: 2.5),
              _bar(9, const Color(0xFFFBBC05)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bar(double w, Color c) => Container(
        width: w,
        height: 2.5,
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(1)),
      );
}

class _SectionTab extends StatelessWidget {
  const _SectionTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            Text(
              label,
              style: TextStyle(
                color: selected ? _accent : _textMuted,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 2.5,
              width: 28,
              color: selected ? _accent : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}

class _ArticleCard extends StatelessWidget {
  const _ArticleCard({required this.article, required this.onTap});

  final RssArticle article;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(article.source,
                      style: const TextStyle(color: _textMuted, fontSize: 12),),
                  const SizedBox(height: 4),
                  Text(
                    article.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                  if (article.timeAgo.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(article.timeAgo,
                        style:
                            const TextStyle(color: _textMuted, fontSize: 12),),
                  ],
                ],
              ),
            ),
            if (article.imageUrl != null) ...[
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CachedNetworkImage(
                  imageUrl: article.imageUrl!,
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(width: 80, height: 80, color: _surface),
                  errorWidget: (_, __, ___) =>
                      Container(width: 80, height: 80, color: _surface),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onTapDown,
    this.onTapCancel,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onTapDown;
  final VoidCallback? onTapCancel;

  @override
  Widget build(BuildContext context) {
    final color = selected ? _accent : _textMuted;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onTapDown: onTapDown == null ? null : (_) => onTapDown!(),
        onTapUp: onTapCancel == null ? null : (_) => onTapCancel!(),
        onTapCancel: onTapCancel,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selected ? activeIcon : icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,),),
          ],
        ),
      ),
    );
  }
}
