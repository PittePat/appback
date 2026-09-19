// Basic smoke test for AppBack.

import 'package:flutter_test/flutter_test.dart';

import 'package:appback/main.dart';

void main() {
  testWidgets('App renders the home screen shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // App bar title and the empty-state connect button should be present.
    expect(find.text('AppBack'), findsOneWidget);
    expect(find.text('Connect & load apps'), findsOneWidget);
    expect(find.text('Search packages'), findsOneWidget);
  });
}
