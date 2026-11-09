import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtunz/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('MTUNZ launches the localized dashboard', (tester) async {
    await tester.pumpWidget(const MtunzApp());
    await tester.pumpAndSettle();

    expect(find.text('MTUNZ'), findsWidgets);
    expect(find.text('Kết nối mọi thiết bị.'), findsOneWidget);
  });

  testWidgets('File transfer page is available and translated', (tester) async {
    await tester.pumpWidget(const MtunzApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Tệp tin').last);
    await tester.pumpAndSettle();

    expect(find.text('Truyền tệp'), findsOneWidget);
    expect(find.text('GỬI TỆP QUA WEBRTC'), findsOneWidget);
    expect(find.textContaining('100 MB'), findsOneWidget);
  });

  testWidgets('Settings includes wired network setup guidance', (tester) async {
    await tester.pumpWidget(const MtunzApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cài đặt').last);
    await tester.pumpAndSettle();

    expect(find.text('WI-FI / ETHERNET / USB'), findsOneWidget);
    if (Platform.isWindows) {
      expect(find.text('Quét adapter mạng'), findsOneWidget);
    } else {
      expect(find.textContaining('Trên Windows, quét adapter'), findsOneWidget);
    }
  });

  testWidgets('Language can be changed immediately and is remembered', (tester) async {
    await tester.pumpWidget(const MtunzApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cài đặt').last);
    await tester.pumpAndSettle();

    final languagePicker = find.byType(DropdownButtonFormField<String>);
    expect(languagePicker, findsOneWidget);
    await tester.tap(languagePicker);
    await tester.pumpAndSettle();

    await tester.tap(find.text('🇺🇸  English').last);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsWidgets);
    expect(find.text('🇺🇸  English'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MtunzApp());
    await tester.pumpAndSettle();

    expect(find.text('Connect every device.'), findsOneWidget);
    expect(find.text('Kết nối mọi thiết bị.'), findsNothing);
  });
}
