import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../services/api_service.dart';

// -- Login Screen for Admins and Workers -- //
class LoginScreen extends StatefulWidget {
  final VoidCallback? onGoToAdminSetup;
  final String initialError;

  const LoginScreen({super.key, this.onGoToAdminSetup, this.initialError = ""});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const String incorrectCredentialsMessage = 'Incorrect credentials.';
  static const String fillFieldsMessage = 'Please fill out all fields.';

  bool isLoading = false;
  late String error;

  @override
  void initState() {
    super.initState();
    error = widget.initialError;
  }

  ButtonStyle _googleButtonStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFFC8E6C9),
      minimumSize: const Size(double.infinity, 50),
      padding: const EdgeInsets.symmetric(vertical: 14),
      textStyle: GoogleFonts.titilliumWeb(fontWeight: FontWeight.bold, fontSize: 18),
    );
  }

  Widget _googleIcon() {
    return const Icon(Icons.g_mobiledata, size: 28, color: Colors.black87);
  }

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        error = fillFieldsMessage;
      });
      return;
    }

    setState(() {
      isLoading = true;
      error = "";
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // AuthGate in main.dart will handle routing
    } on FirebaseAuthException catch (e) {
      final normalizedCode = e.code.toLowerCase();
      final isInvalidCredentials = normalizedCode.contains('wrong-password') ||
          normalizedCode.contains('user-not-found') ||
          normalizedCode.contains('invalid-email') ||
          normalizedCode.contains('invalid-credential') ||
          normalizedCode.contains('too-many-requests');

      setState(() {
        error = isInvalidCredentials ? incorrectCredentialsMessage : (e.message ?? 'Login failed');
      });
    }

    setState(() {
      isLoading = false;
    });
  }

  Future<void> loginWithGoogle() async {
    setState(() {
      isLoading = true;
      error = "";
    });

    try {
      print('Attempting Google sign-in...');
      // Always sign out before attempting to sign in, to ensure the Google account
      // selection popup is displayed.
      await FirebaseAuth.instance.signOut();

      if (kIsWeb) {
        final provider = GoogleAuthProvider()..setCustomParameters({'prompt': 'select_account'});
        print('Web: Calling signInWithPopup...');
        await FirebaseAuth.instance.signInWithPopup(provider);
      } else {
        print('Mobile: Initializing GoogleSignIn...');
        final googleSignIn = GoogleSignIn();
        try {
          await googleSignIn.disconnect();
        } catch (_) {
          try {
            await googleSignIn.signOut();
          } catch (_) {}
        }
        print('Mobile: Calling googleSignIn.signIn()...');
        final googleUser = await googleSignIn.signIn();

        if (googleUser == null) {
          if (!mounted) return;
          setState(() {
            error = incorrectCredentialsMessage;
            isLoading = false;
          });
          return;
        }
        print('Mobile: Google user obtained. Getting authentication...');
        final googleAuth = await googleUser.authentication;
        final credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );

        print('Mobile: Calling signInWithCredential...');

        await FirebaseAuth.instance.signInWithCredential(credential);
      }

      // AuthGate routes signed-in users using their registered backend role.
      final isSetupComplete = await ApiService.fetchSetupStatus();
      if (!isSetupComplete) {
        if (widget.onGoToAdminSetup != null) {
          widget.onGoToAdminSetup!();
          // Keep the authenticated session for the setup flow.
          return;
        }
        await FirebaseAuth.instance.signOut();
        if (!kIsWeb) {
          try {
            await GoogleSignIn().signOut();
          } catch (_) {}
        }
        if (!mounted) return;
        setState(() {
          error = 'BinSight setup is not complete. Only an admin can perform setup.';
          isLoading = false;
        });
        return;
      }

    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        print('FirebaseAuthException during Google login: $e');
        error = incorrectCredentialsMessage;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        print('Generic error during Google login: $e');
        error = incorrectCredentialsMessage;
      });
    }

    if (!mounted) return;
    setState(() {
      isLoading = false;
    });
  }

  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final forgotPasswordEmailController = TextEditingController();

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    forgotPasswordEmailController.dispose();
    super.dispose();
  }

  Future<void> _showForgotPasswordDialog(BuildContext context) async {
    forgotPasswordEmailController.text = emailController.text.trim(); // Pre-fill with login email

    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog( //
          title: Text("Forgot Password?", style: GoogleFonts.titilliumWeb(fontSize: 20)),
          content: TextField(
            controller: forgotPasswordEmailController,
            decoration: InputDecoration(labelText: "Enter your email", labelStyle: GoogleFonts.titilliumWeb(fontSize: 18)),
            keyboardType: TextInputType.emailAddress,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel", style: GoogleFonts.titilliumWeb(fontSize: 16)),
            ),
            ElevatedButton(
              onPressed: () async {
                try {
                  await FirebaseAuth.instance.sendPasswordResetEmail(
                    email: forgotPasswordEmailController.text.trim(),
                  );
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar( //
                    SnackBar(content: Text("Password reset link sent to your email.", style: GoogleFonts.titilliumWeb(fontSize: 16))),
                  );
                } on FirebaseAuthException catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar( //
                    SnackBar(content: Text("Error: ${e.message}", style: GoogleFonts.titilliumWeb(fontSize: 16))),
                  );
                }
              },
              child: const Text("Send Reset Link"),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,

      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.asset(
                  'assets/logo.png',
                  height: 80,
                  width: 80,
                ),
              ),
              const SizedBox(height: 10),

              Text(
                "BinSight",
                style: GoogleFonts.rubikMonoOne(
                  fontSize: 30,
                  color: Colors.black,
                ),
              ),

              const SizedBox(height: 40),

              // EMAIL
              TextField(
                controller: emailController,
                decoration: InputDecoration( //
                  labelText: "Email",
                  labelStyle: GoogleFonts.titilliumWeb(fontSize: 18),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),

              const SizedBox(height: 16),

              // PASSWORD
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: InputDecoration( //
                  labelText: "Password",
                  labelStyle: GoogleFonts.titilliumWeb(fontSize: 18),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),

              const SizedBox(height: 16),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: isLoading ? null : loginWithGoogle,
                  icon: _googleIcon(),
                  label: Text(
                    "Login with Google",
                    style: GoogleFonts.titilliumWeb(
                      color: Colors.black87,
                      fontWeight: FontWeight.bold, //
                      fontSize: 18,
                    ),
                  ),
                  style: _googleButtonStyle(),
                ),
              ),

              const SizedBox(height: 10),

              // FORGOT PASSWORD LINK
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: isLoading ? null : () => _showForgotPasswordDialog(context),
                  child: Text(
                    "Forgot Password?",
                    style: GoogleFonts.titilliumWeb(color: Colors.blue, fontSize: 16),
                  ),
                ),
              ),

              // LOGIN BUTTON
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isLoading ? null : login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    textStyle: GoogleFonts.titilliumWeb(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  child: isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          "LOGIN",
                        ),
                ),
              ),

              const SizedBox(height: 12),

              // ERROR MESSAGE
              if (error.isNotEmpty)
                Text(
                  error,
                  style: GoogleFonts.titilliumWeb(
                    color: Colors.red,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),

              const SizedBox(height: 20),

              // NOTE - Use the credentials provided by your admin
              Text(
                "Use the credentials provided by your admin",
                style: GoogleFonts.titilliumWeb(
                  fontSize: 14,
                  color: Colors.grey,
                ),
              ),

              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding( //
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text("OR", style: GoogleFonts.titilliumWeb(fontWeight: FontWeight.bold)),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: widget.onGoToAdminSetup ?? () {},
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB3E5FC),
                  foregroundColor: Colors.black87,
                  minimumSize: const Size(double.infinity, 58),
                  textStyle: GoogleFonts.titilliumWeb(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                child: const Text(
                  "Go to Admin Setup",
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
