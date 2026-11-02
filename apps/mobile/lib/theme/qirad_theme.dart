import 'package:flutter/material.dart';

/// Design tokens the Material [ColorScheme] has no slot for: the hairline
/// rule between rows, the gold used for exactly one meaning — "this
/// record's signature was checked and holds" (spec 6.1, hard rule 6) — and
/// the soft shadow every elevated card shares. Keeping these as a
/// [ThemeExtension] means every screen reads them from `Theme.of(context)`,
/// the same way it reads `colorScheme`, instead of each screen hard-coding
/// its own copy of these colors.
@immutable
class QiradTokens extends ThemeExtension<QiradTokens> {
  const QiradTokens({
    required this.seal,
    required this.onSeal,
    required this.rule,
    required this.shadow,
    required this.goodBg,
    required this.waitBg,
  });

  final Color seal;
  final Color onSeal;
  final Color rule;
  final Color shadow;
  final Color goodBg;
  final Color waitBg;

  static const light = QiradTokens(
    seal: Color(0xFFA97C22),
    onSeal: Color(0xFF2A1D04),
    rule: Color(0xFFDEE6DC),
    shadow: Color(0x1F0E3C2C),
    goodBg: Color(0xFFE3F1E9),
    waitBg: Color(0xFFF7EDD7),
  );

  static const dark = QiradTokens(
    seal: Color(0xFFE6BA63),
    onSeal: Color(0xFF2A1D04),
    rule: Color(0x24FFFFFF),
    shadow: Color(0x66000000),
    goodBg: Color(0xFF163C29),
    waitBg: Color(0xFF3A2E14),
  );

  @override
  QiradTokens copyWith({
    Color? seal,
    Color? onSeal,
    Color? rule,
    Color? shadow,
    Color? goodBg,
    Color? waitBg,
  }) {
    return QiradTokens(
      seal: seal ?? this.seal,
      onSeal: onSeal ?? this.onSeal,
      rule: rule ?? this.rule,
      shadow: shadow ?? this.shadow,
      goodBg: goodBg ?? this.goodBg,
      waitBg: waitBg ?? this.waitBg,
    );
  }

  @override
  QiradTokens lerp(ThemeExtension<QiradTokens>? other, double t) {
    if (other is! QiradTokens) return this;
    return QiradTokens(
      seal: Color.lerp(seal, other.seal, t)!,
      onSeal: Color.lerp(onSeal, other.onSeal, t)!,
      rule: Color.lerp(rule, other.rule, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      goodBg: Color.lerp(goodBg, other.goodBg, t)!,
      waitBg: Color.lerp(waitBg, other.waitBg, t)!,
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
    fontFamily: 'JetBrains Mono',
    fontWeight: weight,
    fontSize: fontSize,
    fontFeatures: const [FontFeature.tabularFigures()],
    color: Theme.of(context).colorScheme.onSurface,
  );
}

ThemeData qiradLightTheme() => _qiradTheme(
  primary: const Color(0xFF0E3C2C),
  onPrimary: const Color(0xFFFFFFFF),
  bg: const Color(0xFFF3F6F1),
  surface: const Color(0xFFFFFFFF),
  ink: const Color(0xFF11261B),
  inkSoft: const Color(0xFF5F7367),
  danger: const Color(0xFFA8432C),
  onDanger: const Color(0xFFFFFFFF),
  dangerBg: const Color(0xFFF7E3DB),
  tokens: QiradTokens.light,
  brightness: Brightness.light,
);

ThemeData qiradDarkTheme() => _qiradTheme(
  primary: const Color(0xFF22815A),
  onPrimary: const Color(0xFFFFFFFF),
  bg: const Color(0xFF0A2017),
  surface: const Color(0xFF11311F),
  ink: const Color(0xFFF3F1E6),
  inkSoft: const Color(0xFFA7BFB0),
  danger: const Color(0xFFE2896B),
  onDanger: const Color(0xFF170C08),
  dangerBg: const Color(0xFF3B211A),
  tokens: QiradTokens.dark,
  brightness: Brightness.dark,
);

ThemeData _qiradTheme({
  required Color primary,
  required Color onPrimary,
  required Color bg,
  required Color surface,
  required Color ink,
  required Color inkSoft,
  required Color danger,
  required Color onDanger,
  required Color dangerBg,
  required QiradTokens tokens,
  required Brightness brightness,
}) {
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: onPrimary,
    // The gold seal doubles as the tonal-button role, so "Continue" after
    // creating a partnership reads as the same gold as every seal mark,
    // not a leftover Material default.
    secondary: tokens.seal,
    onSecondary: tokens.onSeal,
    secondaryContainer: tokens.seal,
    onSecondaryContainer: tokens.onSeal,
    surface: surface,
    onSurface: ink,
    // Filled inputs and informational banners sit flush with the page
    // instead of floating like a card — the "recessed" role — so this
    // equals the scaffold background, not a third surface color.
    surfaceContainerHighest: bg,
    onSurfaceVariant: inkSoft,
    error: danger,
    onError: onDanger,
    errorContainer: dangerBg,
    onErrorContainer: danger,
    outline: tokens.rule,
  );

  final titleStyle = TextStyle(
    fontFamily: 'Sora',
    fontSize: 21,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: ink,
  );

  final buttonTextStyle = const TextStyle(
    fontFamily: 'Inter',
    fontWeight: FontWeight.w700,
    fontSize: 14.5,
  );

  final pillShape = const StadiumBorder();

  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: bg,
    fontFamily: 'Inter',
    extensions: [tokens],
    textTheme: TextTheme(
      titleLarge: titleStyle,
      titleMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
        color: inkSoft,
      ),
      bodyMedium: TextStyle(fontSize: 14, color: ink),
      bodySmall: TextStyle(fontSize: 12, color: inkSoft),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
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
    // Reserved for the one card role meant to interrupt the reader: the
    // integrity/equivocation/sync warning (spec 6.1 steps 4-5, 7.4). Every
    // other grouped block uses `LedgerGroupCard`, not this theme, so a
    // neutral card never accidentally picks up the warning tint.
    cardTheme: CardThemeData(
      color: dangerBg,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: onPrimary,
        elevation: 0,
        minimumSize: const Size.fromHeight(50),
        shape: pillShape,
        textStyle: buttonTextStyle,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        minimumSize: const Size.fromHeight(50),
        shape: pillShape,
        textStyle: buttonTextStyle,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: primary,
        side: BorderSide(color: primary),
        minimumSize: const Size.fromHeight(48),
        shape: pillShape,
        textStyle: buttonTextStyle,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bg,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: tokens.rule),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: primary, width: 1.6),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
  );
}
