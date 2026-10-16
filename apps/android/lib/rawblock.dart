import 'package:flutter/material.dart';

// Kept as a source-compatible entry point; the product now uses DESIGN tokens.
const rawSuccess = Color(0xff39765a);
const rawWarning = Color(0xff956320);
const rawError = Color(0xffa84545);
const rawMono = TextStyle(fontSize: 15, height: 1.5);

@immutable
class DeskBarColors extends ThemeExtension<DeskBarColors> {
  const DeskBarColors({
    required this.canvas,
    required this.surface,
    required this.sidebar,
    required this.raised,
    required this.text,
    required this.muted,
    required this.line,
    required this.edge,
    required this.accent,
    required this.onAccent,
    required this.selection,
    required this.selectedText,
    required this.success,
    required this.successBg,
    required this.warning,
    required this.warningBg,
    required this.danger,
    required this.dangerBg,
    required this.control,
    required this.chart,
    required this.focus,
  });
  final Color canvas,
      surface,
      sidebar,
      raised,
      text,
      muted,
      line,
      edge,
      accent,
      onAccent,
      selection,
      selectedText,
      success,
      successBg,
      warning,
      warningBg,
      danger,
      dangerBg,
      control,
      chart,
      focus;
  static const silver = DeskBarColors(
    canvas: Color(0xfff6f7f9),
    surface: Color(0xffffffff),
    sidebar: Color(0xffeef0f3),
    raised: Color(0xfff0f2f5),
    text: Color(0xff22262d),
    muted: Color(0xff626c7b),
    line: Color(0xffe1e5eb),
    edge: Color(0xffcbd0d8),
    accent: Color(0xff303e52),
    onAccent: Color(0xffffffff),
    selection: Color(0xffe4eaf3),
    selectedText: Color(0xff314a71),
    success: Color(0xff39765a),
    successBg: Color(0xffe9f3ec),
    warning: Color(0xff956320),
    warningBg: Color(0xfffaf0da),
    danger: Color(0xffa84545),
    dangerBg: Color(0xfffaebeb),
    control: Color(0xffa0a9b6),
    chart: Color(0xff607fa7),
    focus: Color(0xff527bc2),
  );
  static const graphite = DeskBarColors(
    canvas: Color(0xff191a1c),
    surface: Color(0xff222426),
    sidebar: Color(0xff151618),
    raised: Color(0xff2c2e31),
    text: Color(0xffeeefef),
    muted: Color(0xffa1a6ad),
    line: Color(0xff35383d),
    edge: Color(0xff3b3d41),
    accent: Color(0xffd7dce2),
    onAccent: Color(0xff22262c),
    selection: Color(0xff30363f),
    selectedText: Color(0xffd1dbe9),
    success: Color(0xffa2c4b0),
    successBg: Color(0xff293a31),
    warning: Color(0xffd8b87a),
    warningBg: Color(0xff403725),
    danger: Color(0xffe7a4a4),
    dangerBg: Color(0xff422c30),
    control: Color(0xff69717c),
    chart: Color(0xffa9bacd),
    focus: Color(0xffadc6eb),
  );
  @override
  DeskBarColors copyWith() => this;
  @override
  DeskBarColors lerp(covariant DeskBarColors? other, double t) =>
      t < .5 ? this : other ?? this;
}

DeskBarColors deskbarColors(BuildContext context) =>
    Theme.of(context).extension<DeskBarColors>() ?? DeskBarColors.silver;
ButtonStyle rawButton({bool primary = false, bool destructive = false}) =>
    FilledButton.styleFrom(
      minimumSize: const Size(48, 48),
      backgroundColor: destructive ? rawError : null,
      foregroundColor: destructive ? Colors.white : null,
    );

ThemeData rawBlockTheme([Brightness brightness = Brightness.light]) {
  final c = brightness == Brightness.dark
      ? DeskBarColors.graphite
      : DeskBarColors.silver;
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
  final text = TextStyle(
    fontFamily: 'Noto Sans SC',
    color: c.text,
    fontSize: 15,
    height: 1.5,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: BorderSide(color: c.line),
  );
  WidgetStateProperty<BorderSide?> focusBorder([
    BorderSide idle = BorderSide.none,
  ]) => WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.focused) &&
            !states.contains(WidgetState.disabled)
        ? BorderSide(color: c.focus, width: 2)
        : idle,
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Noto Sans SC',
    brightness: brightness,
    extensions: [c],
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      secondary: c.selectedText,
      onSecondary: c.surface,
      error: c.danger,
      onError: c.surface,
      surface: c.surface,
      onSurface: c.text,
      surfaceContainerHighest: c.raised,
      outline: c.line,
      outlineVariant: c.edge,
    ),
    scaffoldBackgroundColor: c.canvas,
    dividerColor: c.line,
    focusColor: c.focus.withValues(alpha: .18),
    disabledColor: c.muted,
    iconTheme: IconThemeData(size: 20, color: c.muted),
    textTheme: TextTheme(
      headlineLarge: text.copyWith(
        fontSize: 48,
        fontWeight: FontWeight.w600,
        height: 1.15,
      ),
      headlineMedium: text.copyWith(
        fontSize: 40,
        fontWeight: FontWeight.w600,
        height: 1.15,
      ),
      headlineSmall: text.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      titleLarge: text.copyWith(fontSize: 20, fontWeight: FontWeight.w600),
      titleMedium: text.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
      bodyLarge: text.copyWith(fontSize: 16),
      bodyMedium: text,
      bodySmall: text.copyWith(fontSize: 12, color: c.muted),
      labelLarge: text.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
      labelMedium: text.copyWith(fontSize: 12),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.sidebar,
      foregroundColor: c.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: c.line)),
      titleTextStyle: text.copyWith(fontSize: 22, fontWeight: FontWeight.w600),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      titleTextStyle: text.copyWith(fontSize: 22, fontWeight: FontWeight.w600),
      contentTextStyle: text,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        textStyle: text.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
      ).copyWith(side: focusBorder()),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        foregroundColor: c.text,
        side: BorderSide(color: c.line),
      ).copyWith(side: focusBorder(BorderSide(color: c.line))),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        foregroundColor: c.selectedText,
      ).copyWith(side: focusBorder()),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: c.muted,
        shape: shape,
      ).copyWith(side: focusBorder()),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.raised,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: c.focus, width: 2),
      ),
      errorBorder: border.copyWith(borderSide: BorderSide(color: c.danger)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      labelStyle: text.copyWith(color: c.muted),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.onAccent : c.surface,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.accent : c.control,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.chart,
      linearTrackColor: c.raised,
      linearMinHeight: 6,
      borderRadius: BorderRadius.circular(4),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.accent,
      thumbColor: c.accent,
      inactiveTrackColor: c.raised,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.focus,
      selectionColor: c.selection,
      selectionHandleColor: c.focus,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.accent,
      contentTextStyle: text.copyWith(color: c.onAccent),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.accent,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: text.copyWith(color: c.onAccent, fontSize: 12),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    listTileTheme: ListTileThemeData(
      textColor: c.text,
      iconColor: c.muted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
  );
}

class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, this.color});
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = deskbarColors(context);
    final foreground = color ?? c.muted;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: foreground == c.success ? c.successBg : c.raised,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: foreground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
