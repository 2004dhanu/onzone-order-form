

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme.dart';
import 'api.dart';
import 'barcode_scanner_page.dart';

class OrderCreatePage extends StatefulWidget {
  const OrderCreatePage({super.key});

  @override
  State<OrderCreatePage> createState() => _OrderCreatePageState();
}

class _OrderCreatePageState extends State<OrderCreatePage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _retailerController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _gstController = TextEditingController();
  final TextEditingController _remarksController = TextEditingController();
  final TextEditingController _barcodeInputController = TextEditingController();
  int _currentStep = 0;
  List<dynamic> _localStock = [];
  bool _isLoadingStock = true;
  bool _isSubmitting = false;

  // Searched barcode state
  Map<String, dynamic>? _searchedSingleItem;
  int _searchedSingleQuantity = 1;
  List<Map<String, dynamic>> _searchedMultipleItems = [];
  final Set<String> _selectedSubBarcodes = {};
  final Map<String, int> _subBarcodeQuantities = {};
  String? _scanErrorMessage;

  // Size selection states (UI placeholders)
  final Set<String> _selectedSingleItemSizes = {};
  final Map<String, Set<String>> _subBarcodeSelectedSizes = {};

  // Added items in current order
  final List<Map<String, dynamic>> _addedItems = [];
  final FocusNode _barcodeFocusNode = FocusNode();
  
  // Global size selection states
  final Set<String> _globalSelectedShirtSizes = {};
  final Set<String> _globalSelectedPantSizes = {};
  final Set<String> _selectedOrderBarcodes = {};

  @override
  void initState() {
    super.initState();
    _loadLocalStock();
  }

  @override
  void dispose() {
    _retailerController.dispose();
    _mobileController.dispose();
    _remarksController.dispose();
    _gstController.dispose();
    _barcodeInputController.dispose();
    _barcodeFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadLocalStock() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stockStr = prefs.getString('fair_order_stock');
      if (stockStr != null) {
        final decoded = jsonDecode(stockStr);
        if (decoded is Map && decoded['data'] is List) {
          _localStock = decoded['data'];
        } else if (decoded is List) {
          _localStock = decoded;
        }
      }
    } catch (e) {
      debugPrint('Error loading stock: $e');
    } finally {
      setState(() {
        _isLoadingStock = false;
      });
    }
  }

  void _processBarcode(String barcode) {
    FocusScope.of(context).unfocus();
    setState(() {
      _searchedSingleItem = null;
      _searchedMultipleItems.clear();
      _selectedSubBarcodes.clear();
      _subBarcodeQuantities.clear();
      _scanErrorMessage = null;
    });

    final cleaned = barcode.trim();
    if (cleaned.isEmpty) return;

    // Find the item matching either full barcode or main barcode
    final matchedIndex = _localStock.indexWhere((item) =>
        item['fair_barcode'].toString().toLowerCase() == cleaned.toLowerCase() ||
        item['fair_barcode_main'].toString().toLowerCase() == cleaned.toLowerCase());

    if (matchedIndex == -1) {
      setState(() {
        _scanErrorMessage = 'Barcode "$barcode" not found in local stock.';
      });
      return;
    }

    final matchedItem = _localStock[matchedIndex];
    final String type = matchedItem['fair_barcode_type']?.toString().toUpperCase() ?? 'S';

    if (type == 'S') {
      setState(() {
        _searchedSingleItem = Map<String, dynamic>.from(matchedItem);
        _searchedSingleQuantity = 1;
      });
    } else {
      // Type is M (Multiple options)
      final String mainBarcode = matchedItem['fair_barcode_main']?.toString() ?? '';
      
      final List<Map<String, dynamic>> subItems = _localStock
          .where((item) => item['fair_barcode_main']?.toString() == mainBarcode)
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      if (subItems.isEmpty) {
        setState(() {
          _scanErrorMessage = 'No sub-barcodes found for main barcode "$mainBarcode".';
        });
        return;
      }

      setState(() {
        _searchedMultipleItems = subItems;
        for (var sub in subItems) {
          final subBarcode = sub['fair_barcode']?.toString() ?? '';
          _subBarcodeQuantities[subBarcode] = 1;
        }
      });
      _showMultipleItemsPopup();
    }
  }

  void _addSingleToOrder() {
    if (_searchedSingleItem == null) return;
    
    final item = _searchedSingleItem!;
    final barcode = item['fair_barcode']?.toString() ?? '';
    final stock = item['stock'] ?? 0;
    
    if (stock <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot add: This item is out of stock!')),
      );
      return;
    }

    // Check if already exists in order, if so update quantity
    final existingIdx = _addedItems.indexWhere((element) => element['fair_order_sub_barcode'] == barcode);
    if (existingIdx != -1) {
      final currentQty = _addedItems[existingIdx]['fair_order_sub_quantity'] as int;
      if (currentQty + _searchedSingleQuantity <= stock) {
        setState(() {
          _addedItems[existingIdx]['fair_order_sub_quantity'] += _searchedSingleQuantity;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot add: Total quantity will exceed available stock of $stock'),
            duration: const Duration(seconds: 2),
          ),
        );
        return;
      }
    } else {
      setState(() {
        _addedItems.add({
          'fair_order_sub_barcode_main': item['fair_barcode_main'],
          'fair_order_sub_barcode': barcode,
          'fair_order_sub_mrp': item['fair_mrp'],
          'fair_order_sub_quantity': _searchedSingleQuantity,
          'fair_order_sub_barcode_type': 'S',
          'stock': stock,
          'fair_order_sub_dress_type': item['fair_dress_type'],
          'sizes': <String>{},
        });
      });
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added barcode $barcode to order.')),
    );

    setState(() {
      _searchedSingleItem = null;
      _selectedSingleItemSizes.clear();
      _barcodeInputController.clear();
    });
  }

  void _addMultipleToOrder() {
    if (_selectedSubBarcodes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one sub-barcode.')),
      );
      return;
    }

    // Validate that none of the selected options are out of stock
    for (var barcode in _selectedSubBarcodes) {
      final sub = _searchedMultipleItems.firstWhere(
        (element) => element['fair_barcode']?.toString() == barcode,
        orElse: () => {},
      );
      final stock = sub['stock'] ?? 0;
      if (stock <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot add: Option $barcode is out of stock!')),
        );
        return;
      }
    }

    int addedCount = 0;    for (var sub in _searchedMultipleItems) {
      final barcode = sub['fair_barcode']?.toString() ?? '';
      if (_selectedSubBarcodes.contains(barcode)) {
        final qty = _subBarcodeQuantities[barcode] ?? 1;
        
        final existingIdx = _addedItems.indexWhere((element) => element['fair_order_sub_barcode'] == barcode);
        if (existingIdx != -1) {
          final currentQty = _addedItems[existingIdx]['fair_order_sub_quantity'] as int;
          final stock = sub['stock'] ?? 0;
          if (currentQty + qty <= stock) {
            setState(() {
              _addedItems[existingIdx]['fair_order_sub_quantity'] += qty;
              final currentSizes = _addedItems[existingIdx]['sizes'] as Set<String>? ?? {};
              currentSizes.addAll(_subBarcodeSelectedSizes[barcode] ?? {});
              _addedItems[existingIdx]['sizes'] = currentSizes;
            });
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Cannot add $barcode: Total quantity will exceed available stock of $stock'),
                duration: const Duration(seconds: 2),
              ),
            );
            return;
          }
        } else {
          setState(() {
            _addedItems.add({
              'fair_order_sub_barcode_main': sub['fair_barcode_main'],
              'fair_order_sub_barcode': barcode,
              'fair_order_sub_mrp': sub['fair_mrp'],
              'fair_order_sub_quantity': qty,
              'fair_order_sub_barcode_type': 'M',
              'fair_colour': sub['fair_colour'],
              'stock': sub['stock'] ?? 0,
              'fair_order_sub_dress_type': sub['fair_dress_type'],
              'sizes': Set<String>.from(_subBarcodeSelectedSizes[barcode] ?? {}),
            });
          });
        }
        addedCount++;
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added $addedCount items to order.')),
    );

    setState(() {
      _searchedMultipleItems.clear();
      _selectedSubBarcodes.clear();
      _subBarcodeQuantities.clear();
      _subBarcodeSelectedSizes.clear();
      _barcodeInputController.clear();
    });
  }

  Future<void> _submitOrder() async {
    if (_addedItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please add at least one barcode to the order')),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');

      final payload = {
        'fair_order_retailer': _retailerController.text.trim(),
        'fair_order_retailer_mobile': _mobileController.text.trim(),
        'fair_order_remarks': _remarksController.text.trim(),
        'fair_order_gst_no': _gstController.text.trim(),
        'subs': _addedItems.map((item) => {
          'fair_order_sub_barcode_main': item['fair_order_sub_barcode_main'],
          'fair_order_sub_barcode': item['fair_order_sub_barcode'],
          'fair_order_sub_mrp': item['fair_order_sub_mrp'],
          'fair_order_sub_quantity': item['fair_order_sub_quantity'],
          'fair_order_sub_barcode_type': item['fair_order_sub_barcode_type'],
          'fair_order_sub_dress_type': item['fair_order_sub_dress_type'] ?? '',
          'fair_order_sub_dress_size': (item['sizes'] as Set<String>?)?.join(', ') ?? '',
        }).toList(),
      };

      final response = await http.post(
        Uri.parse('$baseUrl/faircreateOrderForm'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        // Fetch the updated stock and overwrite local cache
        await fetchAndCacheStock();

        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green),
                  SizedBox(width: 8),
                  Text('Success'),
                ],
              ),
              content: const Text('Order created successfully!'),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context); // Pop dialog
                    Navigator.pop(context, true); // Pop page returning true to refresh
                  },
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      } else {
        if (!mounted) return;
        String errorMsg = 'Failed to create order';
        try {
          final decoded = jsonDecode(response.body);
          errorMsg = decoded['message'] ?? decoded['error'] ?? response.body;
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $errorMsg')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connection error: $e')),
      );
    } finally {
      setState(() {
        _isSubmitting = false;
      });
    }
  }

  void _nextStep() {
    if (_formKey.currentState?.validate() ?? false) {
      setState(() {
        _currentStep = 1;
      });
    }
  }

  Future<void> _startBarcodeScan() async {
    FocusScope.of(context).unfocus();
    final scannedList = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (context) => const BarcodeScannerPage()),
    );

    if (scannedList != null && scannedList.isNotEmpty) {
      _addScannedBarcodes(scannedList);
    }
  }

  void _addScannedBarcodes(List<String> barcodes) {
    int addedCount = 0;
    List<String> notFound = [];
    List<String> outOfStock = [];

    for (var barcode in barcodes) {
      final cleaned = barcode.trim();
      if (cleaned.isEmpty) continue;

      // Find the item matching either full barcode or main barcode
      final matchedIndex = _localStock.indexWhere((item) =>
          item['fair_barcode'].toString().toLowerCase() == cleaned.toLowerCase());

      if (matchedIndex == -1) {
        // Try matching by main style barcode (in case they scanned main code)
        final mainIdx = _localStock.indexWhere((item) =>
            item['fair_barcode_main'].toString().toLowerCase() == cleaned.toLowerCase());
        
        if (mainIdx == -1) {
          notFound.add(cleaned);
          continue;
        }

        final matchedItem = _localStock[mainIdx];
        final String type = matchedItem['fair_barcode_type']?.toString().toUpperCase() ?? 'S';
        if (type == 'M') {
          // If they scanned main style barcode, launch standard selection popup dialog for this style
          _processBarcode(cleaned);
        } else {
          // Single item matches main style
          final stock = matchedItem['stock'] ?? 0;
          if (stock <= 0) {
            outOfStock.add(cleaned);
          } else {
            _addSingleItemToOrderList(matchedItem);
            addedCount++;
          }
        }
        continue;
      }

      final matchedItem = _localStock[matchedIndex];
      final stock = matchedItem['stock'] ?? 0;
      if (stock <= 0) {
        outOfStock.add(cleaned);
        continue;
      }

      final barcodeVal = matchedItem['fair_barcode']?.toString() ?? '';
      final type = matchedItem['fair_barcode_type']?.toString().toUpperCase() ?? 'S';

      final existingIdx = _addedItems.indexWhere((element) => element['fair_order_sub_barcode'] == barcodeVal);
      if (existingIdx != -1) {
        final currentQty = _addedItems[existingIdx]['fair_order_sub_quantity'] as int;
        if (currentQty < stock) {
          setState(() {
            _addedItems[existingIdx]['fair_order_sub_quantity'] += 1;
          });
          addedCount++;
        } else {
          outOfStock.add(cleaned);
        }
      } else {
        setState(() {
          _addedItems.add({
            'fair_order_sub_barcode_main': matchedItem['fair_barcode_main'],
            'fair_order_sub_barcode': barcodeVal,
            'fair_order_sub_mrp': matchedItem['fair_mrp'],
            'fair_order_sub_quantity': 1,
            'fair_order_sub_barcode_type': type,
            'stock': stock,
            'fair_order_sub_dress_type': matchedItem['fair_dress_type'],
            'sizes': <String>{},
          });
        });
      }
      addedCount++;
    }

    if (addedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $addedCount item(s) to order.')),
      );
    }
    if (notFound.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Barcodes not found: ${notFound.join(", ")}'),
          backgroundColor: const Color(0xFF202C4D),
        ),
      );
    }
    if (outOfStock.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Items out of stock: ${outOfStock.join(", ")}'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  void _addSingleItemToOrderList(Map<String, dynamic> item) {
    final barcode = item['fair_barcode']?.toString() ?? '';
    final stock = item['stock'] ?? 0;
    final existingIdx = _addedItems.indexWhere((element) => element['fair_order_sub_barcode'] == barcode);
    if (existingIdx != -1) {
      final currentQty = _addedItems[existingIdx]['fair_order_sub_quantity'] as int;
      if (currentQty < stock) {
        setState(() {
          _addedItems[existingIdx]['fair_order_sub_quantity'] += 1;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot add: Total quantity will exceed available stock of $stock'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } else {
      setState(() {
        _addedItems.add({
          'fair_order_sub_barcode_main': item['fair_barcode_main'],
          'fair_order_sub_barcode': barcode,
          'fair_order_sub_mrp': item['fair_mrp'],
          'fair_order_sub_quantity': 1,
          'fair_order_sub_barcode_type': 'S',
          'stock': stock,
          'fair_order_sub_dress_type': item['fair_dress_type'],
          'sizes': <String>{},
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = AppTheme.primaryColor;

    return Scaffold(
      backgroundColor: AppTheme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Create Order', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: primaryColor,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: _isLoadingStock
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
              ),
            )
          : Stack(
              children: [
                Column(
                  children: [
                    // Step indicators
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildStepIndicator(0, 'Retailer Info'),
                          Container(
                            width: 50,
                            height: 2,
                            color: _currentStep >= 1 ? primaryColor : Colors.grey.shade300,
                          ),
                          _buildStepIndicator(1, 'Items & Scanning'),
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    // Main Step Body
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: _currentStep == 0 ? _buildStep1Form() : _buildStep2Scanning(),
                      ),
                    ),
                  ],
                ),
                if (_isSubmitting)
                  Container(
                    color: Colors.black.withValues(alpha: 0.5),
                    child: const Center(
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildStepIndicator(int stepIndex, String title) {
    final isActive = _currentStep == stepIndex;
    final isDone = _currentStep > stepIndex;
    const primaryColor = AppTheme.primaryColor;

    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDone ? Colors.green : (isActive ? primaryColor : Colors.grey.shade300),
          ),
          child: Center(
            child: isDone
                ? const Icon(Icons.check, color: Colors.white, size: 16)
                : Text(
                    '${stepIndex + 1}',
                    style: TextStyle(
                      color: isActive || isDone ? Colors.white : Colors.grey.shade600,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            color: isActive ? primaryColor : (isDone ? Colors.green : Colors.grey.shade600),
            fontWeight: isActive || isDone ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildStep1Form() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Step 1: Retailer Details',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter the store name, contact number, and optional remarks for this order request.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),
            const SizedBox(height: 30),

            // Retailer Name
            TextFormField(
              controller: _retailerController,
              decoration: InputDecoration(
                labelText: 'Retailer Name',
                prefixIcon: const Icon(Icons.store, color: AppTheme.primaryColor),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter retailer name';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),

            // Retailer Mobile
            TextFormField(
              controller: _mobileController,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Retailer Mobile',
                prefixIcon: const Icon(Icons.phone, color: AppTheme.primaryColor),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter mobile number';
                }
                if (value.trim().length < 10) {
                  return 'Please enter a valid mobile number';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),

            // GST Number
            TextFormField(
              controller: _gstController,
              decoration: InputDecoration(
                labelText: 'GST Number (Optional)',
                prefixIcon: const Icon(Icons.receipt, color: AppTheme.primaryColor),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 20),

            // Remarks
            TextFormField(
              controller: _remarksController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Remarks / Notes (Optional)',
                prefixIcon: const Icon(Icons.rate_review, color: AppTheme.primaryColor),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 40),

            ElevatedButton(
              onPressed: _nextStep,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Next Step', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep2Scanning() {
    return Column(
      children: [
        // Barcode Entry Header
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      focusNode: _barcodeFocusNode,
                      controller: _barcodeInputController,
                      decoration: InputDecoration(
                        hintText: 'Enter barcode number...',
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => _barcodeInputController.clear(),
                        ),
                      ),
                      onSubmitted: (value) => _processBarcode(value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => _processBarcode(_barcodeInputController.text),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      backgroundColor: Colors.grey.shade800,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Verify'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _startBarcodeScan,
                icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
                label: const Text('Open Mobile Camera Scanner'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),

        // Display results of scanning / manual verification
        if (_scanErrorMessage != null)
          Container(
            color: Colors.red.shade50,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              _scanErrorMessage!,
              style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w500),
            ),
          ),

        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                // Render matched Single item
                if (_searchedSingleItem != null) _buildSingleItemCard(),

                // Header for added items
                if (_addedItems.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 16, right: 16, top: 24, bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Items in Order (${_addedItems.length})',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                        ),
                        Text(
                          'Total Qty: ${_addedItems.fold<int>(0, (sum, item) => sum + (item['fair_order_sub_quantity'] as int))}',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
                        ),
                      ],
                    ),
                  ),
                  _buildAddedItemsList(),
                ],
              ],
            ),
          ),
        ),

        // Final Submit Bar
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _retailerController.text,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${_addedItems.length} unique barcode(s) added',
                            style: const TextStyle(color: Colors.grey, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    if (_addedItems.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _showGlobalSizesDialog,
                        icon: const Icon(Icons.checkroom, size: 14),
                        label: Text(
                          _selectedOrderBarcodes.isEmpty
                              ? 'Select Sizes'
                              : 'Sizes (${_selectedOrderBarcodes.length})',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          foregroundColor: AppTheme.primaryColor,
                          side: const BorderSide(color: AppTheme.primaryColor),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _addedItems.isEmpty ? null : _submitOrder,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Create Order', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showSizesDialog({
    required BuildContext context,
    required String title,
    required String? dressType,
    required Set<String> selectedSizes,
    required Function(VoidCallback) setParentState,
  }) {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            List<String> sizes = ['S', 'M', 'L', 'XL', 'XXL'];
            if (dressType != null) {
              final cleanType = dressType.trim().toUpperCase();
              if (cleanType == 'S') {
                sizes = ['S-36', 'M-38', 'L-40', 'XL-42', '2XL-44', '3XL-46', '4XL-48', '5XL-50'];
              } else if (cleanType == 'P') {
                sizes = ['28', '30', '32', '34', '36', '38', '40', '42', '44'];
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text('Select Sizes - $title', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              content: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: sizes.map((size) {
                    final isSelected = selectedSizes.contains(size);
                    return GestureDetector(
                      onTap: () {
                        setDialogState(() {
                          if (isSelected) {
                            selectedSizes.remove(size);
                          } else {
                            selectedSizes.add(size);
                          }
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected ? AppTheme.primaryColor : Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected ? AppTheme.primaryColor : Colors.grey.shade300,
                          ),
                        ),
                        child: Text(
                          size,
                          style: TextStyle(
                            color: isSelected ? Colors.white : Colors.black87,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    setParentState(() {});
                  },
                  child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showGlobalSizesDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final List<String> shirtSizes = ['S-36', 'M-38', 'L-40', 'XL-42', '2XL-44', '3XL-46', '4XL-48', '5XL-50'];
            final List<String> pantSizes = ['28', '30', '32', '34', '36', '38', '40', '42', '44'];

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('Global Size Selection', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Shirt Sizes (S)',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: shirtSizes.map((size) {
                          final isSelected = _globalSelectedShirtSizes.contains(size);
                          return GestureDetector(
                            onTap: () {
                              setDialogState(() {
                                if (isSelected) {
                                  _globalSelectedShirtSizes.remove(size);
                                } else {
                                  _globalSelectedShirtSizes.add(size);
                                }
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: isSelected ? AppTheme.primaryColor : Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected ? AppTheme.primaryColor : Colors.grey.shade300,
                                ),
                              ),
                              child: Text(
                                size,
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const Divider(height: 24),
                      const Text(
                        'Pant Sizes (P)',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: pantSizes.map((size) {
                          final isSelected = _globalSelectedPantSizes.contains(size);
                          return GestureDetector(
                            onTap: () {
                              setDialogState(() {
                                if (isSelected) {
                                  _globalSelectedPantSizes.remove(size);
                                } else {
                                  _globalSelectedPantSizes.add(size);
                                }
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: isSelected ? AppTheme.primaryColor : Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected ? AppTheme.primaryColor : Colors.grey.shade300,
                                ),
                              ),
                              child: Text(
                                size,
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.black87,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      // Apply sizes to target items
                      final targets = _selectedOrderBarcodes.isNotEmpty
                          ? _addedItems.where((item) => _selectedOrderBarcodes.contains(item['fair_order_sub_barcode']))
                          : _addedItems;

                      for (var item in targets) {
                        final dressType = item['fair_order_sub_dress_type']?.toString().trim().toUpperCase() ?? '';
                        if (dressType == 'S') {
                          item['sizes'] = Set<String>.from(_globalSelectedShirtSizes);
                        } else if (dressType == 'P') {
                          item['sizes'] = Set<String>.from(_globalSelectedPantSizes);
                        }
                      }
                      
                      // Clear selected cards and global sets
                      _selectedOrderBarcodes.clear();
                      _globalSelectedShirtSizes.clear();
                      _globalSelectedPantSizes.clear();
                    });
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Selected sizes applied successfully.')),
                    );
                  },
                  child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSingleItemCard() {
    final item = _searchedSingleItem!;
    final stock = item['stock'] ?? 0;
    final isOutOfStock = stock <= 0;

    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade100, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Single Product Found',
                  style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.primaryColor, fontSize: 13),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isOutOfStock ? Colors.red.shade50 : Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isOutOfStock ? Colors.red.shade100 : Colors.blue.shade100,
                      width: 1,
                    ),
                  ),
                  child: Text(
                    isOutOfStock ? 'Out of Stock' : 'Stock: $stock',
                    style: TextStyle(
                      fontSize: 11, 
                      fontWeight: FontWeight.bold, 
                      color: isOutOfStock ? Colors.red.shade800 : Colors.blue.shade800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              item['fair_barcode'] ?? '',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Style: ${item['fair_barcode_main']}',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13, fontWeight: FontWeight.w500),
                ),
                Text(
                  'MRP: ₹${item['fair_mrp'] ?? 'N/A'}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black87),
                ),
              ],
            ),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Order Quantity:',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                ),
                Row(
                  children: [
                    GestureDetector(
                      onTap: isOutOfStock
                          ? null
                          : () {
                              if (_searchedSingleQuantity > 1) {
                                setState(() {
                                  _searchedSingleQuantity--;
                                });
                              }
                            },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.grey.shade50,
                          border: Border.all(color: isOutOfStock ? Colors.grey.shade200 : Colors.grey.shade300),
                        ),
                        child: Icon(
                          Icons.remove, 
                          size: 14, 
                          color: isOutOfStock ? Colors.grey.shade300 : Colors.black87,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Text(
                        isOutOfStock ? '0' : '$_searchedSingleQuantity',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: isOutOfStock ? Colors.grey : Colors.black87,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: isOutOfStock
                          ? null
                          : () {
                              if (_searchedSingleQuantity < stock) {
                                setState(() {
                                  _searchedSingleQuantity++;
                                });
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Cannot exceed available stock of $stock'),
                                    duration: const Duration(seconds: 1),
                                  ),
                                );
                              }
                            },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.grey.shade50,
                          border: Border.all(color: isOutOfStock ? Colors.grey.shade200 : Colors.grey.shade300),
                        ),
                        child: Icon(
                          Icons.add, 
                          size: 14, 
                          color: isOutOfStock ? Colors.grey.shade300 : Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: isOutOfStock ? null : _addSingleToOrder,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                backgroundColor: isOutOfStock ? Colors.grey.shade200 : AppTheme.primaryColor,
                foregroundColor: isOutOfStock ? Colors.grey.shade400 : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: Text(
                isOutOfStock ? 'Out of Stock' : 'Add to Order List',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showMultipleItemsPopup() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setPopupState) {
            final firstItem = _searchedMultipleItems.first;
            final primaryColor = AppTheme.primaryColor;

            return Dialog.fullscreen(
              child: Scaffold(
                backgroundColor: AppTheme.scaffoldBackgroundColor,
                appBar: AppBar(
                  title: Text(
                    'Options: ${firstItem['fair_barcode_main']}',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  backgroundColor: primaryColor,
                  iconTheme: const IconThemeData(color: Colors.white),
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      Navigator.pop(context);
                      setState(() {
                        _searchedMultipleItems.clear();
                        _selectedSubBarcodes.clear();
                        _subBarcodeQuantities.clear();
                        _barcodeInputController.clear();
                      });
                    },
                  ),
                ),
                body: Column(
                  children: [
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Select Sub-Barcodes to add:',
                            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                          Text(
                            '${_selectedSubBarcodes.length} selected',
                            style: TextStyle(color: primaryColor, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: StatefulBuilder(
                        builder: (context, setPopupStateInner) {
                          final inStockSubItems = _searchedMultipleItems
                              .where((sub) => (sub['stock'] ?? 0) > 0)
                              .toList();

                          if (inStockSubItems.isEmpty) {
                            return Center(
                              child: Text(
                                'All sub-barcodes are out of stock.',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            );
                          }

                          return GridView.builder(
                            padding: const EdgeInsets.all(8),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 6,
                              mainAxisSpacing: 6,
                              childAspectRatio: 2.2,
                            ),
                            itemCount: inStockSubItems.length,
                            itemBuilder: (context, index) {
                              final sub = inStockSubItems[index];
                              final barcode = sub['fair_barcode']?.toString() ?? '';
                              final isSelected = _selectedSubBarcodes.contains(barcode);
                              final qty = _subBarcodeQuantities[barcode] ?? 1;
                              final stock = sub['stock'] ?? 0;
                              final colorVal = sub['fair_colour']?.toString() ?? 'No Color';

                              return GestureDetector(
                                onTap: () {
                                  setPopupState(() {
                                    if (isSelected) {
                                      _selectedSubBarcodes.remove(barcode);
                                    } else {
                                      _selectedSubBarcodes.add(barcode);
                                    }
                                  });
                                },
                                child: Card(
                                  elevation: isSelected ? 1 : 0.5,
                                  margin: EdgeInsets.zero,
                                  color: isSelected ? primaryColor : null,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: isSelected ? primaryColor : Colors.grey.shade200,
                                      width: isSelected ? 1.5 : 0,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: isSelected
                                        ? const EdgeInsets.only(left: 8.0, top: 4.0, bottom: 4.0, right: 6.0)
                                        : const EdgeInsets.symmetric(horizontal: 10.0, vertical: 6.0),
                                    child: isSelected
                                        ? Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  mainAxisSize: MainAxisSize.min,
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    Text(
                                                      colorVal,
                                                      style: const TextStyle(
                                                        fontWeight: FontWeight.bold,
                                                        fontSize: 15,
                                                        color: Colors.white,
                                                      ),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '(S: $stock)',
                                                      style: const TextStyle(
                                                        fontSize: 11,
                                                        color: Colors.white70,
                                                        fontWeight: FontWeight.bold,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  GestureDetector(
                                                    behavior: HitTestBehavior.opaque,
                                                    onTap: () {
                                                      if (qty > 1) {
                                                        setPopupState(() {
                                                          _subBarcodeQuantities[barcode] = qty - 1;
                                                        });
                                                      }
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.all(3),
                                                      decoration: BoxDecoration(
                                                        shape: BoxShape.circle,
                                                        border: Border.all(color: Colors.white54, width: 0.8),
                                                      ),
                                                      child: const Icon(
                                                        Icons.remove,
                                                        size: 11,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  Padding(
                                                    padding: const EdgeInsets.symmetric(horizontal: 6),
                                                    child: Text(
                                                      '$qty',
                                                      style: const TextStyle(
                                                        fontWeight: FontWeight.bold,
                                                        fontSize: 17,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                  GestureDetector(
                                                    behavior: HitTestBehavior.opaque,
                                                    onTap: () {
                                                      if (qty < stock) {
                                                        setPopupState(() {
                                                          _subBarcodeQuantities[barcode] = qty + 1;
                                                        });
                                                      } else {
                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                          SnackBar(
                                                            content: Text('Cannot exceed available stock of $stock'),
                                                            duration: const Duration(seconds: 1),
                                                          ),
                                                        );
                                                      }
                                                    },
                                                    child: Container(
                                                      padding: const EdgeInsets.all(3),
                                                      decoration: BoxDecoration(
                                                        shape: BoxShape.circle,
                                                        border: Border.all(color: Colors.white54, width: 0.8),
                                                      ),
                                                      child: const Icon(
                                                        Icons.add,
                                                        size: 11,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          )
                                        : Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                colorVal,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16,
                                                  color: Colors.black87,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '(S: $stock)',
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.grey.shade700,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
                bottomNavigationBar: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, -2),
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    onPressed: _selectedSubBarcodes.isEmpty
                        ? null
                        : () {
                            _addMultipleToOrder();
                            Navigator.pop(context);
                          },
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                      backgroundColor: primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Add Selected Options', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAddedItemsList() {
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _addedItems.length,
      itemBuilder: (context, index) {
        final item = _addedItems[index];
        final barcode = item['fair_order_sub_barcode']?.toString() ?? '';
        final isCardSelected = _selectedOrderBarcodes.contains(barcode);

        return GestureDetector(
          onTap: () {
            setState(() {
              if (isCardSelected) {
                _selectedOrderBarcodes.remove(barcode);
              } else {
                _selectedOrderBarcodes.add(barcode);
              }
            });
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isCardSelected ? AppTheme.primaryColor : Colors.grey.shade200,
                width: isCardSelected ? 2 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
              child: Row(
                children: [
                  // 1. Barcode and Stock
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          item['fair_order_sub_barcode'],
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '(S - ${item['stock'] ?? 0})',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),

                  // 2. Sizes Selector
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      final Set<String> currentSizes = Set<String>.from(item['sizes'] ?? {});
                      _showSizesDialog(
                        context: context,
                        title: item['fair_order_sub_barcode'],
                        dressType: item['fair_order_sub_dress_type'],
                        selectedSizes: currentSizes,
                        setParentState: (fn) {
                          setState(() {
                            fn();
                            item['sizes'] = currentSizes;
                          });
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            _barcodeFocusNode.unfocus();
                          });
                        },
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.checkroom, size: 12, color: Colors.black54),
                          const SizedBox(width: 3),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 80),
                            child: Text(
                              (item['sizes'] as Set<String>?) == null || (item['sizes'] as Set<String>).isEmpty
                                  ? 'Sizes'
                                  : (item['sizes'] as Set<String>).join(","),
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // 3. Quantity Stepper
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          final currentQty = item['fair_order_sub_quantity'] as int;
                          if (currentQty > 1) {
                            setState(() {
                              item['fair_order_sub_quantity'] = currentQty - 1;
                            });
                          } else {
                            setState(() {
                              _selectedOrderBarcodes.remove(barcode);
                              _addedItems.removeAt(index);
                            });
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.grey.shade100,
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: const Icon(Icons.remove, size: 12, color: Colors.black87),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: SizedBox(
                          width: 18,
                          child: Text(
                            '${item['fair_order_sub_quantity']}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Colors.black87,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          final currentQty = item['fair_order_sub_quantity'] as int;
                          final stock = item['stock'] as int? ?? 0;
                          if (currentQty < stock) {
                            setState(() {
                              item['fair_order_sub_quantity'] = currentQty + 1;
                            });
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Cannot exceed available stock of $stock'),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.grey.shade100,
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: const Icon(Icons.add, size: 12, color: Colors.black87),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 4),

                  // 4. Delete/Trash Button
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18),
                    onPressed: () {
                      setState(() {
                        _selectedOrderBarcodes.remove(barcode);
                        _addedItems.removeAt(index);
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
