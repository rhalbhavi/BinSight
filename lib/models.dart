// Setup models for main.dart
import 'dart:typed_data'; // Handling image bytes during setup (admin and worker profile photos)

// PickedData class - holds location details from a place picker
class PickedData {
  final String displayName;
  final double latitude;
  final double longitude;
  PickedData({required this.displayName, required this.latitude, required this.longitude});
}

// SetupDraft singleton class - holds all the data during setup process before submission
class SetupDraft {
  static SetupDraft instance = SetupDraft._();
  SetupDraft._();

  String adminFirstName = '';
  String adminLastName = '';
  String adminDob = '';
  String adminEmail = '';
  String adminPhone = '';
  String adminPassword = '';
  String adminConfirmPassword = '';
  String organizationLocation = '';
  PickedData? selectedPlace;
  List<PendingWorkerSetup> workers = [];
  List<Map<String, dynamic>> bins = [];
  Uint8List? adminPhotoBytes;
  Uint8List? workerPhotoBytes;
  String? adminGoogleUid;
  String? adminGoogleName;
  String? adminGooglePhotoUrl;
  bool adminGoogleSetupDone = false;
  String workerFirstName = '';
  String workerLastName = '';
  String workerDob = '';
  String workerEmail = '';
  String workerPassword = '';
  String workerPhone = '';
  String workerConfirmPassword = '';
}

class PendingWorkerSetup {
  final String localId;
  final String email;
  final String name;
  final String phone;
  final String firstName;
  final String lastName;
  final String dateOfBirth;
  final String? password;
  final bool isGoogleAuth;
  final String? authUid;
  final Uint8List? photoBytes;
  final String? googlePhotoUrl;

  PendingWorkerSetup({
    required this.localId,
    required this.email,
    required this.name,
    required this.phone,
    required this.firstName,
    required this.lastName,
    required this.dateOfBirth,
    this.password,
    required this.isGoogleAuth,
    this.authUid,
    this.photoBytes,
    this.googlePhotoUrl,
  });
}
