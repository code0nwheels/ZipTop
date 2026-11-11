import 'dart:convert';
import 'dart:typed_data';

/// The Cast v2 namespaces ZipTop speaks.
abstract final class CastNamespace {
  static const connection = 'urn:x-cast:com.google.cast.tp.connection';
  static const heartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const receiver = 'urn:x-cast:com.google.cast.receiver';
  static const media = 'urn:x-cast:com.google.cast.media';
}

/// One Cast v2 `CastMessage` with a UTF-8 (JSON) payload.
///
/// On the wire it is a protobuf (cast_channel.proto) behind a 4-byte
/// big-endian length. Only six fields are ever used, so it is encoded here
/// by hand rather than through generated code:
///
///   1 protocol_version  enum    always 0 (CASTV2_1_0)
///   2 source_id         string
///   3 destination_id    string
///   4 namespace         string
///   5 payload_type      enum    0 (STRING)
///   6 payload_utf8      string
class CastMessage {
  const CastMessage({
    required this.source,
    required this.destination,
    required this.namespace,
    required this.payload,
  });

  CastMessage.json({
    required this.source,
    required this.destination,
    required this.namespace,
    required Map<String, Object?> data,
  }) : payload = jsonEncode(data);

  final String source;
  final String destination;
  final String namespace;
  final String payload;

  /// The payload as a JSON object, or null when it is not one.
  Map<String, Object?>? get data {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// The payload's `type`, e.g. `PING` or `MEDIA_STATUS`.
  String? get type => data?['type'] as String?;

  /// The protobuf bytes, without the length prefix.
  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    void varint(int value) {
      var v = value;
      while (v >= 0x80) {
        out.addByte((v & 0x7f) | 0x80);
        v >>= 7;
      }
      out.addByte(v);
    }

    void string(int field, String value) {
      final bytes = utf8.encode(value);
      varint(field << 3 | 2);
      varint(bytes.length);
      out.add(bytes);
    }

    varint(1 << 3);
    varint(0);
    string(2, source);
    string(3, destination);
    string(4, namespace);
    varint(5 << 3);
    varint(0);
    string(6, payload);
    return out.takeBytes();
  }

  /// The message length-prefixed, ready to write to the socket.
  Uint8List frame() {
    final body = encode();
    final framed = Uint8List(4 + body.length);
    ByteData.sublistView(framed).setUint32(0, body.length);
    framed.setRange(4, framed.length, body);
    return framed;
  }

  /// Reads protobuf [bytes]. Binary payloads (only used for device auth,
  /// which ZipTop doesn't do) come back as an empty payload.
  static CastMessage decode(Uint8List bytes) {
    var i = 0;
    int varint() {
      var result = 0;
      var shift = 0;
      while (true) {
        if (i >= bytes.length) throw const FormatException('Truncated varint');
        final b = bytes[i++];
        result |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
        if (shift > 63) throw const FormatException('Varint too long');
      }
    }

    var source = '';
    var destination = '';
    var namespace = '';
    var payload = '';
    while (i < bytes.length) {
      final key = varint();
      final field = key >> 3;
      switch (key & 7) {
        case 0:
          varint();
        case 2:
          final length = varint();
          if (i + length > bytes.length) throw const FormatException('Truncated field');
          final value = Uint8List.sublistView(bytes, i, i + length);
          i += length;
          switch (field) {
            case 2:
              source = utf8.decode(value, allowMalformed: true);
            case 3:
              destination = utf8.decode(value, allowMalformed: true);
            case 4:
              namespace = utf8.decode(value, allowMalformed: true);
            case 6:
              payload = utf8.decode(value, allowMalformed: true);
          }
        case 1:
          i += 8;
        case 5:
          i += 4;
        default:
          throw FormatException('Unsupported wire type in field $field');
      }
    }
    return CastMessage(
      source: source,
      destination: destination,
      namespace: namespace,
      payload: payload,
    );
  }

  @override
  String toString() => 'CastMessage($source → $destination, $namespace, $payload)';
}

/// Splits the socket's byte stream into messages: each is a 4-byte
/// big-endian length, then that many protobuf bytes. Chunks can end anywhere.
class CastFrameReader {
  /// Larger frames are not Cast messages; the connection is broken.
  static const maxFrame = 64 * 1024;

  final _pending = BytesBuilder(copy: true);

  /// Adds a chunk and returns the messages it completed.
  List<CastMessage> add(List<int> chunk) {
    _pending.add(chunk);
    final messages = <CastMessage>[];
    final bytes = _pending.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= 4) {
      final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
      if (length > maxFrame) throw FormatException('Cast frame of $length bytes');
      if (bytes.length - offset - 4 < length) break;
      messages.add(CastMessage.decode(Uint8List.sublistView(bytes, offset + 4, offset + 4 + length)));
      offset += 4 + length;
    }
    if (offset < bytes.length) _pending.add(Uint8List.sublistView(bytes, offset));
    return messages;
  }
}
