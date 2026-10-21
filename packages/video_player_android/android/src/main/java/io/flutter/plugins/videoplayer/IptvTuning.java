package io.flutter.plugins.videoplayer;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.util.UnstableApi;
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
    DefaultRenderersFactory renderers =
        new DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON);
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
   * Automatische Auswahl der besten Spur, die der Decoder schafft, unabhängig von der
   * Bildschirmgröße (Handy mit 1080p-Display bekommt trotzdem 4K). Spuren über der Decoder-Angabe
   * nur, wenn nichts anderes passt; „Daten sparen“ begrenzt über das Qualitäts-Menü.
   */
  @NonNull
  public static DefaultTrackSelector trackSelector(@NonNull Context context) {
    DefaultTrackSelector selector = new DefaultTrackSelector(context);
    selector.setParameters(
        selector
            .buildUponParameters()
            .clearViewportSizeConstraints()
            .setExceedVideoConstraintsIfNecessary(true)
            .setExceedRendererCapabilitiesIfNecessary(true)
            .setAllowVideoMixedMimeTypeAdaptiveness(true)
            .setAllowVideoNonSeamlessAdaptiveness(true));
    return selector;
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
