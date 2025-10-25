import 'package:flutter/material.dart';
import '../../presentation/widgets/auth_scaffold.dart';
import '../../presentation/widgets/pill_text_field.dart';
import '../../../../shared/widgets/field_label.dart';
import '../../../../shared/widgets/round_arrow_button.dart';
import 'package:flutter_svg/flutter_svg.dart';

class LoginPage extends StatefulWidget {
  static const route = '/login';
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailC = TextEditingController();
  final _pwdC = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _emailC.dispose();
    _pwdC.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    // TODO: call your AuthService.signIn(...)
    await Future.delayed(const Duration(milliseconds: 800));

    if (!mounted) return;
    setState(() => _loading = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Login completed (demo)')));
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Login',
      form: Form(
        key: _formKey,
        child: Column(
          children: [
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
              // Local state only for obscuring toggle
              builder: (context, setLocal) {
                bool obscure = true;
                return PillTextField(
                  controller: _pwdC,
                  hint: 'password . . .',
                  obscureText: obscure,
                  validator: (v) =>
                  (v == null || v.isEmpty) ? 'Password required' : null,
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
            "You don’t have an account? ",
            style: TextStyle(
              color: Colors.black.withOpacity(0.85),
              fontWeight: FontWeight.w600,
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.pushReplacementNamed(context, '/register'),
            child: const Text(
              "Register now",
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