import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:miles/features/covers/rss_service.dart';
import 'package:url_launcher/url_launcher.dart';

// Clean Google-News-style light palette — intentionally NOTHING like Miles.
const _bg = Color(0xFFFFFFFF);
const _surface = Color(0xFFF2F2F2);
const _textPrimary = Color(0xFF202124);
const _textMuted = Color(0xFF70757A);
const _accent = Color(0xFF1A73E8);
const _divider = Color(0xFFE0E0E0);

/// A convincing fake "News" reader shown on cold start. Everything behaves
/// like a real news app (live RSS, external article links, pull-to-refresh).
///
/// No door of its own. The way in is the move the owner recorded, matched by
/// the host's pointer layer over this screen; nothing here knows it exists.
/// The doors this cover used to carry — five taps on the mark, a hold on the
/// Local item, and before those a search for `home` and a long-press on a tab
/// — are all gone with the rest of the app-authored gestures: a door the app
/// ships is a door everyone can read.
class NewsCoverScreen extends StatefulWidget {
  const NewsCoverScreen({super.key});

  @override
  State<NewsCoverScreen> createState() => _NewsCoverScreenState();
}

class _NewsCoverScreenState extends State<NewsCoverScreen>
    with WidgetsBindingObserver {
  List<RssArticle> _articles = [];
  bool _loading = true;
  bool _hasError = false;

  // Search + section state.
  final TextEditingController _searchController = TextEditingController();
  bool _searchOpen = false;
  String _query = '';
  int _section = 0; // 0 For You · 1 Headlines · 2 Local

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadNews();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Returning to the cover: close a search that was left open so nothing
      // typed carries across a background, and refresh (cache keeps this
      // instant — no blank).
      if (mounted) setState(_resetSearch);
      _loadNews();
    }
  }

  void _resetSearch() {
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

  void _onSearchSubmitted(String value) => setState(() => _query = value.trim());

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
      title: const Row(
        children: [
          _NewsLogo(),
          SizedBox(width: 10),
          Text(
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
    // Scrollable, because three fixed tabs at 16dp padding overflow a 360dp
    // handset by 35px — and an overflow stripe painted across a cover is the
    // one thing on it that no real news app has.
    return Container(
      color: _bg,
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        children: [
          for (var i = 0; i < labels.length; i++)
            _SectionTab(
              label: labels[i],
              selected: _section == i,
              onTap: () => setState(() => _section = i),
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
            _NavItem(
              icon: Icons.location_on_outlined,
              activeIcon: Icons.location_on,
              label: 'Local',
              selected: _section == 2,
              onTap: () => setState(() => _section = 2),
            ),
          ],
        ),
      ),
    );
  }
}

/// The masthead mark.
///
/// It used to be a letterform in one company's brand colour beside bars in
/// three more of that company's exact hexes — a counterfeit of a mark people
/// know by heart, which is both a trademark problem and a worse disguise: a
/// familiar logo drawn slightly wrong is far more likely to be looked at twice
/// than an unremarkable one nobody recognises.
///
/// This is the same article-card mark the launcher icon draws, so the icon on
/// the home screen and the masthead inside agree.
class _NewsLogo extends StatelessWidget {
  const _NewsLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: const Color(0xFFB3261E),
        borderRadius: BorderRadius.circular(7),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(width: 7, height: 7, color: Colors.white),
              const SizedBox(width: 2),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [_bar(9), const SizedBox(height: 2), _bar(6)],
              ),
            ],
          ),
          _bar(18),
        ],
      ),
    );
  }

  Widget _bar(double w) => Container(width: w, height: 2, color: Colors.white);
}

class _SectionTab extends StatelessWidget {
  const _SectionTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? _accent : _textMuted;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
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
