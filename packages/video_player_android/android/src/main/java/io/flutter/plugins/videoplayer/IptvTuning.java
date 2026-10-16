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
            .build();
    return new ExoPlayer.Builder(context, renderers).setLoadControl(loadControl);
  }

  /**
   * 4K: Standardmäßig wählt ExoPlayer höchstens die Bildschirmauflösung (Handy/TV-Box meist 1080p) und
   * verwirft Spuren, die laut Decoder-Angabe zu groß sind. Viele Geräte spielen 4K trotzdem flüssig.
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
    return new DefaultExtractorsFactory()
        .setTsExtractorFlags(
            DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES
                | DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS)
        .setConstantBitrateSeekingEnabled(true);
  }
}
