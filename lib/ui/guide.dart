import 'package:flutter/material.dart';

import '../epg.dart';
import '../i18n.dart';
import '../errors.dart';
import '../models.dart';
import '../repo.dart';
import '../store.dart';
import 'browse.dart';
import 'common.dart';
import 'player.dart';

String hhmm(BuildContext c, DateTime d) =>
    MaterialLocalizations.of(c).formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true);

/// TV-Guide: links Sender, rechts deren Programm. Vergangene Sendungen von Rückschau-Sendern sind abspielbar.
class GuideView extends StatefulWidget {
  final Source source;
  final Library lib;
  const GuideView({super.key, required this.source, required this.lib});

  @override
  State<GuideView> createState() => _GuideViewState();
}

class _GuideViewState extends State<GuideView> {
  int _sel = 0;
  bool _onlyWithEpg = true;

  List<MediaItem> get _channels {
    final all = widget.lib.of(Kind.live).where((m) => !store.hideAdult || !isAdult(m.group));
    return (_onlyWithEpg ? all.where((m) => epg.of(widget.source, m.epgId).isNotEmpty) : all).toList();
  }

  void _playProg(MediaItem ch, Prog p, List<MediaItem> channels) {
    if (p.isNow || !p.isPast) {
      openItem(context, widget.source, ch, siblings: channels);
      return;
    }
    if (ch.archive == 0 || widget.source.type != SourceType.xtream) {
      toast(context, tr('Für diesen Sender gibt es keine Rückschau'));
      return;
    }
    // Rückschau als „Film“ behandeln: spulbar, mit Fortschritt
    final item = MediaItem(id: '${ch.id}@${p.start.millisecondsSinceEpoch}', name: p.title, kind: Kind.movie, group: ch.name, logo: ch.logo);
    PlayerScreen.open(context, widget.source, [PlayItem(Repo.catchupUrl(widget.source, ch, p.start, p.stop), '${ch.name} · ${p.title}', item)], 0);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: epg,
        builder: (context, _) {
          if (widget.lib.epgUrl == null) {
            return Center(
              child: Text(tr('Diese Quelle hat keinen Programmführer.\nEPG-URL im Server-Menü eintragen (lange drücken).'),
                  textAlign: TextAlign.center, style: TextStyle(color: textDim, fontSize: 15)),
            );
          }
          if (epg.loading(widget.source) && !epg.has(widget.source)) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(tr('Programmführer wird geladen …'), style: TextStyle(color: textDim)),
              ]),
            );
          }
          final channels = _channels;
          if (channels.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(epg.errors[widget.source.id] != null
                    ? tr('Programmführer konnte nicht geladen werden: {0}', [explain(epg.errors[widget.source.id]!)])
                    : tr('Keine Programmdaten für diese Sender'),
                    textAlign: TextAlign.center, style: TextStyle(color: textDim)),
                const SizedBox(height: 16),
                Pill(tr('Erneut laden'), icon: Icons.refresh, onTap: () => epg.ensure(widget.source, widget.lib, force: true)),
              ]),
            );
          }
          _sel = _sel.clamp(0, channels.length - 1);
          final ch = channels[_sel];
          final progs = epg.of(widget.source, ch.epgId);
          final nowIdx = progs.indexWhere((p) => !p.isPast);
          final wide = isWide(context);

          final list = ListView.builder(
            key: ValueKey(ch.id),
            padding: const EdgeInsets.fromLTRB(12, 8, 20, 32),
            itemExtent: 86,
            controller: ScrollController(initialScrollOffset: (nowIdx.clamp(0, progs.length) * 86.0 - 86).clamp(0, double.infinity)),
            itemCount: progs.length,
            itemBuilder: (c, i) => _ProgRow(
              p: progs[i],
              catchup: ch.archive > 0 && widget.source.type == SourceType.xtream,
              autofocus: !wide && i == nowIdx,
              onTap: () => _playProg(ch, progs[i], channels),
            ),
          );

          final chList = ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 24),
            itemCount: channels.length,
            itemExtent: 64,
            itemBuilder: (_, i) {
              final m = channels[i];
              final now = epg.now(widget.source, m.epgId);
              return Tap(
                fill: true,
                scale: 1,
                autofocus: i == _sel,
                onTap: () => openItem(context, widget.source, m, siblings: channels),
                onFocus: (v) {
                  if (v && i != _sel) setState(() => _sel = i);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  color: i == _sel ? store.accent.withValues(alpha: .14) : null,
                  child: Row(children: [
                    SizedBox(width: 52, height: 34, child: Artwork(m.logo, m.name, fit: BoxFit.contain, width: 52)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                        if (now != null)
                          Text(now.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: textDim, fontSize: 12)),
                      ]),
                    ),
                    if (m.archive > 0) Icon(Icons.history_rounded, size: 16, color: ink(.38)),
                  ]),
                ),
              );
            },
          );

          final filter = Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              Pill(tr('Nur mit Programm'), selected: _onlyWithEpg, onTap: () => setState(() => _onlyWithEpg = !_onlyWithEpg)),
              const SizedBox(width: 8),
              Pill(tr('Aktualisieren'), icon: Icons.refresh, onTap: () => epg.ensure(widget.source, widget.lib, force: true)),
            ]),
          );

          if (!wide) {
            // Handy: Sender oben als Leiste, Programm darunter
            return Column(children: [
              filter,
              SizedBox(
                height: 76,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  itemCount: channels.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => Tap(
                    radius: 10,
                    onTap: () => setState(() => _sel = i),
                    child: Container(
                      width: 80,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: i == _sel ? store.accent.withValues(alpha: .25) : surface2,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Artwork(channels[i].logo, channels[i].name, fit: BoxFit.contain, width: 80),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Expanded(child: Text(ch.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
                  Pill(tr('Live'), icon: Icons.play_arrow_rounded, primary: true, onTap: () => openItem(context, widget.source, ch, siblings: channels)),
                ]),
              ),
              Expanded(child: list),
            ]);
          }
          return Column(children: [
            filter,
            Expanded(
              child: Row(children: [
                SizedBox(width: 320, child: FocusTraversalGroup(child: chList)),
                Container(width: 1, color: line),
                Expanded(child: FocusTraversalGroup(child: list)),
              ]),
            ),
          ]);
        },
      );
}

class _ProgRow extends StatelessWidget {
  final Prog p;
  final bool catchup, autofocus;
  final VoidCallback onTap;
  const _ProgRow({required this.p, required this.catchup, required this.onTap, this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    final now = p.isNow, past = p.isPast;
    final dim = past && !catchup;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Tap(
        fill: true,
        scale: 1,
        autofocus: autofocus,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: now ? store.accent.withValues(alpha: .12) : null,
            border: Border(left: BorderSide(color: now ? store.accent : Colors.transparent, width: 3)),
          ),
          child: Row(children: [
            SizedBox(
              width: 108,
              child: Text('${hhmm(context, p.start)}–${hhmm(context, p.stop)}',
                  style: TextStyle(color: dim ? ink(.38) : ink(.7), fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: dim ? ink(.38) : fg)),
                if (p.desc != null)
                  Text(p.desc!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: textDim, fontSize: 12.5)),
                if (now) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: p.progress, minHeight: 3, color: store.accent, backgroundColor: ink(.12)),
                ],
              ]),
            ),
            const SizedBox(width: 10),
            if (now) Icon(Icons.play_circle_fill_rounded, color: store.accent),
            if (past && catchup) Icon(Icons.history_rounded, color: ink(.7)),
          ]),
        ),
      ),
    );
  }
}
