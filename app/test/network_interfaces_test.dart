import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/services/network_interfaces.dart';

void main() {
  test('recognizes loopback and current device addresses', () {
    const endpoints = <NetworkEndpoint>[
      NetworkEndpoint(
        interfaceName: 'Wi-Fi',
        address: '192.168.1.20',
        kind: NetworkLinkKind.wifi,
      ),
    ];

    expect(NetworkInterfaceDiscovery.isThisDeviceAddress('127.0.0.1', endpoints), isTrue);
    expect(NetworkInterfaceDiscovery.isThisDeviceAddress('localhost', endpoints), isTrue);
    expect(NetworkInterfaceDiscovery.isThisDeviceAddress('192.168.1.20', endpoints), isTrue);
    expect(NetworkInterfaceDiscovery.isThisDeviceAddress('192.168.1.21', endpoints), isFalse);
  });

  test('recognizes VPN overlay adapters', () {
    expect(NetworkInterfaceDiscovery.classify('Tailscale'), NetworkLinkKind.vpn);
    expect(NetworkInterfaceDiscovery.classify('ZeroTier One'), NetworkLinkKind.vpn);
    expect(NetworkInterfaceDiscovery.classify('wg0'), NetworkLinkKind.vpn);
    expect(NetworkInterfaceDiscovery.classify('tun0'), NetworkLinkKind.vpn);
    expect(NetworkInterfaceDiscovery.classify('tap-windows'), NetworkLinkKind.vpn);
  });

  test('recognizes Wi-Fi, Ethernet and USB tether interfaces', () {
    expect(NetworkInterfaceDiscovery.classify('Wi-Fi'), NetworkLinkKind.wifi);
    expect(NetworkInterfaceDiscovery.classify('wlan0'), NetworkLinkKind.wifi);
    expect(NetworkInterfaceDiscovery.classify('Ethernet'), NetworkLinkKind.wired);
    expect(NetworkInterfaceDiscovery.classify('eth0'), NetworkLinkKind.wired);
    expect(NetworkInterfaceDiscovery.classify('RNDIS'), NetworkLinkKind.wired);
    expect(NetworkInterfaceDiscovery.classify('USB Ethernet'), NetworkLinkKind.wired);
    expect(NetworkInterfaceDiscovery.classify('rmnet_data0'), NetworkLinkKind.other);
  });
}
