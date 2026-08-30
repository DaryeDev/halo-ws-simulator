import 'package:flutter_test/flutter_test.dart';

import 'package:halo_demo_app/main.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const HaloDemoApp());
    expect(find.text('Halo Demo'), findsOneWidget);
  });
}
