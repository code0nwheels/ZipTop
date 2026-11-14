import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../disk_space.dart';
import '../models.dart';
import 'm3u8_parser.dart';
import 'mp4_join.dart';
import 'ts_join.dart';

/// Thrown inside a capture when its [CaptureToken] is cancelled.
class CaptureCancelled implements Exception {
  const CaptureCancelled([this.container]);

  /// The container written before the stop, when the capture got that far.
  final String? container;
}

/// Lets the owner stop a capture between, or during, its waits.
class CaptureToken {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const CaptureCancelled();
  }

  /// Waits [duration], or throws as soon as the capture is cancelled.
  Future<void> wait(Duration duration) async {
    check();
    await Future.any([Future<void>.delayed(duration), _cancelled.future]);
    check();
  }
}

/// One media playlist being followed.
class _Track {
  _Track(this.url);
  String url;
  int nextSequence = -1;
  String lastSignature = '';

  /// First pass: start near the live edge rather than replaying the whole
  /// server-side window.
  void startNearLiveEdge(HlsMediaPlaylist playlist) {
    if (nextSequence >= 0) return;
    final back = playlist.segments.length - 2;
    nextSequence = playlist.mediaSequence + (back < 0 ? 0 : back);
  }
}

/// What a stream URL resolves to.
class _Playlists {
  const _Playlists(this.videoUrl, this.videoText, this.audioUrl);
  final String videoUrl;
  final String videoText;
  final String? audioUrl;
}

class _Unreadable implements Exception {
  const _Unreadable(this.message);
  final String message;
}

/// Where captured bytes go.
abstract class CaptureSink {
  int get bytesWritten;
  Future<void> write(List<int> bytes);
  Future<void> flush();
  Future<void> close();

  /// Free space where the file lives, or null when it cannot be told.
  int? freeBytes();
}

class FileCaptureSink implements CaptureSink {
  FileCaptureSink._(this.file, this._raf);

  static Future<FileCaptureSink> open(File file) async {
    await file.parent.create(recursive: true);
    return FileCaptureSink._(file, await file.open(mode: FileMode.write));
  }

  final File file;
  final RandomAccessFile _raf;
  int _bytes = 0;
  bool _closed = false;

  @override
  int get bytesWritten => _bytes;

  @override
  Future<void> write(List<int> bytes) async {
    await _raf.writeFrom(bytes);
    _bytes += bytes.length;
  }

  @override
  Future<void> flush() async {
    if (!_closed) await _raf.flush();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
  }

  @override
  int? freeBytes() => freeDiskBytes(file.parent.path);
}

/// What a capture run produced. Bytes and gaps are reported either way.
sealed class CaptureOutcome {
  const CaptureOutcome(this.bytesWritten, this.gapCount, this.container);
  final int bytesWritten;
  final int gapCount;

  /// The container actually produced: `ts` or `mp4`.
  final String? container;
}

/// The capture ran to its deadline.
class CaptureFinished extends CaptureOutcome {
  const CaptureFinished(super.bytesWritten, super.gapCount, String super.container);
}

/// The capture stopped early. Whatever was written is still on disk.
class CaptureFailed extends CaptureOutcome {
  const CaptureFailed(
    this.failure,
    this.message,
    int bytesWritten,
    int gapCount, [
    String? container,
  ]) : super(bytesWritten, gapCount, container);
  final RecordingFailure failure;
  final String message;
}

class CaptureConfig {
  const CaptureConfig({
    required this.userAgent,
    required this.referer,
    required this.variantPreference,
    required this.minFreeBytes,
  });
  final String userAgent;
  final String referer;
  final VariantPreference variantPreference;
  final int minFreeBytes;
}

/// Records a live HLS stream by following its media playlist and appending
/// each new segment to a single file. Ported from the Android app.
///
/// The output is a plain concatenation, which is what makes it playable
/// without a muxer: a run of MPEG-TS segments is a valid TS file, and an
/// EXT-X-MAP init segment followed by fMP4 fragments is a valid fragmented
/// MP4. Neither carries a duration header, so seeking is approximate.
///
/// When the variant's audio is a rendition of its own (typical of 5.1
/// channels), that playlist is followed too and its segments are folded into
/// the same file: [TsAudioJoiner] for a transport stream, [Mp4AudioJoiner]
/// for fMP4.
abstract final class HlsCapture {
  /// A single segment larger than this is treated as a failure.
  static const maxSegmentBytes = 48 * 1024 * 1024;

  /// Give up on the stream after this long with no playlist.
  static const maxOutage = Duration(minutes: 5);

  /// Consecutive segment failures before assuming the URL's token rotated.
  static const segmentFailuresBeforeReresolve = 3;

  /// How many times to ask for a fresh stream URL before giving up.
  static const maxUrlReresolves = 3;
  static const progressEverySegments = 10;
  static const probeBytes = 8 * 1024;
  static const spaceCheckInterval = Duration(seconds: 30);
  static const ioTimeout = Duration(seconds: 15);

  /// A client for capture. Deliberately separate from the API client: auth
  /// and host failover must never be applied to CDN segment URLs.
  static HttpClient newClient() => HttpClient()
    ..connectionTimeout = ioTimeout
    ..idleTimeout = ioTimeout;

  /// [resolveUrl] fetches a fresh stream URL, used when the current one
  /// stops working (the backend hands out short-lived tokenised URLs).
  /// [onProgress] is called every few segments with (bytes, gaps).
  static Future<CaptureOutcome> run({
    required String initialUrl,
    required HttpClient client,
    required CaptureSink sink,
    required CaptureConfig config,
    required DateTime deadline,
    required DateTime hardCap,
    required Future<String?> Function() resolveUrl,
    required void Function(int bytes, int gaps) onProgress,
    required CaptureToken token,
    DateTime Function() clock = DateTime.now,
  }) async {
    var gapCount = 0;
    var container = 'ts';
    var wroteInit = false;
    var urlReresolves = 0;
    final keyCache = <String, Uint8List>{};
    var lastSpaceCheck = clock();
    var segmentsSinceProgress = 0;

    CaptureFailed fail(RecordingFailure failure, String message) =>
        CaptureFailed(failure, message, sink.bytesWritten, gapCount, container);

    try {
      // A direct MPEG-TS endpoint never closes its body, so the first read is
      // bounded: enough to see #EXTM3U and no more.
      final probe = await _probeHead(client, initialUrl, config);
      if (probe == null) return fail(RecordingFailure.network, 'Could not open the stream');
      if (!M3u8Parser.isPlaylist(probe)) {
        return await _direct(
          url: initialUrl,
          client: client,
          sink: sink,
          config: config,
          deadline: deadline,
          hardCap: hardCap,
          onProgress: onProgress,
          token: token,
          clock: clock,
        );
      }

      final _Playlists first;
      try {
        first = await _resolvePlaylists(client, initialUrl, config);
      } on _Unreadable catch (e) {
        return fail(RecordingFailure.network, e.message);
      }

      final video = _Track(first.videoUrl);
      // The variant's audio, when it is a rendition of its own rather than
      // muxed into the video segments.
      var audio = first.audioUrl == null ? null : _Track(first.audioUrl!);
      AudioJoiner? joiner;

      // After a fresh stream URL, which may be a master, before reading on.
      var streamUrl = initialUrl;
      var resolvePending = false;

      DateTime? outageStarted;
      var consecutiveSegmentFailures = 0;
      var backoff = const Duration(seconds: 1);
      String text = first.videoText;

      // The audio playlist as just read for its init segment, so following it
      // starts from the same window as the video.
      String? fetchedAudioText;

      Future<Uint8List> decrypt(Uint8List bytes, HlsSegment segment) =>
          _decrypt(bytes, segment, keyCache, client, config);

      /// Appends the audio rendition's new segments. Its failures are gaps;
      /// whether the stream is alive is the video's call.
      Future<CaptureFailed?> followAudio(_Track track) async {
        final audioText = fetchedAudioText ?? await _fetchText(client, track.url, config);
        fetchedAudioText = null;
        if (audioText == null) return null;
        final playlist = M3u8Parser.parseMedia(audioText, track.url);
        // Audio joins video of its own kind: TS into the transport stream,
        // fMP4 through the init segment merged before any fragment.
        final fmp4 = playlist.initSegmentUri != null;
        if (fmp4 != (container == 'mp4') || (fmp4 && joiner == null)) {
          audio = null;
          return null;
        }
        final j = joiner ??= TsAudioJoiner();
        track.startNearLiveEdge(playlist);
        if (track.nextSequence < playlist.mediaSequence) {
          gapCount++;
          track.nextSequence = playlist.mediaSequence;
        }
        for (final segment in playlist.segments) {
          token.check();
          if (segment.sequence < track.nextSequence) continue;
          if (!clock().isBefore(deadline)) break;
          final key = segment.key;
          if (key != null && !key.isClear && !key.isAes128) {
            return fail(
              RecordingFailure.unsupportedCrypto,
              'This stream uses ${key.method} encryption, which cannot be recorded',
            );
          }
          var bytes = await _fetchBytes(client, segment.uri, config);
          track.nextSequence = segment.sequence + 1;
          if (bytes == null) {
            gapCount++;
            continue;
          }
          if (key != null && !key.isClear) {
            try {
              bytes = await decrypt(bytes, segment);
            } catch (e) {
              return fail(RecordingFailure.unsupportedCrypto, 'Could not decrypt the stream: $e');
            }
          }
          final joined = j.audio(bytes);
          if (joined.isEmpty) continue;
          try {
            await sink.write(joined);
          } on FileSystemException catch (e) {
            return fail(RecordingFailure.diskFull, 'Could not write to storage: ${e.message}');
          }
        }
        return null;
      }

      /// The video's init segment with the audio rendition's track added, or
      /// null when the audio cannot be joined.
      Future<Uint8List?> withAudioTrack(Uint8List videoInit, _Track track) async {
        final audioText = await _fetchText(client, track.url, config);
        if (audioText == null) return null;
        fetchedAudioText = audioText;
        final audioInitUri = M3u8Parser.parseMedia(audioText, track.url).initSegmentUri;
        if (audioInitUri == null) return null;
        final audioInit = await _fetchBytes(client, audioInitUri, config);
        if (audioInit == null) return null;
        final joined = Mp4AudioJoiner.join(videoInit, audioInit);
        if (joined == null) return null;
        joiner = joined.$2;
        return joined.$1;
      }

      while (true) {
        token.check();
        final now = clock();
        if (!now.isBefore(deadline)) break;
        if (!now.isBefore(hardCap)) {
          return fail(RecordingFailure.timedOut, 'Stopped at the maximum recording length');
        }

        if (text.isEmpty) {
          String? refreshed;
          if (resolvePending) {
            try {
              final lists = await _resolvePlaylists(client, streamUrl, config);
              video
                ..url = lists.videoUrl
                ..nextSequence = -1
                ..lastSignature = '';
              audio = lists.audioUrl == null ? null : _Track(lists.audioUrl!);
              resolvePending = false;
              refreshed = lists.videoText;
            } on _Unreadable {
              refreshed = null;
            }
          } else {
            refreshed = await _fetchText(client, video.url, config);
          }
          if (refreshed == null) {
            outageStarted ??= now;
            if (now.difference(outageStarted) > maxOutage) {
              return fail(RecordingFailure.network, 'Lost the stream for too long');
            }
            await token.wait(backoff);
            backoff = backoff * 2 > const Duration(seconds: 15)
                ? const Duration(seconds: 15)
                : backoff * 2;
            continue;
          }
          text = refreshed;
        }

        if (outageStarted != null) {
          // Back after an outage; the live edge moved on without us.
          gapCount++;
          outageStarted = null;
          backoff = const Duration(seconds: 1);
        }

        final playlist = M3u8Parser.parseMedia(text, video.url);
        final signature =
            '${playlist.segments.isEmpty ? '' : playlist.segments.last.uri}:${playlist.mediaSequence}';
        final playlistChanged = signature != video.lastSignature;
        video.lastSignature = signature;

        // The fMP4 init segment goes in once, before any media fragment.
        final initUri = playlist.initSegmentUri;
        if (!wroteInit && initUri != null) {
          final init = await _fetchBytes(client, initUri, config);
          if (init != null) {
            var head = init;
            final audioTrack = audio;
            if (audioTrack != null) {
              final merged = await withAudioTrack(init, audioTrack);
              if (merged == null) {
                audio = null;
              } else {
                head = merged;
              }
            }
            await sink.write(head);
            wroteInit = true;
            container = 'mp4';
          }
        }

        // Audio first, so a TS's audio streams are known before the first
        // video PMT is written.
        final audioTrack = audio;
        if (audioTrack != null) {
          final failed = await followAudio(audioTrack);
          if (failed != null) return failed;
        }

        video.startNearLiveEdge(playlist);
        // The playlist rolled past us while we were busy or offline.
        if (video.nextSequence < playlist.mediaSequence) {
          gapCount++;
          video.nextSequence = playlist.mediaSequence;
        }

        var wroteAny = false;
        var restartPlaylist = false;
        for (final segment in playlist.segments) {
          token.check();
          if (segment.sequence < video.nextSequence) continue;
          if (!clock().isBefore(deadline)) break;

          final key = segment.key;
          if (key != null && !key.isClear && !key.isAes128) {
            return fail(
              RecordingFailure.unsupportedCrypto,
              'This stream uses ${key.method} encryption, which cannot be recorded',
            );
          }

          var bytes = await _fetchBytes(client, segment.uri, config);
          if (bytes == null) {
            consecutiveSegmentFailures++;
            if (consecutiveSegmentFailures >= segmentFailuresBeforeReresolve) {
              if (urlReresolves >= maxUrlReresolves) {
                return fail(RecordingFailure.network, 'The stream stopped responding');
              }
              urlReresolves++;
              consecutiveSegmentFailures = 0;
              gapCount++;
              final fresh = await resolveUrl();
              if (fresh == null || fresh.trim().isEmpty) {
                await token.wait(const Duration(seconds: 5));
              } else {
                streamUrl = fresh;
                resolvePending = true;
              }
              text = '';
              restartPlaylist = true;
              break;
            }
            // One missing segment is a gap, not the end of the recording.
            video.nextSequence = segment.sequence + 1;
            gapCount++;
            continue;
          }
          consecutiveSegmentFailures = 0;

          if (key != null && !key.isClear) {
            try {
              bytes = await decrypt(bytes, segment);
            } catch (e) {
              return fail(RecordingFailure.unsupportedCrypto, 'Could not decrypt the stream: $e');
            }
          }
          // List the joined audio in the video's PMTs.
          final j = joiner;
          if (j != null && j.hasAudio) bytes = j.video(bytes);

          // Only a whole, decrypted segment reaches the file: a failed
          // segment is a clean gap, never a torn fragment.
          try {
            await sink.write(bytes);
          } on FileSystemException catch (e) {
            return fail(RecordingFailure.diskFull, 'Could not write to storage: ${e.message}');
          }

          video.nextSequence = segment.sequence + 1;
          wroteAny = true;
          if (++segmentsSinceProgress >= progressEverySegments) {
            segmentsSinceProgress = 0;
            await sink.flush();
            onProgress(sink.bytesWritten, gapCount);
          }
        }

        // The URL was re-resolved mid-list; fetch again before judging.
        if (restartPlaylist) continue;

        final checkNow = clock();
        if (checkNow.difference(lastSpaceCheck) > spaceCheckInterval) {
          lastSpaceCheck = checkNow;
          final free = sink.freeBytes();
          if (free != null && free < config.minFreeBytes) {
            return fail(RecordingFailure.diskFull, 'Storage is full');
          }
        }

        if (playlist.hasEndList && clock().isBefore(deadline)) {
          // The source ended before our window did, usually a channel
          // restart. Ask for a fresh URL rather than declaring success.
          if (urlReresolves >= maxUrlReresolves) {
            return fail(RecordingFailure.network, 'The stream ended early');
          }
          urlReresolves++;
          gapCount++;
          await token.wait(const Duration(seconds: 5));
          final fresh = await resolveUrl();
          if (fresh != null && fresh.trim().isNotEmpty) {
            streamUrl = fresh;
            resolvePending = true;
          }
          text = '';
          continue;
        }

        // RFC 8216 6.3.4: one target duration after a change, half of one
        // when the playlist was the same as last time.
        final factor = playlistChanged || wroteAny ? 1000 : 500;
        final waitMs = (playlist.targetDurationSec * factor).round().clamp(1000, 10000);
        text = '';
        // Never sleep past the deadline.
        final left = deadline.difference(clock());
        if (left <= Duration.zero) break;
        final wait = Duration(milliseconds: waitMs);
        await token.wait(wait < left ? wait : left);
      }

      await sink.flush();
      onProgress(sink.bytesWritten, gapCount);
      return CaptureFinished(sink.bytesWritten, gapCount, container);
    } on CaptureCancelled {
      // Stopped deliberately. What is on disk stays; the caller labels it,
      // and names the file by what was written.
      try {
        await sink.flush();
      } catch (_) {}
      throw CaptureCancelled(container);
    } catch (e) {
      return fail(RecordingFailure.network, 'Recording failed: $e');
    }
  }

  /// The media playlists behind [url]: the video variant the quality setting
  /// picks and, when that variant's audio is a separate rendition, the audio
  /// playlist. A media playlist URL is its own video.
  static Future<_Playlists> _resolvePlaylists(
    HttpClient client,
    String url,
    CaptureConfig config,
  ) async {
    final text = await _fetchText(client, url, config);
    if (text == null) throw const _Unreadable('Could not read the stream playlist');
    if (!M3u8Parser.isMaster(text)) return _Playlists(url, text, null);
    final chosen = pickVariant(M3u8Parser.parseMaster(text, url), config.variantPreference);
    if (chosen == null) throw const _Unreadable('No playable variant in the stream');
    final variantText = await _fetchText(client, chosen.uri, config);
    if (variantText == null) throw const _Unreadable('Could not open the stream variant');
    final audioUri = M3u8Parser.separateAudioUri(chosen, M3u8Parser.parseRenditions(text, url));
    return _Playlists(chosen.uri, variantText, audioUri == chosen.uri ? null : audioUri);
  }

  static HlsVariant? pickVariant(List<HlsVariant> variants, VariantPreference preference) {
    if (variants.isEmpty) return null;
    HlsVariant best(Iterable<HlsVariant> from, {required bool highest}) => from.reduce(
          (a, b) => (highest ? b.bandwidth > a.bandwidth : b.bandwidth < a.bandwidth) ? b : a,
        );
    switch (preference) {
      case VariantPreference.lowest:
        return best(variants, highest: false);
      case VariantPreference.highest:
        return best(variants, highest: true);
      case VariantPreference.atMost720p:
        final capped = variants.where((v) => (v.height ?? 0) <= 720).toList();
        return best(capped.isEmpty ? variants : capped, highest: true);
    }
  }

  /// Fallback for endpoints that serve one continuous MPEG-TS body rather
  /// than a playlist.
  static Future<CaptureOutcome> _direct({
    required String url,
    required HttpClient client,
    required CaptureSink sink,
    required CaptureConfig config,
    required DateTime deadline,
    required DateTime hardCap,
    required void Function(int bytes, int gaps) onProgress,
    required CaptureToken token,
    required DateTime Function() clock,
  }) async {
    var lastSpaceCheck = clock();
    var lastProgress = lastSpaceCheck;
    try {
      final response = await _open(client, url, config);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>().catchError((_) {});
        return CaptureFailed(
          RecordingFailure.network,
          'The stream returned ${response.statusCode}',
          sink.bytesWritten,
          0,
          'ts',
        );
      }
      await for (final chunk in response.timeout(ioTimeout)) {
        token.check();
        await sink.write(chunk);
        final now = clock();
        if (!now.isBefore(deadline)) break;
        if (!now.isBefore(hardCap)) {
          return CaptureFailed(
            RecordingFailure.timedOut,
            'Stopped at the maximum recording length',
            sink.bytesWritten,
            0,
            'ts',
          );
        }
        if (now.difference(lastProgress) > const Duration(seconds: 10)) {
          lastProgress = now;
          await sink.flush();
          onProgress(sink.bytesWritten, 0);
        }
        if (now.difference(lastSpaceCheck) > spaceCheckInterval) {
          lastSpaceCheck = now;
          final free = sink.freeBytes();
          if (free != null && free < config.minFreeBytes) {
            return CaptureFailed(
              RecordingFailure.diskFull,
              'Storage is full',
              sink.bytesWritten,
              0,
              'ts',
            );
          }
        }
      }
      await sink.flush();
      onProgress(sink.bytesWritten, 0);
      if (clock().isBefore(deadline)) {
        return CaptureFailed(
          RecordingFailure.network,
          'The stream ended early',
          sink.bytesWritten,
          1,
          'ts',
        );
      }
      return CaptureFinished(sink.bytesWritten, 0, 'ts');
    } on CaptureCancelled {
      try {
        await sink.flush();
      } catch (_) {}
      rethrow;
    } catch (e) {
      return CaptureFailed(
        RecordingFailure.network,
        'Recording failed: $e',
        sink.bytesWritten,
        0,
        'ts',
      );
    }
  }

  static Future<Uint8List> _decrypt(
    Uint8List data,
    HlsSegment segment,
    Map<String, Uint8List> keyCache,
    HttpClient client,
    CaptureConfig config,
  ) async {
    final key = segment.key!;
    final keyUri = key.uri;
    if (keyUri == null) throw StateError('encrypted segment with no key URI');
    var keyBytes = keyCache[keyUri];
    if (keyBytes == null) {
      keyBytes = await _fetchBytes(client, keyUri, config);
      if (keyBytes == null) throw StateError('could not fetch the decryption key');
      keyCache[keyUri] = keyBytes;
    }
    return decryptAes128(data, keyBytes, key.iv ?? sequenceIv(segment.sequence));
  }

  /// HLS defaults the IV to the segment's media sequence number, big-endian,
  /// when the playlist does not carry one.
  static Uint8List sequenceIv(int sequence) {
    final iv = Uint8List(16);
    var value = sequence;
    for (var i = 15; i >= 8; i--) {
      iv[i] = value & 0xFF;
      value >>= 8;
    }
    return iv;
  }

  /// AES-128-CBC with PKCS7 padding; each segment is padded on its own.
  static Uint8List decryptAes128(Uint8List data, Uint8List key, Uint8List iv) {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(
        false,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
          ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
          null,
        ),
      );
    return cipher.process(data);
  }

  static Future<HttpClientResponse> _open(
    HttpClient client,
    String url,
    CaptureConfig config,
  ) async {
    final request = await client.getUrl(Uri.parse(url)).timeout(ioTimeout);
    request.headers.set(HttpHeaders.userAgentHeader, config.userAgent);
    request.headers.set(HttpHeaders.refererHeader, config.referer);
    return request.close().timeout(ioTimeout);
  }

  static bool _ok(HttpClientResponse response) =>
      response.statusCode >= 200 && response.statusCode < 300;

  /// Reads at most [probeBytes], so a playlist can be told from an endless
  /// transport stream without committing to reading it.
  static Future<String?> _probeHead(HttpClient client, String url, CaptureConfig config) async {
    try {
      final response = await _open(client, url, config);
      if (!_ok(response)) {
        await response.drain<void>().catchError((_) {});
        return null;
      }
      final head = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(ioTimeout)) {
        head.add(chunk);
        if (head.length >= probeBytes) break;
      }
      final bytes = head.takeBytes();
      return utf8.decode(
        bytes.length > probeBytes ? bytes.sublist(0, probeBytes) : bytes,
        allowMalformed: true,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _fetchText(HttpClient client, String url, CaptureConfig config) async {
    final bytes = await _fetchBytes(client, url, config);
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  /// A whole resource (segment, init segment, key, playlist), refusing
  /// anything implausibly large. Null on any failure.
  static Future<Uint8List?> _fetchBytes(
    HttpClient client,
    String url,
    CaptureConfig config,
  ) async {
    try {
      final response = await _open(client, url, config);
      if (!_ok(response) || response.contentLength > maxSegmentBytes) {
        await response.drain<void>().catchError((_) {});
        return null;
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(ioTimeout)) {
        out.add(chunk);
        if (out.length > maxSegmentBytes) return null;
      }
      return out.takeBytes();
    } catch (_) {
      return null;
    }
  }
}
