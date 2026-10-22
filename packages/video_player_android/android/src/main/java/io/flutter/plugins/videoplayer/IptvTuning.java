package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.graphics.Point;
import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.audio.AudioCapabilities;
import androidx.media3.common.util.Util;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector;
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter;
import androidx.media3.extractor.DefaultExtractorsFactory;
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory;

/**
 * CinemaMax: ExoPlayer-Einstellungen für IPTV.
 *
 * <p>Viele TV-Boxen scheitern am Hardware-Decoder (z. B. Interlaced-Sender), IPTV-Server sind langsam und
 * MPEG-TS-Streams beginnen oft nicht mit einem Keyframe. Ohne diese Anpassungen bleibt das Bild schwarz.
 */
@OptIn(markerClass = UnstableApi.class)
public final class IptvTuning {
  private IptvTuning() {}

  /** Player mit Software-Decoder als Rückfall und schnellem Start-Puffer. */
  @NonNull
  public static ExoPlayer.Builder builder(@NonNull Context context) {
    // FFmpeg-Tondecoder (Einstellung „ffmpegAudio“): on = nur wenn das Gerät das Format nicht kann
    String ffmpeg = setting(context, "ffmpegAudio", "on");
    int extensions =
        "off".equals(ffmpeg)
            ? DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF
            : "prefer".equals(ffmpeg)
                ? DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
                : DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON;
    DefaultRenderersFactory renderers =
        new DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)
            .setExtensionRendererMode(extensions);
    DefaultLoadControl loadControl =
        new DefaultLoadControl.Builder()
            // min 15 s, max 50 s puffern; nach 1,5 s starten, nach Abriss 3 s
            .setBufferDurationsMs(15_000, 50_000, 1_500, 3_000)
            // Puffer liegt im Java-Heap: ohne Grenze wächst er bei 4K (40 Mbit/s) auf ~130 MB und
            // sprengt den Heap von TV-Geräten (192 MB) – Absturz. Höchstens ein Viertel des Heaps.
            .setTargetBufferBytes(bufferBytes(Runtime.getRuntime().maxMemory()))
            .setPrioritizeTimeOverSizeThresholds(false)
            .build();
    // Startschätzung 10 Mbit/s statt ~1: HLS beginnt in 1080p statt 360p/720p und schaltet schneller auf 4K
    DefaultBandwidthMeter bandwidth =
        new DefaultBandwidthMeter.Builder(context).setInitialBitrateEstimate(10_000_000).build();
    return new ExoPlayer.Builder(context, renderers)
        .setLoadControl(loadControl)
        .setBandwidthMeter(bandwidth);
  }

  /** Puffergröße in Bytes: ein Viertel des Heaps, mindestens 16 MB, höchstens 100 MB. */
  static int bufferBytes(long maxHeap) {
    return (int) Math.max(16L << 20, Math.min(100L << 20, maxHeap / 4));
  }

  /**
   * Automatische Auswahl der besten Spur, die der Decoder schafft, höchstens bis zur Einstellung
   * „Bildschirmauflösung“ (siehe {@link #maxHeight}). Spuren über Grenze oder Decoder-Angabe nur,
   * wenn nichts anderes passt (dann die kleinste).
   */
  @NonNull
  public static DefaultTrackSelector trackSelector(@NonNull Context context) {
    DefaultTrackSelector selector = new DefaultTrackSelector(context);
    DefaultTrackSelector.Parameters.Builder params =
        selector
            .buildUponParameters()
            .clearViewportSizeConstraints()
            .setExceedVideoConstraintsIfNecessary(true)
            .setExceedRendererCapabilitiesIfNecessary(true)
            .setAllowVideoMixedMimeTypeAdaptiveness(true)
            .setAllowVideoNonSeamlessAdaptiveness(true);
    int max = maxHeight(context);
    // Wie in Dart (Engine.fits): 1/16 Spielraum (1920×1088 = 1080p), Breite wie bei 16:9 (3840×1600 = 4K)
    if (max > 0) params.setMaxVideoSize(max * 17 / 9, max * 17 / 16);
    selector.setParameters(params);
    return selector;
  }

  /**
   * Höchste Bildhöhe aus Flutters Einstellung „maxRes“: fehlt/-1 = Bildschirm (wie bei 16:9 gerechnet),
   * 0 = keine Grenze. Spart Daten und Decoder-Leistung (4K auf einem 1080p-Gerät).
   */
  static int maxHeight(@NonNull Context context) {
    long v = setting(context, "maxRes", -1L);
    if (v >= 0) return (int) v;
    int[] s = displaySize(context);
    int w = Math.max(s[0], s[1]), h = Math.min(s[0], s[1]);
    return Math.max(h, w * 9 / 16);
  }

  /** Einstellung aus Flutters SharedPreferences (Schlüssel mit „flutter.“), [def] bei fehlendem/anderem Typ. */
  @SuppressWarnings("unchecked")
  static <T> T setting(@NonNull Context context, @NonNull String key, @NonNull T def) {
    Object v = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getAll().get("flutter." + key);
    return def.getClass().isInstance(v) ? (T) v : def;
  }

  /**
   * Tonformate, die das Gerät per HDMI an Fernseher/Anlage durchreicht (kein Decoder nötig), als MIME-Typen.
   */
  @NonNull
  public static java.util.List<String> passthrough(@NonNull Context context) {
    AudioCapabilities caps = AudioCapabilities.getCapabilities(context, AudioAttributes.DEFAULT, null);
    java.util.List<String> out = new java.util.ArrayList<>();
    if (caps.supportsEncoding(C.ENCODING_AC3)) out.add(MimeTypes.AUDIO_AC3);
    if (caps.supportsEncoding(C.ENCODING_E_AC3)) out.add(MimeTypes.AUDIO_E_AC3);
    if (caps.supportsEncoding(C.ENCODING_DTS)) out.add(MimeTypes.AUDIO_DTS);
    if (caps.supportsEncoding(C.ENCODING_DOLBY_TRUEHD)) out.add(MimeTypes.AUDIO_TRUEHD);
    return out;
  }

  /** Echte Bildschirmauflösung: Fernseher melden den 4K-Modus, auch wenn die Oberfläche in 1080p läuft. */
  @NonNull
  public static int[] displaySize(@NonNull Context context) {
    Point p = Util.getCurrentDisplayModeSize(context);
    return new int[] {p.x, p.y};
  }

  /** Langsame IPTV-Server: längere Timeouts als die 8 s von ExoPlayer. */
  @NonNull
  public static DefaultHttpDataSource.Factory http(@NonNull DefaultHttpDataSource.Factory f) {
    return f.setConnectTimeoutMs(20_000).setReadTimeoutMs(25_000).setKeepPostFor302Redirects(true);
  }

  /** MPEG-TS: Streams ohne IDR-Start und mit fehlerhaften Zeitstempeln trotzdem abspielen. */
  @NonNull
  public static DefaultExtractorsFactory extractors() {
    // Ohne FLAG_DETECT_ACCESS_UNITS: IPTV-Streams haben Access-Unit-Delimiter (ffmpeg setzt sie immer),
    // mit dem Flag teilt ExoPlayer jedes Bild doppelt und zeigt nur ein Standbild, während der Ton läuft.
    return new DefaultExtractorsFactory()
        .setTsExtractorFlags(DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES)
        .setConstantBitrateSeekingEnabled(true);
  }
}
