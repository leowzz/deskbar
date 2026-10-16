import 'package:flutter/material.dart';

const rawSuccess = Color(0xff008000);
const rawWarning = Color(0xffffa500);
const rawError = Color(0xffff0000);
const rawMono = TextStyle(fontFamily: 'Space Mono', fontSize: 15, height: 1.5);

ButtonStyle rawButton({bool primary = false, bool destructive = false}) {
  Color background(Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) return const Color(0xfff0f0f0);
    if (states.contains(WidgetState.pressed)) return Colors.black;
    if (states.contains(WidgetState.hovered)) {
      return destructive
          ? Colors.black
          : primary
          ? Colors.white
          : Colors.black;
    }
    return destructive
        ? rawError
        : primary
        ? Colors.black
        : Colors.white;
  }

  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 24, vertical: 10),
    ),
    shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    backgroundColor: WidgetStateProperty.resolveWith(background),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? const Color(0xff777777)
          : destructive && states.contains(WidgetState.hovered)
          ? rawError
          : background(states) == Colors.black || background(states) == rawError
          ? Colors.white
          : Colors.black,
    ),
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.disabled)
            ? const Color(0xffcccccc)
            : Colors.black,
        width:
            states.contains(WidgetState.pressed) ||
                states.contains(WidgetState.focused)
            ? 5
            : 3,
      ),
    ),
    textStyle: WidgetStatePropertyAll(
      TextStyle(
        fontFamily: 'Work Sans',
        fontSize: destructive ? 19 : 14,
        fontWeight: destructive ? FontWeight.w700 : FontWeight.w600,
        letterSpacing: 2,
      ),
    ),
  );
}

ThemeData rawBlockTheme() {
  const headline = TextStyle(
    fontFamily: 'Archivo Black',
    fontWeight: FontWeight.w900,
    color: Colors.black,
  );
  const body = TextStyle(
    fontFamily: 'Work Sans',
    fontSize: 16,
    height: 1.6,
    color: Colors.black,
  );
  const border = OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: BorderSide(width: 3),
  );
  return ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    fontFamily: 'Work Sans',
    fontFamilyFallback: const ['Noto Sans CJK SC', 'sans-serif'],
    colorScheme: const ColorScheme.light(
      primary: Colors.black,
      onPrimary: Colors.white,
      secondary: Colors.black,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: Colors.black,
      error: rawError,
      onError: Colors.white,
      outline: Colors.black,
    ),
    scaffoldBackgroundColor: Colors.white,
    dividerColor: Colors.black,
    textTheme: TextTheme(
      headlineLarge: headline.copyWith(fontSize: 64, height: 1),
      headlineMedium: headline.copyWith(fontSize: 48, height: 1.05),
      headlineSmall: headline.copyWith(fontSize: 32, height: 1.1),
      titleLarge: body.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      bodyLarge: body,
      bodyMedium: body,
      bodySmall: body.copyWith(fontSize: 14, height: 1.5),
      labelLarge: body.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'Archivo Black',
        fontSize: 28,
        color: Colors.black,
      ),
    ),
    cardTheme: const CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(side: BorderSide(width: 3)),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(side: BorderSide(width: 3)),
      titleTextStyle: TextStyle(
        fontFamily: 'Archivo Black',
        fontWeight: FontWeight.w900,
        fontSize: 32,
        height: 1.1,
        color: Colors.black,
      ),
      contentTextStyle: body,
    ),
    filledButtonTheme: FilledButtonThemeData(style: rawButton(primary: true)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: rawButton()),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
        shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? const Color(0xff777777)
              : states.contains(WidgetState.hovered)
              ? const Color(0xff0000ff)
              : Colors.black,
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'Work Sans',
            fontSize: 14,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xfff0f0f0),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      labelStyle: const TextStyle(
        fontFamily: 'Archivo Black',
        fontSize: 14,
        color: Colors.black,
      ),
      hintStyle: rawMono.copyWith(color: const Color(0xff555555)),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: const BorderSide(width: 5)),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(width: 3, color: rawError),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(width: 5, color: rawError),
      ),
      disabledBorder: border.copyWith(
        borderSide: const BorderSide(width: 3, color: Color(0xffcccccc)),
      ),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Colors.black,
      selectionColor: Color(0xffcccccc),
      selectionHandleColor: Colors.black,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Colors.black,
      linearTrackColor: Color(0xffcccccc),
      linearMinHeight: 4,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(color: Colors.black),
      textStyle: TextStyle(
        fontFamily: 'Space Mono',
        fontSize: 13,
        color: Colors.white,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(vertical: 12),
      textColor: Colors.black,
      shape: Border(bottom: BorderSide(width: 3)),
    ),
  );
}

class StatusTag extends StatelessWidget {
  const StatusTag(this.label, {super.key, this.color = Colors.black});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: DecoratedBox(
      decoration: BoxDecoration(border: Border.all(color: color, width: 2)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );
}
