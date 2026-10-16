import 'package:flutter/material.dart';

import '../i18n.dart';
import '../errors.dart';
import '../downloads.dart';
import '../models.dart';
import '../repo.dart';
import '../store.dart';
import 'browse.dart';
import 'common.dart';
import 'downloads_view.dart';
import 'player.dart';

/// Detailseite für Filme und Serien (Handlung, Staffeln, Episoden).
class DetailScreen extends StatefulWidget {
  final Source source;
  final MediaItem item;
  const DetailScreen({super.key, required this.source, required this.item});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Map<String, dynamic> _info = {};
  List<Episode>? _eps;
  int _season = 1;
  Object? _error;

  MediaItem get m => widget.item;
  bool get _xtream => widget.source.type == SourceType.xtream;

  @override
  void initState() {
    super.initState();
    if (_xtream) {
      Repo.xtreamInfo(widget.source, m).then((i) {
        if (mounted) setState(() => _info = i);
      }).catchError((_) {});
    }
    if (m.kind == Kind.series) {
      Repo.episodes(widget.source, m).then(_setEps).catchError((e) {
        if (mounted) setState(() => _error = e);
      });
    }
  }

  void _setEps(List<Episode> eps) {
    if (!mounted) return;
    setState(() {
      _eps = eps;
      // Mit der Staffel der zuletzt gesehenen Folge starten
      final last = _lastEpisode;
      _season = last?.season ?? (eps.isEmpty ? 1 : eps.first.season);
    });
  }

  Episode? get _lastEpisode {
    final eps = _eps;
    if (eps == null) return null;
    Episode? best;
    var ts = 0;
    for (final e in eps) {
      final h = store.history[e.url];
      if (h != null && (h['ts'] as int) > ts) {
        ts = h['ts'];
        best = e;
      }
    }
    return best;
  }

  void _playEpisode(Episode e) {
    final eps = _eps!;
    PlayerScreen.open(
      context,
      widget.source,
      episodeList(m, eps),
      eps.indexOf(e),
    );
  }

  String? _s(String k) {
    final v = _info[k];
    if (v == null || '$v'.trim().isEmpty) return null;
    return '$v';
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final backdrop = (_info['backdrop_path'] is List && (_info['backdrop_path'] as List).isNotEmpty)
        ? '${_info['backdrop_path'][0]}'
        : m.logo;
    final plot = _s('plot') ?? _s('description');
    final meta = [
      (_s('releasedate') ?? _s('releaseDate') ?? m.year)?.split('-').first,
      _s('genre'),
      _s('duration'),
      if (m.rating != null && double.tryParse(m.rating!) != null && m.rating != '0')
        '★ ${double.parse(m.rating!).toStringAsFixed(1)}',
    ].whereType<String>().where((x) => x.isNotEmpty).join('   ·   ');
    final cast = _s('cast') ?? _s('actors');
    final director = _s('director');
    final resume = m.kind == Kind.movie ? store.resumeAt(m.url!) : null;
    final last = _lastEpisode;

    final buttons = Wrap(spacing: 10, runSpacing: 10, children: [
      if (m.kind == Kind.movie) ...[
        Pill(resume != null ? tr('Fortsetzen {0}', [_fmt(resume)]) : tr('Abspielen'),
            icon: Icons.play_arrow_rounded,
            primary: true,
            autofocus: true,
            onTap: () => PlayerScreen.open(context, widget.source, [PlayItem(m.url!, m.name, m)], 0)),
        if (resume != null)
          Pill(tr('Von vorne'),
              icon: Icons.replay_rounded,
              onTap: () => PlayerScreen.open(context, widget.source, [PlayItem(m.url!, m.name, m)], 0, fromStart: true)),
        DownloadButton(source: widget.source, item: m, url: m.url!, title: m.name),
      ],
      if (m.kind == Kind.series && _eps != null && _eps!.isNotEmpty)
        Pill(last != null ? tr('Weiter: S{0} E{1}', [last.season, last.number]) : tr('Erste Folge abspielen'),
            icon: Icons.play_arrow_rounded,
            primary: true,
            autofocus: true,
            onTap: () => _playEpisode(last ?? _eps!.first)),
      ListenableBuilder(
        listenable: store,
        builder: (_, _) => Pill(store.isFav(widget.source, m) ? tr('In Favoriten') : tr('Favorit'),
            icon: store.isFav(widget.source, m) ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            autofocus: m.kind == Kind.series && _eps == null,
            onTap: () => toggleFav(context, widget.source, m)),
      ),
    ]);

    final header = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(m.name,
          style: TextStyle(fontSize: wide ? 38 : 26, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.1)),
      if (meta.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(meta, style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500)),
      ],
      if (plot != null) ...[
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Text(plot, maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, height: 1.5, color: Colors.white)),
        ),
      ],
      if (director != null || cast != null) ...[
        const SizedBox(height: 12),
        Text([if (director != null) tr('Regie: {0}', [director]), if (cast != null) tr('Mit: {0}', [cast])].join('\n'),
            maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: textDim, fontSize: 13, height: 1.5)),
      ],
      const SizedBox(height: 24),
      buttons,
    ]);

    final seasons = {for (final e in _eps ?? const <Episode>[]) e.season}.toList()..sort();
    final eps = (_eps ?? const <Episode>[]).where((e) => e.season == _season).toList();

    return Scaffold(
      body: Stack(children: [
        if (backdrop != null)
          Positioned.fill(
            child: Opacity(opacity: .35, child: Artwork(backdrop, m.name, width: MediaQuery.sizeOf(context).width)),
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [bg.withValues(alpha: .4), bg.withValues(alpha: .85), bg],
                stops: const [0, .45, .8],
              ),
            ),
          ),
        ),
        SafeArea(
          child: ListView(
            padding: EdgeInsets.fromLTRB(wide ? 56 : 18, wide ? 40 : 8, wide ? 56 : 18, 40),
            children: [
              if (!wide) Align(alignment: Alignment.centerLeft, child: BackButton(onPressed: () => Navigator.pop(context))),
              wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        width: 230,
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Artwork(m.logo, m.name, width: 230)),
                        ),
                      ),
                      const SizedBox(width: 40),
                      Expanded(child: header),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Center(
                        child: SizedBox(
                          width: 170,
                          child: AspectRatio(
                            aspectRatio: 2 / 3,
                            child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Artwork(m.logo, m.name, width: 170)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      header,
                    ]),
              if (m.kind == Kind.series) ...[
                const SizedBox(height: 30),
                if (_error != null)
                  Text(tr('Episoden konnten nicht geladen werden: {0}', [explain(_error!)]), style: const TextStyle(color: textDim))
                else if (_eps == null)
                  const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
                else ...[
                  SizedBox(
                    height: 44,
                    child: FocusTraversalGroup(
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        clipBehavior: Clip.none,
                        itemCount: seasons.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (_, i) => Pill(tr('Staffel {0}', [seasons[i]]),
                            selected: seasons[i] == _season, onTap: () => setState(() => _season = seasons[i])),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Pill(tr('Staffel {0} herunterladen', [_season]), icon: Icons.download_rounded, onTap: () {
                      for (final e in eps) {
                        try {
                          downloads.add(widget.source, m, e.url, '${m.name} S${e.season}E${e.number}');
                        } catch (_) {/* z. B. HLS: überspringen */}
                      }
                      toast(context, tr('{0} Folgen in der Warteschlange', [eps.length]));
                    }),
                  ),
                  const SizedBox(height: 12),
                  for (final e in eps)
                    _EpisodeRow(
                      e: e,
                      fallback: m.logo,
                      onTap: () => _playEpisode(e),
                      trailing: DownloadButton(
                          source: widget.source, item: m, url: e.url, title: '${m.name} S${e.season}E${e.number}', compact: true),
                    ),
                ],
              ],
            ],
          ),
        ),
      ]),
    );
  }
}

String _fmt(Duration d) {
  final h = d.inHours, mm = d.inMinutes % 60, ss = d.inSeconds % 60;
  return h > 0 ? '$h:${'$mm'.padLeft(2, '0')}:${'$ss'.padLeft(2, '0')}' : '$mm:${'$ss'.padLeft(2, '0')}';
}

class _EpisodeRow extends StatelessWidget {
  final Episode e;
  final String? fallback;
  final VoidCallback onTap;
  final Widget? trailing;
  const _EpisodeRow({required this.e, required this.fallback, required this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final p = store.progressOf(e.url);
    final wide = isWide(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Tap(
        onTap: onTap,
        fill: true,
        scale: 1.01,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            SizedBox(
              width: wide ? 200 : 132,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(fit: StackFit.expand, children: [
                    Artwork(e.image ?? fallback, '${e.number}', width: 200),
                    if (p > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(value: p, minHeight: 3, color: store.accent, backgroundColor: Colors.black54),
                      ),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${e.number}. ${e.title}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                if (e.plot != null) ...[
                  const SizedBox(height: 4),
                  Text(e.plot!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: textDim, fontSize: 13)),
                ],
              ]),
            ),
            ?trailing,
          ]),
        ),
      ),
    );
  }
}
