import 'package:flutter/material.dart';
import '../../presentation/widgets/auth_scaffold.dart';
import '../../presentation/widgets/pill_text_field.dart';
import '../../../../shared/widgets/field_label.dart';
import '../../../../shared/widgets/round_arrow_button.dart';

class RegisterPage extends StatefulWidget {
  static const route = '/register';
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
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

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    // TODO: call your AuthService.signUp(...)
    await Future.delayed(const Duration(milliseconds: 900));

    if (!mounted) return;
    setState(() => _loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Registration completed (demo)')),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool obscure = true;
    return AuthScaffold(
      title: 'Registration',
      form: Form(
        key: _formKey,
        child: Column(
          children: [
            const FieldLabel('Put your username:'),
            PillTextField(
              controller: _userC,
              hint: 'username . . .',
              keyboardType: TextInputType.name,
              validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'Username required' : null,
            ),
            const SizedBox(height: 14),
            const FieldLabel('Put your e-mail:'),
            PillTextField(
              controller: _emailC,
              hint: 'e-mail . . .',
              keyboardType: TextInputType.emailAddress,
              validator: (v) {
                final value = v?.trim() ?? '';
                final regex = RegExp(r'^[\w\.\-]+@[\w\.\-]+\.[a-zA-Z]{2,}$');
                if (value.isEmpty) return 'E-mail required';
                if (!regex.hasMatch(value)) return 'Invalid e-mail';
                return null;
              },
            ),
            const SizedBox(height: 14),
            const FieldLabel('Put your password:'),
            StatefulBuilder(
              builder: (context, setLocal) {
                return PillTextField(
                  controller: _pwdC,
                  hint: 'password . . .',
                  obscureText: obscure,
                  validator: (v) =>
                  (v == null || v.length < 6) ? 'At least 6 characters' : null,
                  suffix: IconButton(
                    tooltip: obscure ? 'Show password' : 'Hide password',
                    icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setLocal(() => obscure = !obscure),
                  ),
                );
              },
            ),
            const SizedBox(height: 22),
            RoundArrowButton(
              onPressed: _loading ? null : _submit,
              loading: _loading,
              svgAsset: 'assets/icons/send_icon.svg',
              iconSize: 32,
              tooltip: 'Accedi',
              // svgColor: Colors.black,
            ),
          ],
        ),
      ),
      footer: Wrap(
        alignment: WrapAlignment.center,
        children: [
          Text(
            "You have already an account? ",
            style: TextStyle(
              color: Colors.black.withOpacity(0.85),
              fontWeight: FontWeight.w600,
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.pushReplacementNamed(context, '/login'),
            child: const Text(
              "Login now",
              style: TextStyle(
                decoration: TextDecoration.underline,
                fontWeight: FontWeight.w800,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }
}