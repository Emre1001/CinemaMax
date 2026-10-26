import 'package:flutter/material.dart';

import '../downloads.dart';
import '../i18n.dart';
import '../errors.dart';
import '../models.dart';
import '../store.dart';
import 'common.dart';
import 'player.dart';

/// Auflösung für einen Download (Speicher sparen): Einstellung oder Auswahl mit geschätzter Größe.
/// 0 = beste, null = abgebrochen. Nur HLS hat mehrere Qualitäten; MP4/MKV liegen in einer vor.
Future<int?> chooseDownloadQuality(BuildContext c, Source s, String url) async {
  final pref = store.get('dlQuality', -1);
  if (!isHls(url) || pref >= 0) return pref < 0 ? 0 : pref;
  List<({int height, int bytes})> q;
  try {
    q = await hlsQualities(s, url).timeout(const Duration(seconds: 15));
  } catch (_) {
    return 0; // nicht prüfbar: der Download meldet den eigentlichen Fehler
  }
  if (q.isEmpty || !c.mounted) return 0;
  return pick<int>(c, tr('Download-Qualität'), {
    for (final (i, v) in q.indexed)
      v.height: [
        '${v.height}p',
        if (v.bytes > 0) tr('ca. {0}', [fmtBytes(v.bytes)]),
        if (i == 0) tr('beste'),
      ].join(' · '),
  });
}

/// Download-Knopf für Film/Episode: zeigt Status und steuert Laden/Pause/Löschen.
class DownloadButton extends StatelessWidget {
  final Source source;
  final MediaItem item;
  final String url, title;
  final bool compact; // nur Symbol (Episodenliste)

  const DownloadButton(
      {super.key, required this.source, required this.item, required this.url, required this.title, this.compact = false});

  Future<void> _tap(BuildContext c) async {
    final d = downloads.of(url);
    if (d == null) {
      final q = await chooseDownloadQuality(c, source, url);
      if (q == null || !c.mounted) return;
      try {
        downloads.add(source, item, url, title, maxHeight: q);
        toast(c, tr('Download gestartet: {0}', [title]));
      } catch (e) {
        toast(c, tr('Nicht herunterladbar: {0}', [explain(e)]));
      }
      return;
    }
    final a = await pick(c, title, {
      if (d.status == DlStatus.running || d.status == DlStatus.queued) 'pause': tr('Pausieren'),
      if (d.status == DlStatus.paused || d.status == DlStatus.failed) 'resume': tr('Fortsetzen'),
      'delete': tr('Download löschen'),
    });
    switch (a) {
      case 'pause': downloads.pause(url);
      case 'resume': downloads.resume(url);
      case 'delete': await downloads.remove(url);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: downloads,
        builder: (c, _) {
          final d = downloads.of(url);
          final (icon, label) = switch (d?.status) {
            null => (Icons.download_rounded, tr('Herunterladen')),
            DlStatus.done => (Icons.download_done_rounded, tr('Offline verfügbar')),
            DlStatus.running => (Icons.downloading_rounded, '${(d!.progress * 100).round()} %'),
            DlStatus.queued => (Icons.schedule_rounded, tr('Wartet')),
            DlStatus.paused => (Icons.pause_circle_outline_rounded, tr('Pausiert')),
            DlStatus.failed => (Icons.error_outline_rounded, tr('Fehlgeschlagen')),
          };
          if (!compact) return Pill(label, icon: icon, onTap: () => _tap(c));
          return Tap(
            radius: 100,
            onTap: () => _tap(c),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: d?.status == DlStatus.running
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(value: d!.progress, strokeWidth: 2.5, color: store.accent))
                  : Icon(icon, size: 22, color: d?.status == DlStatus.done ? store.accent : ink(.7)),
            ),
          );
        },
      );
}

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Downloads'), style: const TextStyle(fontWeight: FontWeight.w700))),
        body: const SafeArea(top: false, child: DownloadsView()),
      );
}

/// Alle Downloads aller Server. Funktioniert ohne Internet.
class DownloadsView extends StatelessWidget {
  const DownloadsView({super.key});

  void _play(BuildContext c, Download d) {
    final s = store.sources.where((s) => s.id == d.srcId).firstOrNull ??
        Source(id: d.srcId, name: '', type: SourceType.m3u, url: '');
    PlayerScreen.open(c, s, [PlayItem(d.url, d.title, d.item)], 0);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: downloads,
        builder: (context, _) {
          final list = downloads.list;
          if (list.isEmpty) {
            return Center(
              child: Text(tr('Noch keine Downloads.\nFilme und Folgen über „Herunterladen“ offline speichern.'),
                  textAlign: TextAlign.center, style: TextStyle(color: textDim, fontSize: 15)),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Row(children: [
                Text(tr('{0} belegt', [fmtBytes(downloads.usedBytes)]), style: TextStyle(color: textDim)),
                const Spacer(),
                Pill(tr('Alle löschen'), icon: Icons.delete_outline_rounded, onTap: () async {
                  final ok = await pick(context, tr('Alle Downloads löschen?'), {false: tr('Abbrechen'), true: tr('Löschen')});
                  if (ok == true) downloads.removeAll();
                }),
              ]),
              SizedBox(height: 12),
              for (final (i, d) in list.indexed)
                // Download-Knopf (Pause/Löschen) neben der Zeile: per Fernbedienung mit Pfeil rechts erreichbar
                Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(
                      child: Tap(
                    fill: true,
                    scale: 1.01,
                    autofocus: i == 0,
                    onTap: () => d.status == DlStatus.done ? _play(context, d) : null,
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: Row(children: [
                        SizedBox(
                          width: 56,
                          height: 84,
                          child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Artwork(d.item.logo, d.title, width: 56)),
                        ),
                        SizedBox(width: 16),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(d.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                            SizedBox(height: 4),
                            Text(
                              switch (d.status) {
                                DlStatus.done => '${tr('Offline verfügbar')} · ${fmtBytes(d.received)}',
                                DlStatus.running => '${fmtBytes(d.received)} / ${d.total == 0 ? '?' : fmtBytes(d.total)}',
                                DlStatus.queued => tr('Wartet'),
                                DlStatus.paused => '${tr('Pausiert')} · ${fmtBytes(d.received)}',
                                DlStatus.failed => '${tr('Fehlgeschlagen')}: ${d.error ?? ''}',
                              },
                              maxLines: 2,
                              style: TextStyle(color: textDim, fontSize: 13),
                            ),
                            if (d.status == DlStatus.running || d.status == DlStatus.paused) ...[
                              SizedBox(height: 8),
                              LinearProgressIndicator(value: d.progress, minHeight: 3, color: store.accent, backgroundColor: ink(.12)),
                            ],
                          ]),
                        ),
                        SizedBox(width: 8),
                        if (d.status == DlStatus.done) Icon(Icons.play_circle_fill_rounded, color: store.accent, size: 30),
                      ]),
                    ),
                      ),
                    ),
                    SizedBox(width: 6),
                    DownloadButton(source: Source(id: d.srcId, name: '', type: SourceType.m3u, url: ''), item: d.item, url: d.url, title: d.title, compact: true),
                  ]),
                ),
            ],
          );
        },
      );
}
