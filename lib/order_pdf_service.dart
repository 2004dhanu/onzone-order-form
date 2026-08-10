import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:printing/printing.dart';

import 'api.dart';

// ─────────────────────────────────────────────────────────────
// COMPANY CONSTANTS
// ─────────────────────────────────────────────────────────────
const String kCompanyName = 'ONZONE CLOTHING CO.';
const String kCompanyAddress =
    '# 19, Parekh Square, 3rd Cross, H. Siddaiah Road, Bangalore - 560 027.  Phone : 080-41248938.  Mob.: 99160 82518';

const List<String> kTerms = [
  'Order once placed cannot be cancelled.',
  'Our responsibility ceases when the goods leave our godown.',
  'Subject to stock. Disputes if any should be settled in Bangalore Court Only.',
  'Verbal commitments shall be invalid until and unless written on the order sheet.',
  'Interest will be charged at the rate of 24% per annum after the due date.',
];

// ─────────────────────────────────────────────────────────────
// SIZE COLUMNS  ->  [top label, sub label]
//   Sub label carries the shirt alias ("S/36").  Columns whose sub
//   label has no "/" are pant-only.
// ─────────────────────────────────────────────────────────────
const List<List<String>> kSizeColumns = [
  ['28', '28'],
  ['30', '30'],
  ['32', '32'],
  ['34', '34'],
  ['36', 'S/36'],
  ['38', 'M/38'],
  ['40', 'L/40'],
  ['42', 'XL/42'],
  ['44', '2XL/44'],
  ['46', '3XL/46'],
  ['48', '4XL/48'],
  ['50', '5XL/50'],
];

// ─────────────────────────────────────────────────────────────
// PALETTE
// ─────────────────────────────────────────────────────────────
final PdfColor _kRed = PdfColor.fromInt(0xFFA31D1D);
final PdfColor _kBlue = PdfColor.fromInt(0xFF1F5FA8);
final PdfColor _kInk = PdfColor.fromInt(0xFF1A1A1A);
final PdfColor _kGrey = PdfColor.fromInt(0xFF808080);
final PdfColor _kBorder = PdfColor.fromInt(0xFF3C3C3C);

// ─────────────────────────────────────────────────────────────
// GEOMETRY
// ─────────────────────────────────────────────────────────────
const double _tableW = 546;
const double _wQty = 36;
const double _wRate = 42;
const double _sizeColW = 21;
final double _wSizeArea = _sizeColW * kSizeColumns.length;
final double _wStyle = _tableW - _wSizeArea - _wQty - _wRate;

const double _rowH = 24;
const double _headTopH = 12;
const double _headSubH = 22;
const double _headH = _headTopH + _headSubH;
const double _totalH = 22;

const double _footerH = 64;
const double _footerTermsW = 240;
const double _footerOrderedW = 160;

// Line 1 — fixed right block so a 5-digit order number never overflows.
const double _dateFieldW = 58; // underlined date value
const double _orderChipW = 112; // "ORDER NUMBER" + value box
const double _line1RightW = 26 + 5 + _dateFieldW + 12 + _orderChipW; // 213
const double _retailerNameMaxW = 150; // name truncates here, dots take the rest

// Masthead + info block — every element has a fixed height so the
// remaining table space can be computed exactly.
const double _hTitle = 26;
const double _hAddress = 10;
const double _hRule = 1.2;
const double _hLine1 = 22;
const double _hLine2 = 16;
const double _kHeaderH =
    _hTitle + 4 + _hAddress + 6 + _hRule + 10 + _hLine1 + 6 + _hLine2 + 8;

const double _pageMarginV = 20;
const double _pageMarginH = 24;

final double _contentH = PdfPageFormat.a4.height - _pageMarginV * 2;
final double _tableSpaceH =
    _contentH - _kHeaderH - _headH - _totalH - _footerH;

/// How many item rows fit on a single sheet before it has to spill
/// onto a continuation page.
final int _rowCapacity = (_tableSpaceH / _rowH).floor();

// ─────────────────────────────────────────────────────────────
// PUBLIC ENTRY POINT
// ─────────────────────────────────────────────────────────────
Future<void> downloadOrderPdf(BuildContext context, dynamic orderId) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final data = await _fetchOrder(orderId);
    if (data == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not load order details.')),
      );
      return;
    }

    final Uint8List bytes = await _buildPdf(data);
    final ref = (data['fair_order_ref'] ?? 'ORDER').toString();
    final fileName =
        'ONZONE_${ref.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}.pdf';

    final file = await _savePdf(bytes, fileName);

    if (file != null) {
      final result = await OpenFilex.open(file.path);
      messenger.showSnackBar(
        SnackBar(
          content: Text(result.type == ResultType.done
              ? 'Saved: ${file.path}'
              : 'PDF saved to ${file.path}'),
          action: SnackBarAction(
            label: 'Share',
            onPressed: () =>
                Printing.sharePdf(bytes: bytes, filename: fileName),
          ),
        ),
      );
    } else {
      await Printing.sharePdf(bytes: bytes, filename: fileName);
    }
  } catch (e) {
    debugPrint('PDF error: $e');
    messenger.showSnackBar(
      SnackBar(content: Text('Failed to generate PDF: $e')),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// API
// ─────────────────────────────────────────────────────────────
Future<Map<String, dynamic>?> _fetchOrder(dynamic id) async {
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('token');

  final res = await http.get(
    Uri.parse('$baseUrl/fairOrderFormById/$id'),
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    },
  );

  if (res.statusCode != 200) return null;
  final decoded = jsonDecode(res.body);
  if (decoded is Map && decoded['data'] is Map) {
    return Map<String, dynamic>.from(decoded['data']);
  }
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  return null;
}

Future<File?> _savePdf(Uint8List bytes, String name) async {
  try {
    Directory dir;
    if (Platform.isAndroid) {
      final dl = Directory('/storage/emulated/0/Download');
      dir = await dl.exists() ? dl : (await getApplicationDocumentsDirectory());
    } else {
      dir = await getApplicationDocumentsDirectory();
    }
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  } catch (_) {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes, flush: true);
      return f;
    } catch (_) {
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────
// ROW MODEL
//   EXACTLY ONE ROW PER MAIN BARCODE — never split by dress type.
//   Each sub-barcode under that main becomes an _Entry. The number
//   printed in brackets is the REAL sub number taken from the
//   sub-barcode itself: main 70702 + sub 707023  ->  3
// ─────────────────────────────────────────────────────────────
class _Entry {
  final bool isShirt;
  final List<String> tokens;
  final int qty;

  _Entry({required this.isShirt, required this.tokens, required this.qty});
}

class _ItemRow {
  final String style; // main barcode
  final List<String> subNos; // ['1', '3'] — empty when there are no subs
  final List<_Entry> entries;
  final String rate;

  _ItemRow({
    required this.style,
    required this.subNos,
    required this.entries,
    required this.rate,
  });

  /// "(1, 3)" — printed bold beside the main barcode. Empty when
  /// the barcode has no sub-barcodes.
  String get subLabel => subNos.isEmpty ? '' : '(${subNos.join(', ')})';
}

bool _isShirtType(dynamic v) =>
    (v ?? '').toString().trim().toUpperCase().startsWith('S');

/// Real sub number = whatever the sub-barcode carries beyond the main.
///   main 70702, sub 707023  ->  "3"
///   main 70702, sub 7070212 ->  "12"
/// Returns '' when the sub barcode is the main barcode itself, or when
/// no suffix can be derived (caller falls back to the position).
String _subNumberOf(String main, String sub) {
  final m = main.trim();
  final s = sub.trim();
  if (s.isEmpty || m.isEmpty) return '';
  if (s == m) return '';
  if (s.startsWith(m) && s.length > m.length) {
    final suffix = s.substring(m.length);
    final stripped = suffix.replaceFirst(RegExp(r'^[^0-9A-Za-z]+'), '');
    return stripped.isEmpty ? suffix : stripped;
  }
  return '';
}

List<_ItemRow> _buildRows(List subs) {
  // group by MAIN barcode, preserving order of appearance
  final Map<String, List<Map>> mains = {};
  for (final s in subs) {
    if (s is! Map) continue;
    final main =
        (s['fair_order_sub_barcode_main'] ?? s['fair_order_sub_barcode'] ?? '')
            .toString();
    mains.putIfAbsent(main, () => []).add(s);
  }

  final rows = <_ItemRow>[];

  mains.forEach((main, list) {
    final entries = <_Entry>[];
    final subNos = <String>[];
    String rate = '';

    for (int i = 0; i < list.length; i++) {
      final s = list[i];
      final ownBarcode = (s['fair_order_sub_barcode'] ?? '').toString();

      // real sub number from the barcode; positional index only as a
      // last resort when the barcode carries no derivable suffix
      final n = _subNumberOf(main, ownBarcode);
      if (n.isNotEmpty) {
        if (!subNos.contains(n)) subNos.add(n);
      } else if (ownBarcode.isNotEmpty && ownBarcode != main) {
        final fallback = '${i + 1}';
        if (!subNos.contains(fallback)) subNos.add(fallback);
      }

      final tokens = (s['fair_order_sub_dress_size'] ?? '')
          .toString()
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      entries.add(_Entry(
        isShirt: _isShirtType(s['fair_order_sub_dress_type']),
        tokens: tokens,
        qty: int.tryParse((s['fair_order_sub_quantity'] ?? '1').toString()) ?? 1,
      ));

      if (rate.isEmpty) rate = (s['fair_order_sub_mrp'] ?? '').toString();
    }

    // numeric sort so (3, 1) prints as (1, 3)
    subNos.sort((a, b) {
      final ai = int.tryParse(a);
      final bi = int.tryParse(b);
      if (ai != null && bi != null) return ai.compareTo(bi);
      return a.compareTo(b);
    });

    rows.add(_ItemRow(
      style: main,
      subNos: subNos,
      entries: entries,
      rate: rate,
    ));
  });

  return rows;
}

// ─────────────────────────────────────────────────────────────
// SIZE MATCHING
// ─────────────────────────────────────────────────────────────
String _normAlpha(String s) => s
    .toUpperCase()
    .replaceAll(' ', '')
    .replaceAll('XXXXXL', '5XL')
    .replaceAll('XXXXL', '4XL')
    .replaceAll('XXXL', '3XL')
    .replaceAll('XXL', '2XL');

String _colAlpha(int i) {
  final sub = kSizeColumns[i][1];
  return sub.contains('/') ? sub.split('/')[0].toUpperCase() : '';
}

bool _shirtHit(List<String> tokens, String alpha, String num) {
  if (alpha.isEmpty) return false;
  for (final t in tokens) {
    final up = _normAlpha(t);
    if (up == '$alpha-$num') return true;
    final p = up.split('-');
    if (p.length == 2) {
      if (p[0] == alpha || p[1] == num) return true;
    } else if (up == alpha || up == num) {
      return true;
    }
  }
  return false;
}

bool _pantHit(List<String> tokens, String size) {
  for (final t in tokens) {
    final d = t.replaceAll(RegExp(r'[^0-9]'), '');
    if (d == size) return true;
  }
  return false;
}

bool _entryHits(_Entry e, int col) => e.isShirt
    ? _shirtHit(e.tokens, _colAlpha(col), kSizeColumns[col][0])
    : _pantHit(e.tokens, kSizeColumns[col][0]);

/// Value printed in one size cell = total quantity across every
/// sub-barcode on this line that selected that size.
int _colValue(_ItemRow r, int col) {
  int v = 0;
  for (final e in r.entries) {
    if (_entryHits(e, col)) v += e.qty;
  }
  return v;
}

/// Row qty = sum of every size cell on the line.
int _rowQty(_ItemRow r) {
  int total = 0;
  for (int i = 0; i < kSizeColumns.length; i++) {
    total += _colValue(r, i);
  }
  if (total == 0) {
    for (final e in r.entries) {
      total += e.qty;
    }
  }
  return total;
}

// ─────────────────────────────────────────────────────────────
// FORMATTERS
// ─────────────────────────────────────────────────────────────
String _fmtDate(dynamic raw) {
  if (raw == null) return '';
  final s = raw.toString();
  if (s.length < 10) return s;
  final d = DateTime.tryParse(s);
  if (d == null) return s;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year.toString().substring(2)}';
}

String _fmtRate(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  return 'Rs.$v';
}

// ─────────────────────────────────────────────────────────────
// SHARED DECORATIONS
// ─────────────────────────────────────────────────────────────
pw.BoxDecoration get _cell =>
    pw.BoxDecoration(border: pw.Border.all(width: 0.6, color: _kBorder));

pw.Widget _dots({double fs = 8}) => pw.Text(
      '.' * 200,
      maxLines: 1,
      style: pw.TextStyle(fontSize: fs, color: _kGrey, letterSpacing: 1.2),
    );

pw.Widget _kv(String label, String value,
        {PdfColor? valueColor, bool boldValue = false, double fs = 8.5}) =>
    pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(label, style: pw.TextStyle(fontSize: fs, color: _kInk)),
        pw.SizedBox(width: 3),
        pw.Expanded(
          child: pw.Text(value,
              maxLines: 1,
              style: pw.TextStyle(
                fontSize: fs,
                color: valueColor ?? _kInk,
                fontWeight:
                    boldValue ? pw.FontWeight.bold : pw.FontWeight.normal,
              )),
        ),
      ],
    );

// ── MASTHEAD + INFO BLOCK ────────────────────────────────────
List<pw.Widget> _headerWidgets(Map<String, dynamic> d, pw.Font titleFont) => [
      pw.SizedBox(
        height: _hTitle,
        width: _tableW,
        child: pw.Center(
          child: pw.Text(
            kCompanyName,
            style: pw.TextStyle(font: titleFont, fontSize: 21, color: _kRed),
          ),
        ),
      ),
      pw.SizedBox(height: 4),
      pw.SizedBox(
        height: _hAddress,
        width: _tableW,
        child: pw.Center(
          child: pw.Text(kCompanyAddress,
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 6.5)),
        ),
      ),
      pw.SizedBox(height: 6),
      pw.Container(width: _tableW, height: _hRule, color: _kRed),
      pw.SizedBox(height: 10),

      // ── LINE 1 : TO / DATE / ORDER NUMBER ─────
      pw.SizedBox(
        width: _tableW,
        height: _hLine1,
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            // LEFT — flexes, dotted leader absorbs whatever is left
            pw.Expanded(
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('To, M/s', style: const pw.TextStyle(fontSize: 8.5)),
                  pw.SizedBox(width: 6),
                  pw.ConstrainedBox(
                    constraints:
                        const pw.BoxConstraints(maxWidth: _retailerNameMaxW),
                    child: pw.Text(
                        (d['fair_order_retailer'] ?? '').toString(),
                        maxLines: 1,
                        overflow: pw.TextOverflow.clip,
                        style: pw.TextStyle(
                            fontSize: 10, fontWeight: pw.FontWeight.bold)),
                  ),
                  pw.SizedBox(width: 5),
                  pw.Expanded(child: _dots()),
                  pw.SizedBox(width: 10),
                ],
              ),
            ),
            // RIGHT — fixed width, never squeezed
            pw.SizedBox(
              width: _line1RightW,
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.SizedBox(
                    width: 26,
                    child: pw.Text('Date.',
                        style: const pw.TextStyle(fontSize: 8.5)),
                  ),
                  pw.SizedBox(width: 5),
                  pw.Container(
                    width: _dateFieldW,
                    alignment: pw.Alignment.center,
                    padding: const pw.EdgeInsets.only(bottom: 2),
                    decoration: pw.BoxDecoration(
                      border: pw.Border(
                          bottom: pw.BorderSide(width: 0.6, color: _kInk)),
                    ),
                    child: pw.Text(_fmtDate(d['fair_order_date']),
                        maxLines: 1,
                        style: pw.TextStyle(
                            fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
                  ),
                  pw.SizedBox(width: 12),
                  pw.Container(
                    width: _orderChipW,
                    height: 20,
                    padding: const pw.EdgeInsets.symmetric(horizontal: 6),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(width: 0.6, color: _kRed),
                      borderRadius: pw.BorderRadius.circular(2),
                    ),
                    child: pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text('ORDER NUMBER',
                            style: const pw.TextStyle(fontSize: 6)),
                        pw.SizedBox(width: 6),
                        pw.Expanded(
                          child: pw.Text(
                              (d['fair_order_no'] ?? d['id'] ?? '').toString(),
                              maxLines: 1,
                              textAlign: pw.TextAlign.right,
                              style: pw.TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: pw.FontWeight.bold,
                                  color: _kRed)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 6),

      // ── LINE 2 : GSTIN / MOBILE / DELIVERY ────
      pw.SizedBox(
        width: _tableW,
        height: _hLine2,
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.SizedBox(
              width: 186,
              child:
                  _kv('GSTIN. :', (d['fair_order_gst_no'] ?? '').toString()),
            ),
            pw.SizedBox(
              width: 190,
              child: _kv('Mobile Number :',
                  (d['fair_order_retailer_mobile'] ?? '').toString(),
                  valueColor: _kBlue),
            ),
            pw.Expanded(
              child: _kv('Date of Delivery :',
                  _fmtDate(d['fair_order_delivery_date']),
                  boldValue: true),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 8),
    ];

// ── TABLE HEADER ─────────────────────────────────────────────
pw.Widget _tableHeader() => pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: _wStyle,
          height: _headH,
          alignment: pw.Alignment.centerLeft,
          padding: const pw.EdgeInsets.only(left: 8),
          decoration: _cell,
          child: pw.Text('Style Code / Particulars',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ),
        pw.Column(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Container(
              width: _wSizeArea,
              height: _headTopH,
              alignment: pw.Alignment.center,
              decoration: _cell,
              child: pw.Text('SIZE',
                  style: pw.TextStyle(
                      fontSize: 6.5, fontWeight: pw.FontWeight.bold)),
            ),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: List.generate(
                kSizeColumns.length,
                (i) => pw.Container(
                  width: _sizeColW,
                  height: _headSubH,
                  alignment: pw.Alignment.center,
                  decoration: _cell,
                  child: pw.Column(
                    mainAxisSize: pw.MainAxisSize.min,
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    children: [
                      pw.Text(kSizeColumns[i][0],
                          style: pw.TextStyle(
                              fontSize: 7, fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 1),
                      pw.Text(kSizeColumns[i][1],
                          maxLines: 1,
                          style: pw.TextStyle(fontSize: 4.6, color: _kGrey)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        pw.Container(
          width: _wQty,
          height: _headH,
          alignment: pw.Alignment.center,
          decoration: _cell,
          child: pw.Text('Qty.',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ),
        pw.Container(
          width: _wRate,
          height: _headH,
          alignment: pw.Alignment.center,
          decoration: _cell,
          child: pw.Text('Rate',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ),
      ],
    );

// ── ITEM ROW ─────────────────────────────────────────────────
pw.Widget _itemRow(_ItemRow r) => pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: _wStyle,
          height: _rowH,
          alignment: pw.Alignment.centerLeft,
          padding: const pw.EdgeInsets.only(left: 8, right: 4),
          decoration: _cell,
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text(r.style,
                  maxLines: 1,
                  style: pw.TextStyle(
                      fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
              if (r.subLabel.isNotEmpty) ...[
                pw.SizedBox(width: 6),
                pw.Text(r.subLabel,
                    maxLines: 1,
                    style: pw.TextStyle(
                        fontSize: 9.5,
                        fontWeight: pw.FontWeight.bold,
                        color: _kInk)),
              ],
            ],
          ),
        ),
        ...List.generate(
          kSizeColumns.length,
          (i) {
            final v = _colValue(r, i);
            return pw.Container(
              width: _sizeColW,
              height: _rowH,
              alignment: pw.Alignment.center,
              decoration: _cell,
              child: pw.Text(v == 0 ? '' : '$v',
                  style: const pw.TextStyle(fontSize: 8)),
            );
          },
        ),
        pw.Container(
          width: _wQty,
          height: _rowH,
          alignment: pw.Alignment.center,
          decoration: _cell,
          child: pw.Text('${_rowQty(r)}',
              style:
                  pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
        ),
        pw.Container(
          width: _wRate,
          height: _rowH,
          alignment: pw.Alignment.center,
          decoration: _cell,
          child: pw.Text(_fmtRate(r.rate),
              maxLines: 1, style: const pw.TextStyle(fontSize: 8)),
        ),
      ],
    );

// ── ELASTIC BLANK GRID ───────────────────────────────────────
//   Fills every remaining point of vertical space with evenly
//   divided empty rows, so the table always meets the terms block.
pw.Widget _fillerGrid() => pw.CustomPaint(
      size: PdfPoint(_tableW, 0),
      painter: (canvas, size) {
        final double w = size.x;
        final double h = size.y;
        if (h <= 0.5 || w <= 0) return;

        canvas
          ..setStrokeColor(_kBorder)
          ..setLineWidth(0.6);

        // outer frame
        canvas
          ..drawRect(0, 0, w, h)
          ..strokePath();

        // horizontal dividers — as many whole rows as fit, spread evenly
        final int n = (h / _rowH).floor().clamp(1, 200);
        final double rh = h / n;
        for (int i = 1; i < n; i++) {
          canvas
            ..moveTo(0, i * rh)
            ..lineTo(w, i * rh);
        }

        // vertical dividers — same column stops as the header
        double x = _wStyle;
        canvas
          ..moveTo(x, 0)
          ..lineTo(x, h);
        for (int i = 0; i < kSizeColumns.length; i++) {
          x += _sizeColW;
          canvas
            ..moveTo(x, 0)
            ..lineTo(x, h);
        }
        x += _wQty;
        canvas
          ..moveTo(x, 0)
          ..lineTo(x, h);

        canvas.strokePath();
      },
    );

// ── TOTAL ROW ────────────────────────────────────────────────
pw.Widget _totalRow(int total) => pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: _wStyle + _wSizeArea,
          height: _totalH,
          alignment: pw.Alignment.centerRight,
          padding: const pw.EdgeInsets.only(right: 10),
          decoration: _cell,
          child: pw.Text('TOTAL QUANTITY:',
              style:
                  pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
        ),
        pw.Container(
          width: _wQty,
          height: _totalH,
          alignment: pw.Alignment.center,
          decoration: _cell,
          child: pw.Text('$total',
              style: pw.TextStyle(
                  fontSize: 11, fontWeight: pw.FontWeight.bold, color: _kRed)),
        ),
        pw.Container(width: _wRate, height: _totalH, decoration: _cell),
      ],
    );

// ── FOOTER : TERMS / ORDERED BY / SIGNATURE ──────────────────
pw.Widget _footerBlock(Map<String, dynamic> d, pw.Font italic) => pw.Container(
      width: _tableW,
      height: _footerH,
      decoration: _cell,
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // TERMS
          pw.Container(
            width: _footerTermsW,
            height: _footerH,
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: pw.BoxDecoration(
              border:
                  pw.Border(right: pw.BorderSide(width: 0.6, color: _kBorder)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text('TERMS & CONDITIONS :',
                    style: pw.TextStyle(
                      fontSize: 5.8,
                      fontWeight: pw.FontWeight.bold,
                      decoration: pw.TextDecoration.underline,
                    )),
                pw.SizedBox(height: 2),
                ...List.generate(
                  kTerms.length,
                  (i) => pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 1),
                    child: pw.Text('${i + 1}. ${kTerms[i]}',
                        maxLines: 2, style: const pw.TextStyle(fontSize: 5.2)),
                  ),
                ),
              ],
            ),
          ),
          // ORDERED BY
          pw.Container(
            width: _footerOrderedW,
            height: _footerH,
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: pw.BoxDecoration(
              border:
                  pw.Border(right: pw.BorderSide(width: 0.6, color: _kBorder)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text('Ordered by :',
                    style: pw.TextStyle(
                        fontSize: 6, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 36),
                _dots(fs: 6),
                pw.SizedBox(height: 1),
                pw.Text((d['created_by'] ?? '').toString(),
                    maxLines: 1,
                    style: pw.TextStyle(fontSize: 5.5, color: _kGrey)),
              ],
            ),
          ),
          // FOR : COMPANY
          pw.Container(
            width: _tableW - _footerTermsW - _footerOrderedW,
            height: _footerH,
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text('For : $kCompanyName',
                    maxLines: 1,
                    style: pw.TextStyle(
                        fontSize: 6,
                        fontWeight: pw.FontWeight.bold,
                        color: _kRed)),
                pw.SizedBox(height: 38),
                pw.Text('Authorized Signature',
                    style: pw.TextStyle(
                        font: italic, fontSize: 5.5, color: _kGrey)),
              ],
            ),
          ),
        ],
      ),
    );

// ─────────────────────────────────────────────────────────────
// PDF BUILD
// ─────────────────────────────────────────────────────────────
Future<Uint8List> _buildPdf(Map<String, dynamic> d) async {
  final doc = pw.Document();
  final subs = (d['subs'] is List) ? d['subs'] as List : [];
  final rows = _buildRows(subs);
  final totalQty = rows.fold<int>(0, (p, r) => p + _rowQty(r));

  final titleFont = pw.Font.timesBold();
  final italicFont = pw.Font.helveticaOblique();

  final theme = pw.PageTheme(
    pageFormat: PdfPageFormat.a4.copyWith(
      marginTop: _pageMarginV,
      marginBottom: _pageMarginV,
      marginLeft: _pageMarginH,
      marginRight: _pageMarginH,
    ),
    buildBackground: (ctx) => pw.FullPage(
      ignoreMargins: true,
      child: pw.Padding(
        padding: const pw.EdgeInsets.all(12),
        child: pw.Container(
          decoration:
              pw.BoxDecoration(border: pw.Border.all(width: 1, color: _kInk)),
        ),
      ),
    ),
  );

  if (rows.length <= _rowCapacity) {
    // ── SINGLE SHEET : blank grid stretches to the terms block ──
    doc.addPage(
      pw.Page(
        pageTheme: theme,
        build: (ctx) => pw.Column(
          mainAxisSize: pw.MainAxisSize.max,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            ..._headerWidgets(d, titleFont),
            _tableHeader(),
            ...rows.map(_itemRow),
            pw.Expanded(child: _fillerGrid()),
            _totalRow(totalQty),
            _footerBlock(d, italicFont),
          ],
        ),
      ),
    );
  } else {
    // ── OVERFLOW : spill onto continuation pages ────────────────
    doc.addPage(
      pw.MultiPage(
        pageTheme: theme,
        footer: (ctx) => pw.SizedBox(
          width: _tableW,
          height: _footerH,
          child: ctx.pageNumber == ctx.pagesCount
              ? _footerBlock(d, italicFont)
              : pw.SizedBox(),
        ),
        build: (ctx) => [
          ..._headerWidgets(d, titleFont),
          _tableHeader(),
          ...rows.map(_itemRow),
          _totalRow(totalQty),
        ],
      ),
    );
  }

  return doc.save();
}