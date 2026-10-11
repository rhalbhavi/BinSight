import 'dart:async'; // Timer and async operations such as debouncing (delaying execution) and awaiting user interactions
import 'dart:convert';

import 'package:flutter/material.dart'; // Material Icons and Widgets
import 'package:firebase_core/firebase_core.dart'; // Firebase initialization
import 'package:firebase_auth/firebase_auth.dart'; // Firebase Authentication
import 'package:shared_preferences/shared_preferences.dart'; // Shared Preferences - Stores last logged in role & uid for persistent login
import 'package:mobile_scanner/mobile_scanner.dart'; // QR Scanner - For scanning bin QR codes during setup
import 'package:flutter_osm_plugin/flutter_osm_plugin.dart' as osm;
import 'package:google_fonts/google_fonts.dart'; // Google Fonts
import 'package:flutter/foundation.dart'
    show kIsWeb; // To check if the app is running on web
import 'package:google_sign_in/google_sign_in.dart'; // Google Sign-In for authentication
import 'package:image_picker/image_picker.dart'; // Image Picker for picking images
import 'dart:typed_data'; // For handling image bytes during setup (admin and worker profile photos)

import 'models.dart';
import 'firebase_options.dart';
import 'services/api_service.dart';
import 'utils/device_labels.dart';
import 'screens/auth/login_screen.dart';
import 'screens/worker/worker_screen.dart';
import 'screens/admin/admin_screen.dart';

String generateNextBinName(List<Map<String, dynamic>> existingBins) {
  final usedNumbers = <int>{};

  for (final device in existingBins) {
    final type = device['type']?.toString();
    if (type != 'bin') continue;

    final rawName = device['name']?.toString() ?? '';
    final match = RegExp(r'^Bin\s+(\d+)$').firstMatch(rawName.trim());
    if (match != null) {
      final number = int.tryParse(match.group(1) ?? '');
      if (number != null) usedNumbers.add(number);
    }
  }

  var nextIndex = 1;
  while (usedNumbers.contains(nextIndex)) {
    nextIndex++;
  }
  return 'Bin $nextIndex';
}

String? detectQrDeviceType(String rawValue) {
  final trimmed = rawValue.trim();
  if (trimmed.isEmpty) return null;

  final normalized = trimmed.toLowerCase();
  if (normalized == 'bin' || normalized.startsWith('bin:')) return 'bin';
  if (normalized == 'zone' || normalized.startsWith('zone:')) return 'zone';

  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map && decoded['type'] is String) {
      final type = decoded['type'].toString().toLowerCase();
      if (type == 'bin' || type == 'zone') return type;
    }
  } catch (_) {}

  return null;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

// ---------------- APP ---------------- //

// -- Main application widget -- //
// Handles splash screen, initial setup screen and check, and routes to AuthGate for role-based navigation after login
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) =>
          WorkerNotificationOverlay(child: child ?? const SizedBox.shrink()),
      theme: ThemeData(
        textTheme: GoogleFonts.titilliumWebTextTheme().copyWith(
          bodyLarge: GoogleFonts.titilliumWeb(fontSize: 16),
          bodyMedium: GoogleFonts.titilliumWeb(fontSize: 16),
          bodySmall: GoogleFonts.titilliumWeb(fontSize: 16),
        ),
        inputDecorationTheme: InputDecorationTheme(
          labelStyle: GoogleFonts.titilliumWeb(fontSize: 16),
          hintStyle: GoogleFonts.titilliumWeb(fontSize: 16),
          helperStyle: GoogleFonts.titilliumWeb(fontSize: 16),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            textStyle: GoogleFonts.titilliumWeb(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle: GoogleFonts.titilliumWeb(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            textStyle: GoogleFonts.titilliumWeb(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            textStyle: GoogleFonts.titilliumWeb(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        popupMenuTheme: PopupMenuThemeData(
          textStyle: GoogleFonts.titilliumWeb(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        dialogTheme: DialogThemeData(
          titleTextStyle: GoogleFonts.titilliumWeb(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
          contentTextStyle: GoogleFonts.titilliumWeb(
            fontSize: 18,
            color: Colors.black87,
          ),
        ),
      ),
      home: const RootController(),
    );
  }
}
// ---------------- ROOT ---------------- //

class RootController extends StatefulWidget {
  const RootController({super.key});

  @override
  State<RootController> createState() => _RootControllerState();
}

class _RootControllerState extends State<RootController> {
  late final Future<void> _initFuture;
  bool? _isSetupDone; // Status of initial setup - null means still loading
  bool _showAdminSetupFlow =
      false; // Flag to switch to admin setup within the unauthenticated flow
  String? _lastRole;
  String? _lastUid;

  @override
  void initState() {
    super.initState();
    _initFuture = _init();
  }

  Future<void> _init() async {
    // All async init work here
    final dataFetchFuture = () async {
      final prefs = await SharedPreferences.getInstance();
      _lastRole = prefs.getString('lastRole');
      _lastUid = prefs.getString('lastUid');
      try {
        _isSetupDone = await ApiService.fetchSetupStatus();
      } catch (e) {
        debugPrint('Error fetching setup status: $e');
        _isSetupDone = false;
      }
    }();

    // Wait for both splash screen delay and data fetching to complete
    await Future.wait([
      Future.delayed(const Duration(seconds: 4)),
      dataFetchFuture,
    ]);
  }

  Future<void> _returnToLoginFromSetup() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    setState(() {
      _showAdminSetupFlow = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SplashScreen();
        }

        if (snapshot.hasError || _isSetupDone == null) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Failed to initialize: ${snapshot.error ?? 'Unknown error'}',
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => setState(() {
                      _initFuture = _init();
                    }),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }

        // If the user intentionally enters the admin setup flow, show it regardless of
        // the current backend setup status so the login CTA can navigate there reliably.
        if (_showAdminSetupFlow) {
          return SetupFlowScreen(onBackToLogin: _returnToLoginFromSetup);
        }

        // After splash and setup status loaded, check authentication state.
        return StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, authSnapshot) {
            if (authSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            if (authSnapshot.hasData) {
              return AuthGate(
                isSetupDone: _isSetupDone,
                lastRole: authSnapshot.data!.uid == _lastUid ? _lastRole : null,
                onGoToAdminSetup: () =>
                    setState(() => _showAdminSetupFlow = true),
              );
            }

            return LoginScreen(
              onGoToAdminSetup: () =>
                  setState(() => _showAdminSetupFlow = true),
            );
          },
        );
      },
    );
  }
}

// ---------------- SPLASH ---------------- //

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SizedBox.expand(
        child: Image.asset('assets/splash.png', fit: BoxFit.cover),
      ),
    );
  }
}

// ---------------- AUTH GATE (ROLE-BASED NAVIGATION) ---------------- //

class AuthGate extends StatefulWidget {
  final bool? isSetupDone;
  final VoidCallback? onGoToAdminSetup;
  final String? lastRole;

  const AuthGate({
    super.key,
    this.isSetupDone,
    this.onGoToAdminSetup,
    this.lastRole,
  });

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Future<String?> getUserRole(User user) async {
    // If we have a valid role from persistent login, use it
    if (widget.lastRole != null) {
      return widget.lastRole;
    }

    try {
      return await ApiService.fetchUserRole(user.uid, email: user.email);
    } catch (e) {
      debugPrint('Error getting user role: $e');
    }
    return null;
  }

  Future<void> _savePersistentLogin(String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lastRole', role);
    await prefs.setString(
      'lastUid',
      FirebaseAuth.instance.currentUser?.uid ?? '',
    );
  }

  Future<void> _signOutAndGoToLogin() async {
    await FirebaseAuth.instance.signOut();
    try {
      if (!kIsWeb) {
        await GoogleSignIn().signOut();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          // This case should ideally not be reached if RootController handles unauthenticated state
          // But as a fallback, if AuthGate is somehow reached without data, redirect to LoginScreen
          return LoginScreen(onGoToAdminSetup: widget.onGoToAdminSetup);
        }

        final user = snapshot.data!;

        return FutureBuilder<String?>(
          future: getUserRole(user),
          builder: (context, roleSnapshot) {
            if (roleSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            final role = roleSnapshot.data;

            if (role == null) {
              // User authenticated in Firebase but not registered in backend.
              // Sign out and show login screen with appropriate error.
              _signOutAndGoToLogin();
              return LoginScreen(
                onGoToAdminSetup: widget.onGoToAdminSetup,
                initialError: 'Incorrect credentials.',
              );
            }

            // Save persistent login
            _savePersistentLogin(role);

            if (role == "admin") {
              return const AdminDashboard();
            } else if (role == "worker") {
              return const WorkerDashboard();
            } else {
              // Unknown role - sign out and show login
              _signOutAndGoToLogin();
              return LoginScreen(
                onGoToAdminSetup: widget.onGoToAdminSetup,
                initialError: 'Incorrect credentials.',
              );
            }
          },
        );
      },
    );
  }
}

// ---------------- SETUP FLOW ---------------- //

class SetupFlowScreen extends StatefulWidget {
  const SetupFlowScreen({super.key, this.onBackToLogin});

  final VoidCallback? onBackToLogin;

  @override
  State<SetupFlowScreen> createState() => _SetupFlowScreenState();
}

class _SetupFlowScreenState extends State<SetupFlowScreen> {
  static const int _maxProfileImageBytes = 14 * 1024 * 1024;
  final SetupDraft draft = SetupDraft.instance;
  final ImagePicker _picker = ImagePicker();
  final adminFirstName = TextEditingController();
  final adminLastName = TextEditingController();
  final adminDob = TextEditingController();
  final adminEmail = TextEditingController();
  final adminPhoneController = TextEditingController();
  final adminPassword = TextEditingController();
  final organizationLocationController = TextEditingController();
  final _binNameController = TextEditingController();
  final _binLocationController = TextEditingController();
  final _binDetailsController = TextEditingController();
  final confirmPassword = TextEditingController();
  final workerFirstName = TextEditingController();
  final workerLastName = TextEditingController();
  final workerDob = TextEditingController();
  final workerEmail = TextEditingController();
  final workerPhoneController = TextEditingController();
  final workerPassword = TextEditingController();
  final workerConfirmPassword = TextEditingController();
  Timer? _organizationSearchDebounce;
  Timer? _binLocationSearchDebounce;
  Timer? _adminEmailCheckDebounce;
  String? _registeredAdminEmail;
  String? _checkedAdminEmail;
  bool _checkingAdminEmail = false;
  List<osm.SearchInfo> _organizationSuggestions = [];
  List<osm.SearchInfo> _binLocationSuggestions = [];
  Future<List<Map<String, dynamic>>>? _setupZonesFuture;
  PickedData? _selectedBinPlace;
  String? _selectedBinZoneId;
  bool _organizationSearchLoading = false;
  bool _binLocationSearchLoading = false;
  bool _settingOrganizationLocationText = false;
  bool _pendingBinRegistration = false;

  bool loading = false;

  TextStyle get bodyTextStyle => GoogleFonts.titilliumWeb(fontSize: 16);

  Widget _requiredLabel(String text) {
    return RichText(
      text: TextSpan(
        style: bodyTextStyle,
        children: [
          TextSpan(text: text),
          const TextSpan(
            text: ' *',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  List<PendingWorkerSetup> get workers => draft.workers;
  List<Map<String, dynamic>> get bins => draft.bins;
  bool get adminGoogleSetupDone => draft.adminGoogleSetupDone;
  Uint8List? get adminPhotoBytes => draft.adminPhotoBytes;
  String? get adminGoogleUid => draft.adminGoogleUid;
  String? get adminGoogleName => draft.adminGoogleName;
  String? get adminGooglePhotoUrl => draft.adminGooglePhotoUrl;
  Uint8List? get workerPhotoBytes => draft.workerPhotoBytes;

  @override
  void initState() {
    super.initState();
    adminFirstName.text = draft.adminFirstName;
    adminLastName.text = draft.adminLastName;
    adminDob.text = draft.adminDob;
    adminEmail.text = draft.adminEmail;
    adminPhoneController.text = draft.adminPhone;

    adminPassword.text = draft.adminPassword;
    if (draft.selectedPlace != null) {
      organizationLocationController.text = draft.selectedPlace!.displayName;
    } else if (draft.organizationLocation.isNotEmpty) {
      organizationLocationController.text = draft.organizationLocation;
    }
    confirmPassword.text = draft.adminConfirmPassword;
    workerFirstName.text = draft.workerFirstName;
    workerLastName.text = draft.workerLastName;
    workerDob.text = draft.workerDob;
    workerEmail.text = draft.workerEmail;
    workerPassword.text = draft.workerPassword;
    workerPhoneController.text = draft.workerPhone;
    workerConfirmPassword.text = draft.workerConfirmPassword;
    _hydrateAdminDraftFromCurrentUser();
  }

  void _hydrateAdminDraftFromCurrentUser() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || draft.adminGoogleSetupDone) {
      return;
    }

    final displayName = (currentUser.displayName ?? '').trim();
    final parts = displayName.isEmpty
        ? const <String>[]
        : displayName.split(RegExp(r'\s+'));
    final nextFirstName = parts.isEmpty ? draft.adminFirstName : parts.first;
    final nextLastName = parts.length > 1
        ? parts.sublist(1).join(' ')
        : draft.adminLastName;

    draft.adminGoogleSetupDone = true;
    draft.adminGoogleUid = currentUser.uid;
    draft.adminGoogleName = displayName.isEmpty ? 'Admin' : displayName;
    draft.adminGooglePhotoUrl = currentUser.photoURL ?? '';

    if (draft.adminFirstName.trim().isEmpty &&
        nextFirstName.trim().isNotEmpty) {
      draft.adminFirstName = _normalizeText(nextFirstName);
      adminFirstName.text = draft.adminFirstName;
    }

    if (draft.adminLastName.trim().isEmpty && nextLastName.trim().isNotEmpty) {
      draft.adminLastName = _normalizeText(nextLastName);
      adminLastName.text = draft.adminLastName;
    }

    if (adminEmail.text.trim().isEmpty) {
      adminEmail.text = currentUser.email ?? '';
    }

    _syncDraft();
  }

  @override
  void dispose() {
    _organizationSearchDebounce?.cancel();
    _binLocationSearchDebounce?.cancel();
    _adminEmailCheckDebounce?.cancel();
    adminFirstName.dispose();
    adminLastName.dispose();
    adminDob.dispose();
    adminEmail.dispose();
    adminPhoneController.dispose();
    adminPassword.dispose();
    organizationLocationController.dispose();
    _binNameController.dispose();
    _binLocationController.dispose();
    _binDetailsController.dispose();
    confirmPassword.dispose();
    workerFirstName.dispose();
    workerLastName.dispose();
    workerDob.dispose();
    workerEmail.dispose();
    workerPhoneController.dispose();
    workerPassword.dispose();
    workerConfirmPassword.dispose();
    super.dispose();
  }

  bool get adminPasswordsMatch =>
      confirmPassword.text.isEmpty ||
      adminPassword.text == confirmPassword.text;

  bool get workerPasswordsMatch =>
      workerConfirmPassword.text.isEmpty ||
      workerPassword.text == workerConfirmPassword.text;

  bool get isAdminGoogleProfileReady =>
      adminFirstName.text.trim().isNotEmpty &&
      adminLastName.text.trim().isNotEmpty &&
      adminDob.text.trim().isNotEmpty &&
      adminPhoneController.text.trim().isNotEmpty;

  bool get isAdminManualReady =>
      adminFirstName.text.trim().isNotEmpty &&
      adminLastName.text.trim().isNotEmpty &&
      adminDob.text.trim().isNotEmpty &&
      adminPhoneController.text.trim().isNotEmpty && // Phone mandatory
      adminEmail.text.trim().isNotEmpty &&
      adminPassword.text.isNotEmpty &&
      confirmPassword.text.isNotEmpty &&
      adminPassword.text == confirmPassword.text;

  bool get isAdminReadyForNextStep =>
      adminGoogleSetupDone ? isAdminGoogleProfileReady : isAdminManualReady;

  bool get isWorkerManualReady =>
      workerFirstName.text.trim().isNotEmpty &&
      workerLastName.text.trim().isNotEmpty &&
      workerDob.text.trim().isNotEmpty &&
      workerPhoneController.text.trim().isNotEmpty &&
      workerEmail.text.trim().isNotEmpty &&
      workerPassword.text.trim().isNotEmpty &&
      workerConfirmPassword.text.trim().isNotEmpty &&
      workerPassword.text == workerConfirmPassword.text;

  String _normalizeText(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');
  String _normalizeCompact(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').trim();
  String _joinedName(String first, String last, String fallback) {
    final combined = '${_normalizeText(first)} ${_normalizeText(last)}'.trim();
    return combined.isEmpty ? fallback : combined;
  }

  String _normalizedEmail(String value) =>
      _normalizeCompact(value).toLowerCase();

  Future<bool> _isAdminEmailRegistered(String value) async {
    final email = _normalizedEmail(value);
    if (email.isEmpty || !email.contains("@")) return false;
    if (_checkedAdminEmail == email) return _registeredAdminEmail == email;
    try {
      final methods = await FirebaseAuth.instance.fetchSignInMethodsForEmail(
        email,
      );
      if (!mounted) return false;
      setState(() {
        _checkedAdminEmail = email;
        _registeredAdminEmail = methods.isNotEmpty ? email : null;
        _checkingAdminEmail = false;
      });
      return methods.isNotEmpty;
    } on FirebaseAuthException catch (error) {
      debugPrint("Could not check admin email registration (${error.code}).");
      if (mounted) setState(() => _checkingAdminEmail = false);
      return false;
    }
  }

  void _scheduleAdminEmailCheck(String value) {
    _adminEmailCheckDebounce?.cancel();
    final email = _normalizedEmail(value);
    if (_registeredAdminEmail != null && _registeredAdminEmail != email)
      _registeredAdminEmail = null;
    if (_checkedAdminEmail != email) _checkedAdminEmail = null;
    if (email.isEmpty || !email.contains("@")) {
      _checkingAdminEmail = false;
      return;
    }
    _checkingAdminEmail = true;
    _adminEmailCheckDebounce = Timer(const Duration(milliseconds: 450), () {
      _isAdminEmailRegistered(email);
    });
  }

  void _syncDraft() {
    draft.adminFirstName = _normalizeText(adminFirstName.text);
    draft.adminLastName = _normalizeText(adminLastName.text);
    draft.adminDob = adminDob.text.trim();
    draft.adminEmail = _normalizeCompact(adminEmail.text);
    draft.adminPhone = _normalizeCompact(adminPhoneController.text);
    draft.adminPassword = _normalizeCompact(adminPassword.text);
    draft.organizationLocation = organizationLocationController.text.trim();
    draft.adminConfirmPassword = _normalizeCompact(confirmPassword.text);
    draft.workerFirstName = _normalizeText(workerFirstName.text);
    draft.workerLastName = _normalizeText(workerLastName.text);
    draft.workerDob = workerDob.text.trim();
    draft.workerEmail = _normalizeCompact(workerEmail.text);
    draft.workerPassword = _normalizeCompact(workerPassword.text);
    draft.workerPhone = _normalizeCompact(workerPhoneController.text);
    draft.workerConfirmPassword = _normalizeCompact(workerConfirmPassword.text);
  }

  // Future Type - Used for async operations that don't return a value but need to be awaited for completion, such as showing dialogs, picking images, or performing authentication tasks
  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 20),
      firstDate: DateTime(1950),
      lastDate: now,
    );
    if (picked == null) return;
    controller.text =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    setState(_syncDraft);
  }

  bool get canScanQr =>
      !loading && !_pendingBinRegistration && draft.selectedPlace != null;
  bool get canFinishSetup => !loading;

  InputDecoration _textFieldDecoration(
    String label, {
    bool showError = false,
    String? errorText,
    String? hintText,
  }) {
    final borderColor = showError ? Colors.red : Colors.grey.shade300;
    return InputDecoration(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      errorText: errorText,
      errorStyle: bodyTextStyle.copyWith(color: Colors.red, fontSize: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: borderColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(
          color: showError ? Colors.red : const Color(0xFF03A9F4),
          width: 2,
        ),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: const BorderSide(color: Colors.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: const BorderSide(color: Colors.red, width: 2),
      ),
      hintText: hintText,
    );
  }

  ButtonStyle _setupButtonStyle(Color color) {
    return ElevatedButton.styleFrom(
      backgroundColor: color,
      minimumSize: const Size(double.infinity, 50),
      padding: const EdgeInsets.symmetric(vertical: 14),
      textStyle: bodyTextStyle.copyWith(fontWeight: FontWeight.bold),
    );
  }

  Widget _googleIcon() {
    return const Icon(Icons.g_mobiledata, size: 28, color: Colors.black87);
  }

  Future<Uint8List?> _pickImageBytes() async {
    final image = await _picker.pickImage(
      source: ImageSource.gallery,
    ); // Corrected `Future` type usage
    if (image == null) return null; // Explicitly return null
    final bytes = await image.readAsBytes();
    if (bytes.length > _maxProfileImageBytes) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Selected photo is too large. Please choose an image smaller than 14 MB.',
          ),
        ),
      );
      return null;
    }
    return bytes;
  }

  Future<void> _pickAdminPhoto() async {
    final bytes = await _pickImageBytes();
    if (bytes == null) return; // Explicitly return
    setState(() {
      draft.adminPhotoBytes = bytes;
    });
  }

  Future<void> _pickWorkerPhoto() async {
    final bytes = await _pickImageBytes();
    if (bytes == null) return; // Explicitly return
    setState(() {
      draft.workerPhotoBytes = bytes;
    });
  }

  void _onOrganizationLocationChanged(String value) {
    if (_settingOrganizationLocationText) {
      return;
    }

    _organizationSearchDebounce?.cancel();

    setState(() {
      draft.selectedPlace = null;
      _syncDraft();
    });

    final query = value.trim();
    if (query.length < 3) {
      setState(() {
        _organizationSuggestions = [];
        _organizationSearchLoading = false;
      });
      return;
    }

    _organizationSearchDebounce = Timer(
      const Duration(milliseconds: 450),
      () async {
        if (!mounted) return;

        setState(() {
          _organizationSearchLoading = true;
        });

        try {
          final results = await osm.addressSuggestion(
            query,
            limitInformation: 6,
          );
          if (!mounted) return;
          setState(() {
            _organizationSuggestions = results;
            _organizationSearchLoading = false;
          });
        } catch (_) {
          if (!mounted) return;
          setState(() {
            _organizationSuggestions = [];
            _organizationSearchLoading = false;
          });
        }
      },
    );
  }

  String _organizationSuggestionLabel(osm.SearchInfo suggestion) {
    final text = suggestion.address?.toString().trim() ?? '';
    if (text.isNotEmpty) {
      return text;
    }

    final point = suggestion.point;
    if (point == null) {
      return 'Selected location';
    }

    return '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';
  }

  Future<void> _selectOrganizationSuggestion(osm.SearchInfo suggestion) async {
    final point = suggestion.point;
    if (point == null) return;

    final label = _organizationSuggestionLabel(suggestion);
    _organizationSearchDebounce?.cancel();

    _settingOrganizationLocationText = true;
    organizationLocationController.value = TextEditingValue(
      text: label,
      selection: TextSelection.collapsed(offset: label.length),
    );

    setState(() {
      draft.selectedPlace = PickedData(
        displayName: label,
        latitude: point.latitude,
        longitude: point.longitude,
      );
      _organizationSuggestions = [];
      _organizationSearchLoading = false;
      _syncDraft();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settingOrganizationLocationText = false;
    });

    FocusScope.of(context).unfocus();
  }

  Future<bool> _confirmFinishSetup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finish Setup'),
        content: const Text(
          'This will create the admin, save workers, upload profile photos, and save any devices you have already added.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Widget _photoPreview(Uint8List? bytes, {String? imageUrl}) {
    ImageProvider? imageProvider;
    if (bytes != null) {
      imageProvider = MemoryImage(bytes);
    } else if (imageUrl != null && imageUrl.isNotEmpty) {
      imageProvider = NetworkImage(imageUrl);
    }

    return CircleAvatar(
      radius: 32,
      backgroundImage: imageProvider,
      child: imageProvider == null ? const Icon(Icons.person) : null,
    );
  }

  Widget _sectionDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Divider(color: Colors.grey[300], thickness: 2, height: 1),
    );
  }

  Future<FirebaseAuth> _createSecondaryAuth() async {
    final app = await Firebase.initializeApp(
      name: 'worker-setup-${DateTime.now().microsecondsSinceEpoch}',
      options: DefaultFirebaseOptions.currentPlatform,
    );
    return Future.value(
      FirebaseAuth.instanceFor(app: app),
    ); // Explicitly return Future
  }

  Future<void> _disposeSecondaryAuth(FirebaseAuth? auth) async {
    if (auth == null) return;
    try {
      await auth.signOut();
    } catch (_) {}
    try {
      await auth.app.delete();
    } catch (_) {}
  }

  Future<void> addWorker() async {
    if (!isAdminReadyForNextStep) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Complete admin setup first.")),
      );
      return;
    }

    if (!isWorkerManualReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Fill all worker details before adding.")),
      );
      return;
    }

    setState(() {
      _syncDraft();
      workers.add(
        PendingWorkerSetup(
          localId: DateTime.now().microsecondsSinceEpoch.toString(),
          email: _normalizeCompact(workerEmail.text),
          name:
              '${_normalizeText(workerFirstName.text)} ${_normalizeText(workerLastName.text)}',
          phone: _normalizeCompact(workerPhoneController.text), // NEW
          firstName: _normalizeText(workerFirstName.text),
          lastName: _normalizeText(workerLastName.text),
          dateOfBirth: workerDob.text.trim(),
          password: workerPassword.text.trim(),
          isGoogleAuth: false,
          photoBytes: workerPhotoBytes,
        ),
      );
      workerFirstName.clear();
      workerLastName.clear();
      workerDob.clear();
      workerEmail.clear();
      workerPhoneController.clear();
      workerPassword.clear();
      workerConfirmPassword.clear();
      draft.workerPhotoBytes = null;
      _syncDraft();
    });
  }

  void removeWorker(PendingWorkerSetup worker) {
    setState(() {
      workers.remove(worker);
    });
  }

  // ---------------- GOOGLE SIGN-IN FOR ADMIN ---------------- //

  Future<void> signInAdminWithGoogle() async {
    setState(() => loading = true);
    try {
      UserCredential userCredential;
      String adminName = 'Admin';
      String adminPhotoUrl = '';

      if (kIsWeb) {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        final provider = GoogleAuthProvider()
          ..setCustomParameters({'prompt': 'select_account'});
        userCredential = await FirebaseAuth.instance.signInWithPopup(provider);
        adminName = userCredential.user?.displayName ?? 'Admin';
        if (!mounted) return;
        adminPhotoUrl = userCredential.user?.photoURL ?? '';
      } else {
        final GoogleSignIn googleSignIn = GoogleSignIn();
        await FirebaseAuth.instance.signOut();
        try {
          await googleSignIn.disconnect();
        } catch (_) {
          try {
            await googleSignIn.signOut();
          } catch (_) {}
        }
        if (!mounted) return;
        final GoogleSignInAccount? googleUser = await googleSignIn.signIn();

        if (googleUser == null) {
          setState(() => loading = false);
          return;
        }

        final GoogleSignInAuthentication googleAuth =
            await googleUser.authentication;
        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );

        userCredential = await FirebaseAuth.instance.signInWithCredential(
          credential,
        );
        adminName = googleUser.displayName ?? 'Admin';
        adminPhotoUrl = googleUser.photoUrl ?? '';
      }

      final adminUid = userCredential.user!.uid;
      final adminEmailAddress = userCredential.user!.email ?? '';

      if (userCredential.additionalUserInfo?.isNewUser != true) {
        final existingEmail = _normalizedEmail(adminEmailAddress);
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        setState(() {
          adminEmail.text = adminEmailAddress;
          _registeredAdminEmail = existingEmail;
          _checkedAdminEmail = existingEmail;
          draft.adminGoogleSetupDone = false;
          draft.adminGoogleUid = null;
          draft.adminGoogleName = null;
          draft.adminGooglePhotoUrl = null;
          loading = false;
          _syncDraft();
        });
        return;
      }

      final displayName = (adminName).trim();
      final parts = displayName.isEmpty
          ? const <String>[]
          : displayName.split(RegExp(r'\s+'));
      final nextFirstName = parts.isEmpty ? '' : parts.first;
      final nextLastName = parts.length > 1 ? parts.sublist(1).join(' ') : '';

      if (!mounted) return;
      setState(() {
        _syncDraft();
        draft.adminGoogleSetupDone = true;
        draft.adminGoogleUid = adminUid;
        draft.adminGoogleName = adminName;
        draft.adminGooglePhotoUrl = adminPhotoUrl;
        adminEmail.text = adminEmailAddress;
        if (nextFirstName.isNotEmpty) {
          adminFirstName.text = _normalizeText(nextFirstName);
        }
        if (nextLastName.isNotEmpty) {
          adminLastName.text = _normalizeText(nextLastName);
        }
        loading = false;
        _syncDraft();
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Admin account set up with Google: $adminName"),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      if ({
        "email-already-in-use",
        "credential-already-in-use",
        "account-exists-with-different-credential",
      }.contains(e.code)) {
        final existingEmail = _normalizedEmail(e.email ?? adminEmail.text);
        setState(() {
          _registeredAdminEmail = existingEmail;
          _checkedAdminEmail = existingEmail;
          loading = false;
        });
        return;
      }
      setState(() => loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error: ${e.message}")));
      debugPrint('FirebaseAuthException: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        // Explicitly return
        SnackBar(content: Text("Error: $e")),
      );
      debugPrint('Google Sign-In Error: $e');
    }
  }

  // ---------------- QR SCAN - REGISTER BIN ---------------- //

  void addBinFromQR(String rawQrValue) {
    final detectedType = detectQrDeviceType(rawQrValue);
    if (detectedType != 'bin') {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This QR code is not a bin code.')),
      );
      return;
    }
    if (!canScanQr) return;

    setState(() {
      _pendingBinRegistration = true;
      _binNameController.text = generateNextBinName(bins);
      _binLocationController.clear();
      _binDetailsController.clear();
      _binLocationSuggestions = [];
      _selectedBinPlace = null;
      _selectedBinZoneId = null;
      _setupZonesFuture = ApiService.fetchZones();
    });
  }

  void _onBinLocationChanged(String value) {
    _binLocationSearchDebounce?.cancel();
    setState(() {
      _selectedBinPlace = null;
      _binLocationSuggestions = [];
      _binLocationSearchLoading = false;
    });

    final query = value.trim();
    if (query.length < 3) return;

    _binLocationSearchDebounce = Timer(
      const Duration(milliseconds: 450),
      () async {
        if (!mounted) return;
        setState(() => _binLocationSearchLoading = true);
        try {
          final suggestions = await osm.addressSuggestion(
            query,
            limitInformation: 6,
          );
          if (!mounted) return;
          setState(() {
            _binLocationSuggestions = suggestions;
            _binLocationSearchLoading = false;
          });
        } catch (_) {
          if (!mounted) return;
          setState(() {
            _binLocationSuggestions = [];
            _binLocationSearchLoading = false;
          });
        }
      },
    );
  }

  void _selectBinLocation(osm.SearchInfo suggestion) {
    final point = suggestion.point;
    if (point == null) return;
    final label = _organizationSuggestionLabel(suggestion);
    _binLocationSearchDebounce?.cancel();
    _binLocationController.value = TextEditingValue(
      text: label,
      selection: TextSelection.collapsed(offset: label.length),
    );
    setState(() {
      _selectedBinPlace = PickedData(
        displayName: label,
        latitude: point.latitude,
        longitude: point.longitude,
      );
      _binLocationSuggestions = [];
      _binLocationSearchLoading = false;
    });
    FocusScope.of(context).unfocus();
  }

  void _cancelPendingBinRegistration() {
    setState(() {
      _pendingBinRegistration = false;
      _binNameController.clear();
      _binLocationController.clear();
      _binDetailsController.clear();
      _binLocationSuggestions = [];
      _selectedBinPlace = null;
      _selectedBinZoneId = null;
    });
  }

  Future<void> _createSetupZone() async {
    final screenContext = context;
    final organizationPlace = draft.selectedPlace;
    if (organizationPlace == null) return;

    List<Map<String, dynamic>> existingZones;
    try {
      existingZones = await ApiService.fetchZones();
    } catch (error) {
      if (!screenContext.mounted) return;
      ScaffoldMessenger.of(
        screenContext,
      ).showSnackBar(SnackBar(content: Text('Could not load zones: $error')));
      return;
    }
    if (!screenContext.mounted) return;

    final dialogController = TextEditingController();
    String? nameError;
    var saving = false;
    await showDialog<void>(
      context: screenContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Create Zone'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: dialogController,
                enabled: !saving,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Zone name'),
                onChanged: (_) => setDialogState(() => nameError = null),
              ),
              if (nameError != null) ...[
                const SizedBox(height: 6),
                Text(nameError!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final zoneName = dialogController.text.trim().replaceAll(
                        RegExp(r'\s+'),
                        ' ',
                      );
                      if (zoneName.isEmpty) {
                        setDialogState(() => nameError = 'Enter a zone name.');
                        return;
                      }
                      if (existingZones.any(
                        (zone) =>
                            zone['name']?.toString().trim().toLowerCase() ==
                            zoneName.toLowerCase(),
                      )) {
                        setDialogState(
                          () => nameError =
                              'This name already belongs to an existing zone.',
                        );
                        return;
                      }

                      setDialogState(() {
                        saving = true;
                        nameError = null;
                      });
                      try {
                        final createdZone = await ApiService.createDeviceFromQr(
                          qrValue: 'zone',
                          name: zoneName,
                          locationDescription: organizationPlace.displayName,
                          latitude: organizationPlace.latitude,
                          longitude: organizationPlace.longitude,
                        );
                        final zoneId = createdZone['id']?.toString();
                        if (zoneId == null || zoneId.isEmpty) {
                          throw Exception(
                            'The backend did not return a zone ID.',
                          );
                        }
                        if (!screenContext.mounted || !dialogContext.mounted) {
                          return;
                        }
                        setState(() {
                          bins.add({
                            'id': zoneId,
                            'device_id': zoneId,
                            'zone_id': zoneId,
                            'name': zoneName,
                            'type': 'zone',
                            'location_description':
                                organizationPlace.displayName,
                            'location': {
                              'type': 'Point',
                              'coordinates': [
                                organizationPlace.longitude,
                                organizationPlace.latitude,
                              ],
                            },
                            'qr_payload': 'zone',
                          });
                          _selectedBinZoneId = zoneId;
                          _setupZonesFuture = ApiService.fetchZones();
                        });
                        Navigator.pop(dialogContext);
                        ScaffoldMessenger.of(screenContext).showSnackBar(
                          SnackBar(content: Text('Zone "$zoneName" created.')),
                        );
                      } catch (error) {
                        if (!screenContext.mounted || !dialogContext.mounted) {
                          return;
                        }
                        final message =
                            error.toString().contains(
                              'This name already belongs to an existing zone.',
                            )
                            ? 'This name already belongs to an existing zone.'
                            : 'Could not create zone: $error';
                        setDialogState(() {
                          saving = false;
                          nameError = message;
                        });
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
    dialogController.dispose();
  }

  Future<void> _registerPendingBin() async {
    final place = _selectedBinPlace;
    final name = _binNameController.text.trim();
    if (name.isEmpty || place == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a bin name and select its location.'),
        ),
      );
      return;
    }
    final details = _binDetailsController.text.trim();
    final locationDescription = details.isEmpty
        ? place.displayName
        : '$details (${place.displayName})';

    setState(() => loading = true);
    try {
      final registeredBin = await ApiService.createDeviceFromQr(
        qrValue: 'bin',
        name: name,
        locationDescription: locationDescription,
        latitude: place.latitude,
        longitude: place.longitude,
        zoneId: _selectedBinZoneId,
      );
      if (!mounted) return;

      final binId = registeredBin['id']?.toString();
      if (binId == null || binId.isEmpty) {
        throw Exception('The backend did not return a bin ID.');
      }
      final zoneId = _selectedBinZoneId;
      setState(() {
        bins.add({
          'id': binId,
          'device_id': binId,
          'bin_id': binId,
          'name': registeredBin['name']?.toString() ?? name,
          'type': 'bin',
          'location_description': locationDescription,
          'location': {
            'type': 'Point',
            'coordinates': [place.longitude, place.latitude],
          },
          'qr_payload': 'bin',
          'zone_id': zoneId,
        });
        _pendingBinRegistration = false;
        loading = false;
        _binNameController.clear();
        _binLocationController.clear();
        _binDetailsController.clear();
        _binLocationSuggestions = [];
        _selectedBinPlace = null;
        _selectedBinZoneId = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$name registered and saved.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not register bin: $error')));
    }
  }

  Future<void> _confirmAndDeleteBin(Map<String, dynamic> bin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete bin'),
        content: const Text('Are you sure you want to delete this bin?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final binId = (bin['bin_id'] ?? bin['device_id'] ?? bin['id']).toString();
    setState(() => loading = true);
    try {
      await ApiService.deleteBin(binId);
      if (!mounted) return;
      setState(() {
        bins.removeWhere(
          (device) =>
              device['bin_id'] == binId ||
              device['device_id'] == binId ||
              device['id'] == binId,
        );
        for (var i = 0; i < bins.length; i++) {
          final device = bins[i];
          if (device['type'] == 'bin') {
            device['name'] = 'Bin ${i + 1}';
          }
        }
        loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${bin['name'] ?? 'Bin'} deleted.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not delete bin: $error')));
    }
  }

  Future<void> _editRegisteredBin(Map<String, dynamic> device) async {
    final nameController = TextEditingController(
      text: device['name']?.toString() ?? '',
    );
    final locationController = TextEditingController(
      text: device['location_description']?.toString() ?? '',
    );
    final zonesFuture = ApiService.fetchZones();
    String? selectedZoneId = device['zone_id']?.toString();
    String? locationError;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Edit ${device['name'] ?? 'Bin'}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  enabled: false,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    helperText: 'Automatic and fixed by the system',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: locationController,
                  decoration: const InputDecoration(
                    labelText: 'Location description',
                  ),
                ),
                const SizedBox(height: 12),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: zonesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const LinearProgressIndicator();
                    }
                    if (snapshot.hasError) {
                      return const Text('Could not load zones.');
                    }
                    final zones = snapshot.data ?? const [];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButtonFormField<String?>(
                          initialValue: selectedZoneId,
                          decoration: const InputDecoration(labelText: 'Zone'),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('No zone'),
                            ),
                            ...zones.map(
                              (zone) => DropdownMenuItem<String?>(
                                value: zone['zone_id']?.toString(),
                                child: Text(zone['name']?.toString() ?? 'Zone'),
                              ),
                            ),
                          ],
                          onChanged: (zoneId) =>
                              setDialogState(() => selectedZoneId = zoneId),
                        ),
                        if (zones.isEmpty)
                          TextButton.icon(
                            onPressed: () async {
                              final zoneName = await _showCreateZoneDialog();
                              if (zoneName == null || !mounted) return;
                              try {
                                final created =
                                    await ApiService.createDeviceFromQr(
                                      qrValue: 'zone',
                                      name: zoneName,
                                      locationDescription:
                                          locationController.text
                                              .trim()
                                              .isNotEmpty
                                          ? locationController.text.trim()
                                          : 'New zone',
                                    );
                                final zoneId = created['id']?.toString();
                                if (zoneId == null || zoneId.isEmpty) {
                                  throw Exception(
                                    'The backend did not return a zone ID.',
                                  );
                                }
                                if (!mounted || !dialogContext.mounted) return;
                                setDialogState(() {
                                  selectedZoneId = zoneId;
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Zone "$zoneName" created.'),
                                  ),
                                );
                              } catch (error) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Could not create zone: $error',
                                    ),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.add),
                            label: const Text('Create Zone'),
                          ),
                      ],
                    );
                  },
                ),
                if (locationError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    locationError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final updatedLocation = locationController.text.trim();
                if (updatedLocation.isEmpty) {
                  setDialogState(() => locationError = 'Location is required.');
                  return;
                }

                try {
                  final binId =
                      (device['bin_id'] ?? device['device_id'] ?? device['id'])
                          ?.toString() ??
                      '';
                  if (binId.isEmpty) throw Exception('Bin ID is missing.');
                  await ApiService.updateBinDetails(
                    binId: binId,
                    locationDescription: updatedLocation,
                    zoneId: selectedZoneId,
                  );
                  if (!mounted || !dialogContext.mounted) return;
                  setState(() {
                    device['location_description'] = updatedLocation;
                    device['zone_id'] = selectedZoneId;
                  });
                  Navigator.pop(dialogContext);
                } catch (error) {
                  if (!mounted || !dialogContext.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not update bin: $error')),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      nameController.dispose();
      locationController.dispose();
    });
  }

  Future<String?> _showCreateZoneDialog() async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Create Zone'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Zone name'),
                onChanged: (_) => setDialogState(() => error = null),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final zoneName = controller.text.trim();
                if (zoneName.isEmpty) {
                  setDialogState(() => error = 'Enter a zone name.');
                  return;
                }
                Navigator.pop(dialogContext, zoneName);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Map<String, dynamic> buildBinPayload(
    String deviceId,
    String name,
    String locationDescription,
    String? zoneId,
    Map<String, dynamic>? location,
  ) {
    return {
      'id': deviceId,
      'bin_id': deviceId,
      'type': 'bin',
      'name': name,
      'location_description': locationDescription,
      'zone_id': zoneId,
      if (location != null) 'location': location,
    };
  }

  Map<String, dynamic> buildZonePayload(
    String deviceId,
    String name,
    String locationDescription,
  ) {
    return {
      'id': deviceId,
      'zone_id': deviceId,
      'type': 'zone',
      'name': name,
      'location_description': locationDescription,
    };
  }

  // ---------------- COMPLETE SETUP ---------------- //

  Future<void> completeSetup() async {
    if (!canFinishSetup) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Add at least 1 bin or zone first.")),
      );
      return;
    }

    final confirmed = await _confirmFinishSetup();
    if (!confirmed) return;

    if (!adminGoogleSetupDone &&
        await _isAdminEmailRegistered(adminEmail.text)) {
      if (!mounted) return;
      setState(() {});
      return;
    }

    final currentUser = FirebaseAuth.instance.currentUser;

    // Check if admin is set up (either via Google or manual email/password)
    bool hasAdmin = false;
    String? adminUid;
    String? adminEmailAddress;
    String adminName = 'Admin';

    // If user is logged in with Google, they are the admin
    if (currentUser != null) {
      hasAdmin = true;
      adminUid = currentUser.uid;
      adminEmailAddress = currentUser.email;
      adminName = currentUser.displayName ?? 'Admin';
    } else {
      // Check if manual admin email/password is set
      if (adminEmail.text.isEmpty || adminPassword.text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Please set up an admin account (email/password or Google).",
            ),
          ), // Explicitly return
        );
        return;
      }

      if (adminPassword.text != confirmPassword.text) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Passwords do not match")),
        ); // Explicitly return
        return;
      }
      hasAdmin = false;
    }

    setState(() => loading = true);

    try {
      // Only create admin account if not already signed in with Google
      if (!hasAdmin) {
        final adminCred = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(
              email: adminEmail.text.trim(),
              password: adminPassword.text.trim(),
            );

        adminUid = adminCred.user!.uid;
        adminEmailAddress = adminCred.user!.email;
        adminName = adminEmail.text.trim().split('@').first;
      } else {
        adminUid = adminGoogleUid ?? adminUid;
        adminName = adminGoogleName ?? adminName;
      }
      final workerPayloads = <SetupWorkerPayload>[];

      for (final worker in workers) {
        String workerUid = (worker.authUid ?? '').trim();
        if (workerUid.isEmpty) {
          workerUid = worker.email;
        }

        if (!worker.isGoogleAuth) {
          final workerPasswordValue = worker.password?.trim() ?? '';
          if (workerPasswordValue.isEmpty) {
            throw FirebaseAuthException(
              code: 'missing-worker-password',
              message: 'Worker password is missing for ${worker.email}.',
            );
          }

          FirebaseAuth? secondaryAuth;
          try {
            secondaryAuth = await _createSecondaryAuth();

            String? resolvedWorkerUid;
            try {
              final workerCredential = await secondaryAuth
                  .createUserWithEmailAndPassword(
                    email: worker.email,
                    password: workerPasswordValue,
                  );
              resolvedWorkerUid = workerCredential.user?.uid;
            } on FirebaseAuthException catch (e) {
              if (e.code != 'email-already-in-use') {
                rethrow;
              }

              try {
                final workerCredential = await secondaryAuth
                    .signInWithEmailAndPassword(
                      email: worker.email,
                      password: workerPasswordValue,
                    );
                resolvedWorkerUid = workerCredential.user?.uid;
              } on FirebaseAuthException catch (signInError) {
                debugPrint(
                  'Worker Firebase account already exists for ${worker.email}, '
                  'but the supplied password could not be verified (${signInError.code}). '
                  'Continuing setup with email fallback so MongoDB data is still saved.',
                );
              }
            }

            workerUid = resolvedWorkerUid ?? workerUid;
          } finally {
            await _disposeSecondaryAuth(secondaryAuth);
          }
        }

        if (workerUid.isEmpty) {
          throw FirebaseAuthException(
            code: 'invalid-worker-account',
            message: 'Unable to create a Firebase account for ${worker.email}.',
          );
        }

        workerPayloads.add(
          SetupWorkerPayload(
            localId: worker.localId,
            workerId: workerUid,
            firstName: worker.firstName,
            lastName: worker.lastName,
            dateOfBirth: worker.dateOfBirth,
            name: worker.name,
            phone: worker.phone,
            email: worker.email,
            profileImageUrl: '',
            photoBytes: worker.photoBytes,
          ),
        );
      }

      final binPayloads = <Map<String, dynamic>>[];
      final zonePayloads = <Map<String, dynamic>>[];

      for (final device in bins) {
        final deviceId = device['device_id'] as String;
        final type = device['type'] as String;
        final name = ((device['name'] as String?) ?? '').trim();
        final locationDescription =
            ((device['location_description'] as String?) ?? '').trim();

        if (type == 'zone') {
          zonePayloads.add(
            buildZonePayload(deviceId, name, locationDescription),
          );
        } else {
          binPayloads.add(
            buildBinPayload(
              deviceId,
              name,
              locationDescription,
              device['zone_id'] as String?,
              device['location'] as Map<String, dynamic>?,
            ),
          );
        }
      }

      await ApiService.completeSetup(
        admin: {
          'admin_id': adminUid,
          'first_name': _normalizeText(adminFirstName.text),
          'last_name': _normalizeText(adminLastName.text),
          'date_of_birth': adminDob.text.trim(),
          'phone': _normalizeCompact(adminPhoneController.text),
          'name': _joinedName(
            adminFirstName.text,
            adminLastName.text,
            adminName,
          ),
          'email': _normalizeCompact(adminEmailAddress ?? ''),
          'organization_location': _normalizeText(
            organizationLocationController.text,
          ),
          'location_lat': draft.selectedPlace?.latitude ?? 0.0,
          'location_lon': draft.selectedPlace?.longitude ?? 0.0,
          'profile_image_url': adminGooglePhotoUrl ?? '',
        },
        workers: workerPayloads,
        bins: binPayloads,
        zones: zonePayloads,
        adminPhotoBytes: adminPhotoBytes,
      );

      // Save persistent login
      if (!mounted) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastRole', 'admin');
      await prefs.setString('lastUid', adminUid!);

      if (!mounted) return;
      setState(() => loading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Setup completed successfully!")),
        );
      }

      // Navigate to AdminDashboard
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AdminDashboard()),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      if (e.code == "email-already-in-use") {
        final existingEmail = _normalizedEmail(adminEmail.text);
        setState(() {
          _registeredAdminEmail = existingEmail;
          _checkedAdminEmail = existingEmail;
          loading = false;
        });
        return;
      }
      setState(() => loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error: ${e.message}")));
      debugPrint('FirebaseAuthException: ${e.message}');
    } catch (e) {
      // Explicitly return
      setState(() => loading = false); // Explicitly return
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        // Explicitly return
        SnackBar(content: Text("Error: $e")),
      );
      debugPrint('Error during setup: $e');
    }
  }

  // ---------------- UI ---------------- //

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8E1),
      appBar: AppBar(
        backgroundColor: const Color(0xFF03A9F4),
        elevation: 0,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/logo.png',
                height: 32,
                width: 32,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'BinSight',
                  style: GoogleFonts.rubikMonoOne(
                    color: Colors.white,
                    fontSize: 18,
                  ),
                ),
                Text(
                  'Initial Setup',
                  style: GoogleFonts.titilliumWeb(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: widget.onBackToLogin,
            child: Text(
              '< Back to Login',
              style: bodyTextStyle.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Text(
              "1) ADMIN SETUP",
              style: GoogleFonts.rubikMonoOne(fontSize: 18),
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: ElevatedButton.icon(
                  onPressed: loading ? null : signInAdminWithGoogle,
                  icon: _googleIcon(),
                  label: Text(
                    "Setup Admin with Google",
                    style: bodyTextStyle.copyWith(fontWeight: FontWeight.bold),
                  ),
                  style: _setupButtonStyle(const Color(0xFFC8E6C9)),
                ),
              ),
            ),
            Center(
              child: Text(
                "OR",
                style: bodyTextStyle.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _requiredLabel("First Name"),
                      TextField(
                        controller: adminFirstName,
                        onChanged: (_) => setState(_syncDraft),
                        style: bodyTextStyle,
                        decoration: _textFieldDecoration("Admin First Name"),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _requiredLabel("Last Name"),
                      TextField(
                        controller: adminLastName,
                        onChanged: (_) => setState(_syncDraft),
                        style: bodyTextStyle,
                        decoration: _textFieldDecoration("Admin Last Name"),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _requiredLabel("Date of Birth"),
            TextField(
              controller: adminDob,
              readOnly: true,
              onTap: () => _pickDate(adminDob),
              style: bodyTextStyle,
              decoration: _textFieldDecoration(
                "Admin Date of Birth",
              ).copyWith(suffixIcon: const Icon(Icons.calendar_month)),
            ),
            const SizedBox(height: 10),
            _requiredLabel("Admin Phone Number"),
            TextField(
              controller: adminPhoneController,
              onChanged: (_) => setState(_syncDraft),
              style: bodyTextStyle,
              keyboardType: TextInputType.phone,
              decoration: _textFieldDecoration("Admin Phone Number"),
            ),
            const SizedBox(height: 10),
            adminGoogleSetupDone
                ? Text("Admin Email", style: bodyTextStyle)
                : _requiredLabel("Admin Email"),
            TextField(
              controller: adminEmail,
              readOnly: adminGoogleSetupDone,
              onChanged: (_) {
                adminEmail.value = adminEmail.value.copyWith(
                  text: _normalizeCompact(adminEmail.text),
                  selection: TextSelection.collapsed(
                    offset: _normalizeCompact(adminEmail.text).length,
                  ),
                );
                setState(() {
                  _scheduleAdminEmailCheck(adminEmail.text);
                  _syncDraft();
                });
              },
              style: bodyTextStyle,
              decoration: _textFieldDecoration(
                "Admin Email",
                showError:
                    _registeredAdminEmail == _normalizedEmail(adminEmail.text),
                errorText:
                    _registeredAdminEmail == _normalizedEmail(adminEmail.text)
                    ? "This email is already registered"
                    : null,
                hintText: _checkingAdminEmail ? "Checking email…" : null,
              ),
            ),
            const SizedBox(height: 10),
            adminGoogleSetupDone
                ? Text("Admin Password", style: bodyTextStyle)
                : _requiredLabel("Admin Password"),
            TextField(
              controller: adminPassword,
              enabled: !adminGoogleSetupDone,
              obscureText: true,
              onChanged: (_) {
                setState(_syncDraft);
              },
              style: bodyTextStyle,
              decoration: _textFieldDecoration("Admin Password"),
            ),
            const SizedBox(height: 10),

            adminGoogleSetupDone
                ? Text("Confirm Admin Password", style: bodyTextStyle)
                : _requiredLabel("Confirm Admin Password"),
            TextField(
              controller: confirmPassword,
              enabled: !adminGoogleSetupDone,
              obscureText: true,
              onChanged: (_) {
                setState(_syncDraft);
              },
              style: bodyTextStyle,
              decoration: _textFieldDecoration(
                "Confirm Admin Password",
                showError: !adminPasswordsMatch,
                errorText: !adminPasswordsMatch
                    ? "Passwords don't match"
                    : null,
              ),
            ),

            const SizedBox(height: 12),
            Row(
              children: [
                _photoPreview(adminPhotoBytes, imageUrl: adminGooglePhotoUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: loading ? null : _pickAdminPhoto,
                    icon: const Icon(Icons.upload),
                    label: Text(
                      "Upload Admin Photo",
                      style: bodyTextStyle.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: _setupButtonStyle(const Color(0xFFE3F2FD)),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 18),
            _sectionDivider(),
            Text(
              "2) ORGANIZATION LOCATION",
              style: GoogleFonts.rubikMonoOne(fontSize: 18),
            ),
            const SizedBox(height: 18),
            _requiredLabel("Organization Location"),
            const SizedBox(height: 12),
            TextField(
              controller: organizationLocationController,
              onChanged: _onOrganizationLocationChanged,
              style: bodyTextStyle,
              decoration: _textFieldDecoration(
                "Organization Location",
                hintText: "Type to search for a location",
              ).copyWith(prefixIcon: const Icon(Icons.search)),
            ),
            if (_organizationSearchLoading) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Searching locations...',
                    style: bodyTextStyle.copyWith(
                      fontSize: 14,
                      color: Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ],
            if (_organizationSuggestions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _organizationSuggestions.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final suggestion = _organizationSuggestions[index];
                    return ListTile(
                      leading: const Icon(Icons.place_outlined),
                      title: Text(
                        _organizationSuggestionLabel(suggestion),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: bodyTextStyle.copyWith(fontSize: 16),
                      ),
                      onTap: () => _selectOrganizationSuggestion(suggestion),
                    );
                  },
                ),
              ),
            ],
            if (draft.selectedPlace != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5FAFD),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFB3E5FC)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      draft.selectedPlace!.displayName,
                      style: bodyTextStyle.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Lat: ${draft.selectedPlace!.latitude.toStringAsFixed(6)}  Lon: ${draft.selectedPlace!.longitude.toStringAsFixed(6)}',
                      style: bodyTextStyle.copyWith(
                        fontSize: 14,
                        color: Colors.grey[700],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Validation for organization location
            if (organizationLocationController.text.trim().isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  "Organization/Location Name is required.",
                  style: bodyTextStyle.copyWith(
                    color: Colors.red,
                    fontSize: 14,
                  ),
                ),
              ),

            if (draft.selectedPlace != null && isAdminReadyForNextStep) ...[
              const SizedBox(height: 18),
              _sectionDivider(),
              Text(
                '3) ADD DEVICES (BINS)',
                style: GoogleFonts.rubikMonoOne(fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                'Scan the QR code on the device to register a bin.',
                style: bodyTextStyle,
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: canScanQr
                    ? () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QRScannerScreen(onScan: addBinFromQR),
                        ),
                      )
                    : null,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('SCAN QR CODE'),
                style: _setupButtonStyle(const Color(0xFF03A9F4)).copyWith(
                  foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
                ),
              ),
              if (loading) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
              ],
              if (_pendingBinRegistration) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _binNameController,
                  enabled: false,
                  decoration: _textFieldDecoration('Bin name').copyWith(
                    helperText: 'Auto-assigned and fixed by the system',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _binLocationController,
                  enabled: !loading,
                  onChanged: _onBinLocationChanged,
                  decoration: _textFieldDecoration(
                    'Search bin location',
                    hintText: 'Type an address or area',
                  ).copyWith(prefixIcon: const Icon(Icons.search)),
                ),
                if (_binLocationSearchLoading) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
                if (_binLocationSuggestions.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    constraints: const BoxConstraints(maxHeight: 180),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _binLocationSuggestions.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final suggestion = _binLocationSuggestions[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.place_outlined),
                          title: Text(
                            _organizationSuggestionLabel(suggestion),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _selectBinLocation(suggestion),
                        );
                      },
                    ),
                  ),
                if (_selectedBinPlace != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Selected: ${_selectedBinPlace!.displayName} (${_selectedBinPlace!.latitude.toStringAsFixed(5)}, ${_selectedBinPlace!.longitude.toStringAsFixed(5)})',
                    style: bodyTextStyle.copyWith(fontSize: 14),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: _binDetailsController,
                  enabled: !loading,
                  maxLength: 120,
                  decoration: _textFieldDecoration(
                    'Additional location details',
                  ).copyWith(helperText: 'For example: Floor 5, Room 407A'),
                ),
                const SizedBox(height: 12),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: _setupZonesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: LinearProgressIndicator(),
                      );
                    }
                    final zones = snapshot.data ?? const [];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Zone',
                              style: bodyTextStyle.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            if (zones.isEmpty)
                              TextButton.icon(
                                onPressed: loading ? null : _createSetupZone,
                                icon: const Icon(Icons.add),
                                label: const Text('Create Zone'),
                              ),
                          ],
                        ),
                        Text(
                          'Optional: Assign this bin to a zone/area.',
                          style: bodyTextStyle.copyWith(
                            fontSize: 14,
                            color: Colors.grey[700],
                          ),
                        ),
                        DropdownButtonFormField<String?>(
                          initialValue: _selectedBinZoneId,
                          decoration: _textFieldDecoration(
                            snapshot.hasError
                                ? 'Zone unavailable'
                                : 'Select zone',
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('No zone'),
                            ),
                            ...zones.map(
                              (zone) => DropdownMenuItem<String?>(
                                value: zone['zone_id']?.toString(),
                                child: Text(zone['name']?.toString() ?? 'Zone'),
                              ),
                            ),
                          ],
                          onChanged: loading
                              ? null
                              : (zoneId) =>
                                    setState(() => _selectedBinZoneId = zoneId),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton(
                      onPressed: loading ? null : _cancelPendingBinRegistration,
                      child: const Text('Cancel'),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: loading ? null : _registerPendingBin,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('ADD BIN'),
                    ),
                  ],
                ),
              ],
              if (bins
                  .where((device) => device['type'] == 'bin')
                  .isNotEmpty) ...[
                const SizedBox(height: 12),
                ...bins
                    .where((device) => device['type'] == 'bin')
                    .map(
                      (device) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: IconButton(
                          tooltip: 'Edit bin',
                          onPressed: loading
                              ? null
                              : () => _editRegisteredBin(device),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        title: Text(buildBinDisplayName(device)),
                        subtitle: Text(
                          'ID: ${device['bin_id'] ?? device['device_id'] ?? device['id'] ?? 'unknown'}',
                        ),
                        trailing: SizedBox(
                          width: 104,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                            onPressed: loading
                                ? null
                                : () => _confirmAndDeleteBin(device),
                            child: const Text(
                              'Delete',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                    ),
              ],
            ],

            const SizedBox(height: 18),
            _sectionDivider(),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final curved = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                );
                return FadeTransition(
                  opacity: curved,
                  child: SizeTransition(
                    sizeFactor: curved,
                    axisAlignment: -1,
                    child: child,
                  ),
                );
              },
              child:
                  isAdminReadyForNextStep &&
                      organizationLocationController.text.trim().isNotEmpty
                  ? Column(
                      key: const ValueKey('setup-sections'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "4) ADD WORKERS",
                          style: GoogleFonts.rubikMonoOne(fontSize: 18),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _requiredLabel("First Name"),
                                  TextField(
                                    controller: workerFirstName,
                                    onChanged: (_) => setState(_syncDraft),
                                    style: bodyTextStyle,
                                    decoration: _textFieldDecoration(
                                      "Worker First Name",
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _requiredLabel("Last Name"),
                                  TextField(
                                    controller: workerLastName,
                                    onChanged: (_) => setState(_syncDraft),
                                    style: bodyTextStyle,
                                    decoration: _textFieldDecoration(
                                      "Worker Last Name",
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        _requiredLabel("Date of Birth"),
                        TextField(
                          controller: workerDob,
                          readOnly: true,
                          onTap: () => _pickDate(workerDob),
                          style: bodyTextStyle,
                          decoration:
                              _textFieldDecoration(
                                "Worker Date of Birth",
                              ).copyWith(
                                suffixIcon: const Icon(Icons.calendar_month),
                              ),
                        ),
                        const SizedBox(height: 10),
                        _requiredLabel("Worker Phone Number"),
                        TextField(
                          controller: workerPhoneController,
                          onChanged: (_) => setState(_syncDraft),
                          style: bodyTextStyle,
                          keyboardType: TextInputType.phone,
                          decoration: _textFieldDecoration(
                            "Worker Phone Number",
                          ),
                        ),
                        const SizedBox(height: 10),
                        _requiredLabel("Worker Email"),
                        TextField(
                          controller: workerEmail,
                          onChanged: (_) {
                            workerEmail.value = workerEmail.value.copyWith(
                              text: _normalizeCompact(workerEmail.text),
                              selection: TextSelection.collapsed(
                                offset: _normalizeCompact(
                                  workerEmail.text,
                                ).length,
                              ),
                            );
                            setState(_syncDraft);
                          },
                          style: bodyTextStyle,
                          decoration: _textFieldDecoration("Worker Email"),
                        ),
                        const SizedBox(height: 10),
                        _requiredLabel("Worker Password"),
                        TextField(
                          controller: workerPassword,
                          obscureText: true,
                          onChanged: (_) {
                            workerPassword.value = workerPassword.value
                                .copyWith(
                                  text: _normalizeCompact(workerPassword.text),
                                  selection: TextSelection.collapsed(
                                    offset: _normalizeCompact(
                                      workerPassword.text,
                                    ).length,
                                  ),
                                );
                            setState(_syncDraft);
                          },
                          style: bodyTextStyle,
                          decoration: _textFieldDecoration("Worker Password"),
                        ),
                        const SizedBox(height: 10),
                        _requiredLabel("Confirm Worker Password"),
                        TextField(
                          controller: workerConfirmPassword,
                          obscureText: true,
                          onChanged: (_) {
                            workerConfirmPassword.value = workerConfirmPassword
                                .value
                                .copyWith(
                                  text: _normalizeCompact(
                                    workerConfirmPassword.text,
                                  ),
                                  selection: TextSelection.collapsed(
                                    offset: _normalizeCompact(
                                      workerConfirmPassword.text,
                                    ).length,
                                  ),
                                );
                            setState(_syncDraft);
                          },
                          style: bodyTextStyle,
                          decoration: _textFieldDecoration(
                            "Confirm Worker Password",
                            showError: !workerPasswordsMatch,
                            errorText: !workerPasswordsMatch
                                ? "Passwords don't match"
                                : null,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            _photoPreview(workerPhotoBytes),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: loading ? null : _pickWorkerPhoto,
                                icon: const Icon(Icons.upload),
                                label: Text(
                                  "Upload Worker Photo",
                                  style: bodyTextStyle.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: _setupButtonStyle(
                                  const Color(0xFFE3F2FD),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                onPressed: (!loading && isWorkerManualReady)
                                    ? addWorker
                                    : null,
                                style:
                                    _setupButtonStyle(
                                      const Color(0xFF03A9F4),
                                    ).copyWith(
                                      foregroundColor:
                                          WidgetStateProperty.all<Color>(
                                            Colors.white,
                                          ),
                                    ),
                                child: Text(
                                  "Add Worker",
                                  style: bodyTextStyle.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: workers.map((worker) {
                            ImageProvider? imageProvider;
                            if (worker.photoBytes != null) {
                              imageProvider = MemoryImage(worker.photoBytes!);
                            } else if (worker.googlePhotoUrl != null &&
                                worker.googlePhotoUrl!.isNotEmpty) {
                              imageProvider = NetworkImage(
                                worker.googlePhotoUrl!,
                              );
                            }

                            return Chip(
                              avatar: CircleAvatar(
                                backgroundImage: imageProvider,
                                child: imageProvider == null
                                    ? const Icon(Icons.person, size: 16)
                                    : null,
                              ),
                              label: Text(worker.name, style: bodyTextStyle),
                              onDeleted: () => removeWorker(worker),
                              deleteIcon: const Icon(Icons.close),
                            );
                          }).toList(),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),

            _sectionDivider(),

            ElevatedButton(
              onPressed: canFinishSetup ? completeSetup : null,
              style: _setupButtonStyle(const Color(0xFF03A9F4)).copyWith(
                foregroundColor: WidgetStateProperty.all<Color>(Colors.white),
              ),
              child: loading
                  ? const CircularProgressIndicator()
                  : Text(
                      "FINISH SETUP",
                      style: bodyTextStyle.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
            ),

            const SizedBox(height: 20),

            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    "OR",
                    style: bodyTextStyle.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 12),

            ElevatedButton(
              onPressed: widget.onBackToLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFB3E5FC),
                minimumSize: const Size(double.infinity, 58),
              ),
              child: Text(
                "LOGIN AS WORKER",
                style: GoogleFonts.rubikMonoOne(
                  fontSize: 14,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Extension for capitalizing strings
extension StringExtension on String {
  String capitalize() {
    return "${this[0].toUpperCase()}${substring(1).toLowerCase()}";
  }
}

// ---------------- QR SCANNER ---------------- //

class QRScannerScreen extends StatefulWidget {
  final Function(String) onScan;

  const QRScannerScreen({super.key, required this.onScan});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  bool _scanned = false;

  final MobileScannerController _scannerController = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  String? _extractQrValue(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      if (barcode.format != BarcodeFormat.qrCode &&
          barcode.format != BarcodeFormat.unknown) {
        continue;
      }

      final rawValue = barcode.rawValue?.trim();
      if (rawValue != null && rawValue.isNotEmpty) {
        return rawValue;
      }

      final displayValue = barcode.displayValue?.trim();
      if (displayValue != null && displayValue.isNotEmpty) {
        return displayValue;
      }
    }

    return null;
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR')),
      body: MobileScanner(
        controller: _scannerController,
        onDetect: (capture) {
          if (_scanned || !mounted) {
            return;
          }

          final raw = _extractQrValue(capture);
          if (raw != null) {
            // Pop the scanner before invoking the callback. Manage Devices
            // opens its registration dialog from that callback; invoking it
            // first would make this pop close the dialog instead of scanner.
            _scanned = true;
            final onScan = widget.onScan;
            Navigator.of(context).pop();
            Future<void>.delayed(Duration.zero, () => onScan(raw));
          }
        },
      ),
    );
  }
}
