import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/services/network_interfaces.dart';

void main() {
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
