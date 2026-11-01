import 'package:flutter/material.dart';

/// Design tokens the Material [ColorScheme] has no slot for: the ledger's
/// hairline rule between rows, and the brass used for exactly one meaning —
/// "this record's signature was checked and holds" (spec 6.1, hard rule 6).
/// Keeping these as a [ThemeExtension] means every screen reads them from
/// `Theme.of(context)`, the same way it reads `colorScheme`, instead of each
/// screen hard-coding its own copy of these colors.
@immutable
class QiradTokens extends ThemeExtension<QiradTokens> {
  const QiradTokens({required this.seal, required this.rule});

  final Color seal;
  final Color rule;

  static const light = QiradTokens(
    seal: Color(0xFF916325),
    rule: Color(0xFFD7D2C0),
  );

  static const dark = QiradTokens(
    seal: Color(0xFFD7A753),
    rule: Color(0xFF2B352C),
  );

  @override
  QiradTokens copyWith({Color? seal, Color? rule}) {
    return QiradTokens(seal: seal ?? this.seal, rule: rule ?? this.rule);
  }

  @override
  QiradTokens lerp(ThemeExtension<QiradTokens>? other, double t) {
    if (other is! QiradTokens) return this;
    return QiradTokens(
      seal: Color.lerp(seal, other.seal, t)!,
      rule: Color.lerp(rule, other.rule, t)!,
    );
  }
}

/// The text style for every paisa amount and `seq` number on screen.
///
/// A fixed mono face with tabular figures, so a column of amounts lines up
/// the way it would in a paper ledger, and a figure's own digits never
/// change the row's width as they change (hard rule 1: money is exact).
TextStyle qiradFigureStyle(
  BuildContext context, {
  FontWeight weight = FontWeight.w500,
  double fontSize = 14,
}) {
  return TextStyle(
    fontFamily: 'IBM Plex Mono',
    fontWeight: weight,
    fontSize: fontSize,
    fontFeatures: const [FontFeature.tabularFigures()],
    color: Theme.of(context).colorScheme.onSurface,
  );
}

ThemeData qiradLightTheme() => _qiradTheme(
  pine: const Color(0xFF2A5A4B),
  onPine: const Color(0xFFF8F6EE),
  paper: const Color(0xFFEEECE3),
  paperRaised: const Color(0xFFF8F6EE),
  ink: const Color(0xFF1B241D),
  inkSoft: const Color(0xFF5C6660),
  rust: const Color(0xFF954032),
  rustBg: const Color(0xFFF3E4DF),
  tokens: QiradTokens.light,
  brightness: Brightness.light,
);

ThemeData qiradDarkTheme() => _qiradTheme(
  pine: const Color(0xFF75B299),
  onPine: const Color(0xFF0E1613),
  paper: const Color(0xFF131A15),
  paperRaised: const Color(0xFF1B241D),
  ink: const Color(0xFFE8E5D8),
  inkSoft: const Color(0xFF97A096),
  rust: const Color(0xFFE08D7C),
  rustBg: const Color(0xFF2C1C18),
  tokens: QiradTokens.dark,
  brightness: Brightness.dark,
);

ThemeData _qiradTheme({
  required Color pine,
  required Color onPine,
  required Color paper,
  required Color paperRaised,
  required Color ink,
  required Color inkSoft,
  required Color rust,
  required Color rustBg,
  required QiradTokens tokens,
  required Brightness brightness,
}) {
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: pine,
    onPrimary: onPine,
    secondary: tokens.seal,
    onSecondary: onPine,
    surface: paper,
    onSurface: ink,
    surfaceContainerHighest: paperRaised,
    onSurfaceVariant: inkSoft,
    error: rust,
    onError: onPine,
    errorContainer: rustBg,
    onErrorContainer: rust,
    outline: tokens.rule,
  );

  final titleStyle = TextStyle(
    fontFamily: 'Fraunces',
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: ink,
  );

  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: paper,
    fontFamily: 'IBM Plex Sans',
    extensions: [tokens],
    textTheme: TextTheme(
      titleLarge: titleStyle,
      titleMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: inkSoft,
      ),
      bodyMedium: TextStyle(fontSize: 14, color: ink),
      bodySmall: TextStyle(fontSize: 12, color: inkSoft),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: paperRaised,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: titleStyle,
      iconTheme: IconThemeData(color: inkSoft),
    ),
    dividerTheme: DividerThemeData(color: tokens.rule, space: 1, thickness: 1),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 13,
    ),
    cardTheme: CardThemeData(
      color: rustBg,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: pine,
        foregroundColor: onPine,
        elevation: 0,
        minimumSize: const Size.fromHeight(46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        textStyle: const TextStyle(
          fontFamily: 'IBM Plex Sans',
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: pine,
        side: BorderSide(color: pine),
        minimumSize: const Size.fromHeight(44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: paperRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: tokens.rule),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: pine, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
  );
}
