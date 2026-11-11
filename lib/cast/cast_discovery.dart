import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import 'cast_client.dart';

/// Finds Cast devices on the local network over mDNS (`_googlecast._tcp`).
class CastDiscovery {
  static const service = '_googlecast._tcp.local';

  /// Asks the network for Cast devices and returns those that answer within
  /// [timeout], sorted by name. Speaker groups are included; they play the
  /// sound only.
  Future<List<CastDevice>> scan({Duration timeout = const Duration(seconds: 3)}) async {
    final client = MDnsClient(rawDatagramSocketFactory: _bind);
    // Windows refuses to join the mDNS group on its loopback interface,
    // which multicast_dns would otherwise include.
    await client.start(
      interfacesFactory: (type) async => [
        for (final i in await NetworkInterface.list(type: type))
          if (i.addresses.isNotEmpty &&
              !i.addresses.first.isLoopback &&
              !i.addresses.first.isLinkLocal)
            i,
      ],
    );
    try {
      final found = <String, CastDevice>{};
      final lookups = <Future<void>>[];
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(service),
        timeout: timeout,
      )) {
        lookups.add(_resolve(client, ptr.domainName).then((device) {
          if (device != null) found[device.id] = device;
        }));
      }
      await Future.wait(lookups);
      return found.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } finally {
      client.stop();
    }
  }

  /// The device behind one service instance. Cast devices send the SRV, TXT
  /// and address records along with the pointer, so these usually come from
  /// the client's cache at once.
  Future<CastDevice?> _resolve(MDnsClient client, String instance) async {
    const wait = Duration(seconds: 2);
    try {
      final txt = await _first(client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(instance),
        timeout: wait,
      ));
      final srv = await _first(client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(instance),
        timeout: wait,
      ));
      if (srv == null) return null;
      final ip = await _first(client.lookup<IPAddressResourceRecord>(
        ResourceRecordQuery.addressIPv4(srv.target),
        timeout: wait,
      ));
      final fields = parseCastTxt(txt?.text ?? '');
      return CastDevice(
        id: fields['id'] ?? instance,
        name: fields['fn'] ?? instance.split('._googlecast').first,
        model: fields['md'],
        // The address when it came back, else the name for the system's own
        // mDNS resolver to try.
        host: ip?.address.address ?? srv.target,
        port: srv.port,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<T?> _first<T>(Stream<T> records) =>
      records.cast<T?>().firstWhere((_) => true, orElse: () => null);

  /// multicast_dns asks for SO_REUSEPORT, which Windows doesn't have.
  static Future<RawDatagramSocket> _bind(
    dynamic host,
    int port, {
    bool reuseAddress = true,
    bool reusePort = false,
    int ttl = 1,
  }) =>
      RawDatagramSocket.bind(
        host,
        port,
        reuseAddress: reuseAddress,
        reusePort: reusePort && !Platform.isWindows,
        ttl: ttl,
      );
}

/// A Cast TXT record (`id=…`, `fn=Living Room TV`, `md=Chromecast`, one per
/// line as multicast_dns gives them) as a map.
Map<String, String> parseCastTxt(String text) {
  final fields = <String, String>{};
  for (final line in text.split('\n')) {
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    fields[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return fields;
}
