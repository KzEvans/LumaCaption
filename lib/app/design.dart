import 'dart:io';
import 'package:flutter/material.dart';

ThemeData macContentTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff007aff),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff17191e)
        : const Color(0xfff6f7fa),
    fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : 'Segoe UI',
    dividerColor: dark ? const Color(0xff30333c) : const Color(0xffe4e6ed),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xff21242b) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: dark ? const Color(0xff30333c) : const Color(0xffe4e6ed),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xff272a33) : const Color(0xfffafbfe),
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(9),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      bodySmall: TextStyle(fontSize: 12, height: 1.5),
      titleLarge: TextStyle(
        fontSize: 25,
        fontWeight: FontWeight.w600,
        letterSpacing: -.6,
      ),
    ),
  );
}
