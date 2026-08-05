import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryColor = Color(0xFFFF6B00); // Premium modern orange
  
  static const List<Color> gradientColors = [
    Color(0xFFFF9E80),
    Color(0xFFFF3D00),
  ];
  
  static const Color scaffoldBackgroundColor = Color(0xFFFAFAFA);
  
  static final ThemeData lightTheme = ThemeData(
    primaryColor: primaryColor,
    scaffoldBackgroundColor: scaffoldBackgroundColor,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primaryColor,
      primary: primaryColor,
      secondary: const Color(0xFFFF3D00),
      surface: scaffoldBackgroundColor,
    ),
    useMaterial3: true,
  );
}
