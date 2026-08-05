import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme.dart';
import 'api.dart';
import 'barcode_scanner_page.dart';

class OrderEditPage extends StatefulWidget {
  final Map<String, dynamic> orderData;
  const OrderEditPage({super.key, required this.orderData});

  @override
  State<OrderEditPage> createState() => _OrderEditPageState();
}

class _OrderEditPageState extends State<OrderEditPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _retailerController;
  late TextEditingController _mobileController;
  late TextEditingController _remarksController;
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

  // Added items in current order
  final List<Map<String, dynamic>> _addedItems = [];

  @override
  void initState() {
    super.initState();
    _retailerController = TextEditingController(text: widget.orderData['fair_order_retailer']);
    _mobileController = TextEditingController(text: widget.orderData['fair_order_retailer_mobile']);
    _remarksController = TextEditingController(text: widget.orderData['fair_order_remarks'] ?? '');
    _loadLocalStockAndPrepopulate();
  }

  @override
  void dispose() {
    _retailerController.dispose();
    _mobileController.dispose();
    _remarksController.dispose();
    _barcodeInputController.dispose();
    super.dispose();
  }

  Future<void> _loadLocalStockAndPrepopulate() async {
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

      // Prepopulate existing items in the order
      final List<dynamic> subs = widget.orderData['subs'] ?? [];
      for (var sub in subs) {
        final barcode = sub['fair_order_sub_barcode']?.toString() ?? '';
        
        // Try to find available stock from local database
        final stockIdx = _localStock.indexWhere((element) => element['fair_barcode']?.toString() == barcode);
        final int stock = stockIdx != -1 ? (_localStock[stockIdx]['stock'] ?? 0) : 0;

        _addedItems.add({
          'id': sub['id'], // Database ID of the order sub-item
          'fair_order_sub_barcode_main': sub['fair_order_sub_barcode_main'],
          'fair_order_sub_barcode': barcode,
          'fair_order_sub_mrp': sub['fair_order_sub_mrp'],
          'fair_order_sub_quantity': int.tryParse(sub['fair_order_sub_quantity'].toString()) ?? 1,
          'fair_order_sub_barcode_type': sub['fair_order_sub_barcode_type'],
          'stock': stock,
        });
      }
    } catch (e) {
      debugPrint('Error loading stock or prepopulating: $e');
    } finally {
      setState(() {
        _isLoadingStock = false;
      });
    }
  }

  void _processBarcode(String barcode) {
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
      setState(() {
        _addedItems[existingIdx]['fair_order_sub_quantity'] += _searchedSingleQuantity;
      });
    } else {
      setState(() {
        _addedItems.add({
          'id': null, // Newly added in this edit session
          'fair_order_sub_barcode_main': item['fair_barcode_main'],
          'fair_order_sub_barcode': barcode,
          'fair_order_sub_mrp': item['fair_mrp'],
          'fair_order_sub_quantity': _searchedSingleQuantity,
          'fair_order_sub_barcode_type': 'S',
          'stock': stock,
        });
      });
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added barcode $barcode to order.')),
    );

    setState(() {
      _searchedSingleItem = null;
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

    int addedCount = 0;
    for (var sub in _searchedMultipleItems) {
      final barcode = sub['fair_barcode']?.toString() ?? '';
      if (_selectedSubBarcodes.contains(barcode)) {
        final qty = _subBarcodeQuantities[barcode] ?? 1;
        
        final existingIdx = _addedItems.indexWhere((element) => element['fair_order_sub_barcode'] == barcode);
        if (existingIdx != -1) {
          setState(() {
            _addedItems[existingIdx]['fair_order_sub_quantity'] += qty;
          });
        } else {
          setState(() {
            _addedItems.add({
              'id': null, // Newly added in this edit session
              'fair_order_sub_barcode_main': sub['fair_barcode_main'],
              'fair_order_sub_barcode': barcode,
              'fair_order_sub_mrp': sub['fair_mrp'],
              'fair_order_sub_quantity': qty,
              'fair_order_sub_barcode_type': 'M',
              'stock': sub['stock'] ?? 0,
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
      _barcodeInputController.clear();
    });
  }

  Future<void> _removeItem(int index) async {
    if (_addedItems.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot delete: An order must have at least one barcode item.')),
      );
      return;
    }

    final item = _addedItems[index];
    final subId = item['id'];

    if (subId != null) {
      // Item is saved in database, we must hit the delete API
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete Barcode'),
          content: const Text('Are you sure you want to permanently delete this barcode from this order?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      setState(() {
        _isSubmitting = true;
      });

      try {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('token');

        final response = await http.delete(
          Uri.parse('$baseUrl/fairdeleteOrderSub/$subId'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
        );

        if (response.statusCode == 200 || response.statusCode == 204) {
          setState(() {
            _addedItems.removeAt(index);
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Item deleted successfully from database.')),
            );
          }
        } else {
          String errorMsg = 'Failed to delete item';
          try {
            final decoded = jsonDecode(response.body);
            errorMsg = decoded['message'] ?? decoded['error'] ?? response.body;
          } catch (_) {}
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: $errorMsg')),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Connection error: $e')),
          );
        }
      } finally {
        setState(() {
          _isSubmitting = false;
        });
      }
    } else {
      // Unsaved item, just remove locally
      setState(() {
        _addedItems.removeAt(index);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unsaved item removed.')),
      );
    }
  }

  Future<void> _updateOrder() async {
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
      final int orderId = widget.orderData['id'];

      final payload = {
        'fair_order_retailer': _retailerController.text.trim(),
        'fair_order_retailer_mobile': _mobileController.text.trim(),
        'fair_order_remarks': _remarksController.text.trim(),
        'subs': _addedItems.map((item) => {
          'id': item['id'],
          'fair_order_sub_barcode_main': item['fair_order_sub_barcode_main'],
          'fair_order_sub_barcode': item['fair_order_sub_barcode'],
          'fair_order_sub_mrp': item['fair_order_sub_mrp'],
          'fair_order_sub_quantity': item['fair_order_sub_quantity'],
          'fair_order_sub_barcode_type': item['fair_order_sub_barcode_type'],
        }).toList(),
      };

      final response = await http.put(
        Uri.parse('$baseUrl/fairUpdateOrderForm/$orderId'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        // Fetch updated stock cache
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
              content: const Text('Order updated successfully!'),
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
        String errorMsg = 'Failed to update order';
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
    final scanned = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (context) => const BarcodeScannerPage()),
    );

    if (scanned != null && scanned.isNotEmpty) {
      _processBarcode(scanned);
    }
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = AppTheme.primaryColor;

    return Scaffold(
      backgroundColor: AppTheme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Edit Order #${widget.orderData['fair_order_no'] ?? widget.orderData['id']}', 
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
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
              'Update the retailer name, contact, or remarks for this order.',
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _retailerController.text,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${_addedItems.length} unique barcode(s) added',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: _addedItems.isEmpty ? null : _updateOrder,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Update Order', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ],
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
            const Divider(height: 24),
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
                              setState(() {
                                _searchedSingleQuantity++;
                              });
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
                      child: GridView.builder(
                        padding: const EdgeInsets.all(16),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.8,
                        ),
                        itemCount: _searchedMultipleItems.length,
                        itemBuilder: (context, index) {
                          final sub = _searchedMultipleItems[index];
                          final barcode = sub['fair_barcode']?.toString() ?? '';
                          final isSelected = _selectedSubBarcodes.contains(barcode);
                          final qty = _subBarcodeQuantities[barcode] ?? 1;
                          final stock = sub['stock'] ?? 0;
                          final isOutOfStock = stock <= 0;
                          final color = sub['fair_colour'] != null ? 'Col: ${sub['fair_colour']}' : 'No Color';

                          return Card(
                            elevation: isSelected ? 3 : 0.5,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: isSelected ? primaryColor : Colors.grey.shade200,
                                width: isSelected ? 2 : 1,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(10.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          barcode,
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: Checkbox(
                                          activeColor: primaryColor,
                                          value: isSelected && !isOutOfStock,
                                          onChanged: isOutOfStock
                                              ? null
                                              : (val) {
                                                  setPopupState(() {
                                                    if (val == true) {
                                                      _selectedSubBarcodes.add(barcode);
                                                    } else {
                                                      _selectedSubBarcodes.remove(barcode);
                                                    }
                                                  });
                                                },
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(color, style: const TextStyle(color: Colors.grey, fontSize: 11)),
                                  Text('MRP: ₹${sub['fair_mrp'] ?? 'N/A'}', style: const TextStyle(fontSize: 12)),
                                  Text(
                                    isOutOfStock ? 'Out of Stock' : 'Stock: $stock',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isOutOfStock ? Colors.red.shade700 : Colors.blue.shade800,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      GestureDetector(
                                        onTap: isOutOfStock
                                            ? null
                                            : () {
                                                if (qty > 1) {
                                                  setPopupState(() {
                                                    _subBarcodeQuantities[barcode] = qty - 1;
                                                  });
                                                }
                                              },
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(color: isOutOfStock ? Colors.grey.shade300 : Colors.grey),
                                          ),
                                          child: Icon(
                                            Icons.remove, 
                                            size: 14, 
                                            color: isOutOfStock ? Colors.grey.shade300 : Colors.black,
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 10),
                                        child: Text(
                                          isOutOfStock ? '0' : '$qty',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: isOutOfStock ? Colors.grey.shade400 : Colors.black,
                                          ),
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: isOutOfStock
                                            ? null
                                            : () {
                                                setPopupState(() {
                                                  _subBarcodeQuantities[barcode] = qty + 1;
                                                });
                                              },
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(color: isOutOfStock ? Colors.grey.shade300 : Colors.grey),
                                          ),
                                          child: Icon(
                                            Icons.add, 
                                            size: 14, 
                                            color: isOutOfStock ? Colors.grey.shade300 : Colors.black,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
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
        final isMultiple = item['fair_order_sub_barcode_type'] == 'M';

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade100, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.01),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Row(
              children: [
                // Icon Avatar
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isMultiple ? Colors.purple.shade50 : Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isMultiple ? Icons.grid_view : Icons.sell,
                    color: isMultiple ? Colors.purple.shade700 : Colors.blue.shade700,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 14),

                // Barcode details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['fair_order_sub_barcode'],
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'MRP: ₹${item['fair_order_sub_mrp'] ?? 'N/A'} | Style: ${item['fair_order_sub_barcode_main']}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // Controls row
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Minus Button
                    GestureDetector(
                      onTap: () {
                        final currentQty = item['fair_order_sub_quantity'] as int;
                        if (currentQty > 1) {
                          setState(() {
                            item['fair_order_sub_quantity'] = currentQty - 1;
                          });
                        } else {
                          // Remove item via _removeItem
                          _removeItem(index);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.grey.shade50,
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: const Icon(Icons.remove, size: 14, color: Colors.black87),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: SizedBox(
                        width: 24,
                        child: Text(
                          '${item['fair_order_sub_quantity']}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.black87,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    // Plus Button
                    GestureDetector(
                      onTap: () {
                        final currentQty = item['fair_order_sub_quantity'] as int;
                        setState(() {
                          item['fair_order_sub_quantity'] = currentQty + 1;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.grey.shade50,
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: const Icon(Icons.add, size: 14, color: Colors.black87),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Trash Delete Button
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                      onPressed: () => _removeItem(index),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
