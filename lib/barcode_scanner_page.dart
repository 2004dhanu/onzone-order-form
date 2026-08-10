import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class BarcodeScannerPage extends StatefulWidget {
  const BarcodeScannerPage({super.key});

  @override
  State<BarcodeScannerPage> createState() => _BarcodeScannerPageState();
}

class _BarcodeScannerPageState extends State<BarcodeScannerPage> {
  final MobileScannerController controller = MobileScannerController();
  final List<String> _scannedBarcodes = [];
  final Map<String, DateTime> _lastScannedTimes = {};
  String? _latestDetectedBarcode;

  // Flashlight and camera state
  bool _isTorchOn = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _captureBarcode() {
    if (_latestDetectedBarcode != null) {
      _onBarcodeDetected(_latestDetectedBarcode!);
      setState(() {
        _latestDetectedBarcode = null; // Clear focus after scanning
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please align a barcode in the viewfinder first.'),
          duration: Duration(milliseconds: 1000),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _onBarcodeDetected(String barcode) {
    final cleaned = barcode.trim();
    if (cleaned.isEmpty) return;

    final now = DateTime.now();
    final lastTime = _lastScannedTimes[cleaned];

    // Throttle duplicate scans of the exact same barcode for 1.5 seconds
    if (lastTime != null && now.difference(lastTime).inMilliseconds < 1500) {
      return;
    }

    _lastScannedTimes[cleaned] = now;

    // Trigger haptic feedback
    HapticFeedback.lightImpact();

    setState(() {
      _scannedBarcodes.add(cleaned);
    });

    // Show a temporary Toast/SnackBar overlay
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Scanned: $cleaned'),
        duration: const Duration(milliseconds: 600),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Continuous Scan', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: Icon(_isTorchOn ? Icons.flash_on : Icons.flash_off, color: Colors.white),
            onPressed: () {
              controller.toggleTorch();
              setState(() {
                _isTorchOn = !_isTorchOn;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.switch_camera, color: Colors.white),
            onPressed: () => controller.switchCamera(),
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Camera scanner viewport
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                MobileScanner(
                  controller: controller,
                  onDetect: (capture) {
                    final List<Barcode> barcodes = capture.barcodes;
                    if (barcodes.isNotEmpty) {
                      final barcode = barcodes.first;
                      if (barcode.rawValue != null) {
                        setState(() {
                          _latestDetectedBarcode = barcode.rawValue!;
                        });
                      }
                    }
                  },
                ),
                // Scanner viewfinder guide overlay
                Center(
                  child: Container(
                    width: 260,
                    height: 180,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _latestDetectedBarcode != null ? Colors.green : primaryColor,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      color: Colors.transparent,
                    ),
                  ),
                ),
                // Capture Barcode Button and Status Banner
                Positioned(
                  bottom: 24,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Visual feedback status banner
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _latestDetectedBarcode != null
                                ? 'Ready: $_latestDetectedBarcode'
                                : 'Align barcode in box',
                            style: TextStyle(
                              color: _latestDetectedBarcode != null ? Colors.green.shade400 : Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Shutter button for capture
                        GestureDetector(
                          onTap: _captureBarcode,
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.9),
                              border: Border.all(
                                color: _latestDetectedBarcode != null ? Colors.green : Colors.grey.shade400,
                                width: 4,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: (_latestDetectedBarcode != null ? Colors.green : Colors.black).withValues(alpha: 0.2),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Center(
                              child: Icon(
                                Icons.qr_code_scanner,
                                color: _latestDetectedBarcode != null ? Colors.green.shade700 : Colors.grey.shade600,
                                size: 32,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 2. Scanned items list and action panel
          Expanded(
            flex: 3,
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(24),
                  topRight: Radius.circular(24),
                ),
              ),
              child: Column(
                children: [
                  // Panel Header
                  Padding(
                    padding: const EdgeInsets.only(left: 20, right: 20, top: 16, bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Scanned Barcodes (${_scannedBarcodes.length})',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87),
                        ),
                        if (_scannedBarcodes.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _scannedBarcodes.clear();
                              });
                            },
                            child: Text(
                              'Clear All',
                              style: TextStyle(color: Colors.red.shade600, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // Scanned Chips View
                  Expanded(
                    child: _scannedBarcodes.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.qr_code_scanner, color: Colors.grey.shade300, size: 40),
                                const SizedBox(height: 8),
                                Text(
                                  'Aim at a barcode, then tap the Scan button',
                                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            itemCount: _scannedBarcodes.length,
                            itemBuilder: (context, index) {
                              final barcode = _scannedBarcodes[index];
                              return Card(
                                elevation: 0,
                                color: Colors.grey.shade50,
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(color: Colors.grey.shade100),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.inventory, size: 16, color: primaryColor.withValues(alpha: 0.8)),
                                          const SizedBox(width: 10),
                                          Text(
                                            barcode,
                                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                                          ),
                                        ],
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.remove_circle, color: Colors.redAccent, size: 20),
                                        onPressed: () {
                                          setState(() {
                                            _scannedBarcodes.removeAt(index);
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),

                  // Confirm button
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: ElevatedButton(
                      onPressed: _scannedBarcodes.isEmpty
                          ? null
                          : () {
                              Navigator.pop(context, _scannedBarcodes);
                            },
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        backgroundColor: primaryColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: Text(
                        'Add Scanned Barcodes (${_scannedBarcodes.length})',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
