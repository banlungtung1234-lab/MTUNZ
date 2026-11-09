import 'dart:io';

enum NetworkLinkKind { wifi, wired, other }

class NetworkEndpoint {
  const NetworkEndpoint({
    required this.interfaceName,
    required this.address,
    required this.kind,
  });

  final String interfaceName;
  final String address;
  final NetworkLinkKind kind;
}

class NetworkInterfaceDiscovery {
  static NetworkLinkKind classify(String interfaceName) {
    final name = interfaceName.toLowerCase();
    if (name.contains('wifi') ||
        name.contains('wi-fi') ||
        name.contains('wireless') ||
        name.contains('wlan') ||
        name.startsWith('wl')) {
      return NetworkLinkKind.wifi;
    }
    if (name.contains('ethernet') ||
        name.contains('rndis') ||
        name.contains('usb') ||
        name.contains('veth') ||
        name.contains('enx') ||
        name.contains('eth') ||
        name.startsWith('en')) {
      return NetworkLinkKind.wired;
    }
    return NetworkLinkKind.other;
  }

  static bool isThisDeviceAddress(
    String host,
    Iterable<NetworkEndpoint> endpoints,
  ) {
    final normalized = host.trim().toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    final parsed = InternetAddress.tryParse(normalized);
    if (parsed != null && parsed.isLoopback) return true;
    return endpoints.any((endpoint) => endpoint.address == normalized);
  }

  static Future<List<NetworkEndpoint>> discover() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    final endpoints = <NetworkEndpoint>[];
    final seen = <String>{};
    for (final interface in interfaces) {
      final kind = classify(interface.name);
      for (final address in interface.addresses) {
        final ip = address.address;
        // Ignore loopback, APIPA/link-local, unspecified and multicast ranges.
        if (ip.startsWith('127.') ||
            ip.startsWith('169.254.') ||
            ip.startsWith('0.') ||
            ip.startsWith('224.') ||
            ip == '255.255.255.255' ||
            !seen.add(ip)) {
          continue;
        }
        endpoints.add(NetworkEndpoint(
          interfaceName: interface.name,
          address: ip,
          kind: kind,
        ));
      }
    }
    endpoints.sort((a, b) {
      int rank(NetworkLinkKind kind) {
        switch (kind) {
          case NetworkLinkKind.wired:
            return 0;
          case NetworkLinkKind.wifi:
            return 1;
          case NetworkLinkKind.other:
            return 2;
        }
      }
      final byKind = rank(a.kind).compareTo(rank(b.kind));
      if (byKind != 0) return byKind;
      return a.interfaceName.toLowerCase().compareTo(b.interfaceName.toLowerCase());
    });
    return endpoints;
  }
}
