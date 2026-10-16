# CinemaMax

IPTV-Player für Android (Handy und Android TV), Linux und Windows. Eine App für freie IPTV-Listen, eigene M3U-Playlists, Xtream Codes und Stalker-Portale.

CinemaMax liefert **keine** Inhalte mit. Es spielt nur Listen und Zugänge ab, die du selbst einträgst. Nutze nur Quellen, zu deren Nutzung du berechtigt bist.

## Funktionen

- **Quellen:** freie Sender von [iptv-org](https://github.com/iptv-org/iptv) nach Land, eigene IPTV-Listen, M3U/M3U8, Xtream Codes (Live, Filme, Serien, Kontoinfo), Stalker/MAG-Portale
- **Live TV, Filme, Serien** mit Kategorien, Länder-Filter (`DE |`, `|TR|` …), Favoriten, Weiterschauen, Startseite mit Neuheiten
- **TV-Guide (XMLTV/EPG)**, „Jetzt läuft“ auf den Senderkacheln, Rückschau (Xtream Catch-up)
- **Player:** ExoPlayer auf Android (für IPTV angepasst), libmpv auf PC. Senderwechsel, Sendernummer per Zifferntasten, Tonspur, Untertitel (mpv), Bildformat, Tempo, Sleep-Timer, Bild-in-Bild, Live-Aufnahme
- **Downloads** von Filmen und Folgen zum Offline-Schauen
- **Android TV:** komplett mit der Fernbedienung bedienbar, eigene TV-Oberfläche
- **Sprachen:** Deutsch, Englisch, Türkisch (folgt der Systemsprache)
- **Einstellungen:** Akzentfarbe (auch Wunschfarbe), Kindersicherung mit PIN, Kategorien ausblenden, User-Agent, Puffer und vieles mehr

## Download

Fertige Builds (APK, .deb, .rpm, AppImage) gibt es unter [Releases](../../releases).

## Selbst bauen

Voraussetzung: [Flutter](https://docs.flutter.dev/get-started/install) (stable).

```bash
flutter pub get
flutter build apk --release        # Android
flutter build windows --release    # Windows (nur auf Windows)
```

Linux (Ubuntu/Debian):

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev rpm file
scripts/package_linux.sh           # baut .deb, .rpm und .AppImage nach dist/
```

Bei einem Tag `v*` baut [GitHub Actions](.github/workflows/build.yml) alles automatisch.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `lib/repo.dart` | Laden von M3U, Xtream und Stalker, Cache |
| `lib/m3u.dart` | M3U-Parser und Typ-Erkennung |
| `lib/epg.dart` | XMLTV-Programmführer |
| `lib/playback.dart` | Player-Schnittstelle (ExoPlayer / mpv) |
| `lib/downloads.dart` | Downloads und Aufnahmen |
| `lib/ui/` | Oberfläche |
| `packages/video_player_android` | `video_player_android` mit IPTV-Anpassungen (`IptvTuning.java`) |
| `tool/make_intro_sound.py` | erzeugt den Startton |

## Lizenz

[MIT](LICENSE). `packages/video_player_android` stammt vom Flutter-Team und steht unter BSD-3-Clause (siehe dortige `LICENSE`).
