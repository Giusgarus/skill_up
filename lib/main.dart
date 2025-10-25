import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Entry point for the app.
void main() => runApp(const SkillUpApp());

/// Root widget that wires routes and theme.
class SkillUpApp extends StatelessWidget {
  const SkillUpApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Use Google Fonts for a clean, modern look.
    final baseTextTheme = GoogleFonts.poppinsTextTheme();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SkillUp',
      theme: ThemeData(
        useMaterial3: true,
        textTheme: baseTextTheme,
      ),
      // Start on the Login page; you can change to '/register' if needed.
      initialRoute: '/login',
      routes: {
        '/login': (_) => const LoginPage(),
        '/register': (_) => const RegisterPage(),
      },
    );
  }
}

/// Reusable scaffold for auth pages (shared gradient background, layout, footer).
class AuthScaffold extends StatelessWidget {
  final String title;
  final Widget form;
  final String footerPrefix; // e.g., "You don’t have an account?"
  final String footerAction; // e.g., "Register now"
  final VoidCallback onFooterTap; // switch between Login/Register

  const AuthScaffold({
    super.key,
    required this.title,
    required this.form,
    required this.footerPrefix,
    required this.footerAction,
    required this.onFooterTap,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Gradient background matching the mockup.
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFF2A3B7), // soft pink
              Color(0xFFF6C789), // pale orange
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // App logo or fallback text.
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                      child: _Logo(),
                    ),
                    // Big title (LOGIN / REGISTRATION).
                    Text(
                      title.toUpperCase(),
                      style: GoogleFonts.bebasNeue(
                        fontSize: 40,
                        letterSpacing: 1.5,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    // The actual page form (injected by child pages).
                    form,
                    const SizedBox(height: 24),
                    // Footer with a link to toggle between pages.
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          footerPrefix,
                          style: TextStyle(
                            color: Colors.black.withOpacity(0.85),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: onFooterTap,
                          child: Text(
                            footerAction,
                            style: const TextStyle(
                              decoration: TextDecoration.underline,
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Logo widget:
/// - Tries to load assets/skillup.png
/// - If the asset is missing, falls back to a styled text "SkillUP".
class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/skillup.png',
      height: 88,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => Text(
        'SkillUP',
        style: GoogleFonts.bebasNeue(
          fontSize: 72,
          color: Colors.white,
          height: 1.0,
        ),
      ),
    );
  }
}

/// -------------------- LOGIN PAGE --------------------
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  // Form state key to validate inputs.
  final _formKey = GlobalKey<FormState>();

  // Controllers for text fields.
  final _emailC = TextEditingController();
  final _pwdC = TextEditingController();

  // Loading flag to show a progress indicator on the button.
  bool _loading = false;

  @override
  void dispose() {
    _emailC.dispose();
    _pwdC.dispose();
    super.dispose();
  }

  /// Fake submit just to show interaction; replace with your backend call.
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    // TODO: plug your real authentication (Firebase/Supabase/custom API).
    await Future.delayed(const Duration(milliseconds: 800));

    setState(() => _loading = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Login completed (demo)')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Login',
      footerPrefix: "You don’t have an account?",
      footerAction: "Register now",
      onFooterTap: () => Navigator.pushReplacementNamed(context, '/register'),
      form: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _FieldLabel(text: 'Put your e-mail:'),
            _EmailField(controller: _emailC),
            const SizedBox(height: 14),
            const _FieldLabel(text: 'Put your password:'),
            _PasswordField(controller: _pwdC),
            const SizedBox(height: 22),
            // Round arrow button
            Center(
              child: _RoundArrowButton(
                onPressed: _loading ? null : _submit,
                loading: _loading,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// -------------------- REGISTRATION PAGE --------------------
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();

  // Controllers for username, email, and password.
  final _userC = TextEditingController();
  final _emailC = TextEditingController();
  final _pwdC = TextEditingController();

  bool _loading = false;

  @override
  void dispose() {
    _userC.dispose();
    _emailC.dispose();
    _pwdC.dispose();
    super.dispose();
  }

  /// Fake submit just to show interaction; replace with your backend call.
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    // TODO: plug your real registration logic here.
    await Future.delayed(const Duration(milliseconds: 900));

    setState(() => _loading = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Registration completed (demo)')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Registration',
      footerPrefix: "You have already an account?",
      footerAction: "Login now",
      onFooterTap: () => Navigator.pushReplacementNamed(context, '/login'),
      form: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _FieldLabel(text: 'Put your username:'),
            _PillTextField(
              controller: _userC,
              hint: 'username . . .',
              keyboardType: TextInputType.name,
              validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'Username required' : null,
            ),
            const SizedBox(height: 14),
            const _FieldLabel(text: 'Put your e-mail:'),
            _EmailField(controller: _emailC),
            const SizedBox(height: 14),
            const _FieldLabel(text: 'Put your password:'),
            _PasswordField(controller: _pwdC),
            const SizedBox(height: 22),
            Center(
              child: _RoundArrowButton(
                onPressed: _loading ? null : _submit,
                loading: _loading,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small bold label above each input (matches the mockup style).
class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.left,
      style: TextStyle(
        fontWeight: FontWeight.w900,
        fontSize: 18,
        color: Colors.black.withOpacity(0.9),
      ),
    );
  }
}

/// Email field with basic validation.
/// Uses the pill-shaped input decorator.
class _EmailField extends StatelessWidget {
  final TextEditingController controller;
  const _EmailField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return _PillTextField(
      controller: controller,
      hint: 'e-mail . . .',
      keyboardType: TextInputType.emailAddress,
      validator: (v) {
        final value = v?.trim() ?? '';
        final regex = RegExp(r'^[\w\.\-]+@[\w\.\-]+\.[a-zA-Z]{2,}$');
        if (value.isEmpty) return 'E-mail required';
        if (!regex.hasMatch(value)) return 'Invalid e-mail';
        return null;
      },
    );
  }
}

/// Password field with show/hide toggle.
class _PasswordField extends StatefulWidget {
  final TextEditingController controller;
  const _PasswordField({required this.controller});

  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return _PillTextField(
      controller: widget.controller,
      hint: 'password . . .',
      obscureText: _obscure,
      validator: (v) {
        final value = v ?? '';
        if (value.isEmpty) return 'Password required';
        if (value.length < 6) return 'At least 6 characters';
        return null;
      },
      suffix: IconButton(
        onPressed: () => setState(() => _obscure = !_obscure),
        icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
        tooltip: _obscure ? 'Show password' : 'Hide password',
      ),
    );
  }
}

/// Generic pill-shaped TextFormField used across inputs.
class _PillTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscureText;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final Widget? suffix;

  const _PillTextField({
    required this.controller,
    required this.hint,
    this.obscureText = false,
    this.keyboardType,
    this.validator,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    // Invisible border + large radius = “pill” look.
    final border = OutlineInputBorder(
      borderSide: BorderSide.none,
      borderRadius: BorderRadius.circular(40),
    );

    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(fontWeight: FontWeight.w700),
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white.withOpacity(0.95),
        contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        border: border,
        enabledBorder: border,
        focusedBorder: border,
        suffixIcon: suffix,
      ),
    );
  }
}

/// Circular button with a right arrow.
/// Disabled when [onPressed] is null. Shows a loader if [loading] is true.
class _RoundArrowButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool loading;

  const _RoundArrowButton({required this.onPressed, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 74,
      height: 74,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          shape: const CircleBorder(),
          elevation: 3,
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
        ),
        child: loading
            ? const SizedBox(
            width: 26, height: 26, child: CircularProgressIndicator())
            : const Icon(Icons.chevron_right, size: 38),
      ),
    );
  }
}