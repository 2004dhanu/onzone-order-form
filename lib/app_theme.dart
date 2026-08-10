import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryColor = Color(0xFF202C4D); // Premium dark navy
  
  static const List<Color> gradientColors = [
    Color(0xFF3A4A6B),
    Color(0xFF202C4D),
  ];
  
  static const Color scaffoldBackgroundColor = Color(0xFFFAFAFA);
  
  static final ThemeData lightTheme = ThemeData(
    primaryColor: primaryColor,
    scaffoldBackgroundColor: scaffoldBackgroundColor,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primaryColor,
      primary: primaryColor,
      secondary: const Color(0xFF202C4D),
      surface: scaffoldBackgroundColor,
    ),
    useMaterial3: true,
  );
}
