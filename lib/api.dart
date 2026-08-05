import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String baseUrl = 'https://houseofonzone.com/admin/public/api';

Future<void> fetchAndCacheStock() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    final response = await http.get(
      Uri.parse('$baseUrl/fairOrderStock'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 200) {
      await prefs.setString('fair_order_stock', response.body);
      debugPrint('Successfully fetched and cached fairOrderStock data');
    } else {
      debugPrint('Failed to fetch fairOrderStock: ${response.statusCode}');
    }
  } catch (e) {
    debugPrint('Error fetching/caching fairOrderStock: $e');
  }
}
