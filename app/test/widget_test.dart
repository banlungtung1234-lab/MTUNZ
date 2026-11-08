import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/main.dart';

void main() {
  testWidgets('MTUNZ launches the native dashboard', (tester) async {
    await tester.pumpWidget(const MtunzApp());
    expect(find.text('MTUNZ'), findsOneWidget);
    expect(find.text('Kết nối mọi thiết bị.'), findsOneWidget);
  });
}
