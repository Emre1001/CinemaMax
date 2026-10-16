import 'dart:convert';

import 'package:cinemamax/models.dart';
import 'package:cinemamax/repo.dart';
import 'package:cinemamax/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simuliert ein Stalker-Portal, das nur unter /stalker_portal/server/load.php antwortet.
http.Response portal(http.Request r) {
  if (!r.url.path.endsWith('/stalker_portal/server/load.php')) return http.Response('not found', 404);
  final q = r.url.queryParameters;
  final authed = r.headers['Authorization'] == 'Bearer T1';
  if (!r.headers['Cookie']!.contains('mac=00%3A1A%3A79%3A12%3A34%3A56')) return http.Response('bad mac', 403);
  js(Object v) => http.Response(jsonEncode({'js': v}), 200);
  switch ((q['type'], q['action'])) {
    case ('stb', 'handshake'): return js({'token': 'T1'});
    case ('stb', 'get_profile'): return js({});
    case _ when !authed: return http.Response('Authorization failed.', 200);
    case ('itv', 'get_genres'): return js([{'id': '*', 'title': 'All'}, {'id': '7', 'title': 'Sport'}]);
    case ('itv', 'get_all_channels'):
      return js({'data': [{'id': '1', 'name': 'Sport 1', 'cmd': 'ffmpeg http://localhost/ch/1', 'tv_genre_id': '7', 'logo': '/misc/1.png'}]});
    case ('vod', 'get_categories'): return js([{'id': '*', 'title': 'Alle'}, {'id': '3', 'title': 'Action'}]);
    case ('series', 'get_categories'): return js([]);
    case ('vod', 'get_ordered_list'):
      return js({'total_items': '2', 'max_page_items': '14', 'data': [
        {'id': '10', 'name': 'Film A', 'cmd': 'movie10', 'screenshot_uri': 'http://img/a.jpg'},
        {'id': '11', 'name': 'Serie B', 'is_series': '1', 'cmd': 'x'},
      ]});
    case ('itv' || 'vod', 'create_link'):
      return js({'cmd': 'ffmpeg http://cdn/${q['cmd']}${q['series'] == null ? '' : '?ep=${q['series']}'}'});
  }
  return http.Response('?', 400);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await store.init();
  });

  test('Stalker: Login, Sender, Kategorien, Link auflösen', () async {
    final s = Source(
        id: 'st', name: 'P', type: SourceType.stalker, url: 'http://host:80/stalker_portal/c/', mac: '00:1A:79:12:34:56');
    await http.runWithClient(() async {
      final lib = await Repo.load(s, force: true);
      final ch = lib.of(Kind.live).single;
      expect(ch.group, 'Sport');
      expect(ch.logo, 'http://host/misc/1.png');
      expect(lib.groups[Kind.movie], ['Action']);

      final vod = await lib.lazy!(Kind.movie, 'Action');
      expect(vod.map((m) => '${m.kind.name}:${m.name}'), ['movie:Film A', 'series:Serie B']);

      expect(await Repo.stalkerResolve(s, ch.url!), 'http://cdn/ffmpeg http://localhost/ch/1');
      expect(await Repo.stalkerResolve(s, 'stalker:vod:season5#ep=3'), 'http://cdn/season5?ep=3');
    }, () => MockClient((r) async => portal(r)));
  });
}
