import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../errors.dart';
import '../i18n.dart';
import '../models.dart';
import '../tv_link.dart';
import 'common.dart';

/// Wie lange ein angezeigter Code gilt.
const _validFor = Duration(minutes: 15);

/// QR-Code als Grafik (schwarz auf weiß mit Ruhezone, damit jede Kamera ihn liest).
class QrView extends StatelessWidget {
  final String data;
  final double size;
  const QrView(this.data, {super.key, this.size = 220});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: EdgeInsets.all(size * .06),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
    child: CustomPaint(painter: _QrPainter(QrImage(QrCode(payload: QrPayload.fromString(data))))),
  );
}

class _QrPainter extends CustomPainter {
  final QrImage qr;
  _QrPainter(this.qr);

  @override
  void paint(Canvas canvas, Size size) {
    final n = qr.moduleCount, cell = size.width / n;
    final p = Paint()..color = Colors.black;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        // Leicht überlappend: keine feinen Lücken zwischen Modulen
        if (qr.isDark(y, x)) canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + .5, cell + .5), p);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.qr != qr;
}

/// Empfangene Serverdaten und der Code, über den die Rückmeldung an den Absender geht.
typedef Received = ({TvLink link, Map<String, Object?> data});

/// Fernseher/Empfänger: QR und Code zeigen, bis Daten ankommen. null = abgebrochen.
Future<Received?> receiveServer(BuildContext context) =>
    showDialog<Received>(context: context, builder: (_) => const _ReceiveDialog());

class _ReceiveDialog extends StatefulWidget {
  const _ReceiveDialog();
  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  late TvLink _link;
  StreamSubscription? _sub;
  Timer? _tick;
  late DateTime _until;

  @override
  void initState() {
    super.initState();
    _newCode();
  }

  void _newCode() {
    _sub?.cancel();
    _tick?.cancel();
    _link = TvLink.random();
    _until = DateTime.now().add(_validFor);
    _sub = _link.listen().listen((m) {
      if (m['k'] != 'server' || !mounted) return;
      _link.send({'k': 'status', 'state': 'received'}).catchError((_) {});
      Navigator.pop(context, (link: _link, data: m));
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (DateTime.now().isAfter(_until)) {
        _sub?.cancel();
        _tick?.cancel();
      }
    });
    setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = _until.difference(DateTime.now());
    final expired = left.isNegative;
    final wide = MediaQuery.sizeOf(context).width > 720;
    final accent = Theme.of(context).colorScheme.primary;
    final qr = Opacity(opacity: expired ? .15 : 1, child: QrView(_link.url, size: wide ? 260 : 220));
    final info = Column(
      crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(tr('Server empfangen'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -.5)),
        const SizedBox(height: 8),
        Text(
          tr('QR-Code mit dem Handy scannen, oder auf jedem Gerät weltweit diese Seite öffnen und den Code eingeben:'),
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: TextStyle(color: textDim, height: 1.4),
        ),
        const SizedBox(height: 14),
        Text(TvLink.site.replaceFirst('https://', '').replaceFirst(RegExp(r'/$'), ''),
            style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(color: surface2, borderRadius: BorderRadius.circular(12)),
          child: SelectableText(
            _link.pretty,
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
              fontFamily: 'monospace',
              decoration: expired ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (!expired) ...[
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text(tr('Warte auf Daten · gültig {0}', ['${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}']), style: TextStyle(color: textDim)),
          ] else
            Text(tr('Code abgelaufen'), style: TextStyle(color: textDim)),
        ]),
      ],
    );
    return Dialog(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            wide
                ? Row(children: [qr, const SizedBox(width: 32), Expanded(child: info)])
                : Column(children: [qr, const SizedBox(height: 22), info]),
            const SizedBox(height: 22),
            Row(children: [
              Icon(Icons.lock_rounded, size: 16, color: textDim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('Ende-zu-Ende verschlüsselt. Code nur an Personen geben, denen du vertraust.'),
                  style: TextStyle(color: textDim, fontSize: 12.5),
                ),
              ),
            ]),
            const SizedBox(height: 18),
            Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.end, children: [
              Pill(tr('Neuer Code'), icon: Icons.refresh_rounded, autofocus: expired, onTap: _newCode),
              Pill(tr('Schließen'), primary: !expired, autofocus: !expired, onTap: () => Navigator.pop(context)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Gespeicherten Server an ein anderes Gerät schicken (Code vom Fernseher eingeben).
Future<void> sendServer(BuildContext context, Source s) =>
    showDialog(context: context, builder: (_) => _SendDialog(s));

/// Nachricht mit den Zugangsdaten einer Quelle (gleiches Format wie die Webseite).
Map<String, Object?> serverMessage(Source s) => {
  'k': 'server',
  'type': s.type == SourceType.iptv ? 'm3u' : s.type.name,
  'name': s.name,
  'url': s.url,
  'user': s.user,
  'pass': s.pass,
  'mac': s.mac,
};

class _SendDialog extends StatefulWidget {
  final Source source;
  const _SendDialog(this.source);
  @override
  State<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends State<_SendDialog> {
  final _code = TextEditingController();
  StreamSubscription? _sub;
  Timer? _timeout;
  String? _status;
  bool _busy = false, _done = false;

  @override
  void dispose() {
    _sub?.cancel();
    _timeout?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final code = TvLink.fromText(_code.text);
    if (code == null) return setState(() => _status = tr('Der Code hat 10 Zeichen, z. B. K7M2Q-9XR4T.'));
    final link = TvLink(code);
    setState(() {
      _busy = true;
      _status = tr('Wird gesendet …');
    });
    // Erst zuhören, dann senden: keine Rückmeldung verpassen
    _sub = link.listen().listen((m) {
      // Reihenfolge beim Relay nicht garantiert: nach „fertig“ nichts mehr überschreiben
      if (m['k'] != 'status' || !mounted || _done) return;
      setState(() {
        switch (m['state']) {
          case 'received':
            _status = tr('Angekommen. Das Gerät verbindet sich …');
          case 'ok':
            _status = tr('Fertig: Das Gerät ist verbunden.');
            _done = true;
            _busy = false;
          default:
            _status = tr('Das Gerät meldet: {0}', ['${m['text'] ?? ''}']);
            _busy = false;
        }
      });
    });
    try {
      await link.send(serverMessage(widget.source));
      if (!mounted) return;
      setState(() => _status = tr('Gesendet. Warte auf das Gerät …'));
      _timeout = Timer(const Duration(seconds: 40), () {
        if (mounted && _busy) {
          setState(() {
            _busy = false;
            _status = tr('Keine Antwort. Ist der Code noch auf dem Gerät zu sehen?');
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = explain(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('An anderes Gerät senden')),
    content: SizedBox(
      width: 460,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          tr('Auf dem anderen Gerät unter „Server hinzufügen“ → „Per Code empfangen“ wählen und den angezeigten Code hier eingeben.'),
          style: TextStyle(color: textDim, height: 1.4),
        ),
        const SizedBox(height: 16),
        InputBox(
          controller: _code,
          autofocus: true,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 3),
          decoration: InputDecoration(labelText: tr('Code'), hintText: 'K7M2Q-9XR4T'),
          onSubmitted: (_) => _busy ? null : _send(),
        ),
        if (_status != null) ...[
          const SizedBox(height: 14),
          Row(children: [
            if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            if (_done) const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 20),
            if (_busy || _done) const SizedBox(width: 10),
            Expanded(child: Text(_status!)),
          ]),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.lock_rounded, size: 14, color: textDim),
          const SizedBox(width: 6),
          Expanded(child: Text(tr('Ende-zu-Ende verschlüsselt.'), style: TextStyle(color: textDim, fontSize: 12))),
        ]),
      ]),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(_done ? tr('Schließen') : tr('Abbrechen'))),
      if (!_done) FilledButton(onPressed: _busy ? null : _send, child: Text(tr('Senden'))),
    ],
  );
}
