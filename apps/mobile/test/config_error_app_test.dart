import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';

void main() {
  testWidgets('shows the relay problem instead of throwing before runApp', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ConfigErrorApp(
        message: 'The relay address must start with https://.',
      ),
    );

    expect(find.textContaining('cannot start'), findsOneWidget);
    expect(find.textContaining('must start with https://'), findsOneWidget);
  });
}
